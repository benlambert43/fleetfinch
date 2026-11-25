import { useSyncExternalStore } from "react";

import {
  type DeviceLogTail,
  keepLatest,
  type LogDumpImport,
  type LogGroup,
  type LogSource,
  type LogsUpdate,
} from "@/logs.ts";

export const logsHref = "#/logs";

interface Logs {
  groups: readonly LogGroup[];
  canReadDevices: boolean;
  deviceTail: DeviceLogTail;
  importing: boolean;
  imported: LogDumpImport | null;
  source: LogSource;
  selected: Record<LogSource, string | null>;
}

let logs: Logs = {
  groups: [],
  canReadDevices: false,
  deviceTail: { enabled: false, paused: false },
  importing: false,
  imported: null,
  source: "app",
  selected: { app: null, computer: null, device: null },
};
let seq: number | null = null;
let early: LogsUpdate[] = [];
const listeners = new Set<() => void>();

function emit(next: Logs): void {
  logs = next;
  for (const listener of listeners) {
    listener();
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getLogs(): Logs {
  return logs;
}

function getSource(): LogSource {
  return logs.source;
}

function apply(update: LogsUpdate): void {
  if (seq === null) {
    early.push(update);
    return;
  }
  if (update.seq <= seq) {
    return;
  }
  seq = update.seq;
  const removed = new Set(update.removed);
  const infos = new Map(update.groups.map((group) => [group.id, group]));
  const added = new Map(update.lines.map(({ id, lines }) => [id, lines]));
  const known = new Set(logs.groups.map((group) => group.id));
  const kept = logs.groups
    .filter((group) => !removed.has(group.id))
    .map((group) => {
      const info = infos.get(group.id);
      const lines = added.get(group.id);
      if (info === undefined && lines === undefined) {
        return group;
      }
      return {
        ...group,
        ...info,
        lines:
          lines === undefined ? group.lines : keepLatest(group.lines, lines),
      };
    });
  const created = [...infos.values()]
    .filter((info) => !known.has(info.id) && !removed.has(info.id))
    .map((info) => ({
      ...info,
      lines: keepLatest([], added.get(info.id) ?? []),
    }));
  emit({
    ...logs,
    canReadDevices: update.canReadDevices,
    deviceTail: update.deviceTail,
    groups: [...kept, ...created],
  });
}

function settle(): void {
  const waiting = early;
  early = [];
  for (const update of waiting) {
    apply(update);
  }
}

window.bridge.onLogs(apply);

export const logsLoaded: Promise<void> = window.bridge
  .getLogs()
  .then((snapshot) => {
    seq = snapshot.seq;
    emit({
      ...logs,
      groups: snapshot.groups,
      canReadDevices: snapshot.canReadDevices,
      deviceTail: snapshot.deviceTail,
    });
    settle();
  })
  .catch((error: unknown) => {
    console.error("The logs could not be loaded", error);
    seq = 0;
    settle();
  });

export function useLogs(): Logs {
  return useSyncExternalStore(subscribe, getLogs);
}

export function useLogSource(): LogSource {
  return useSyncExternalStore(subscribe, getSource);
}

export function setLogSource(source: LogSource): void {
  if (logs.source !== source) {
    emit({ ...logs, source });
  }
}

export function setDeviceTailEnabled(enabled: boolean): void {
  const previous = logs.deviceTail;
  emit({ ...logs, deviceTail: { ...previous, enabled } });
  window.bridge.setDeviceLogTail(enabled).catch((error: unknown) => {
    console.error("The device log tail setting could not be changed", error);
    emit({ ...logs, deviceTail: previous });
  });
}

export function importLogDump(address: string | null): void {
  if (logs.importing) {
    return;
  }
  emit({ ...logs, importing: true, imported: null });
  void window.bridge
    .importLogDump(address)
    .catch((error: unknown): LogDumpImport => ({
      state: "failed",
      message: error instanceof Error ? error.message : String(error),
    }))
    .then((result) => {
      const first = result.state === "imported" ? result.first : null;
      emit({
        ...logs,
        importing: false,
        imported: result.state === "canceled" ? null : result,
        selected:
          first === null ? logs.selected : { ...logs.selected, device: first },
      });
    });
}

export function selectLogGroup(source: LogSource, id: string): void {
  emit({ ...logs, selected: { ...logs.selected, [source]: id } });
}

export function showLogs(source: LogSource): void {
  emit({ ...logs, source, selected: { ...logs.selected, [source]: null } });
}
