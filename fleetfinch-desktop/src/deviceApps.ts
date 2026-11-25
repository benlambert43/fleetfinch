export const deviceTaskChannel = "deviceTask";

export const packageIdPattern = /^[A-Za-z\d][A-Za-z\d+._-]+$/;

export type DeviceAppSource = "package" | "user" | "system";

export interface DeviceApp {
  path: string;
  identifier: string | null;
  name: string;
  version: string | null;
  build: string | null;
  source: DeviceAppSource;
  packageId: string | null;
  hidden: boolean;
}

export interface DeviceService {
  label: string;
  file: string;
  loaded: boolean;
  pid: number | null;
}

export type DevicePackageState = "installed" | "unfinished";

export interface DevicePackage {
  id: string;
  name: string;
  version: string;
  section: string | null;
  summary: string | null;
  author: string | null;
  installedKb: number | null;
  state: DevicePackageState;
  apps: string[];
  services: DeviceService[];
  locked: string | null;
}

export interface DeviceVolume {
  mount: string;
  totalKb: number;
  freeKb: number;
}

export interface DeviceInventory {
  apps: DeviceApp[];
  packages: DevicePackage[];
  volumes: DeviceVolume[];
  readAt: number;
}

export type DeviceInventoryResult =
  | { state: "listed"; inventory: DeviceInventory }
  | { state: "failed"; message: string };

export const installSteps = [
  "read",
  "copy",
  "check",
  "install",
  "refresh",
] as const;

export const removeSteps = ["remove", "refresh"] as const;

export type DeviceTaskStep =
  (typeof installSteps)[number] | (typeof removeSteps)[number];

export const deviceTaskStepLabels: Record<DeviceTaskStep, string> = {
  read: "Read the package",
  copy: "Copy it to the device",
  check: "Check it on the device",
  install: "Install it",
  remove: "Remove the package",
  refresh: "Refresh the Home screen",
};

export type DeviceTaskTarget = "computer" | "device";

export type DeviceTaskEvent =
  | {
      address: string;
      type: "started";
      title: string;
      steps: DeviceTaskStep[];
    }
  | {
      address: string;
      type: "progress";
      step: DeviceTaskStep;
      message: string;
      fraction: number | null;
    }
  | {
      address: string;
      type: "log";
      kind: "message" | "command" | "output" | "error";
      text: string;
      target: DeviceTaskTarget;
    }
  | {
      address: string;
      type: "finished";
      state: "done" | "failed";
      message: string;
    };

export type DevicePackageInstall =
  | {
      state: "installed";
      id: string;
      name: string;
      version: string;
      previous: string | null;
      warning: string | null;
    }
  | { state: "canceled" }
  | { state: "failed"; message: string; output: string };

export type DevicePackageRemoval =
  | { state: "removed"; id: string; name: string; warning: string | null }
  | { state: "failed"; message: string; output: string };

const systemMount = "/";

const volumeLabels: Record<string, string> = {
  [systemMount]: "System",
  "/private/var": "Data",
};

export function volumeLabel({ mount }: DeviceVolume): string {
  return volumeLabels[mount] ?? mount;
}

export function systemVolume(
  volumes: readonly DeviceVolume[],
): DeviceVolume | null {
  return volumes.find((volume) => volume.mount === systemMount) ?? null;
}

const sizeUnits = ["KB", "MB", "GB", "TB"] as const;

export function formatKb(kilobytes: number): string {
  let amount = Math.max(0, kilobytes);
  let unit = 0;
  while (amount >= 1024 && unit < sizeUnits.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || amount >= 100 ? 0 : 1;
  return `${amount.toFixed(digits)} ${sizeUnits[unit] ?? "KB"}`;
}

export function installSummary(
  result: Extract<DevicePackageInstall, { state: "installed" }>,
): string {
  const { name, version, previous } = result;
  if (previous === null) {
    return `Installed ${name} ${version}`;
  }
  return previous === version
    ? `Installed ${name} ${version} again`
    : `Installed ${name} ${version} over ${previous}`;
}
