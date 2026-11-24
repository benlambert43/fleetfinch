"use client";

import { useId, useState, useSyncExternalStore } from "react";

const prerequisites = [
  {
    id: "carbon",
    label:
      "I have run the Carbon exploit and I can now see Cydia on my home screen",
  },
  { id: "iocaste", label: "I have installed iocaste untether by staturnz" },
  {
    id: "openssh",
    label: "I have installed the OpenSSH package by Jay Freeman (saurik)",
  },
] as const;

type PrerequisiteId = (typeof prerequisites)[number]["id"];

const storageKey = "fleetfinch-prerequisites";
const listeners = new Set<() => void>();
const noneCompleted: ReadonlySet<PrerequisiteId> = new Set();
let completed: ReadonlySet<PrerequisiteId> | undefined;

function readStored(): ReadonlySet<PrerequisiteId> {
  try {
    const saved: unknown = JSON.parse(localStorage.getItem(storageKey) ?? "{}");
    const entries = new Map<string, unknown>(
      typeof saved === "object" && saved !== null ? Object.entries(saved) : [],
    );
    return new Set(
      prerequisites
        .map(({ id }) => id)
        .filter((id) => entries.get(id) === true),
    );
  } catch (error) {
    console.warn("Could not read the saved prerequisites", error);
    return noneCompleted;
  }
}

function subscribe(listener: () => void): () => void {
  function onStorage(event: StorageEvent) {
    if (event.key === storageKey) {
      completed = undefined;
      listener();
    }
  }
  listeners.add(listener);
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", onStorage);
  };
}

function getSnapshot(): ReadonlySet<PrerequisiteId> {
  completed ??= readStored();
  return completed;
}

function getServerSnapshot(): ReadonlySet<PrerequisiteId> {
  return noneCompleted;
}

function save(next: ReadonlySet<PrerequisiteId>): void {
  completed = next;
  try {
    localStorage.setItem(
      storageKey,
      JSON.stringify(
        Object.fromEntries(prerequisites.map(({ id }) => [id, next.has(id)])),
      ),
    );
  } catch (error) {
    console.warn("Could not save the prerequisites", error);
  }
  for (const listener of listeners) {
    listener();
  }
}

export function InstallChecklist() {
  const done = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const [failedAttempts, setFailedAttempts] = useState(0);
  const errorId = useId();
  const ready = done.size === prerequisites.length;

  function toggle(id: PrerequisiteId, checked: boolean) {
    const next = new Set(done);
    if (checked) {
      next.add(id);
    } else {
      next.delete(id);
    }
    save(next);
    if (next.size === prerequisites.length) {
      setFailedAttempts(0);
    }
  }

  function install() {
    if (!ready) {
      setFailedAttempts((count) => count + 1);
    }
  }

  return (
    <>
      <fieldset className="mt-2 min-w-0">
        <legend className="mb-2 text-muted">
          Check off each prerequisite once it is complete.
        </legend>
        <div className="rounded-xl border border-border">
          {prerequisites.map(({ id, label }) => (
            <label
              key={id}
              className="flex min-h-11 cursor-pointer items-center gap-3
                border-t border-border px-4 py-2 text-muted first:border-t-0"
            >
              <span className="relative flex shrink-0">
                <input
                  type="checkbox"
                  checked={done.has(id)}
                  onChange={(event) => {
                    toggle(id, event.currentTarget.checked);
                  }}
                  className="peer size-6 cursor-pointer appearance-none
                    rounded-md border border-muted checked:border-primary
                    checked:bg-primary focus-visible:outline-2
                    focus-visible:outline-offset-2
                    focus-visible:outline-foreground"
                />
                <svg
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="3"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="pointer-events-none absolute inset-1 hidden
                    text-primary-foreground peer-checked:block"
                >
                  <path d="M5 12.5l4.5 4.5L19 7.5" />
                </svg>
              </span>
              {label}
            </label>
          ))}
        </div>
      </fieldset>
      <button
        type="button"
        aria-disabled={!ready}
        aria-describedby={errorId}
        onClick={install}
        className="mt-4 rounded-lg border border-primary-border bg-primary-soft
          px-4 py-2.75 text-primary-soft-foreground
          not-aria-disabled:hover:bg-primary
          not-aria-disabled:hover:text-primary-foreground
          focus-visible:outline-2 focus-visible:outline-offset-2
          focus-visible:outline-foreground not-aria-disabled:active:bg-primary
          not-aria-disabled:active:text-primary-foreground
          aria-disabled:cursor-default aria-disabled:border-border
          aria-disabled:bg-foreground/10 aria-disabled:text-muted"
      >
        Install FleetFinch
      </button>
      <p
        key={failedAttempts}
        id={errorId}
        role="alert"
        hidden={failedAttempts === 0}
        className="mt-2 text-danger"
      >
        Check off all three prerequisites above as complete before installing
        FleetFinch.
      </p>
    </>
  );
}
