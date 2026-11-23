import { app } from "electron";

import type { Bridge } from "@/bridge.ts";
import { getThemePreference, setThemePreference } from "@/main/theme.ts";

type Handlers = {
  [Method in keyof Bridge]: (...args: unknown[]) => ReturnType<Bridge[Method]>;
};

export const handlers: Handlers = {
  getAppVersion: () => Promise.resolve(app.getVersion()),
  getTheme: () => Promise.resolve(getThemePreference()),
  setTheme: (theme) => setThemePreference(theme),
};
