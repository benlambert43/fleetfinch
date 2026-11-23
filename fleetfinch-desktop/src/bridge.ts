import type { ThemePreference } from "@fleetfinch/ui/theme-preference";

export interface Bridge {
  getAppVersion: () => Promise<string>;
  getTheme: () => Promise<ThemePreference>;
  setTheme: (theme: ThemePreference) => Promise<void>;
}

declare global {
  interface Window {
    bridge: Bridge;
  }
}
