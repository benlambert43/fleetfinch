import { app, type BrowserWindow } from "electron";
import { z } from "zod";

import type { BridgeMethods } from "@/bridge.ts";
import {
  buildToolsLogChannel,
  buildToolsProgressChannel,
  buildToolSteps,
} from "@/buildTools.ts";
import {
  type BuildToolsListener,
  checkBuildTools,
  readBuildTools,
  setUpBuildTools,
} from "@/main/buildTools/setup.ts";
import { readLogs } from "@/main/logs.ts";
import { runMenuAction } from "@/main/menu.ts";
import { getThemePreference, setThemePreference } from "@/main/theme.ts";

type Handlers = {
  [Method in keyof BridgeMethods]: (
    window: BrowserWindow,
    ...args: unknown[]
  ) => ReturnType<BridgeMethods[Method]>;
};

const setUpOptionsSchema = z
  .strictObject({
    password: z.string().optional(),
    clean: z.enum(buildToolSteps).optional(),
  })
  .optional();

function listenerFor(window: BrowserWindow): BuildToolsListener {
  const send = (channel: string, payload: unknown) => {
    if (!window.isDestroyed()) {
      window.webContents.send(channel, payload);
    }
  };
  return {
    progress: (progress) => {
      send(buildToolsProgressChannel, progress);
    },
    log: (line) => {
      send(buildToolsLogChannel, line);
    },
  };
}

export const handlers: Handlers = {
  getAppVersion: () => Promise.resolve(app.getVersion()),
  getTheme: () => Promise.resolve(getThemePreference()),
  setTheme: (_window, theme) => setThemePreference(theme),
  isWindowMaximized: (window) => Promise.resolve(window.isMaximized()),
  runMenuAction: (window, action) => runMenuAction(window, action),
  getBuildTools: () => readBuildTools(),
  checkBuildTools: (window) => checkBuildTools(listenerFor(window)),
  setUpBuildTools: (window, options) => {
    const parsed = setUpOptionsSchema.safeParse(options);
    if (!parsed.success) {
      return Promise.reject(new Error("Refused unknown build tools options"));
    }
    return setUpBuildTools(listenerFor(window), parsed.data);
  },
  getLogs: () => Promise.resolve(readLogs()),
};
