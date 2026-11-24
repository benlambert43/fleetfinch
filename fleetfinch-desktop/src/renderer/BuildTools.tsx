import {
  CheckCircleIcon,
  ExclamationCircleIcon,
} from "@heroicons/react/20/solid";
import { use, useEffect, useId, useState, useTransition } from "react";

import {
  areBuildToolsReady,
  type BuildToolsProgress,
  type BuildToolsSetUpOptions,
  type BuildToolsStatus,
  type BuildToolStep,
  buildToolLabels,
  buildToolSteps,
  type PasswordAccount,
  readyBuildTools,
  type SystemPackage,
} from "@/buildTools.ts";
import {
  finishBuildToolsCheck,
  finishBuildToolsTask,
  startBuildToolsTask,
} from "@/renderer/buildToolsActivity.ts";
import {
  PanelActions,
  PanelBody,
  primaryButton,
  StatusList,
  StatusRow,
} from "@/renderer/Panel.tsx";

interface Problem {
  message: string;
  output: string;
  step: BuildToolStep | null;
  retry: "check" | "setUp";
}

type Updates = "unchecked" | "outdated" | "current";

const updateLabels: Record<Updates, string> = {
  unchecked: "Check for Updates",
  outdated: "Update Build Tools",
  current: "Up to Date",
};

const upToDateButton =
  "h-9 rounded-lg bg-foreground/10 px-3 text-subheadline text-muted";

interface PasswordRequest {
  account: PasswordAccount;
  packages: SystemPackage[];
  message: string | null;
  clean: BuildToolStep | undefined;
}

const savedStatus = window.bridge.getBuildTools();

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
              ...(toolchain.missing.length === 0
                ? []
                : [`no ${toolchain.missing.join(", ")}`]),
            ];
      const sdkPart =
        sdk === null
          ? "SDK not installed"
          : `SDK ${sdk.release ?? "unknown"}${sdk.adjusted ? "" : " not adjusted"}`;
      return [...toolchainParts, sdkPart].join(" · ");
    }
  }
}

function buttonLabel(
  busy: boolean,
  checking: boolean,
  ready: boolean,
  updates: Updates,
): string {
  if (busy) {
    return checking ? "Checking…" : "Setting Up…";
  }
  return ready ? updateLabels[updates] : "Set Up Build Tools";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function BuildTools() {
  const [status, setStatus] = useState(use(savedStatus));
  const [progress, setProgress] = useState<BuildToolsProgress | null>(null);
  const [problem, setProblem] = useState<Problem | null>(null);
  const [request, setRequest] = useState<PasswordRequest | null>(null);
  const [updates, setUpdates] = useState<Updates>("unchecked");
  const [pending, startTransition] = useTransition();
  const [checking, startChecking] = useTransition();
  const passwordId = useId();

  useEffect(() => window.bridge.onBuildToolsProgress(setProgress), []);

  useEffect(
    () => () => {
      setUpdates("unchecked");
    },
    [],
  );

  const ready = readyBuildTools(status);
  const allReady = areBuildToolsReady(status);
  const busy = pending || checking || progress !== null;
  const upToDate = allReady && updates === "current";

  function checkForUpdates() {
    setProblem(null);
    startBuildToolsTask("Check build tools");
    startChecking(async () => {
      const result = await window.bridge
        .checkBuildTools()
        .catch((error: unknown) => ({
          state: "error" as const,
          message: errorMessage(error),
        }));
      finishBuildToolsCheck(result);
      startChecking(() => {
        setProgress(null);
        if (result.state === "error") {
          setProblem({
            message: result.message,
            output: "",
            step: null,
            retry: "check",
          });
          return;
        }
        setStatus(result.status);
        if (result.state === "checked") {
          setUpdates(result.updates.length > 0 ? "outdated" : "current");
          return;
        }
        const damaged = result.state === "damaged";
        setProblem({
          message: `${buildToolLabels[result.step]}: ${result.message}`,
          output: result.output,
          step: damaged ? result.step : null,
          retry: damaged ? "setUp" : "check",
        });
      });
    });
  }

  function setUp(options: BuildToolsSetUpOptions = {}) {
    setProblem(null);
    startBuildToolsTask(
      options.clean === undefined
        ? undefined
        : `Retry ${buildToolLabels[options.clean]}`,
    );
    startTransition(async () => {
      const result = await window.bridge
        .setUpBuildTools(options)
        .catch((error: unknown) => ({
          state: "error" as const,
          message: errorMessage(error),
        }));
      finishBuildToolsTask(result);
      startTransition(() => {
        setProgress(null);
        if (result.state === "error") {
          setProblem({
            message: result.message,
            output: "",
            step: null,
            retry: "setUp",
          });
          return;
        }
        setStatus(result.status);
        if (result.state === "ready") {
          setUpdates("current");
        }
        setRequest(
          result.state === "password"
            ? {
                account: result.account,
                packages: result.packages,
                message: result.message,
                clean: options.clean,
              }
            : null,
        );
        setProblem(
          result.state === "failed"
            ? {
                message: `${buildToolLabels[result.step]}: ${result.message}`,
                output: result.output,
                step: result.step,
                retry: "setUp",
              }
            : null,
        );
      });
    });
  }

  function submitPassword(form: FormData) {
    const password = form.get("password");
    if (typeof password === "string" && password !== "") {
      setUp({ password, clean: request?.clean });
    }
  }

  return (
    <PanelBody>
      <StatusList>
        {buildToolSteps.map((step) => (
          <StatusRow
            key={step}
            icon={
              ready[step] ? (
                <CheckCircleIcon
                  aria-hidden="true"
                  className="size-5 shrink-0 text-foreground"
                />
              ) : (
                <ExclamationCircleIcon
                  aria-hidden="true"
                  className="size-5 shrink-0 text-danger"
                />
              )
            }
            title={buildToolLabels[step]}
            state={ready[step] ? "ready" : "needs setting up"}
            description={describe(step, status)}
          />
        ))}
      </StatusList>
      <PanelActions>
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
        {request === null && problem === null && (
          <button
            type="button"
            onClick={() => {
              if (allReady && updates === "unchecked") {
                checkForUpdates();
              } else {
                setUp();
              }
            }}
            disabled={busy || upToDate}
            className={upToDate ? upToDateButton : primaryButton}
          >
            {buttonLabel(busy, checking, allReady, updates)}
          </button>
        )}
        {request === null && problem !== null && (
          <button
            type="button"
            title={
              problem.step === null
                ? "Try again"
                : `Clean up the failed ${buildToolLabels[problem.step]} install and try again`
            }
            onClick={() => {
              if (problem.retry === "check") {
                checkForUpdates();
              } else {
                setUp({ clean: problem.step ?? undefined });
              }
            }}
            disabled={busy}
            className={primaryButton}
          >
            Retry
          </button>
        )}
        {request !== null && (
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
      </PanelActions>
    </PanelBody>
  );
}
