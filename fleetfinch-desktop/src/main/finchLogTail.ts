import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { app } from "electron";
import { z } from "zod";

import { type Device, deviceDetails } from "@/devices.ts";
import type { ProcessResult } from "@/main/buildTools/process.ts";
import { connectionFailure, readDevices, sshFailed } from "@/main/devices.ts";
import { finchEntry, parseStoredLine } from "@/main/finchLogLines.ts";
import {
  describeError,
  logAppError,
  type LogWriter,
  openLogGroup,
  setDeviceTail,
} from "@/main/logs.ts";
import { followAsRoot, onPriorityChange, priorityRunning } from "@/main/ssh.ts";

const followSeconds = 60 * 60;
const firstLines = 200;
const batchLines = 500;
const syncMs = 10_000;
const againMs = 1000;
const retryMs = 5000;
const longestRetryMs = 60_000;
const missingRetryMs = 5 * 60_000;
const listenMs = 15_000;
const quietMs = 45_000;
const steadyMs = 60_000;
const checkAfterMs = [2, 5, 10, 20, 30].map((minutes) => minutes * 60_000);
const longestCheckMs = 30 * 60_000;
const missingCode = 127;
const tool = "finchlog";
const trailer = /^@@finchlog cursor=(\S*) more=[01] lines=\d+$/u;
const safeCursor = /^[\w.:,-]*$/u;
const notInstalled = /finchlog: (?:command )?not found/iu;

const settingsSchema = z.object({
  tail: z.boolean().optional(),
  refresh: z.boolean().optional(),
});

interface Tail {
  device: Device;
  group: LogWriter;
  cursor: string;
  session: AbortController | null;
  timer: NodeJS.Timeout | undefined;
  lastProblem: string | null;
  failures: number;
  closed: boolean;
  heard: number;
  awakeSince: number | null;
  quiet: boolean;
  checks: number;
  recheck: boolean;
}

const tails = new Map<string, Tail>();
let enabled = false;
let syncing = false;
let syncTimer: NodeJS.Timeout | undefined;

function settingsFile(): string {
  return path.join(app.getPath("userData"), "device-logs.json");
}

function publish(): void {
  setDeviceTail({ enabled, paused: enabled && priorityRunning() });
}

function followCommand(cursor: string): string {
  const from = cursor === "" ? "" : ` --cursor ${cursor}`;
  const lines = cursor === "" ? firstLines : batchLines;
  return `${tool} read --follow --for ${String(followSeconds)} --lines ${String(lines)}${from}`;
}

function problem(tail: Tail, text: string): void {
  if (text !== tail.lastProblem) {
    tail.lastProblem = text;
    tail.group.log({ kind: "error", text });
  }
}

function recovered(tail: Tail): void {
  tail.failures = 0;
  if (tail.lastProblem !== null) {
    tail.lastProblem = null;
    tail.group.log({ kind: "message", text: "Tailing the device again" });
  }
}

function heard(tail: Tail): void {
  tail.heard = Date.now();
  tail.awakeSince ??= tail.heard;
  if (tail.heard - tail.awakeSince >= steadyMs) {
    tail.checks = 0;
  }
  if (tail.quiet) {
    tail.quiet = false;
    tail.group.log({ kind: "message", text: "The device is awake again" });
  }
}

function takeRecheck(tail: Tail): boolean {
  const wanted = tail.recheck;
  tail.recheck = false;
  return wanted;
}

function listen(tail: Tail, session: AbortController): void {
  const silentMs = Date.now() - tail.heard;
  if (silentMs < quietMs) {
    return;
  }
  tail.awakeSince = null;
  if (!tail.quiet && tail.lastProblem === null) {
    tail.quiet = true;
    tail.group.log({
      kind: "message",
      text: "Nothing new from the device. It is probably asleep, and the tail carries on when it wakes.",
    });
  }
  if (silentMs >= (checkAfterMs[tail.checks] ?? longestCheckMs)) {
    tail.checks += 1;
    tail.recheck = true;
    session.abort();
  }
}

function take(tail: Tail, text: string): boolean {
  const cursor = trailer.exec(text)?.[1];
  if (cursor !== undefined) {
    if (safeCursor.test(cursor)) {
      tail.cursor = cursor;
    }
    recovered(tail);
    return true;
  }
  const tab = text.indexOf("\t");
  const line = tab === -1 ? null : parseStoredLine(text.slice(tab + 1));
  if (line === null) {
    return false;
  }
  recovered(tail);
  tail.group.log(finchEntry(line, text.slice(0, tab), false));
  return true;
}

function endedBadly(tail: Tail, result: ProcessResult): number {
  const name = tail.device.name ?? tail.device.address;
  if (result.code === missingCode || notInstalled.test(result.output)) {
    problem(
      tail,
      `Finch Logs is not installed on ${name}. Install its package from Devices and the tail starts by itself.`,
    );
    return missingRetryMs;
  }
  tail.failures += 1;
  if (!sshFailed(result)) {
    problem(tail, `Finch Logs on ${name} stopped answering.`);
  } else if (result.output.includes("Permission denied")) {
    problem(
      tail,
      "The device no longer accepts this computer's key. Add it again.",
    );
  } else {
    problem(tail, connectionFailure(tail.device.address, result).message);
  }
  return Math.min(longestRetryMs, retryMs * 2 ** (tail.failures - 1));
}

function followLater(tail: Tail, delayMs: number): void {
  clearTimeout(tail.timer);
  tail.timer = undefined;
  if (enabled && !tail.closed) {
    tail.timer = setTimeout(() => {
      tail.timer = undefined;
      void follow(tail);
    }, delayMs);
  }
}

async function follow(tail: Tail): Promise<void> {
  if (!enabled || tail.closed || tail.session !== null || priorityRunning()) {
    return;
  }
  const session = new AbortController();
  tail.session = session;
  tail.heard = Date.now();
  tail.awakeSince = null;
  tail.recheck = false;
  let delayMs = retryMs;
  const seen = { live: false };
  const listening = setInterval(() => {
    listen(tail, session);
  }, listenMs);
  try {
    const result = await followAsRoot(
      tail.device.address,
      followCommand(tail.cursor),
      (line) => {
        if (
          line.kind === "output" &&
          !session.signal.aborted &&
          take(tail, line.text)
        ) {
          seen.live = true;
          heard(tail);
        }
      },
      session.signal,
    );
    if (result.code === 0) {
      delayMs = againMs;
    } else if (!seen.live || !sshFailed(result)) {
      delayMs = endedBadly(tail, result);
    }
  } catch (error) {
    if (!session.signal.aborted) {
      tail.failures += 1;
      problem(tail, describeError(error));
    }
  } finally {
    clearInterval(listening);
    tail.session = null;
  }
  if (takeRecheck(tail)) {
    followLater(tail, 0);
  } else if (!session.signal.aborted) {
    followLater(tail, delayMs);
  }
}

function open(device: Device): Tail {
  const tail: Tail = {
    device,
    group: openLogGroup(
      "device",
      device.name ?? device.address,
      `${deviceDetails(device)} · Finch Logs over SSH`,
    ),
    cursor: "",
    session: null,
    timer: undefined,
    lastProblem: null,
    failures: 0,
    closed: false,
    heard: 0,
    awakeSince: null,
    quiet: false,
    checks: 0,
    recheck: false,
  };
  tail.group.log({
    kind: "message",
    text: "Tailing every log that Finch Logs keeps on this device",
  });
  tails.set(device.address, tail);
  return tail;
}

function close(tail: Tail, outcome: string, removed: boolean): void {
  tail.closed = true;
  clearTimeout(tail.timer);
  tail.session?.abort();
  tail.group.log({ kind: "message", text: outcome });
  tail.group.finish(removed ? "done" : "stopped", outcome);
  tails.delete(tail.device.address);
}

async function sync(): Promise<void> {
  const devices = await readDevices();
  if (!enabled) {
    return;
  }
  for (const tail of [...tails.values()]) {
    if (!devices.some((device) => device.address === tail.device.address)) {
      close(tail, "Removed from FleetFinch", true);
    }
  }
  for (const device of devices) {
    const saved = tails.get(device.address);
    if (saved === undefined) {
      void follow(open(device));
    } else {
      saved.device = device;
    }
  }
}

function syncNow(): void {
  clearTimeout(syncTimer);
  if (!enabled) {
    return;
  }
  if (syncing) {
    syncTimer = setTimeout(syncNow, syncMs);
    return;
  }
  syncing = true;
  void sync()
    .catch((error: unknown) => {
      logAppError("Tailing device logs over SSH failed", error);
    })
    .finally(() => {
      syncing = false;
      if (enabled) {
        syncTimer = setTimeout(syncNow, syncMs);
      }
    });
}

function pause(running: boolean): void {
  publish();
  if (!enabled) {
    return;
  }
  for (const tail of tails.values()) {
    tail.group.log({
      kind: "message",
      text: running ? "Paused while another SSH task runs" : "Resumed",
    });
    if (running) {
      clearTimeout(tail.timer);
      tail.timer = undefined;
      tail.session?.abort();
    } else {
      followLater(tail, 0);
    }
  }
}

function stop(outcome: string): void {
  clearTimeout(syncTimer);
  for (const tail of [...tails.values()]) {
    close(tail, outcome, false);
  }
}

export function retryDeviceLogTail(address: string): void {
  const tail = tails.get(address);
  if (tail === undefined || priorityRunning()) {
    return;
  }
  if (tail.session === null) {
    followLater(tail, 0);
  } else if (Date.now() - tail.heard >= quietMs) {
    tail.recheck = true;
    tail.session.abort();
  }
}

export async function setDeviceLogTail(value: boolean): Promise<void> {
  if (value === enabled) {
    return;
  }
  enabled = value;
  publish();
  if (value) {
    syncNow();
  } else {
    stop("Tail turned off");
  }
  await writeFile(settingsFile(), JSON.stringify({ tail: value }));
}

export async function watchFinchLogs(): Promise<void> {
  onPriorityChange(pause);
  const saved: unknown = await readFile(settingsFile(), "utf8")
    .then((text): unknown => JSON.parse(text))
    .catch(() => null);
  const parsed = settingsSchema.safeParse(saved);
  if (parsed.success && (parsed.data.tail ?? parsed.data.refresh ?? false)) {
    enabled = true;
    publish();
    syncNow();
  }
}

export function stopWatchingFinchLogs(): void {
  enabled = false;
  clearTimeout(syncTimer);
  for (const tail of tails.values()) {
    clearTimeout(tail.timer);
    tail.session?.abort();
  }
}
