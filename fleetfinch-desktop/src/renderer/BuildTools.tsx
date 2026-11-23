import {
  CheckCircleIcon,
  ExclamationCircleIcon,
} from "@heroicons/react/20/solid";
import { use, useEffect, useId, useState, useTransition } from "react";

import {
  areBuildToolsReady,
  type BuildToolsProgress,
  type BuildToolsStatus,
  type BuildToolStep,
  buildToolLabels,
  buildToolSteps,
  type PasswordAccount,
  readyBuildTools,
  type SystemPackage,
} from "@/buildTools.ts";
import {
  finishBuildToolsTask,
  startBuildToolsTask,
} from "@/renderer/buildToolsActivity.ts";

interface Problem {
  message: string;
  output: string;
}

interface PasswordRequest {
  account: PasswordAccount;
  packages: SystemPackage[];
  message: string | null;
}

const savedStatus = window.bridge.getBuildTools();

const primaryButton = `h-9 rounded-lg bg-primary px-3 text-subheadline
  text-primary-foreground hover:opacity-90 focus-visible:outline-2
  focus-visible:outline-offset-2 focus-visible:outline-foreground
  disabled:opacity-60`;

function describe(step: BuildToolStep, status: BuildToolsStatus): string {
  switch (step) {
    case "system": {
      const missing = status.system
        .filter((item) => !item.installed)
        .map((item) => item.name);
      return missing.length === 0
        ? `All ${String(status.system.length)} installed`
        : `Missing ${missing.join(", ")}`;
    }
    case "theos": {
      if (status.theos === null) {
        return "Not installed";
      }
      const { commit, date } = status.theos;
      return `Commit ${commit ?? "unknown"}${date === null ? "" : ` from ${date}`}`;
    }
    case "toolchain": {
      const { toolchain, sdk } = status;
      if (toolchain === null && sdk === null) {
        return "Not installed";
      }
      const toolchainParts =
        toolchain === null
          ? ["Toolchain not installed"]
          : [
              toolchain.release ?? "Unknown release",
              toolchain.clang === null
                ? "clang does not run"
                : `clang ${toolchain.clang}`,
              ...(toolchain.armv7 ? [] : ["cannot link armv7"]),
              ...(toolchain.ldid ? [] : ["no ldid"]),
            ];
      const sdkPart =
        sdk === null
          ? "SDK not installed"
          : `SDK ${sdk.release ?? "unknown"}${sdk.adjusted ? "" : " not adjusted"}`;
      return [...toolchainParts, sdkPart].join(" · ");
    }
  }
}

function buttonLabel(busy: boolean, ready: boolean): string {
  if (busy) {
    return "Setting Up…";
  }
  return ready ? "Update Build Tools" : "Set Up Build Tools";
}

export function BuildTools() {
  const [status, setStatus] = useState(use(savedStatus));
  const [progress, setProgress] = useState<BuildToolsProgress | null>(null);
  const [problem, setProblem] = useState<Problem | null>(null);
  const [request, setRequest] = useState<PasswordRequest | null>(null);
  const [pending, startTransition] = useTransition();
  const passwordId = useId();

  useEffect(() => window.bridge.onBuildToolsProgress(setProgress), []);

  const ready = readyBuildTools(status);
  const busy = pending || progress !== null;

  function setUp(password?: string) {
    setProblem(null);
    startBuildToolsTask();
    startTransition(async () => {
      const result = await window.bridge
        .setUpBuildTools(password)
        .catch((error: unknown) => ({
          state: "error" as const,
          message: error instanceof Error ? error.message : String(error),
        }));
      finishBuildToolsTask(result);
      startTransition(() => {
        setProgress(null);
        if (result.state === "error") {
          setProblem({ message: result.message, output: "" });
          return;
        }
        setStatus(result.status);
        setRequest(
          result.state === "password"
            ? {
                account: result.account,
                packages: result.packages,
                message: result.message,
              }
            : null,
        );
        setProblem(
          result.state === "failed"
            ? {
                message: `${buildToolLabels[result.step]}: ${result.message}`,
                output: result.output,
              }
            : null,
        );
      });
    });
  }

  function submitPassword(form: FormData) {
    const password = form.get("password");
    if (typeof password === "string" && password !== "") {
      setUp(password);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <dl className="flex flex-col gap-3">
        {buildToolSteps.map((step) => (
          <div key={step} className="flex items-start gap-2">
            {ready[step] ? (
              <CheckCircleIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-foreground"
              />
            ) : (
              <ExclamationCircleIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-danger"
              />
            )}
            <div className="flex min-w-0 flex-wrap items-baseline gap-x-2">
              <dt className="text-subheadline">
                {buildToolLabels[step]}
                <span className="sr-only">
                  {ready[step] ? ", ready" : ", needs setting up"}
                </span>
              </dt>
              <dd className="text-footnote wrap-break-word text-muted">
                {describe(step, status)}
              </dd>
            </div>
          </div>
        ))}
      </dl>
      <div className="mt-auto flex flex-col items-start gap-4">
        {progress !== null && (
          <div role="status" className="flex flex-col gap-1 self-stretch">
            <p className="text-footnote wrap-break-word">
              {buildToolLabels[progress.step]}: {progress.message}
            </p>
            <progress
              max={1}
              value={progress.fraction ?? undefined}
              aria-label={`${buildToolLabels[progress.step]} progress`}
              className="h-1.5 w-full accent-primary"
            />
          </div>
        )}
        {problem !== null && (
          <div role="alert" className="flex flex-col gap-1 self-stretch">
            <p className="text-footnote wrap-break-word text-danger">
              {problem.message}
            </p>
            {problem.output !== "" && (
              <pre
                className="rounded-lg border border-border p-2 font-mono
                  text-footnote wrap-break-word whitespace-pre-wrap"
              >
                {problem.output}
              </pre>
            )}
          </div>
        )}
        {request === null ? (
          <button
            type="button"
            onClick={() => {
              setUp();
            }}
            disabled={busy}
            className={primaryButton}
          >
            {buttonLabel(busy, areBuildToolsReady(status))}
          </button>
        ) : (
          <form
            action={submitPassword}
            className="flex flex-col gap-2 self-stretch"
          >
            <p className="text-footnote">
              Installing {request.packages.join(", ")} needs administrator
              rights.{" "}
              {request.account === "yours"
                ? "Enter your password to continue."
                : "Enter the root password to continue."}
            </p>
            {request.message !== null && (
              <p role="alert" className="text-footnote text-danger">
                {request.message}
              </p>
            )}
            <label htmlFor={passwordId} className="text-footnote text-muted">
              {request.account === "yours" ? "Your password" : "Root password"}
            </label>
            <div className="flex flex-wrap gap-2">
              <input
                id={passwordId}
                name="password"
                type="password"
                autoComplete="off"
                required
                disabled={busy}
                className="h-9 max-w-md min-w-40 flex-1 basis-48 rounded-lg
                  border-2 border-border bg-background px-2 text-subheadline
                  focus-visible:outline-2 focus-visible:outline-offset-2
                  focus-visible:outline-foreground"
              />
              <button type="submit" disabled={busy} className={primaryButton}>
                {busy ? "Installing…" : "Install"}
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => {
                  setRequest(null);
                }}
                className="h-9 rounded-lg border-2 border-border px-3
                  text-subheadline hover:bg-foreground/5 focus-visible:outline-2
                  focus-visible:outline-offset-2
                  focus-visible:outline-foreground disabled:opacity-60"
              >
                Cancel
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
