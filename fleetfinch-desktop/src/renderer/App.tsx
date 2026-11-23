import { AppShell } from "@fleetfinch/ui";
import { Suspense } from "react";

import { NativeThemeToggle } from "@/renderer/NativeThemeToggle.tsx";
import { TitleBar } from "@/renderer/TitleBar.tsx";

const appName = "FleetFinch";

export function App() {
  return (
    <>
      <TitleBar title={appName} />
      <div className="relative flex min-h-0 flex-1 flex-col overflow-y-auto">
        <header className="absolute top-4.25 right-3">
          <Suspense>
            <NativeThemeToggle />
          </Suspense>
        </header>
        <AppShell
          title={appName}
          description="A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices"
        />
      </div>
    </>
  );
}
