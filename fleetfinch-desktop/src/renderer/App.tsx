import {
  AppShell,
  SectionHeading,
  Sidebar,
  type SidebarLink,
  useSidebarExpanded,
} from "@fleetfinch/ui";
import {
  Cog6ToothIcon,
  DocumentTextIcon,
  HomeIcon,
} from "@heroicons/react/24/outline";
import {
  Activity,
  type ReactNode,
  Suspense,
  useSyncExternalStore,
} from "react";

import { setActivityOpen, useActivityOpen } from "@/renderer/activity.ts";
import { ActivityPane } from "@/renderer/ActivityPane.tsx";
import { BuildTools } from "@/renderer/BuildTools.tsx";
import { DeviceBackup } from "@/renderer/DeviceBackup.tsx";
import { DeviceSettings } from "@/renderer/DeviceSettings.tsx";
import { Devices } from "@/renderer/Devices.tsx";
import { Logs } from "@/renderer/Logs.tsx";
import { logsHref } from "@/renderer/logs.ts";
import { NativeThemeToggle } from "@/renderer/NativeThemeToggle.tsx";
import { RecentProjects } from "@/renderer/RecentProjects.tsx";
import { RecentTasks } from "@/renderer/RecentTasks.tsx";
import { TitleBar } from "@/renderer/TitleBar.tsx";

const appName = "FleetFinch Developer";

const homeHref = "#/";
const settingsHref = "#/settings";

const links: SidebarLink[] = [
  { href: homeHref, label: "Home", icon: HomeIcon },
  { href: logsHref, label: "Logs", icon: DocumentTextIcon },
  { href: settingsHref, label: "Settings", icon: Cog6ToothIcon },
];

const panels: { title: string; content: ReactNode }[] = [
  { title: "Recent Projects", content: <RecentProjects /> },
  {
    title: "Devices",
    content: (
      <Suspense>
        <Devices />
      </Suspense>
    ),
  },
  { title: "Recent Tasks", content: <RecentTasks /> },
  {
    title: "Computer Info",
    content: (
      <Suspense>
        <BuildTools />
      </Suspense>
    ),
  },
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
  const [sidebarExpanded, setSidebarExpanded] = useSidebarExpanded();
  const activityOpen = useActivityOpen();
  return (
    <>
      <TitleBar
        title={appName}
        sidebarExpanded={sidebarExpanded}
        onSidebarExpandedChange={setSidebarExpanded}
        activityOpen={activityOpen}
        onActivityOpenChange={setActivityOpen}
      />
      <div className="relative flex min-h-0 flex-1 overflow-hidden">
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
                  className="grid size-full max-h-[calc(800px+var(--gap))]
                    min-h-min max-w-[calc(1200px+var(--gap))]
                    grid-cols-[repeat(2,minmax(200px,1fr))]
                    grid-rows-[repeat(2,minmax(min-content,auto))] gap-(--gap)
                    [--gap:--spacing(4)] [anchor-name:--home-panels]
                    sm:[--gap:--spacing(6)] lg:[--gap:--spacing(8)]
                    xl:size-19/20"
                >
                  {panels.map((panel) => (
                    <section
                      key={panel.title}
                      className="flex min-h-50 flex-col gap-3 rounded-2xl
                        border-2 border-border p-4"
                    >
                      <SectionHeading>{panel.title}</SectionHeading>
                      {panel.content}
                    </section>
                  ))}
                </div>
              </div>
            </AppShell>
          </Activity>
          <Activity mode={visibleOn(logsHref, current)}>
            <Suspense>
              <Logs />
            </Suspense>
          </Activity>
          <Activity mode={visibleOn(settingsHref, current)}>
            <AppShell title="Settings">
              <section className="flex flex-col items-start gap-3">
                <SectionHeading>Theme</SectionHeading>
                <Suspense>
                  <NativeThemeToggle />
                </Suspense>
              </section>
              <section className="flex flex-col items-start gap-3">
                <SectionHeading>Devices</SectionHeading>
                <Suspense>
                  <DeviceSettings />
                </Suspense>
              </section>
              <section className="flex flex-col items-start gap-3">
                <SectionHeading>Device Backup</SectionHeading>
                <DeviceBackup />
              </section>
            </AppShell>
          </Activity>
        </div>
        <ActivityPane open={activityOpen} />
      </div>
    </>
  );
}
