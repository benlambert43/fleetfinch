import { Fragment } from "react";

import { Accordion } from "@/app/_components/Accordion.tsx";
import { ExternalLinkIcon } from "@/app/_components/ExternalLinkIcon.tsx";

const devices = [
  {
    name: "iPhone 4s",
    specs: ["Apple A5", "512 MB RAM", "960×640"],
    article: "https://en.wikipedia.org/wiki/IPhone_4s",
  },
  {
    name: "iPad 2",
    specs: ["Apple A5", "512 MB RAM", "1024×768"],
    article: "https://en.wikipedia.org/wiki/IPad_2",
  },
  {
    name: "iPad (3rd generation)",
    specs: ["Apple A5X", "1 GB RAM", "2048×1536"],
    article: "https://en.wikipedia.org/wiki/IPad_(3rd_generation)",
  },
  {
    name: "iPad mini (1st generation)",
    specs: ["Apple A5", "512 MB RAM", "1024×768"],
    article: "https://en.wikipedia.org/wiki/IPad_Mini_(1st_generation)",
  },
  {
    name: "iPod touch (5th generation)",
    specs: ["Apple A5", "512 MB RAM", "1136×640"],
    article: "https://en.wikipedia.org/wiki/IPod_Touch_(5th_generation)",
  },
];

export function SupportedDevices() {
  return (
    <Accordion summary="Supported Devices" className="mx-auto mt-4 max-w-md">
      <ul className="px-4 pb-2 text-muted">
        {devices.map((device) => (
          <li
            key={device.name}
            className="flex flex-wrap items-center gap-x-3 border-t
              border-border py-1"
          >
            <div className="my-1 flex-auto">
              <span className="block text-foreground">{device.name}</span>
              <span className="mt-0.5 block text-sm">
                {device.specs.map((spec, index) => (
                  <Fragment key={spec}>
                    {index > 0 && " "}
                    <span className="whitespace-nowrap">
                      {index < device.specs.length - 1 ? `${spec},` : spec}
                    </span>
                  </Fragment>
                ))}
              </span>
            </div>
            <a
              href={device.article}
              aria-label={`${device.name} on Wikipedia`}
              className="my-1 shrink-0 rounded-lg border border-secondary-border
                bg-secondary-soft p-2.75 text-secondary-soft-foreground
                hover:bg-secondary hover:text-secondary-foreground
                focus-visible:outline-2 focus-visible:outline-offset-2
                focus-visible:outline-foreground active:bg-secondary
                active:text-secondary-foreground"
            >
              <ExternalLinkIcon className="size-5" />
            </a>
          </li>
        ))}
      </ul>
    </Accordion>
  );
}
