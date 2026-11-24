import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  app,
  BrowserWindow,
  ipcMain,
  nativeTheme,
  net,
  protocol,
  session,
  shell,
} from "electron";

import { darkColors, lightColors } from "@fleetfinch/ui/colors";

import { windowMaximizedChannel } from "@/bridge.ts";
import { contentSecurityPolicy } from "@/contentSecurityPolicy.ts";
import { env } from "@/env.ts";
import type { LogKind } from "@/logs.ts";
import { stopWatchingDevices, watchDevices } from "@/main/deviceLogs.ts";
import { handlers } from "@/main/handlers.ts";
import { logApp, logAppError } from "@/main/logs.ts";
import { setApplicationMenu } from "@/main/menu.ts";
import { restoreThemePreference } from "@/main/theme.ts";

// Security model. The window is treated as untrusted: it shows data from the
// API, so everything it can reach is decided here and nothing is left to the
// page. Each rule below closes one way out of that; change them together.
//
// - Sandbox: app.enableSandbox() sandboxes every renderer, and context
//   isolation stays on, so the page has no Node.js or Electron APIs. The
//   preload script exposes only the named functions of Bridge, never
//   ipcRenderer itself.
// - IPC: every handler checks that the calling frame is the app's own page
//   (isRenderer) before it runs, so an embedded or navigated-to page cannot
//   call the main process.
// - Origin: a packaged app is served from app://renderer, a privileged
//   standard scheme, because file:// pages have no origin for the API's CORS
//   list or the Content-Security-Policy to refer to. serveRendererFile only
//   answers for that host and only with files inside the renderer folder; the
//   startsWith check is what stops ../ paths from reading the rest of the disk.
// - Content-Security-Policy: sent with every file by serveRendererFile, and by
//   Vite's dev server in development. It limits the page to its own files and
//   the API's origin, with no inline or evaluated script in a packaged app
//   (src/contentSecurityPolicy.ts).
// - Navigation: will-navigate and the window-open handler keep the window on
//   the app's own page. Anything else is refused, and only https addresses are
//   handed to the default browser, so a link cannot launch another program
//   through a custom scheme or open a local file.
// - Permissions: both the request and the check handler refuse everything not
//   in grantedPermissions, so the page cannot get the camera, microphone,
//   location or notifications by asking.
// - Binary: the fuses in forge.config.ts stop a packaged app from being run as
//   plain Node.js, taking NODE_OPTIONS or debugger flags, or loading code from
//   outside app.asar.

const devServerUrl = MAIN_WINDOW_VITE_DEV_SERVER_URL as string | undefined;
const renderer = new URL(devServerUrl ?? "app://renderer");

const preload = path.join(__dirname, "preload.cjs");
const rendererFiles = path.join(
  __dirname,
  "../renderer",
  MAIN_WINDOW_VITE_NAME,
);

const policy = contentSecurityPolicy(env.VITE_API_BASE_URL, {
  devServer: false,
});

const grantedPermissions = new Set(["clipboard-sanitized-write", "fullscreen"]);

const consoleKinds: Record<string, LogKind> = {
  warning: "warning",
  error: "error",
};

function isRenderer(url = ""): boolean {
  const target = URL.parse(url);
  return (
    target?.protocol === renderer.protocol && target.host === renderer.host
  );
}

function decodePath(pathname: string): string | null {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return null;
  }
}

async function serveRendererFile(request: Request): Promise<Response> {
  const { host, pathname } = new URL(request.url);
  const decoded = decodePath(pathname);
  if (decoded === null) {
    return new Response(null, { status: 400 });
  }
  const file = path.join(rendererFiles, decoded);
  if (host !== renderer.host || !file.startsWith(rendererFiles + path.sep)) {
    return new Response(null, { status: 404 });
  }
  const response = await net.fetch(pathToFileURL(file).href).catch(() => null);
  if (!response) {
    return new Response(null, { status: 404 });
  }
  const headers = new Headers(response.headers);
  headers.set("Content-Security-Policy", policy);
  return new Response(response.body, { status: response.status, headers });
}

function openInBrowser(url: string): void {
  if (URL.parse(url)?.protocol === "https:") {
    shell.openExternal(url).catch((error: unknown) => {
      logAppError(`Could not open ${url}`, error);
    });
  }
}

function windowBackground(): string {
  return nativeTheme.shouldUseDarkColors
    ? darkColors.background
    : lightColors.background;
}

function logWindow(window: BrowserWindow): void {
  const { webContents } = window;
  webContents.on(
    "console-message",
    ({ level, message, sourceId, lineNumber }) => {
      const kind = consoleKinds[level] ?? "output";
      const source =
        kind === "output" || sourceId === ""
          ? ""
          : ` (${sourceId}:${String(lineNumber)})`;
      logApp(kind, `${message.replaceAll("%c", "")}${source}`);
    },
  );
  webContents.on("did-finish-load", () => {
    logApp("message", "The window loaded");
  });
  webContents.on(
    "did-fail-load",
    (_event, code, description, url, isMainFrame) => {
      if (isMainFrame) {
        logAppError(
          `The window could not load ${url}: ${description} (${String(code)})`,
        );
      }
    },
  );
  webContents.on("preload-error", (_event, _path, error) => {
    logAppError("The preload script failed", error);
  });
  webContents.on("render-process-gone", (_event, { reason, exitCode }) => {
    logAppError(
      `The window's process is gone: ${reason}, exit code ${String(exitCode)}`,
    );
  });
  window.on("unresponsive", () => {
    logApp("warning", "The window stopped responding");
  });
  window.on("responsive", () => {
    logApp("message", "The window is responding again");
  });
}

function createWindow(): void {
  const window = new BrowserWindow({
    width: 1282,
    height: 720,
    minWidth: 768,
    minHeight: 600,
    frame: false,
    backgroundColor: windowBackground(),
    webPreferences: {
      preload,
      v8CacheOptions: "bypassHeatCheck",
    },
  });
  const sendMaximized = () => {
    window.webContents.send(windowMaximizedChannel, window.isMaximized());
  };
  window.on("maximize", sendMaximized);
  window.on("unmaximize", sendMaximized);
  logWindow(window);
  void window.loadURL(new URL("/index.html", renderer).href);
}

function showWindow(): void {
  const [window] = BrowserWindow.getAllWindows();
  if (!window) {
    createWindow();
    return;
  }
  if (window.isMinimized()) {
    window.restore();
  }
  window.focus();
}

async function start(): Promise<void> {
  await restoreThemePreference();
  nativeTheme.on("updated", () => {
    for (const window of BrowserWindow.getAllWindows()) {
      window.setBackgroundColor(windowBackground());
    }
  });

  if (!devServerUrl) {
    protocol.handle("app", serveRendererFile);
  }

  session.defaultSession.setPermissionRequestHandler(
    (_contents, permission, callback) => {
      callback(grantedPermissions.has(permission));
    },
  );
  session.defaultSession.setPermissionCheckHandler((_contents, permission) =>
    grantedPermissions.has(permission),
  );

  for (const [method, handler] of Object.entries(handlers)) {
    ipcMain.handle(method, async (event, ...args: unknown[]) => {
      const window = BrowserWindow.fromWebContents(event.sender);
      if (!window || !isRenderer(event.senderFrame?.url)) {
        const refusal = `Refused ${method} from an unexpected sender`;
        logAppError(refusal);
        throw new Error(refusal);
      }
      try {
        return await handler(window, ...args);
      } catch (error) {
        logAppError(`The window's call to ${method} failed`, error);
        throw error;
      }
    });
  }

  setApplicationMenu();
  createWindow();
  watchDevices();
  app.on("activate", showWindow);
  app.on("second-instance", showWindow);
}

if (devServerUrl) {
  app.setPath("userData", `${app.getPath("userData")} (development)`);
}

logApp(
  "message",
  `Started ${app.getName()} ${app.getVersion()} with Electron ${process.versions.electron}, Chromium ${process.versions.chrome} and Node.js ${process.versions.node} on ${process.platform} ${process.arch}`,
);

process.on("uncaughtExceptionMonitor", (error, origin) => {
  logAppError(
    origin === "unhandledRejection"
      ? "A promise was rejected and nothing handled it"
      : "An exception was thrown and nothing caught it",
    error,
  );
});

app.enableSandbox();

protocol.registerSchemesAsPrivileged([
  {
    scheme: "app",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      codeCache: true,
    },
  },
]);

app.on("web-contents-created", (_event, contents) => {
  contents.on("will-navigate", (event) => {
    if (!isRenderer(event.url)) {
      event.preventDefault();
      openInBrowser(event.url);
    }
  });
  contents.setWindowOpenHandler(({ url }) => {
    openInBrowser(url);
    return { action: "deny" };
  });
});

app.on("child-process-gone", (_event, { type, reason, exitCode }) => {
  logAppError(
    `The ${type} process is gone: ${reason}, exit code ${String(exitCode)}`,
  );
});

app.on("will-quit", stopWatchingDevices);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

if (app.requestSingleInstanceLock()) {
  void app.whenReady().then(start);
} else {
  app.quit();
}
