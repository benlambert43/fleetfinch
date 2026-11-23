"use client";

import {
  type ComponentType,
  type ReactNode,
  useState,
  useSyncExternalStore,
} from "react";

export interface SidebarLink<Href extends string = string> {
  href: Href;
  label: string;
  icon: ComponentType<{ className?: string }>;
}

export interface SidebarLinkProps<Href extends string = string> {
  href: Href;
  className: string;
  title: string | undefined;
  "aria-current": "page" | undefined;
  children: ReactNode;
}

const wideQuery = "(width >= 80rem)";

function subscribeToWidth(onChange: () => void): () => void {
  const query = window.matchMedia(wideQuery);
  query.addEventListener("change", onChange);
  return () => {
    query.removeEventListener("change", onChange);
  };
}

function isWide(): boolean {
  return window.matchMedia(wideQuery).matches;
}

function isWideOnServer(): boolean {
  return true;
}

export function useSidebarExpanded() {
  const wide = useSyncExternalStore(subscribeToWidth, isWide, isWideOnServer);
  const [expanded, setExpanded] = useState(wide);
  const [prevWide, setPrevWide] = useState(wide);
  if (wide !== prevWide) {
    setPrevWide(wide);
    setExpanded(wide);
  }
  return [expanded, setExpanded] as const;
}

export function Sidebar<Href extends string>({
  links,
  current,
  expanded,
  Link,
}: {
  links: readonly SidebarLink<Href>[];
  current: string;
  expanded: boolean;
  Link: ComponentType<SidebarLinkProps<Href>> | "a";
}) {
  return (
    <nav
      aria-label="Main"
      className={`shrink-0 border-r border-foreground/10 bg-chrome p-3
        ${expanded ? "w-56" : ""}`}
    >
      <ul className="flex flex-col gap-1">
        {links.map(({ href, label, icon: Icon }) => (
          <li key={href}>
            <Link
              href={href}
              title={expanded ? undefined : label}
              aria-current={href === current ? "page" : undefined}
              className="flex h-10 items-center gap-3 rounded-lg px-3 text-body
                text-muted hover:bg-foreground/5 hover:text-foreground
                focus-visible:outline-2 focus-visible:-outline-offset-2
                focus-visible:outline-foreground
                aria-[current=page]:bg-foreground/10
                aria-[current=page]:text-foreground"
            >
              <Icon className="size-5 shrink-0" />
              <span className={expanded ? undefined : "sr-only"}>{label}</span>
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}
