import { DevicePhoneMobileIcon } from "@heroicons/react/20/solid";

import { deviceDetails } from "@/devices.ts";
import { AddDevice } from "@/renderer/AddDevice.tsx";
import { deviceHref, useDevices } from "@/renderer/devices.ts";
import {
  EmptyState,
  PanelActions,
  PanelBody,
  StatusList,
  StatusRow,
} from "@/renderer/Panel.tsx";

export function Devices() {
  const devices = useDevices();
  return (
    <PanelBody>
      {devices.length === 0 ? (
        <EmptyState
          icon={
            <DevicePhoneMobileIcon
              aria-hidden="true"
              className="size-5 shrink-0 text-muted"
            />
          }
          title="No devices"
          description="iPhones and iPads connected by USB show up here"
        />
      ) : (
        <StatusList>
          {devices.map((device) => (
            <StatusRow
              key={device.address}
              icon={
                <DevicePhoneMobileIcon
                  aria-hidden="true"
                  className="size-5 shrink-0 text-foreground"
                />
              }
              title={device.name ?? device.address}
              href={deviceHref(device.address)}
              description={deviceDetails(device)}
            />
          ))}
        </StatusList>
      )}
      <PanelActions>
        <AddDevice />
      </PanelActions>
    </PanelBody>
  );
}
