import { DevicePhoneMobileIcon } from "@heroicons/react/20/solid";
import { useEffect, useId, useRef, useState, useTransition } from "react";

import { type Device, deviceDetails, type DeviceRemoval } from "@/devices.ts";
import { setDevices, useDevices } from "@/renderer/devices.ts";

const countdownSeconds = 5;

const dialogButton = `h-9 rounded-lg px-3 text-subheadline
  focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-menu-foreground aria-disabled:opacity-60`;

function RemoveDeviceDialog({
  device,
  onClosed,
}: {
  device: Device;
  onClosed: () => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const headingId = useId();
  const descriptionId = useId();
  const problemId = useId();
  const [remaining, setRemaining] = useState(countdownSeconds);
  const [problem, setProblem] = useState<string | null>(null);
  const [removing, startRemoving] = useTransition();
  const name = device.name ?? device.address;

  useEffect(() => {
    const dialog = dialogRef.current;
    dialog?.showModal();
    return () => {
      dialog?.close();
    };
  }, []);

  useEffect(() => {
    if (remaining === 0) {
      return;
    }
    const timer = setTimeout(() => {
      setRemaining(remaining - 1);
    }, 1000);
    return () => {
      clearTimeout(timer);
    };
  }, [remaining]);

  function remove() {
    if (remaining > 0 || removing) {
      return;
    }
    const revoke = problem === null;
    startRemoving(async () => {
      const result = await window.bridge
        .removeDevice(device.address, revoke)
        .catch((error: unknown): DeviceRemoval => ({
          state: "failed",
          message: error instanceof Error ? error.message : String(error),
        }));
      if (result.state === "removed") {
        setDevices(result.devices);
        dialogRef.current?.close();
      } else {
        setProblem(result.message);
      }
    });
  }

  function removeLabel(): string {
    if (remaining > 0) {
      return `Remove (${String(remaining)})`;
    }
    if (removing) {
      return "Removing…";
    }
    return problem === null ? "Remove" : "Remove Anyway";
  }

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby={headingId}
      aria-describedby={descriptionId}
      closedby="none"
      onKeyDown={(event) => {
        if (event.key === "Escape" && !removing) {
          dialogRef.current?.close();
        }
      }}
      onClose={() => {
        if (dialogRef.current?.open !== true) {
          onClosed();
        }
      }}
      className="m-auto w-[calc(100%-2rem)] max-w-sm rounded-2xl border-2
        border-menu-border bg-menu p-5 text-menu-foreground shadow-lg
        backdrop:bg-background/60 backdrop:backdrop-blur-xs"
    >
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <h2 id={headingId} className="text-headline">
            Remove {name}?
          </h2>
          <p id={descriptionId} className="text-footnote text-menu-muted">
            {problem === null
              ? "Takes this computer's key off the device. Adding it back needs the root password."
              : "Forgets the device on this computer only. Its key stays on the device."}
          </p>
        </div>
        {problem !== null && (
          <p
            id={problemId}
            role="alert"
            className="text-footnote wrap-break-word text-danger"
          >
            {problem}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <button
            type="button"
            aria-disabled={removing}
            onClick={() => {
              if (!removing) {
                dialogRef.current?.close();
              }
            }}
            className={`${dialogButton} hover:bg-menu-border/50
              active:bg-menu-border/80`}
          >
            Cancel
          </button>
          <button
            type="button"
            disabled={remaining > 0}
            aria-disabled={removing}
            aria-describedby={problem === null ? undefined : problemId}
            onClick={remove}
            className={`${dialogButton} bg-danger text-background tabular-nums
              hover:opacity-90 disabled:opacity-60`}
          >
            {removeLabel()}
          </button>
        </div>
      </div>
    </dialog>
  );
}

export function DeviceSettings() {
  const devices = useDevices();
  const [removing, setRemoving] = useState<Device | null>(null);
  return (
    <>
      {devices.length === 0 ? (
        <p className="text-footnote text-muted">No devices added yet.</p>
      ) : (
        <ul className="flex w-full max-w-md flex-col gap-3">
          {devices.map((device) => {
            const name = device.name ?? device.address;
            return (
              <li key={device.address} className="flex items-start gap-2">
                <DevicePhoneMobileIcon
                  aria-hidden="true"
                  className="size-5 shrink-0 text-foreground"
                />
                <div
                  className="flex min-w-0 flex-1 flex-wrap items-baseline
                    gap-x-2"
                >
                  <span className="text-subheadline">{name}</span>
                  <span className="text-footnote wrap-break-word text-muted">
                    {deviceDetails(device)}
                  </span>
                </div>
                <button
                  type="button"
                  aria-haspopup="dialog"
                  aria-label={`Remove ${name}`}
                  onClick={() => {
                    setRemoving(device);
                  }}
                  className="-my-1 flex h-7 shrink-0 items-center rounded-md
                    px-2 text-footnote text-danger transition-colors
                    hover:bg-danger/10 focus-visible:outline-2
                    focus-visible:outline-offset-2
                    focus-visible:outline-foreground active:bg-danger/20"
                >
                  Remove
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {removing !== null && (
        <RemoveDeviceDialog
          key={removing.address}
          device={removing}
          onClosed={() => {
            setRemoving(null);
          }}
        />
      )}
    </>
  );
}
