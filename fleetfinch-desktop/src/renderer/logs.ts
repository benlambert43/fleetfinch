import { useSyncExternalStore } from "react";

import {
  keepLatest,
  type LogGroup,
  type LogSource,
  type LogsUpdate,
  type SshLogRefresh,
} from "@/logs.ts";

export const logsHref = "#/logs";

interface Logs {
  groups: readonly LogGroup[];
  canReadDevices: boolean;
  sshRefresh: SshLogRefresh;
  source: LogSource;
  selected: Record<LogSource, string | null>;
}

let logs: Logs = {
  groups: [],
  canReadDevices: false,
  sshRefresh: { enabled: false, paused: false },
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
    sshRefresh: update.sshRefresh,
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
      sshRefresh: snapshot.sshRefresh,
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

export function setSshRefreshEnabled(enabled: boolean): void {
  const previous = logs.sshRefresh;
  emit({ ...logs, sshRefresh: { ...previous, enabled } });
  window.bridge.setDeviceLogRefresh(enabled).catch((error: unknown) => {
    console.error("The device log refresh setting could not be changed", error);
    emit({ ...logs, sshRefresh: previous });
  });
}

export function selectLogGroup(source: LogSource, id: string): void {
  emit({ ...logs, selected: { ...logs.selected, [source]: id } });
}

export function showLogs(source: LogSource): void {
  emit({ ...logs, source, selected: { ...logs.selected, [source]: null } });
}
