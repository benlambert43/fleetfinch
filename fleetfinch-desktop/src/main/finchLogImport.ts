import { rm } from "node:fs/promises";
import path from "node:path";

import { app, type BrowserWindow, dialog } from "electron";

import type { Device } from "@/devices.ts";
import { type LogDumpImport, logLineLimit } from "@/logs.ts";
import { connectionFailure, noSsh, savedDevice } from "@/main/devices.ts";
import {
  finchEntry,
  finchLogTitle,
  finchLogTitles,
  finchSnapshotTitles,
  parseStoredLine,
} from "@/main/finchLogLines.ts";
import { type LogDump, readLogDump } from "@/main/logDump.ts";
import {
  describeError,
  flushLogs,
  type LogWriter,
  openLogGroup,
} from "@/main/logs.ts";
import {
  awake,
  hasSsh,
  saveAsRoot,
  sshFailedCode,
  withPriority,
} from "@/main/ssh.ts";

const copyTimeoutMs = 30 * 60_000;
const missingCode = 127;
const dumpCommand = "finchlog dump --gzip";
const notInstalled = /finchlog: (?:command )?not found/iu;
const unsafeName = /[^\w.-]+/gu;
const fileFilters = [
  { name: "Finch Logs Dump", extensions: ["gz", "tgz", "tar"] },
];

let importing = false;

function fileStamp(): string {
  const now = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  const day = [now.getFullYear(), now.getMonth() + 1, now.getDate()]
    .map(pad)
    .join("-");
  return `${day}-${pad(now.getHours())}${pad(now.getMinutes())}`;
}

function formatBytes(bytes: number): string {
  const megabytes = bytes / (1024 * 1024);
  return megabytes >= 1
    ? `${megabytes.toFixed(1)} MB`
    : `${String(Math.max(1, Math.round(bytes / 1024)))} KB`;
}

function streamOrder(stream: string): number {
  const index = Object.keys(finchLogTitles).indexOf(stream);
  return index === -1 ? Number.MAX_SAFE_INTEGER : index;
}

function show(dump: LogDump, from: string, file: string): LogDumpImport {
  const made = dump.details.Made?.replace("T", " ").slice(0, 19) ?? null;
  const detail = [from, made === null ? null : `dump made ${made}`]
    .filter((part) => part !== null)
    .join(" · ");
  const snapshots = dump.snapshots.toSorted((first, second) =>
    (finchSnapshotTitles[first.kind] ?? first.kind).localeCompare(
      finchSnapshotTitles[second.kind] ?? second.kind,
    ),
  );
  const logs = dump.logs.toSorted(
    (first, second) => streamOrder(first.stream) - streamOrder(second.stream),
  );
  let lines = 0;
  let first: string | null = null;
  const finish = (group: LogWriter, shown: number, total: number) => {
    lines += shown;
    group.finish(
      "done",
      shown < total
        ? `Showing ${shown.toLocaleString()} of ${total.toLocaleString()} lines; the file has them all`
        : `Imported ${shown.toLocaleString()} lines`,
    );
    flushLogs();
  };
  for (const snapshot of snapshots.toReversed()) {
    const group = openLogGroup(
      "device",
      `Snapshot: ${finchSnapshotTitles[snapshot.kind] ?? snapshot.kind}`,
      detail,
    );
    for (const text of snapshot.lines) {
      group.log({ kind: "output", text: text === "" ? " " : text });
    }
    finish(group, snapshot.lines.length, snapshot.total);
  }
  for (const log of logs.toReversed()) {
    const group = openLogGroup("device", finchLogTitle(log.stream), detail);
    for (const text of log.lines) {
      const line = parseStoredLine(text);
      group.log(
        line === null ? { kind: "output", text } : finchEntry(line, null, true),
      );
    }
    finish(group, log.lines.length, log.total);
    first = group.id;
  }
  return {
    state: "imported",
    from,
    file,
    logs: logs.length,
    snapshots: snapshots.length,
    lines,
    first,
  };
}

async function readAndShow(
  file: string,
  from: string | null,
  task: LogWriter,
): Promise<LogDumpImport> {
  task.log({ kind: "step", text: "Reading the dump" });
  const dump = await readLogDump(file, logLineLimit);
  const result = show(dump, from ?? dump.details.Device ?? "A log dump", file);
  if (result.state === "imported") {
    task.log({
      kind: "message",
      text: `Read ${String(dump.files)} files: ${String(result.logs)} logs and ${String(result.snapshots)} snapshots are now under Device`,
    });
  }
  return result;
}

async function copyFromDevice(
  window: BrowserWindow,
  device: Device,
): Promise<LogDumpImport> {
  const name = device.name ?? device.address;
  if (!(await hasSsh())) {
    return { state: "failed", message: noSsh };
  }
  const { canceled, filePath } = await dialog.showSaveDialog(window, {
    title: `Save the Logs from ${name}`,
    defaultPath: path.join(
      app.getPath("documents"),
      `${name.replaceAll(unsafeName, "-")}-logs-${fileStamp()}.tar.gz`,
    ),
    filters: fileFilters,
  });
  if (canceled || filePath === "") {
    return { state: "canceled" };
  }
  const task = openLogGroup("computer", `Import logs from ${name}`, filePath);
  const fail = (message: string): LogDumpImport => {
    task.log({ kind: "error", text: message });
    task.finish("failed", message);
    return { state: "failed", message };
  };
  const discard = async (message: string): Promise<LogDumpImport> => {
    await rm(filePath, { force: true });
    return fail(message);
  };
  task.log({ kind: "step", text: "Copying the logs from the device" });
  const copied = await withPriority(() =>
    awake(device.address, () =>
      saveAsRoot(
        device.address,
        dumpCommand,
        filePath,
        (line) => {
          task.log(line);
        },
        copyTimeoutMs,
      ),
    ),
  ).catch((error: unknown) => describeError(error));
  if (typeof copied === "string") {
    return discard(copied);
  }
  if (copied.code === missingCode || notInstalled.test(copied.errors)) {
    return discard(
      `Finch Logs is not installed on ${name}. Install its package from Devices first.`,
    );
  }
  if (copied.code === null || copied.code === sshFailedCode) {
    return discard(
      connectionFailure(device.address, {
        code: copied.code,
        output: copied.errors,
      }).message,
    );
  }
  if (copied.code !== 0 || copied.bytes === 0) {
    return discard(`${name} could not put its logs together.`);
  }
  task.log({
    kind: "message",
    text: `Copied ${formatBytes(copied.bytes)} to ${filePath}`,
  });
  try {
    const result = await readAndShow(filePath, name, task);
    task.finish("done", "Imported");
    return result;
  } catch (error) {
    const reason =
      error instanceof Error ? error.message : describeError(error);
    return fail(`The logs were copied, but could not be read. ${reason}`);
  }
}

async function openFile(window: BrowserWindow): Promise<LogDumpImport> {
  const { canceled, filePaths } = await dialog.showOpenDialog(window, {
    title: "Open a Log Dump",
    defaultPath: app.getPath("documents"),
    properties: ["openFile"],
    filters: fileFilters,
  });
  const [file] = filePaths;
  if (canceled || file === undefined) {
    return { state: "canceled" };
  }
  const task = openLogGroup("computer", "Import a log dump", file);
  try {
    const result = await readAndShow(file, null, task);
    task.finish("done", "Imported");
    return result;
  } catch (error) {
    const message =
      error instanceof Error ? error.message : describeError(error);
    task.log({ kind: "error", text: message });
    task.finish("failed", message);
    return { state: "failed", message };
  }
}

export async function importLogDump(
  window: BrowserWindow,
  address: string | null,
): Promise<LogDumpImport> {
  if (importing) {
    return { state: "failed", message: "Another import is still running." };
  }
  importing = true;
  try {
    if (address === null) {
      return await openFile(window);
    }
    const device = await savedDevice(address);
    return device === null
      ? { state: "failed", message: "This device is no longer added." }
      : await copyFromDevice(window, device);
  } finally {
    importing = false;
  }
}
