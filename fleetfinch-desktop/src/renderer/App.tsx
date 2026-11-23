import {
  AppShell,
  SectionHeading,
  Sidebar,
  type SidebarLink,
} from "@fleetfinch/ui";
import { Activity, Suspense, useSyncExternalStore } from "react";

import { NativeThemeToggle } from "@/renderer/NativeThemeToggle.tsx";
import { TitleBar } from "@/renderer/TitleBar.tsx";

const appName = "FleetFinch Developer";

const homeHref = "#/";
const settingsHref = "#/settings";

const links: SidebarLink[] = [
  { href: homeHref, label: "Home" },
  { href: settingsHref, label: "Settings" },
];

function subscribe(listener: () => void): () => void {
  window.addEventListener("hashchange", listener);
  return () => {
    window.removeEventListener("hashchange", listener);
  };
}

function currentHref(): string {
  const { hash } = window.location;
  return links.some((link) => link.href === hash) ? hash : homeHref;
}

function visibleOn(href: string, current: string) {
  return href === current ? "visible" : "hidden";
}

export function App() {
  const current = useSyncExternalStore(subscribe, currentHref);
  return (
    <>
      <TitleBar title={appName} />
      <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        <Sidebar links={links} current={current} Link="a" />
        <div className="flex min-h-0 flex-1 flex-col overflow-y-auto">
          <Activity mode={visibleOn(homeHref, current)}>
            <AppShell
              title={appName}
              description="A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices"
            />
          </Activity>
          <Activity mode={visibleOn(settingsHref, current)}>
            <AppShell title="Settings">
              <section className="flex flex-col items-start gap-3">
                <SectionHeading>Theme</SectionHeading>
                <Suspense>
                  <NativeThemeToggle />
                </Suspense>
              </section>
            </AppShell>
          </Activity>
        </div>
      </div>
    </>
  );
}
