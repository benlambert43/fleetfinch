import { app, type BrowserWindow } from "electron";

import type { BridgeMethods } from "@/bridge.ts";
import {
  buildToolsLogChannel,
  buildToolsProgressChannel,
} from "@/buildTools.ts";
import { readBuildTools, setUpBuildTools } from "@/main/buildTools/setup.ts";
import { runMenuAction } from "@/main/menu.ts";
import { getThemePreference, setThemePreference } from "@/main/theme.ts";

type Handlers = {
  [Method in keyof BridgeMethods]: (
    window: BrowserWindow,
    ...args: unknown[]
  ) => ReturnType<BridgeMethods[Method]>;
};

export const handlers: Handlers = {
  getAppVersion: () => Promise.resolve(app.getVersion()),
  getTheme: () => Promise.resolve(getThemePreference()),
  setTheme: (_window, theme) => setThemePreference(theme),
  isWindowMaximized: (window) => Promise.resolve(window.isMaximized()),
  runMenuAction: (window, action) => runMenuAction(window, action),
  getBuildTools: () => readBuildTools(),
  setUpBuildTools: (window, password) => {
    if (password !== undefined && typeof password !== "string") {
      return Promise.reject(new Error("Refused a password that is not text"));
    }
    const send = (channel: string, payload: unknown) => {
      if (!window.isDestroyed()) {
        window.webContents.send(channel, payload);
      }
    };
    return setUpBuildTools(
      {
        progress: (progress) => {
          send(buildToolsProgressChannel, progress);
        },
        log: (line) => {
          send(buildToolsLogChannel, line);
        },
      },
      password,
    );
  },
};
