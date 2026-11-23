export const menuActions = [
  "quit",
  "undo",
  "redo",
  "cut",
  "copy",
  "paste",
  "delete",
  "selectAll",
  "reload",
  "forceReload",
  "toggleDevTools",
  "resetZoom",
  "zoomIn",
  "zoomOut",
  "toggleFullScreen",
  "minimize",
  "maximize",
  "close",
] as const;

export type MenuAction = (typeof menuActions)[number];

export interface MenuCommand {
  action: MenuAction;
  label: string;
  accelerator?: string;
}

export interface MenuSection {
  label: string;
  groups: MenuCommand[][];
}

export function isMenuAction(value: unknown): value is MenuAction {
  return menuActions.some((action) => action === value);
}

export function menuSections(platform: string): MenuSection[] {
  const isMac = platform === "darwin";
  return [
    {
      label: "File",
      groups: [[{ action: "quit", label: "Quit", accelerator: "CmdOrCtrl+Q" }]],
    },
    {
      label: "Edit",
      groups: [
        [
          { action: "undo", label: "Undo", accelerator: "CmdOrCtrl+Z" },
          {
            action: "redo",
            label: "Redo",
            accelerator: platform === "win32" ? "Ctrl+Y" : "CmdOrCtrl+Shift+Z",
          },
        ],
        [
          { action: "cut", label: "Cut", accelerator: "CmdOrCtrl+X" },
          { action: "copy", label: "Copy", accelerator: "CmdOrCtrl+C" },
          { action: "paste", label: "Paste", accelerator: "CmdOrCtrl+V" },
          { action: "delete", label: "Delete" },
        ],
        [
          {
            action: "selectAll",
            label: "Select All",
            accelerator: "CmdOrCtrl+A",
          },
        ],
      ],
    },
    {
      label: "View",
      groups: [
        [
          { action: "reload", label: "Reload", accelerator: "CmdOrCtrl+R" },
          {
            action: "forceReload",
            label: "Force Reload",
            accelerator: "CmdOrCtrl+Shift+R",
          },
          {
            action: "toggleDevTools",
            label: "Toggle Developer Tools",
            accelerator: isMac ? "Alt+Cmd+I" : "Ctrl+Shift+I",
          },
        ],
        [
          {
            action: "resetZoom",
            label: "Actual Size",
            accelerator: "CmdOrCtrl+0",
          },
          { action: "zoomIn", label: "Zoom In", accelerator: "CmdOrCtrl+Plus" },
          { action: "zoomOut", label: "Zoom Out", accelerator: "CmdOrCtrl+-" },
        ],
        [
          {
            action: "toggleFullScreen",
            label: "Toggle Full Screen",
            accelerator: isMac ? "Ctrl+Cmd+F" : "F11",
          },
        ],
      ],
    },
    {
      label: "Window",
      groups: [
        [
          { action: "minimize", label: "Minimize", accelerator: "CmdOrCtrl+M" },
          { action: "maximize", label: "Maximize" },
          { action: "close", label: "Close", accelerator: "CmdOrCtrl+W" },
        ],
      ],
    },
  ];
}
