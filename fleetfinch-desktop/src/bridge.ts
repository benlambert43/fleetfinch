import type { ThemePreference } from "@fleetfinch/ui/theme-preference";

import type {
  BuildToolsLogLine,
  BuildToolsProgress,
  BuildToolsSetup,
  BuildToolsStatus,
} from "@/buildTools.ts";
import type { MenuAction } from "@/menu.ts";

export const windowMaximizedChannel = "windowMaximized";

export interface BridgeMethods {
  getAppVersion: () => Promise<string>;
  getTheme: () => Promise<ThemePreference>;
  setTheme: (theme: ThemePreference) => Promise<void>;
  isWindowMaximized: () => Promise<boolean>;
  runMenuAction: (action: MenuAction) => Promise<void>;
  getBuildTools: () => Promise<BuildToolsStatus>;
  setUpBuildTools: (password?: string) => Promise<BuildToolsSetup>;
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
}

declare global {
  interface Window {
    bridge: Bridge;
  }
}
