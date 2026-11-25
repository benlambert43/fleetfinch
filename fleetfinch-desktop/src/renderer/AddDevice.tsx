import { CheckCircleIcon, XMarkIcon } from "@heroicons/react/20/solid";
import { PlusIcon } from "@heroicons/react/24/outline";
import { useActionState, useId, useRef, useState } from "react";

import { type DeviceConnection, deviceSummary } from "@/devices.ts";
import { rememberDevice } from "@/renderer/devices.ts";
import { primaryButton, StatusRow } from "@/renderer/Panel.tsx";

const label = "Add Device";

const field = `h-9 rounded-lg border-2 border-menu-border bg-background px-2
  text-subheadline focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-menu-foreground aria-invalid:border-danger`;

function focus(element: HTMLElement | null): void {
  element?.focus();
}

function text(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

function DeviceForm({
  headingId,
  onDone,
}: {
  headingId: string;
  onDone: () => void;
}) {
  const addressId = useId();
  const passwordId = useId();
  const problemId = useId();
  const addressRef = useRef<HTMLInputElement>(null);
  const passwordRef = useRef<HTMLInputElement>(null);
  const [address, setAddress] = useState("");
  const [password, setPassword] = useState("");
  const [result, connect, connecting] = useActionState(
    async (
      _previous: DeviceConnection | null,
      form: FormData,
    ): Promise<DeviceConnection> => {
      const outcome = await window.bridge
        .addDevice({
          address: text(form, "address"),
          password: text(form, "password"),
        })
        .catch((error: unknown): DeviceConnection => ({
          state: "failed",
          field: null,
          message: error instanceof Error ? error.message : String(error),
        }));
      if (outcome.state === "connected") {
        rememberDevice(outcome.device);
      } else if (outcome.field !== null) {
        (outcome.field === "address"
          ? addressRef
          : passwordRef
        ).current?.select();
      }
      return outcome;
    },
    null,
  );

  const heading = (
    <h2 id={headingId} className="text-headline text-menu-muted">
      {label}
    </h2>
  );

  if (result?.state === "connected") {
    return (
      <div className="flex w-full max-w-xs flex-col gap-4">
        {heading}
        <dl role="status">
          <StatusRow
            icon={
              <CheckCircleIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-menu-foreground"
              />
            }
            title="Added"
            description={deviceSummary(result.device)}
          />
        </dl>
        <button
          ref={focus}
          type="button"
          onClick={onDone}
          className={`w-full ${primaryButton}`}
        >
          Done
        </button>
      </div>
    );
  }

  const problem = result?.state === "failed" ? result : null;

  return (
    <form action={connect} className="flex w-full max-w-xs flex-col gap-4">
      {heading}
      <div className="flex flex-col gap-1">
        <label htmlFor={addressId} className="text-footnote text-menu-muted">
          IP address
        </label>
        <input
          ref={addressRef}
          id={addressId}
          name="address"
          type="text"
          autoComplete="off"
          spellCheck={false}
          required
          placeholder="192.168.1.20"
          value={address}
          onChange={(event) => {
            setAddress(event.target.value);
          }}
          aria-invalid={problem?.field === "address"}
          aria-describedby={
            problem?.field === "address" ? problemId : undefined
          }
          className={field}
        />
      </div>
      <div className="flex flex-col gap-1">
        <label htmlFor={passwordId} className="text-footnote text-menu-muted">
          Root password
        </label>
        <input
          ref={passwordRef}
          id={passwordId}
          name="password"
          type="password"
          autoComplete="off"
          required
          value={password}
          onChange={(event) => {
            setPassword(event.target.value);
          }}
          aria-invalid={problem?.field === "password"}
          aria-describedby={
            problem?.field === "password" ? problemId : undefined
          }
          className={field}
        />
      </div>
      {problem !== null && (
        <p
          id={problemId}
          role="alert"
          className="text-footnote wrap-break-word text-danger"
        >
          {problem.message}
        </p>
      )}
      <button
        type="submit"
        disabled={connecting}
        className={`w-full ${primaryButton}`}
      >
        {connecting ? "Connecting…" : "Connect"}
      </button>
    </form>
  );
}

const placements = {
  panels: `top-[calc(anchor(top)-10px)] right-[calc(anchor(right)-10px)]
    bottom-[calc(anchor(bottom)-10px)] left-[calc(anchor(left)-10px)] size-auto
    max-h-none max-w-none p-4 [position-anchor:--home-panels]`,
  center: "m-auto w-[calc(100%-2rem)] max-w-md px-4 py-10",
} as const;

export function AddDevice({
  placement = "panels",
}: {
  placement?: keyof typeof placements;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const headingId = useId();
  const [opening, setOpening] = useState(0);
  return (
    <>
      <button
        type="button"
        aria-haspopup="dialog"
        onClick={() => {
          dialogRef.current?.showModal();
        }}
        className={`flex items-center gap-1.5 ${primaryButton}`}
      >
        <PlusIcon aria-hidden="true" className="size-4.5" strokeWidth={2} />
        {label}
      </button>
      <dialog
        ref={dialogRef}
        aria-labelledby={headingId}
        onClose={() => {
          setOpening((count) => count + 1);
        }}
        className={`rounded-2xl border-2 border-menu-border bg-menu
          text-menu-foreground shadow-lg backdrop:bg-background/60
          backdrop:backdrop-blur-xs ${placements[placement]}`}
      >
        <div className="grid size-full place-items-center">
          <DeviceForm
            key={opening}
            headingId={headingId}
            onDone={() => {
              dialogRef.current?.close();
            }}
          />
        </div>
        <button
          type="button"
          aria-label="Close"
          title="Close"
          onClick={() => {
            dialogRef.current?.close();
          }}
          className="absolute top-3 right-3 flex size-7 items-center
            justify-center rounded-md text-menu-muted transition-colors
            hover:bg-menu-border/50 hover:text-menu-foreground
            focus-visible:outline-2 focus-visible:outline-offset-2
            focus-visible:outline-menu-foreground active:bg-menu-border/80"
        >
          <XMarkIcon aria-hidden="true" className="size-5" />
        </button>
      </dialog>
    </>
  );
}
