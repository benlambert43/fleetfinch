import { XMarkIcon } from "@heroicons/react/20/solid";
import { PlusIcon } from "@heroicons/react/24/outline";
import { useRef } from "react";

import { primaryButton } from "@/renderer/Panel.tsx";

const label = "Add Device";

export function AddDevice() {
  const dialogRef = useRef<HTMLDialogElement>(null);
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
        aria-label={label}
        className="top-[calc(anchor(top)-10px)] right-[calc(anchor(right)-10px)]
          bottom-[calc(anchor(bottom)-10px)] left-[calc(anchor(left)-10px)]
          size-auto max-h-none max-w-none rounded-2xl border-2
          border-menu-border bg-menu p-4 text-menu-foreground shadow-lg
          [position-anchor:--home-panels] backdrop:bg-background/60
          backdrop:backdrop-blur-xs"
      >
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
        <p
          className="grid size-full place-items-center text-body
            text-menu-muted"
        >
          Placeholder
        </p>
      </dialog>
    </>
  );
}
