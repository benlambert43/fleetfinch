import { contextBridge, ipcRenderer, type IpcRendererEvent } from "electron";

import {
  type Bridge,
  type BridgeMethods,
  windowMaximizedChannel,
} from "@/bridge.ts";

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
  onWindowMaximizedChange: (listener) => {
    const forward = (_event: IpcRendererEvent, maximized: boolean) => {
      listener(maximized);
    };
    ipcRenderer.on(windowMaximizedChannel, forward);
    return () => {
      ipcRenderer.off(windowMaximizedChannel, forward);
    };
  },
};

contextBridge.exposeInMainWorld("bridge", bridge);
