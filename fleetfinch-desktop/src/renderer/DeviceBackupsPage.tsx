import { AppShell } from "@fleetfinch/ui";
import { ArchiveBoxIcon } from "@heroicons/react/20/solid";

import type { Device } from "@/devices.ts";
import { BackLink } from "@/renderer/DevicePage.tsx";
import { deviceHref } from "@/renderer/devices.ts";
import { StatusRow } from "@/renderer/Panel.tsx";

export function DeviceBackupsPage({ device }: { device: Device }) {
  const name = device.name ?? device.address;
  return (
    <AppShell
      title={`${name} Backups`}
      lead={<BackLink href={deviceHref(device.address)}>{name}</BackLink>}
    >
      <dl className="flex min-h-64 flex-1 flex-col items-center justify-center">
        <StatusRow
          icon={
            <ArchiveBoxIcon
              aria-hidden="true"
              className="size-5 shrink-0 text-muted"
            />
          }
          title="No backups"
          description={`Backups of ${name} show up here`}
        />
      </dl>
    </AppShell>
  );
}
