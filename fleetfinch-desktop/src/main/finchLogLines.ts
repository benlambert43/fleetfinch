import type { LogEntry, LogKind } from "@/logs.ts";

export const finchLogTitles: Record<string, string> = {
  system: "System Log",
  kernel: "Kernel",
  boot: "Boot",
  process: "Processes",
  app: "Apps",
  service: "Services",
  resource: "Resources",
  power: "Power",
  network: "Network",
  connection: "Connections",
  event: "Events",
  file: "Log Files",
  import: "Dumps",
  change: "Changes",
  finchlogs: "Finch Logs",
};

export const finchSnapshotTitles: Record<string, string> = {
  environment: "Environment",
  device: "Device",
  processes: "Processes",
  services: "Services",
  apps: "Apps",
  packages: "Packages",
  volumes: "Storage Volumes",
  network: "Network",
  power: "Power and Battery",
  kernel: "Kernel Messages",
  extensions: "Kernel Extensions",
  sysctl: "Kernel Settings",
  registry: "Hardware Registry",
  usage: "What Has Run",
  inventory: "What Is Installed",
  dependencies: "What Depends on What",
  health: "Problems per Component",
  connections: "Programs and Servers",
  loaded: "Loaded Libraries",
  changes: "Changes",
  calls: "System Calls",
  opened: "Files Reached",
  talks: "Connections Between Programs",
  touched: "Files Read",
  candidates: "What Looks Unused",
};

export interface FinchLine {
  day: string;
  clock: string;
  level: string;
  source: string;
  message: string;
}

const storedLine =
  /^(\d{4}-\d\d-\d\d)T(\d\d:\d\d:\d\d\.\d{3})[+-]\d\d:\d\d\t([DINWEF])\t([^\t]*)\t(.*)$/su;
const escaped = /\\(?:x([\da-f]{2})|(.))/giu;
const plainEscapes: Record<string, string> = { n: "\n", t: "\t", r: "\r" };
const labelWidth = Math.max(
  ...Object.values(finchLogTitles).map((title) => title.length),
);

const kinds: Record<string, LogKind> = {
  W: "warning",
  E: "error",
  F: "error",
};

export function unescapeField(text: string): string {
  if (!text.includes("\\")) {
    return text;
  }
  return text.replace(escaped, (_match, hex?: string, letter?: string) =>
    hex === undefined
      ? (plainEscapes[letter ?? ""] ?? letter ?? "")
      : String.fromCodePoint(Number.parseInt(hex, 16)),
  );
}

export function parseStoredLine(text: string): FinchLine | null {
  const match = storedLine.exec(text);
  if (match === null) {
    return null;
  }
  const [, day = "", clock = "", level = "", source = "", message = ""] = match;
  return {
    day,
    clock,
    level,
    source: unescapeField(source),
    message: unescapeField(message),
  };
}

export function finchLogTitle(stream: string): string {
  return finchLogTitles[stream] ?? stream;
}

export function finchEntry(
  line: FinchLine,
  stream: string | null,
  dated: boolean,
): LogEntry {
  const time = dated ? `${line.day.slice(5)} ${line.clock}` : line.clock;
  const label =
    stream === null ? "" : `${finchLogTitle(stream).padEnd(labelWidth)} `;
  const source = line.source === "" ? "" : `${line.source}: `;
  return {
    kind: kinds[line.level] ?? "output",
    text: `${time} ${label}${source}${line.message}`,
  };
}
