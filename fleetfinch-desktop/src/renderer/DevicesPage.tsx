import { AppShell } from "@fleetfinch/ui";
import {
  ChevronRightIcon,
  DevicePhoneMobileIcon,
} from "@heroicons/react/20/solid";
import { useEffect } from "react";

import { deviceDetails } from "@/devices.ts";
import { AddDevice } from "@/renderer/AddDevice.tsx";
import { DevicePage } from "@/renderer/DevicePage.tsx";
import {
  deviceHref,
  showDevices,
  useDevices,
  useShownDeviceAddress,
} from "@/renderer/devices.ts";
import { StatusRow } from "@/renderer/Panel.tsx";

export function DevicesPage() {
  const devices = useDevices();
  const address = useShownDeviceAddress();
  const device = devices.find((saved) => saved.address === address);
  const missing = address !== null && device === undefined;

  useEffect(() => {
    if (missing) {
      showDevices();
    }
  }, [missing]);

  if (device !== undefined) {
    return <DevicePage key={device.address} device={device} />;
  }

  return (
    <AppShell title="Devices">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-footnote text-muted">
          iPhones and iPads this computer signs in to over SSH. Open one to
          manage its apps.
        </p>
        <AddDevice placement="center" />
      </div>
      {devices.length === 0 ? (
        <dl
          className="flex min-h-64 flex-1 flex-col items-center justify-center"
        >
          <StatusRow
            icon={
              <DevicePhoneMobileIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-muted"
              />
            }
            title="No devices"
            description="Add Device signs in to a jailbroken iPhone or iPad by its IP address"
          />
        </dl>
      ) : (
        <ul
          className="grid grid-cols-[repeat(auto-fill,minmax(17rem,1fr))] gap-4"
        >
          {devices.map((saved) => (
            <li key={saved.address}>
              <a
                href={deviceHref(saved.address)}
                className="flex h-full items-center gap-3 rounded-2xl border-2
                  border-border p-4 hover:bg-foreground/5
                  focus-visible:outline-2 focus-visible:outline-offset-2
                  focus-visible:outline-foreground"
              >
                <DevicePhoneMobileIcon
                  aria-hidden="true"
                  className="size-6 shrink-0 text-foreground"
                />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate text-headline">
                    {saved.name ?? saved.address}
                  </span>
                  <span className="text-footnote wrap-break-word text-muted">
                    {deviceDetails(saved)}
                  </span>
                </span>
                <ChevronRightIcon
                  aria-hidden="true"
                  className="size-5 shrink-0 text-muted"
                />
              </a>
            </li>
          ))}
        </ul>
      )}
    </AppShell>
  );
}
