import { spawn } from "node:child_process";

import { exists, isExecutable } from "@/main/buildTools/paths.ts";
import {
  commandText,
  readLines,
  runProcess,
} from "@/main/buildTools/process.ts";
import {
  logAppError,
  type LogWriter,
  openLogGroup,
  setCanReadDevices,
} from "@/main/logs.ts";

const deviceIdFile = "/usr/bin/idevice_id";
const deviceInfoFile = "/usr/bin/ideviceinfo";
const syslogFile = "/usr/bin/idevicesyslog";
const usbmuxdSocket = "/var/run/usbmuxd";
const pollMs = 2000;
const retryMs = 5000;
const udidPattern = /^[\dA-Fa-f-]{24,40}$/;
const infoLine = /^(\w+): (.*)$/;
const connectedPrefix = "[connected:";
const disconnectedPrefix = "[disconnected:";
const failedLine = /^(?:ERROR:|Could not start logger)/;
export const errorLine = /^\w{3} [^<]*\] <(?:Error|Fault)>:/;

interface Reader {
  udid: string;
  args: string[];
  group: LogWriter;
  stop: (() => void) | null;
  connected: boolean;
  started: boolean;
  lastProblem: string | null;
  retryAt: number;
}

const readers = new Map<string, Reader>();
let watching = false;
let timer: NodeJS.Timeout | undefined;
let relayOptions: Promise<string[]> | null = null;

async function canReadDevices(): Promise<boolean> {
  const tools = await Promise.all([deviceIdFile, syslogFile].map(isExecutable));
  return tools.every(Boolean);
}

async function connectedDevices(): Promise<string[]> {
  if (!(await exists(usbmuxdSocket))) {
    return [];
  }
  const { code, output } = await runProcess(deviceIdFile, ["-l"], {
    timeoutMs: 10_000,
  }).catch(() => ({ code: null, output: "" }));
  if (code !== 0) {
    return [];
  }
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter((udid) => udidPattern.test(udid));
}

async function describeDevice(
  udid: string,
): Promise<{ title: string; detail: string }> {
  const { code, output } = await runProcess(
    deviceInfoFile,
    ["-u", udid, "-s"],
    { timeoutMs: 10_000 },
  ).catch(() => ({ code: null, output: "" }));
  const values = new Map<string, string>();
  for (const line of code === 0 ? output.split("\n") : []) {
    const [, key, value] = infoLine.exec(line.trim()) ?? [];
    if (key !== undefined && value !== undefined) {
      values.set(key, value);
    }
  }
  const version = values.get("ProductVersion");
  return {
    title: values.get("DeviceName") ?? "iOS device",
    detail: [
      values.get("ProductType"),
      version === undefined ? undefined : `iOS ${version}`,
      udid,
    ]
      .filter((part) => part !== undefined)
      .join(" · "),
  };
}

function syslogRelayOptions(): Promise<string[]> {
  relayOptions ??= runProcess(syslogFile, ["--help"], { timeoutMs: 10_000 })
    .then(({ output }) =>
      output.includes("--syslog-relay") ? ["--syslog-relay"] : [],
    )
    .catch(() => []);
  return relayOptions;
}

function problem(reader: Reader, text: string): void {
  if (text !== reader.lastProblem) {
    reader.lastProblem = text;
    reader.group.log({ kind: "error", text });
  }
}

function startReader(reader: Reader): void {
  if (!reader.started) {
    reader.started = true;
    reader.group.log({
      kind: "command",
      text: commandText(syslogFile, reader.args),
    });
  }
  const child = spawn(syslogFile, reader.args, {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let ignoring = false;
  const stop = () => {
    ignoring = true;
    child.kill();
  };
  const ended = () => {
    if (reader.stop === stop) {
      reader.stop = null;
      reader.connected = false;
      reader.retryAt = Date.now() + retryMs;
    }
  };
  reader.stop = stop;
  readLines(child.stdout, (text) => {
    if (ignoring || text.startsWith(disconnectedPrefix)) {
      return;
    }
    if (text.startsWith(connectedPrefix)) {
      reader.connected = true;
      reader.lastProblem = null;
      reader.group.log({ kind: "message", text: "Reading the device's log" });
      return;
    }
    reader.group.log({ kind: errorLine.test(text) ? "error" : "output", text });
  });
  readLines(child.stderr, (text) => {
    if (ignoring) {
      return;
    }
    if (!reader.connected && failedLine.test(text)) {
      const first = reader.lastProblem === null;
      problem(reader, text);
      if (first) {
        reader.group.log({
          kind: "message",
          text: `Unlock the device, and tap Trust if it asks whether to trust this computer. Trying again every ${String(retryMs / 1000)} seconds.`,
        });
      }
      stop();
      return;
    }
    if (text !== reader.lastProblem) {
      reader.lastProblem = text;
      reader.group.log({ kind: "message", text });
    }
  });
  child.on("error", (error) => {
    problem(reader, `${syslogFile} could not start: ${error.message}`);
    ended();
  });
  child.on("close", ended);
}

function disconnect(reader: Reader): void {
  reader.stop?.();
  readers.delete(reader.udid);
  reader.group.log({ kind: "message", text: "Disconnected" });
  reader.group.finish("done", "Disconnected");
}

async function connect(udid: string): Promise<void> {
  const { title, detail } = await describeDevice(udid);
  const options = await syslogRelayOptions();
  if (!watching) {
    return;
  }
  const reader: Reader = {
    udid,
    args: ["-u", udid, "-x", ...options],
    group: openLogGroup("device", title, detail),
    stop: null,
    connected: false,
    started: false,
    lastProblem: null,
    retryAt: 0,
  };
  readers.set(udid, reader);
  startReader(reader);
}

async function poll(): Promise<void> {
  const available = await canReadDevices();
  setCanReadDevices(available);
  const present = new Set(available ? await connectedDevices() : []);
  for (const reader of readers.values()) {
    if (!present.has(reader.udid)) {
      disconnect(reader);
    }
  }
  for (const udid of present) {
    const reader = readers.get(udid);
    if (reader === undefined) {
      await connect(udid);
    } else if (reader.stop === null && Date.now() >= reader.retryAt) {
      startReader(reader);
    }
  }
}

function pollNow(): void {
  void poll()
    .catch((error: unknown) => {
      logAppError("Looking for connected devices failed", error);
    })
    .finally(pollLater);
}

function pollLater(): void {
  if (watching) {
    timer = setTimeout(pollNow, pollMs);
  }
}

export function watchDevices(): void {
  if (!watching) {
    watching = true;
    pollNow();
  }
}

export function stopWatchingDevices(): void {
  watching = false;
  clearTimeout(timer);
  for (const reader of readers.values()) {
    reader.stop?.();
  }
}
