import { useActionState, useId, useState } from "react";

import { setDevices } from "@/renderer/devices.ts";
import { primaryButton, secondaryButton } from "@/renderer/Panel.tsx";

const minimumPassword = 8;

interface Notice {
  tone: "status" | "alert";
  text: string;
}

function count(amount: number, noun: string): string {
  return `${String(amount)} ${noun}${amount === 1 ? "" : "s"}`;
}

async function exportBackup(password: string): Promise<Notice | null> {
  const result = await window.bridge.exportBackup(password);
  switch (result.state) {
    case "saved":
      return { tone: "status", text: `Saved to ${result.file}` };
    case "canceled":
      return null;
    case "failed":
      return { tone: "alert", text: result.message };
  }
}

async function restoreBackup(password: string): Promise<Notice | null> {
  const result = await window.bridge.restoreBackup(password);
  switch (result.state) {
    case "restored":
      setDevices(result.devices);
      return {
        tone: "status",
        text:
          result.keys + result.added === 0
            ? "Everything in this backup is already here."
            : `Restored ${count(result.keys, "key")} and ${count(result.added, "device")}.`,
      };
    case "canceled":
      return null;
    case "failed":
      return { tone: "alert", text: result.message };
  }
}

export function DeviceBackup() {
  const passwordId = useId();
  const [password, setPassword] = useState("");
  const [notice, run, running] = useActionState(
    async (
      _previous: Notice | null,
      form: FormData,
    ): Promise<Notice | null> => {
      if (password.length < minimumPassword) {
        return {
          tone: "alert",
          text: `Use at least ${String(minimumPassword)} characters.`,
        };
      }
      const task =
        form.get("intent") === "restore" ? restoreBackup : exportBackup;
      const outcome = await task(password).catch((error: unknown): Notice => ({
        tone: "alert",
        text: error instanceof Error ? error.message : String(error),
      }));
      if (outcome?.tone === "status") {
        setPassword("");
      }
      return outcome;
    },
    null,
  );

  return (
    <form action={run} className="flex w-full max-w-md flex-col gap-3">
      <p className="text-footnote text-muted">
        Saves the key that signs in to your devices as root, and your device
        list, in a password-protected file.
      </p>
      <div className="flex flex-col gap-1">
        <label htmlFor={passwordId} className="text-footnote text-muted">
          Backup password
        </label>
        <input
          id={passwordId}
          name="password"
          type="password"
          autoComplete="off"
          required
          minLength={minimumPassword}
          value={password}
          onChange={(event) => {
            setPassword(event.target.value);
          }}
          className="h-9 rounded-lg border-2 border-border bg-background px-2
            text-subheadline focus-visible:outline-2
            focus-visible:outline-offset-2 focus-visible:outline-foreground"
        />
      </div>
      {notice !== null && (
        <p
          role={notice.tone}
          className={`text-footnote wrap-break-word ${
            notice.tone === "alert" ? "text-danger" : "text-muted"
          }`}
        >
          {notice.text}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <button
          type="submit"
          name="intent"
          value="export"
          disabled={running}
          className={primaryButton}
        >
          Export Backup
        </button>
        <button
          type="submit"
          name="intent"
          value="restore"
          disabled={running}
          className={secondaryButton}
        >
          Restore Backup
        </button>
      </div>
    </form>
  );
}
