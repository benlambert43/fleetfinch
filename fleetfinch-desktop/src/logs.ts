export const logsChannel = "logs";

export const logSources = ["app", "computer", "device"] as const;

export type LogSource = (typeof logSources)[number];

export const logSourceLabels: Record<LogSource, string> = {
  app: "App",
  computer: "This Computer",
  device: "Device",
};

export const logLineLimit = 5000;
export const logGroupLimit = 20;

export type LogKind =
  "step" | "message" | "command" | "output" | "warning" | "error";

export interface LogEntry {
  kind: LogKind;
  text: string;
}

export interface LogLine extends LogEntry {
  id: number;
  at: number;
}

export type LogGroupState = "running" | "done" | "stopped" | "failed";

export const logGroupStateLabels: Record<LogGroupState, string> = {
  running: "Running",
  done: "Done",
  stopped: "Stopped",
  failed: "Failed",
};

export interface LogGroupInfo {
  id: string;
  source: LogSource;
  title: string;
  detail: string | null;
  state: LogGroupState;
  outcome: string | null;
  startedAt: number;
  endedAt: number | null;
  written: number;
}

export interface LogGroup extends LogGroupInfo {
  lines: LogLine[];
}

export interface LogsSnapshot {
  seq: number;
  groups: LogGroup[];
  canReadDevices: boolean;
}

export interface LogsUpdate {
  seq: number;
  groups: LogGroupInfo[];
  lines: { id: string; lines: LogLine[] }[];
  removed: string[];
  canReadDevices: boolean;
}

export function keepLatest(
  lines: readonly LogLine[],
  added: readonly LogLine[],
): LogLine[] {
  return [...lines, ...added].slice(-logLineLimit);
}
