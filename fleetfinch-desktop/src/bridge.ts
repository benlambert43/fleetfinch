import type { ThemePreference } from "@fleetfinch/ui/theme-preference";

import type { MenuAction } from "@/menu.ts";

export const windowMaximizedChannel = "windowMaximized";

export interface BridgeMethods {
  getAppVersion: () => Promise<string>;
  getTheme: () => Promise<ThemePreference>;
  setTheme: (theme: ThemePreference) => Promise<void>;
  isWindowMaximized: () => Promise<boolean>;
  runMenuAction: (action: MenuAction) => Promise<void>;
}

export interface Bridge extends BridgeMethods {
  platform: string;
  onWindowMaximizedChange: (
    listener: (maximized: boolean) => void,
  ) => () => void;
}

declare global {
  interface Window {
    bridge: Bridge;
  }
}
