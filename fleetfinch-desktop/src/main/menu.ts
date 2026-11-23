import {
  app,
  BrowserWindow,
  Menu,
  type MenuItemConstructorOptions,
} from "electron";

import {
  isMenuAction,
  type MenuAction,
  type MenuCommand,
  menuSections,
} from "@/menu.ts";

interface Command {
  role?: MenuItemConstructorOptions["role"];
  run: (window: BrowserWindow) => void;
}

const commands: Record<MenuAction, Command> = {
  quit: {
    role: "quit",
    run: () => {
      app.quit();
    },
  },
  undo: {
    role: "undo",
    run: ({ webContents }) => {
      webContents.undo();
    },
  },
  redo: {
    role: "redo",
    run: ({ webContents }) => {
      webContents.redo();
    },
  },
  cut: {
    role: "cut",
    run: ({ webContents }) => {
      webContents.cut();
    },
  },
  copy: {
    role: "copy",
    run: ({ webContents }) => {
      webContents.copy();
    },
  },
  paste: {
    role: "paste",
    run: ({ webContents }) => {
      webContents.paste();
    },
  },
  delete: {
    role: "delete",
    run: ({ webContents }) => {
      webContents.delete();
    },
  },
  selectAll: {
    role: "selectAll",
    run: ({ webContents }) => {
      webContents.selectAll();
    },
  },
  reload: {
    role: "reload",
    run: ({ webContents }) => {
      webContents.reload();
    },
  },
  forceReload: {
    role: "forceReload",
    run: ({ webContents }) => {
      webContents.reloadIgnoringCache();
    },
  },
  toggleDevTools: {
    role: "toggleDevTools",
    run: ({ webContents }) => {
      webContents.toggleDevTools();
    },
  },
  resetZoom: {
    role: "resetZoom",
    run: ({ webContents }) => {
      webContents.zoomLevel = 0;
    },
  },
  zoomIn: {
    role: "zoomIn",
    run: ({ webContents }) => {
      webContents.zoomLevel += 0.5;
    },
  },
  zoomOut: {
    role: "zoomOut",
    run: ({ webContents }) => {
      webContents.zoomLevel -= 0.5;
    },
  },
  toggleFullScreen: {
    role: "togglefullscreen",
    run: (window) => {
      window.setFullScreen(!window.isFullScreen());
    },
  },
  minimize: {
    role: "minimize",
    run: (window) => {
      window.minimize();
    },
  },
  maximize: {
    run: (window) => {
      if (window.isMaximized()) {
        window.unmaximize();
      } else {
        window.maximize();
      }
    },
  },
  close: {
    role: "close",
    run: (window) => {
      window.close();
    },
  },
};

function menuItem({
  action,
  ...item
}: MenuCommand): MenuItemConstructorOptions {
  const { role, run } = commands[action];
  if (role) {
    return { ...item, role };
  }
  return {
    ...item,
    click: () => {
      const window = BrowserWindow.getFocusedWindow();
      if (window) {
        run(window);
      }
    },
  };
}

export function setApplicationMenu(): void {
  const template = menuSections(process.platform).map(
    ({ label, groups }): MenuItemConstructorOptions => ({
      label,
      submenu: groups.flatMap((group, index) => [
        ...(index > 0 ? [{ type: "separator" as const }] : []),
        ...group.map(menuItem),
      ]),
    }),
  );
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

export function runMenuAction(
  window: BrowserWindow,
  action: unknown,
): Promise<void> {
  if (!isMenuAction(action)) {
    throw new Error("Refused an unknown menu action");
  }
  commands[action].run(window);
  return Promise.resolve();
}
