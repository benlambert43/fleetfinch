import { AppShell, SectionHeading } from "@fleetfinch/ui";
import { ChevronLeftIcon } from "@heroicons/react/20/solid";
import { useEffect, useState } from "react";

import {
  type DeviceVolume,
  formatKb,
  systemVolume,
  volumeLabel,
} from "@/deviceApps.ts";
import type { Device } from "@/devices.ts";
import { DeviceApps } from "@/renderer/DeviceApps.tsx";
import { ensureDeviceApps, useDeviceApps } from "@/renderer/deviceApps.ts";
import { devicesHref } from "@/renderer/devices.ts";
import { RemoveDeviceDialog } from "@/renderer/DeviceSettings.tsx";

const lowSpace = 0.1;

function usedFraction({ totalKb, freeKb }: DeviceVolume): number {
  return totalKb === 0 ? 0 : Math.min(Math.max(1 - freeKb / totalKb, 0), 1);
}

function VolumeMeter({ volume }: { volume: DeviceVolume }) {
  const label = volumeLabel(volume);
  const percent = Math.round(usedFraction(volume) * 100);
  const free = `${formatKb(volume.freeKb)} free of ${formatKb(volume.totalKb)}`;
  return (
    <div className="flex flex-col gap-1.5">
      <p className="flex flex-wrap items-baseline justify-between gap-x-3">
        <span className="text-subheadline">{label}</span>
        <span className="text-footnote text-muted">{free}</span>
      </p>
      <div
        role="meter"
        aria-label={`${label} volume used`}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent}
        aria-valuetext={free}
        className="h-1.5 overflow-hidden rounded-full bg-foreground/10"
      >
        <div
          className="h-full rounded-full bg-primary"
          style={{ width: `${String(percent)}%` }}
        />
      </div>
    </div>
  );
}

function Storage({ address }: { address: string }) {
  const { inventory, loading, problem } = useDeviceApps(address);
  if (inventory === null) {
    return (
      <p className="text-footnote text-muted">
        {loading || problem === null
          ? "Reading the device…"
          : "Shown once the device answers."}
      </p>
    );
  }
  const { volumes } = inventory;
  const system = systemVolume(volumes);
  return (
    <div className="flex w-full max-w-md flex-col gap-3">
      {volumes.length === 0 && (
        <p className="text-footnote text-muted">
          The device did not report its storage.
        </p>
      )}
      {volumes.map((volume) => (
        <VolumeMeter key={volume.mount} volume={volume} />
      ))}
      {system !== null && 1 - usedFraction(system) < lowSpace && (
        <p
          className="rounded-lg bg-accent-soft px-2 py-1 text-footnote
            text-accent-soft-foreground"
        >
          Apps install to the system volume, which is nearly full.
        </p>
      )}
    </div>
  );
}

export function DevicePage({ device }: { device: Device }) {
  const { address } = device;
  const name = device.name ?? address;
  const [removing, setRemoving] = useState(false);
  const facts = [
    { label: "Model", value: device.model },
    { label: "iOS", value: device.version },
    { label: "Address", value: address },
  ];

  useEffect(() => {
    ensureDeviceApps(address);
  }, [address]);

  return (
    <AppShell
      title={name}
      lead={
        <a
          href={devicesHref}
          className="-ml-1 flex h-7 items-center gap-0.5 rounded-md pr-2 pl-1
            text-subheadline text-muted hover:bg-foreground/5
            hover:text-foreground focus-visible:outline-2
            focus-visible:outline-offset-2 focus-visible:outline-foreground"
        >
          <ChevronLeftIcon aria-hidden="true" className="size-5 shrink-0" />
          Devices
        </a>
      }
    >
      <div className="grid gap-6 lg:grid-cols-2">
        <section className="flex flex-col items-start gap-3">
          <SectionHeading>About</SectionHeading>
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            {facts.map(({ label, value }) => (
              <div key={label} className="contents">
                <dt className="text-subheadline text-muted">{label}</dt>
                <dd className="text-subheadline wrap-break-word">
                  {value ?? "Unknown"}
                </dd>
              </div>
            ))}
          </dl>
        </section>
        <section className="flex flex-col items-start gap-3">
          <SectionHeading>Storage</SectionHeading>
          <Storage address={address} />
        </section>
      </div>
      <DeviceApps device={device} />
      <section className="flex flex-col items-start gap-3">
        <SectionHeading>Remove Device</SectionHeading>
        <p className="text-footnote text-muted">
          Forgets {name} on this computer and takes this computer’s key off it.
          Its apps stay as they are.
        </p>
        <button
          type="button"
          aria-haspopup="dialog"
          onClick={() => {
            setRemoving(true);
          }}
          className="h-9 rounded-lg border-2 border-danger px-3 text-subheadline
            text-danger transition-colors hover:bg-danger/10
            focus-visible:outline-2 focus-visible:outline-offset-2
            focus-visible:outline-foreground active:bg-danger/20"
        >
          Remove Device…
        </button>
      </section>
      {removing && (
        <RemoveDeviceDialog
          device={device}
          onClosed={() => {
            setRemoving(false);
          }}
        />
      )}
    </AppShell>
  );
}
