import {
  MinusIcon,
  Square2StackIcon,
  StopIcon,
  XMarkIcon,
} from "@heroicons/react/24/outline";
import { useSyncExternalStore } from "react";

import type { MenuAction } from "@/menu.ts";

let maximized = false;
const listeners = new Set<() => void>();

function setMaximized(next: boolean) {
  maximized = next;
  for (const listener of listeners) {
    listener();
  }
}

window.bridge.onWindowMaximizedChange(setMaximized);
void window.bridge.isWindowMaximized().then(setMaximized);

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getMaximized() {
  return maximized;
}

function WindowButton({
  label,
  icon: Icon,
  action,
  danger = false,
}: {
  label: string;
  icon: typeof MinusIcon;
  action: MenuAction;
  danger?: boolean;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={() => {
        void window.bridge.runMenuAction(action);
      }}
      className={`flex size-7 shrink-0 items-center justify-center rounded-md
        bg-border/40 text-foreground transition-colors [app-region:no-drag]
        focus-visible:outline-2 focus-visible:outline-offset-2
        focus-visible:outline-foreground ${
          danger
            ? `hover:bg-accent hover:text-accent-foreground
              active:bg-accent-soft`
            : "hover:bg-border/70 active:bg-border"
        }`}
    >
      <Icon className="size-4" strokeWidth={2} />
    </button>
  );
}

export function WindowControls() {
  const isMaximized = useSyncExternalStore(subscribe, getMaximized);
  return (
    <div className="ml-auto flex items-center gap-1">
      <WindowButton label="Minimize" icon={MinusIcon} action="minimize" />
      <WindowButton
        label={isMaximized ? "Restore" : "Maximize"}
        icon={isMaximized ? Square2StackIcon : StopIcon}
        action="maximize"
      />
      <WindowButton label="Close" icon={XMarkIcon} action="close" danger />
    </div>
  );
}
