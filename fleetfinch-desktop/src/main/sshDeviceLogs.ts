import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { stripVTControlCharacters } from "node:util";

import { app } from "electron";
import { z } from "zod";

import { type Device, deviceDetails } from "@/devices.ts";
import type { ProcessResult } from "@/main/buildTools/process.ts";
import { errorLine } from "@/main/deviceLogs.ts";
import { connectionFailure, readDevices, sshFailed } from "@/main/devices.ts";
import {
  describeError,
  logAppError,
  type LogWriter,
  openLogGroup,
  setSshRefresh,
} from "@/main/logs.ts";
import { onPriorityChange, priorityRunning, runAsRoot } from "@/main/ssh.ts";

const refreshMs = 5000;
const logFile = "/var/log/syslog";
const firstLines = 100;
const batchLines = 200;
const missingMarker = "fleetfinch-log=missing";
const headerLine = /^fleetfinch-log=(\d+) (\d+)$/m;
const missingLog = `The device has no ${logFile}. Install “syslogd to /var/log/syslog” from Cydia, then restart the device.`;

const settingsSchema = z.object({ refresh: z.boolean() });

interface Reader {
  group: LogWriter;
  offset: number;
  lastProblem: string | null;
}

const readers = new Map<string, Reader>();
let enabled = false;
let refreshing = false;
let timer: NodeJS.Timeout | undefined;
let reading: AbortController | null = null;

function settingsFile(): string {
  return path.join(app.getPath("userData"), "device-logs.json");
}

function publish(): void {
  setSshRefresh({ enabled, paused: enabled && priorityRunning() });
}

function readCommand(offset: number): string {
  return [
    `f=${logFile}`,
    `if [ ! -r "$f" ]; then echo ${missingMarker}; exit 0; fi`,
    `total=$(($(wc -l < "$f")))`,
    `start=${String(offset)}`,
    `if [ "$start" -lt 0 ] || [ "$start" -gt "$total" ]; then start=$((total > ${String(firstLines)} ? total - ${String(firstLines)} : 0)); fi`,
    `count=$((total - start > ${String(batchLines)} ? ${String(batchLines)} : total - start))`,
    `tail -n +$((start + 1)) "$f" 2>/dev/null | head -n "$count"`,
    String.raw`printf '\nfleetfinch-log=%s %s\n' "$start" "$count"`,
  ].join("\n");
}

function readerFor(device: Device): Reader {
  const saved = readers.get(device.address);
  if (saved !== undefined) {
    return saved;
  }
  const reader: Reader = {
    group: openLogGroup(
      "device",
      device.name ?? device.address,
      `${deviceDetails(device)} · over SSH`,
    ),
    offset: -1,
    lastProblem: null,
  };
  reader.group.log({
    kind: "message",
    text: `Reading ${logFile} every ${String(refreshMs / 1000)} seconds`,
  });
  readers.set(device.address, reader);
  return reader;
}

function problem(reader: Reader, text: string): void {
  if (text !== reader.lastProblem) {
    reader.lastProblem = text;
    reader.group.log({ kind: "error", text });
  }
}

function readProblem(address: string, result: ProcessResult): string {
  if (!sshFailed(result)) {
    return "Could not read the device's log.";
  }
  return result.output.includes("Permission denied")
    ? "The device no longer accepts this computer's key. Add it again."
    : connectionFailure(address, result).message;
}

function showLines(reader: Reader, output: string): boolean {
  const header = headerLine.exec(output);
  if (header === null) {
    return false;
  }
  const start = Number(header[1]);
  const count = Number(header[2]);
  const lines = output.slice(0, header.index).split("\n").slice(0, count);
  if (reader.lastProblem !== null) {
    reader.lastProblem = null;
    reader.group.log({
      kind: "message",
      text: "Reading the device's log again",
    });
  }
  for (const line of lines) {
    const text = stripVTControlCharacters(line).trimEnd();
    if (text !== "") {
      reader.group.log({
        kind: errorLine.test(text) ? "error" : "output",
        text,
      });
    }
  }
  reader.offset = start + count;
  return true;
}

async function readDevice(device: Device): Promise<void> {
  const reader = readerFor(device);
  const controller = new AbortController();
  reading = controller;
  try {
    const result = await runAsRoot(
      device.address,
      readCommand(reader.offset),
      undefined,
      controller.signal,
    );
    if (result.output.includes(missingMarker)) {
      problem(reader, missingLog);
    } else if (!showLines(reader, result.output)) {
      problem(reader, readProblem(device.address, result));
    }
  } catch (error) {
    if (!controller.signal.aborted) {
      problem(reader, describeError(error));
    }
  } finally {
    if (reading === controller) {
      reading = null;
    }
  }
}

function forgetRemoved(devices: readonly Device[]): void {
  for (const [address, reader] of readers) {
    if (!devices.some((device) => device.address === address)) {
      reader.group.log({ kind: "message", text: "Removed from FleetFinch" });
      reader.group.finish("done", "Removed");
      readers.delete(address);
    }
  }
}

async function refresh(): Promise<void> {
  const devices = await readDevices();
  forgetRemoved(devices);
  for (const device of devices) {
    if (!enabled || priorityRunning()) {
      return;
    }
    await readDevice(device);
  }
}

function refreshLater(delayMs = refreshMs): void {
  clearTimeout(timer);
  if (enabled) {
    timer = setTimeout(refreshNow, delayMs);
  }
}

function refreshNow(): void {
  if (refreshing || priorityRunning()) {
    refreshLater();
    return;
  }
  refreshing = true;
  void refresh()
    .catch((error: unknown) => {
      logAppError("Refreshing device logs over SSH failed", error);
    })
    .finally(() => {
      refreshing = false;
      refreshLater();
    });
}

function pause(running: boolean): void {
  publish();
  if (!enabled) {
    return;
  }
  if (running) {
    reading?.abort();
  }
  for (const reader of readers.values()) {
    reader.group.log({
      kind: "message",
      text: running ? "Paused while another SSH task runs" : "Resumed",
    });
  }
  if (!running && !refreshing) {
    refreshLater(0);
  }
}

function stopReaders(outcome: string): void {
  for (const reader of readers.values()) {
    reader.group.log({ kind: "message", text: outcome });
    reader.group.finish("stopped", outcome);
  }
  readers.clear();
}

export async function setDeviceLogRefresh(value: boolean): Promise<void> {
  if (value === enabled) {
    return;
  }
  enabled = value;
  publish();
  if (value) {
    refreshLater(0);
  } else {
    clearTimeout(timer);
    reading?.abort();
    stopReaders("Refresh turned off");
  }
  await writeFile(settingsFile(), JSON.stringify({ refresh: value }));
}

export async function watchSshDevices(): Promise<void> {
  onPriorityChange(pause);
  const saved: unknown = await readFile(settingsFile(), "utf8")
    .then((text): unknown => JSON.parse(text))
    .catch(() => null);
  const parsed = settingsSchema.safeParse(saved);
  if (parsed.success && parsed.data.refresh) {
    enabled = true;
    publish();
    refreshLater(0);
  }
}

export function stopWatchingSshDevices(): void {
  enabled = false;
  clearTimeout(timer);
  reading?.abort();
}
