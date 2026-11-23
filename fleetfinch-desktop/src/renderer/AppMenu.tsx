import { Bars3Icon, ChevronRightIcon } from "@heroicons/react/24/outline";
import {
  type KeyboardEvent,
  type MouseEvent,
  type PointerEvent,
  type ToggleEvent,
  useId,
  useRef,
} from "react";

import { type MenuAction, type MenuSection, menuSections } from "@/menu.ts";

const isMac = window.bridge.platform === "darwin";
const sections = menuSections(window.bridge.platform);
const trailLength = 4;
const aimWindow = 60;
const aimDelay = 50;
const minAimSpeed = 0.1;

interface Point {
  x: number;
  y: number;
  t: number;
}

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

function isPointerClick(event: MouseEvent): boolean {
  return event.detail > 0;
}

function focusOnHover(event: PointerEvent<HTMLElement>): void {
  if (document.activeElement !== event.currentTarget) {
    event.currentTarget.focus();
  }
}

function unfocusOnLeave(event: PointerEvent<HTMLElement>): void {
  if (document.activeElement === event.currentTarget) {
    event.currentTarget.closest<HTMLElement>('[role="menu"]')?.focus();
  }
}

function pointOf(event: PointerEvent): Point {
  return { x: event.clientX, y: event.clientY, t: event.timeStamp };
}

function isAimingAt(from: Point, to: Point, target: DOMRect): boolean {
  const edge = target.left >= to.x ? target.left : target.right;
  const dx = to.x - from.x;
  const towardTarget = Math.sign(dx) === Math.sign(edge - to.x);
  const fastEnough = Math.abs(dx) >= minAimSpeed * (to.t - from.t);
  if (dx === 0 || !towardTarget || !fastEnough) {
    return false;
  }
  const y = to.y + ((edge - to.x) * (to.y - from.y)) / dx;
  return y >= target.top && y <= target.bottom;
}

function Submenu({
  section,
  onChoose,
  isAimingAtOpenSubmenu,
}: {
  section: MenuSection;
  onChoose: (action: MenuAction) => void;
  isAimingAtOpenSubmenu: (event: PointerEvent) => boolean;
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

  function activate() {
    const button = buttonRef.current;
    if (button && document.activeElement !== button) {
      button.focus();
    }
    open();
  }

  function enter() {
    open();
    const submenu = submenuRef.current;
    if (submenu) {
      itemsOf(submenu)[0]?.focus();
    }
  }

  function activateOnHover(event: PointerEvent<HTMLButtonElement>) {
    clearTimeout(hoverTimer.current);
    if (
      document.activeElement === event.currentTarget &&
      submenuRef.current?.matches(":popover-open")
    ) {
      return;
    }
    if (isAimingAtOpenSubmenu(event)) {
      hoverTimer.current = setTimeout(activate, aimDelay);
    } else {
      activate();
    }
  }

  function deactivateOnLeave(event: PointerEvent<HTMLButtonElement>) {
    clearTimeout(hoverTimer.current);
    unfocusOnLeave(event);
  }

  function onButtonClick(event: MouseEvent<HTMLButtonElement>) {
    event.preventDefault();
    if (isPointerClick(event)) {
      activate();
    } else {
      enter();
    }
  }

  function onButtonKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === "ArrowRight") {
      event.preventDefault();
      enter();
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
        onClick={onButtonClick}
        onKeyDown={onButtonKeyDown}
        onPointerMove={activateOnHover}
        onPointerLeave={deactivateOnLeave}
        className="flex w-full items-center justify-between gap-8 rounded-md
          px-2.5 py-1.5 text-left text-sm outline-none
          group-has-open:bg-menu-border/50 focus:bg-menu-border/50"
      >
        {section.label}
        <ChevronRightIcon className="size-3.5 text-menu-muted" />
      </button>
      <div
        ref={submenuRef}
        id={submenuId}
        popover="auto"
        role="menu"
        aria-label={section.label}
        tabIndex={-1}
        onKeyDown={onSubmenuKeyDown}
        className="inset-auto -mt-1.25 ml-2 min-w-56 rounded-lg border
          border-menu-border bg-menu p-1 text-menu-foreground shadow-lg
          outline-none [app-region:no-drag] [position-area:right_span-bottom]
          [position-try-fallbacks:flip-inline,flip-block]"
      >
        {section.groups.map((group, index) => (
          <div
            key={index}
            role="group"
            className="not-first:mt-1 not-first:border-t
              not-first:border-menu-border not-first:pt-1"
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
                onPointerMove={focusOnHover}
                onPointerLeave={unfocusOnLeave}
                className="flex w-full items-center justify-between gap-8
                  rounded-md px-2.5 py-1.5 text-left text-sm outline-none
                  focus:bg-menu-border/50"
              >
                {label}
                {accelerator && (
                  <kbd className="font-sans text-xs text-menu-muted">
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
  const trail = useRef<Point[]>([]);

  function toggle(focusFirstItem: boolean) {
    const menu = menuRef.current;
    const button = buttonRef.current;
    if (!menu || !button) {
      return;
    }
    if (menu.matches(":popover-open")) {
      menu.hidePopover();
    } else {
      menu.showPopover({ source: button });
      if (focusFirstItem) {
        itemsOf(menu)[0]?.focus();
      } else {
        menu.focus();
      }
    }
  }

  function track(event: PointerEvent<HTMLDivElement>) {
    trail.current = [...trail.current.slice(1 - trailLength), pointOf(event)];
  }

  function isAimingAtOpenSubmenu(event: PointerEvent): boolean {
    const to = pointOf(event);
    const from = trail.current.find((point) => to.t - point.t <= aimWindow);
    const submenu = menuRef.current?.querySelector(":popover-open");
    if (!from || !submenu) {
      return false;
    }
    return isAimingAt(from, to, submenu.getBoundingClientRect());
  }

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
        onPointerDown={(event) => {
          if (event.button === 0) {
            toggle(false);
          }
        }}
        onMouseDown={(event) => {
          event.preventDefault();
        }}
        onClick={(event) => {
          event.preventDefault();
          if (!isPointerClick(event)) {
            toggle(true);
          }
        }}
        className="flex size-8 shrink-0 items-center justify-center rounded-md
          text-foreground [app-region:no-drag] hover:bg-border/50
          focus-visible:outline-2 focus-visible:outline-offset-2
          focus-visible:outline-foreground active:bg-border/80
          has-[+:popover-open]:bg-border/50"
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
        onKeyDown={onKeyDown}
        onPointerMove={track}
        className="inset-auto mt-2.5 min-w-40 rounded-lg border
          border-menu-border bg-menu p-1 text-menu-foreground shadow-lg
          outline-none [app-region:no-drag] [position-area:bottom_span-right]"
      >
        {sections.map((section) => (
          <Submenu
            key={section.label}
            section={section}
            onChoose={choose}
            isAimingAtOpenSubmenu={isAimingAtOpenSubmenu}
          />
        ))}
      </div>
    </>
  );
}
