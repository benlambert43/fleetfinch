import {
  AppShell,
  SectionHeading,
  Sidebar,
  type SidebarLink,
  useSidebarExpanded,
} from "@fleetfinch/ui";
import { Cog6ToothIcon, HomeIcon } from "@heroicons/react/24/outline";
import { Activity, Suspense, useSyncExternalStore } from "react";

import { NativeThemeToggle } from "@/renderer/NativeThemeToggle.tsx";
import { TitleBar } from "@/renderer/TitleBar.tsx";

const appName = "FleetFinch Developer";

const homeHref = "#/";
const settingsHref = "#/settings";

const links: SidebarLink[] = [
  { href: homeHref, label: "Home", icon: HomeIcon },
  { href: settingsHref, label: "Settings", icon: Cog6ToothIcon },
];

const placeholderIds = [1, 2, 3, 4];

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
  const [sidebarExpanded, setSidebarExpanded] = useSidebarExpanded();
  return (
    <>
      <TitleBar
        title={appName}
        sidebarExpanded={sidebarExpanded}
        onSidebarExpandedChange={setSidebarExpanded}
      />
      <div className="flex min-h-0 flex-1">
        <Sidebar
          links={links}
          current={current}
          expanded={sidebarExpanded}
          Link="a"
        />
        <div className="flex min-h-0 flex-1 flex-col overflow-y-auto">
          <Activity mode={visibleOn(homeHref, current)}>
            <AppShell title={appName}>
              <div className="flex flex-1 items-center justify-center">
                <div
                  className="grid size-full max-h-[calc(1200px+var(--gap))]
                    min-h-min max-w-[calc(1200px+var(--gap))]
                    grid-cols-[repeat(2,minmax(200px,1fr))]
                    grid-rows-[repeat(2,minmax(200px,1fr))] gap-(--gap)
                    [--gap:--spacing(4)] sm:[--gap:--spacing(6)]
                    lg:[--gap:--spacing(8)] xl:size-4/5"
                >
                  {placeholderIds.map((id) => (
                    <div
                      key={id}
                      className="flex items-center justify-center rounded-2xl
                        border-2 border-border p-4 text-center text-muted"
                    >
                      Placeholder
                    </div>
                  ))}
                </div>
              </div>
            </AppShell>
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
