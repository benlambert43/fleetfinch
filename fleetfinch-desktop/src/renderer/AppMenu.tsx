import { Bars3Icon, ChevronRightIcon } from "@heroicons/react/24/outline";
import { type KeyboardEvent, type ToggleEvent, useId, useRef } from "react";

import { type MenuAction, type MenuSection, menuSections } from "@/menu.ts";

const isMac = window.bridge.platform === "darwin";
const sections = menuSections(window.bridge.platform);

const macKeys: Record<string, string> = {
  CmdOrCtrl: "⌘",
  Cmd: "⌘",
  Ctrl: "⌃",
  Alt: "⌥",
  Shift: "⇧",
  Plus: "+",
};

function formatAccelerator(accelerator: string): string {
  if (!isMac) {
    return accelerator.replace("CmdOrCtrl", "Ctrl");
  }
  return accelerator
    .split("+")
    .map((key) => macKeys[key] ?? key)
    .join("");
}

function itemsOf(menu: HTMLElement): HTMLElement[] {
  return [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')].filter(
    (item) => item.closest('[role="menu"]') === menu,
  );
}

function isOwnKey(event: KeyboardEvent<HTMLElement>): boolean {
  return (
    event.target instanceof Element &&
    event.target.closest('[role="menu"]') === event.currentTarget
  );
}

function moveFocus(event: KeyboardEvent<HTMLElement>): void {
  const items = itemsOf(event.currentTarget);
  const index = items.findIndex((item) => item === event.target);
  const targets: Record<string, number> = {
    ArrowDown: (index + 1) % items.length,
    ArrowUp: index > 0 ? index - 1 : items.length - 1,
    Home: 0,
    End: items.length - 1,
  };
  const target = targets[event.key];
  if (target !== undefined) {
    event.preventDefault();
    items[target]?.focus();
  }
}

function focusOnOpen(
  event: ToggleEvent<HTMLElement>,
  invoker: HTMLElement | null,
): void {
  const menu = event.currentTarget;
  if (event.target !== menu || event.newState !== "open") {
    return;
  }
  if (invoker && document.activeElement === invoker) {
    itemsOf(menu)[0]?.focus();
  } else {
    menu.focus();
  }
}

function Submenu({
  section,
  onChoose,
}: {
  section: MenuSection;
  onChoose: (action: MenuAction) => void;
}) {
  const submenuId = useId();
  const buttonRef = useRef<HTMLButtonElement>(null);
  const submenuRef = useRef<HTMLDivElement>(null);
  const hoverTimer = useRef<number | undefined>(undefined);

  function open() {
    const button = buttonRef.current;
    const submenu = submenuRef.current;
    if (
      button?.closest(":popover-open") &&
      submenu &&
      !submenu.matches(":popover-open")
    ) {
      submenu.showPopover({ source: button });
    }
  }

  function scheduleOpen() {
    clearTimeout(hoverTimer.current);
    hoverTimer.current = setTimeout(open, 150);
  }

  function cancelOpen() {
    clearTimeout(hoverTimer.current);
  }

  function onButtonKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === "ArrowRight") {
      event.preventDefault();
      const submenu = submenuRef.current;
      if (submenu?.matches(":popover-open")) {
        itemsOf(submenu)[0]?.focus();
      } else {
        open();
      }
    }
  }

  function onSubmenuKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!isOwnKey(event)) {
      return;
    }
    if (event.key === "ArrowLeft" || event.key === "Escape") {
      event.preventDefault();
      event.currentTarget.hidePopover();
      buttonRef.current?.focus();
    } else {
      moveFocus(event);
    }
  }

  return (
    <div className="group">
      <button
        ref={buttonRef}
        type="button"
        role="menuitem"
        aria-haspopup="menu"
        tabIndex={-1}
        popoverTarget={submenuId}
        popoverTargetAction="show"
        onKeyDown={onButtonKeyDown}
        onPointerEnter={scheduleOpen}
        onPointerLeave={cancelOpen}
        className="flex w-full items-center justify-between gap-8 rounded-md
          px-2.5 py-1.5 text-left text-sm outline-none
          group-has-open:bg-border/50 hover:bg-border/50
          focus-visible:bg-border/50"
      >
        {section.label}
        <ChevronRightIcon className="size-3.5 text-muted" />
      </button>
      <div
        ref={submenuRef}
        id={submenuId}
        popover="auto"
        role="menu"
        aria-label={section.label}
        tabIndex={-1}
        onToggle={(event) => {
          focusOnOpen(event, buttonRef.current);
        }}
        onKeyDown={onSubmenuKeyDown}
        className="inset-auto -mt-1.25 ml-2 min-w-56 rounded-lg border
          border-border bg-chrome p-1 text-foreground shadow-lg outline-none
          [app-region:no-drag] [position-area:right_span-bottom]
          [position-try-fallbacks:flip-inline,flip-block]"
      >
        {section.groups.map((group, index) => (
          <div
            key={index}
            role="group"
            className="not-first:mt-1 not-first:border-t not-first:border-border
              not-first:pt-1"
          >
            {group.map(({ action, label, accelerator }) => (
              <button
                key={action}
                type="button"
                role="menuitem"
                tabIndex={-1}
                onClick={() => {
                  onChoose(action);
                }}
                className="flex w-full items-center justify-between gap-8
                  rounded-md px-2.5 py-1.5 text-left text-sm outline-none
                  hover:bg-border/50 focus-visible:bg-border/50"
              >
                {label}
                {accelerator && (
                  <kbd className="font-sans text-xs text-muted">
                    {formatAccelerator(accelerator)}
                  </kbd>
                )}
              </button>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

export function AppMenu() {
  const menuId = useId();
  const buttonRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const returnFocus = useRef<Element | null>(null);

  function rememberFocus(event: ToggleEvent<HTMLDivElement>) {
    if (event.target === event.currentTarget && event.newState === "open") {
      returnFocus.current = document.activeElement;
    }
  }

  function choose(action: MenuAction) {
    menuRef.current?.hidePopover();
    if (returnFocus.current instanceof HTMLElement) {
      returnFocus.current.focus();
    }
    void window.bridge.runMenuAction(action);
  }

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Tab") {
      event.preventDefault();
      event.currentTarget.hidePopover();
    } else if (isOwnKey(event)) {
      moveFocus(event);
    }
  }

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        aria-label="Menu"
        title="Menu"
        aria-haspopup="menu"
        popoverTarget={menuId}
        onMouseDown={(event) => {
          event.preventDefault();
        }}
        className="flex size-8 shrink-0 items-center justify-center rounded-md
          text-foreground transition-colors [app-region:no-drag]
          hover:bg-border/50 focus-visible:outline-2
          focus-visible:outline-offset-2 focus-visible:outline-foreground
          active:bg-border/80 has-[+:popover-open]:bg-border/50"
      >
        <Bars3Icon className="size-5" strokeWidth={2.25} />
      </button>
      <div
        ref={menuRef}
        id={menuId}
        popover="auto"
        role="menu"
        aria-label="Application menu"
        tabIndex={-1}
        onBeforeToggle={rememberFocus}
        onToggle={(event) => {
          focusOnOpen(event, buttonRef.current);
        }}
        onKeyDown={onKeyDown}
        className="inset-auto mt-2.5 min-w-40 rounded-lg border border-border
          bg-chrome p-1 text-foreground shadow-lg outline-none
          [app-region:no-drag] [position-area:bottom_span-right]"
      >
        {sections.map((section) => (
          <Submenu key={section.label} section={section} onChoose={choose} />
        ))}
      </div>
    </>
  );
}
