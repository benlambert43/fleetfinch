import { app, BrowserWindow } from "electron";

import {
  type LogEntry,
  type LogGroup,
  type LogGroupInfo,
  logGroupLimit,
  type LogGroupState,
  type LogKind,
  type LogLine,
  logLineLimit,
  logsChannel,
  type LogsSnapshot,
  type LogSource,
  type LogsUpdate,
} from "@/logs.ts";

export interface LogWriter {
  log: (entry: LogEntry) => void;
  finish: (
    state: Exclude<LogGroupState, "running">,
    outcome: string | null,
  ) => void;
}

const flushDelayMs = 100;

const groups = new Map<string, LogGroup>();
const pendingGroups = new Map<string, LogGroupInfo>();
const pendingLines = new Map<string, LogLine[]>();
const pendingRemoved = new Set<string>();
let pendingDevices = false;
let canReadDevices = false;
let nextGroupId = 0;
let nextLineId = 0;
let seq = 0;
let flushTimer: NodeJS.Timeout | undefined;

function info({ lines: _lines, ...group }: LogGroup): LogGroupInfo {
  return group;
}

function flush(): void {
  clearTimeout(flushTimer);
  flushTimer = undefined;
  if (
    pendingGroups.size === 0 &&
    pendingLines.size === 0 &&
    pendingRemoved.size === 0 &&
    !pendingDevices
  ) {
    return;
  }
  seq += 1;
  const update: LogsUpdate = {
    seq,
    groups: [...pendingGroups.values()],
    lines: [...pendingLines].map(([id, lines]) => ({
      id,
      lines: lines.slice(-logLineLimit),
    })),
    removed: [...pendingRemoved],
    canReadDevices,
  };
  pendingGroups.clear();
  pendingLines.clear();
  pendingRemoved.clear();
  pendingDevices = false;
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed()) {
      window.webContents.send(logsChannel, update);
    }
  }
}

function scheduleFlush(): void {
  flushTimer ??= setTimeout(flush, flushDelayMs);
}

function changed(group: LogGroup): void {
  pendingGroups.set(group.id, info(group));
  scheduleFlush();
}

function prune(source: LogSource): void {
  const ofSource = [...groups.values()].filter(
    (group) => group.source === source,
  );
  const finished = ofSource.filter((group) => group.state !== "running");
  const extra = Math.max(0, ofSource.length - logGroupLimit);
  for (const { id } of finished.slice(0, extra)) {
    groups.delete(id);
    pendingGroups.delete(id);
    pendingLines.delete(id);
    pendingRemoved.add(id);
  }
}

export function openLogGroup(
  source: LogSource,
  title: string,
  detail: string | null = null,
): LogWriter {
  const group: LogGroup = {
    id: `${source}-${String(nextGroupId++)}`,
    source,
    title,
    detail,
    state: "running",
    outcome: null,
    startedAt: Date.now(),
    endedAt: null,
    written: 0,
    lines: [],
  };
  groups.set(group.id, group);
  prune(source);
  changed(group);
  return {
    log: ({ kind, text }) => {
      if (!groups.has(group.id)) {
        return;
      }
      const line: LogLine = { id: nextLineId++, at: Date.now(), kind, text };
      group.lines.push(line);
      if (group.lines.length > logLineLimit) {
        group.lines.shift();
      }
      group.written += 1;
      const pending = pendingLines.get(group.id);
      if (pending) {
        pending.push(line);
      } else {
        pendingLines.set(group.id, [line]);
      }
      changed(group);
    },
    finish: (state, outcome) => {
      group.state = state;
      group.outcome = outcome;
      group.endedAt = Date.now();
      changed(group);
    },
  };
}

export function readLogs(): LogsSnapshot {
  flush();
  return { seq, groups: [...groups.values()], canReadDevices };
}

export function setCanReadDevices(value: boolean): void {
  if (canReadDevices !== value) {
    canReadDevices = value;
    pendingDevices = true;
    scheduleFlush();
  }
}

export function describeError(error: unknown): string {
  if (error instanceof Error) {
    return error.stack ?? error.message;
  }
  return String(error);
}

const appLog = openLogGroup(
  "app",
  `${app.getName()} ${app.getVersion()}`,
  `Electron ${process.versions.electron} · ${process.platform} ${process.arch}`,
);

export function logApp(kind: LogKind, text: string): void {
  appLog.log({ kind, text });
}

export function logAppError(message: string, error?: unknown): void {
  console.error(message, ...(error === undefined ? [] : [error]));
  logApp(
    "error",
    error === undefined ? message : `${message}: ${describeError(error)}`,
  );
}
