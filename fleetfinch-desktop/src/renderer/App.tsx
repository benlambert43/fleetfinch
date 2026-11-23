import { AppShell } from "@fleetfinch/ui";
import { Suspense } from "react";

import { NativeThemeToggle } from "@/renderer/NativeThemeToggle.tsx";

export function App() {
  return (
    <>
      <header className="absolute top-3 right-3">
        <Suspense>
          <NativeThemeToggle />
        </Suspense>
      </header>
      <AppShell
        title="FleetFinch"
        description="A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices"
      />
    </>
  );
}
