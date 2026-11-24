import type { ThemePreference } from "@fleetfinch/ui/theme-preference";

import type {
  BuildToolsCheck,
  BuildToolsLogLine,
  BuildToolsProgress,
  BuildToolsSetup,
  BuildToolsSetUpOptions,
  BuildToolsStatus,
} from "@/buildTools.ts";
import type {
  BackupExport,
  BackupRestore,
  Device,
  DeviceConnection,
  DeviceLogin,
  DeviceRemoval,
} from "@/devices.ts";
import type { LogsSnapshot, LogsUpdate } from "@/logs.ts";
import type { MenuAction } from "@/menu.ts";

export const windowMaximizedChannel = "windowMaximized";

export interface BridgeMethods {
  getAppVersion: () => Promise<string>;
  getTheme: () => Promise<ThemePreference>;
  setTheme: (theme: ThemePreference) => Promise<void>;
  isWindowMaximized: () => Promise<boolean>;
  runMenuAction: (action: MenuAction) => Promise<void>;
  getBuildTools: () => Promise<BuildToolsStatus>;
  checkBuildTools: () => Promise<BuildToolsCheck>;
  setUpBuildTools: (
    options?: BuildToolsSetUpOptions,
  ) => Promise<BuildToolsSetup>;
  getLogs: () => Promise<LogsSnapshot>;
  getDevices: () => Promise<Device[]>;
  addDevice: (login: DeviceLogin) => Promise<DeviceConnection>;
  removeDevice: (address: string, revoke: boolean) => Promise<DeviceRemoval>;
  exportBackup: (password: string) => Promise<BackupExport>;
  restoreBackup: (password: string) => Promise<BackupRestore>;
}

export interface Bridge extends BridgeMethods {
  platform: string;
  onWindowMaximizedChange: (
    listener: (maximized: boolean) => void,
  ) => () => void;
  onBuildToolsProgress: (
    listener: (progress: BuildToolsProgress) => void,
  ) => () => void;
  onBuildToolsLog: (listener: (line: BuildToolsLogLine) => void) => () => void;
  onLogs: (listener: (update: LogsUpdate) => void) => () => void;
}

declare global {
  interface Window {
    bridge: Bridge;
  }
}
