import { DevicePhoneMobileIcon } from "@heroicons/react/20/solid";

import { AddDevice } from "@/renderer/AddDevice.tsx";
import { EmptyState, PanelActions, PanelBody } from "@/renderer/Panel.tsx";

export function Devices() {
  return (
    <PanelBody>
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
      <PanelActions>
        <AddDevice />
      </PanelActions>
    </PanelBody>
  );
}
