import { contextBridge, ipcRenderer, type IpcRendererEvent } from "electron";

import {
  type Bridge,
  type BridgeMethods,
  windowMaximizedChannel,
} from "@/bridge.ts";
import {
  type BuildToolsLogLine,
  buildToolsLogChannel,
  type BuildToolsProgress,
  buildToolsProgressChannel,
} from "@/buildTools.ts";
import { logsChannel, type LogsUpdate } from "@/logs.ts";

function invoke<Method extends keyof BridgeMethods>(method: Method) {
  return ((...args: Parameters<BridgeMethods[Method]>) =>
    ipcRenderer.invoke(method, ...args)) as BridgeMethods[Method];
}

const bridge: Bridge = {
  platform: process.platform,
  getAppVersion: invoke("getAppVersion"),
  getTheme: invoke("getTheme"),
  setTheme: invoke("setTheme"),
  isWindowMaximized: invoke("isWindowMaximized"),
  runMenuAction: invoke("runMenuAction"),
  getBuildTools: invoke("getBuildTools"),
  checkBuildTools: invoke("checkBuildTools"),
  setUpBuildTools: invoke("setUpBuildTools"),
  getLogs: invoke("getLogs"),
  getDevices: invoke("getDevices"),
  addDevice: invoke("addDevice"),
  removeDevice: invoke("removeDevice"),
  exportBackup: invoke("exportBackup"),
  restoreBackup: invoke("restoreBackup"),
  onWindowMaximizedChange: (listener) => {
    const forward = (_event: IpcRendererEvent, maximized: boolean) => {
      listener(maximized);
    };
    ipcRenderer.on(windowMaximizedChannel, forward);
    return () => {
      ipcRenderer.off(windowMaximizedChannel, forward);
    };
  },
  onBuildToolsProgress: (listener) => {
    const forward = (
      _event: IpcRendererEvent,
      progress: BuildToolsProgress,
    ) => {
      listener(progress);
    };
    ipcRenderer.on(buildToolsProgressChannel, forward);
    return () => {
      ipcRenderer.off(buildToolsProgressChannel, forward);
    };
  },
  onBuildToolsLog: (listener) => {
    const forward = (_event: IpcRendererEvent, line: BuildToolsLogLine) => {
      listener(line);
    };
    ipcRenderer.on(buildToolsLogChannel, forward);
    return () => {
      ipcRenderer.off(buildToolsLogChannel, forward);
    };
  },
  onLogs: (listener) => {
    const forward = (_event: IpcRendererEvent, update: LogsUpdate) => {
      listener(update);
    };
    ipcRenderer.on(logsChannel, forward);
    return () => {
      ipcRenderer.off(logsChannel, forward);
    };
  },
};

contextBridge.exposeInMainWorld("bridge", bridge);
