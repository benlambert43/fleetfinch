import { AppShell } from "@fleetfinch/ui";

import { Notes } from "@/renderer/Notes.tsx";
import { StatusChecks } from "@/renderer/StatusChecks.tsx";

export function App() {
  return (
    <AppShell
      title="FleetFinch"
      description="A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices"
    >
      <Notes />
      <StatusChecks />
    </AppShell>
  );
}
