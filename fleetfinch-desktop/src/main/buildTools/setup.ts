import {
  type BuildToolsCheck,
  buildToolsCheckSummary,
  buildToolsFindings,
  type BuildToolsLogLine,
  type BuildToolsProgress,
  type BuildToolsSetup,
  type BuildToolsSetUpOptions,
  type BuildToolsStatus,
  type BuildToolStep,
  buildToolLabels,
  buildToolSteps,
  checkBuildToolsTitle,
  setUpBuildToolsTitle,
} from "@/buildTools.ts";
import type { LogGroupState } from "@/logs.ts";
import {
  lastLines,
  PasswordNeeded,
  type Report,
  StepError,
  type StepOptions,
} from "@/main/buildTools/process.ts";
import {
  cleanSdk,
  hasSdkUpdate,
  installSdk,
  readSdk,
  verifySdk,
} from "@/main/buildTools/sdk.ts";
import {
  installSystemPackages,
  readSystemPackages,
  verifySystemPackages,
} from "@/main/buildTools/system.ts";
import {
  hasTheosUpdate,
  installTheos,
  readTheos,
  verifyTheos,
} from "@/main/buildTools/theos.ts";
import {
  cleanToolchain,
  hasToolchainUpdate,
  installToolchain,
  readToolchain,
  verifyToolchain,
} from "@/main/buildTools/toolchain.ts";
import {
  describeError,
  logAppError,
  type LogWriter,
  openLogGroup,
} from "@/main/logs.ts";

const installers: Record<
  BuildToolStep,
  (report: Report, options: StepOptions) => Promise<void>
> = {
  system: installSystemPackages,
  theos: installTheos,
  toolchain: async (report, { clean }) => {
    if (clean) {
      await cleanToolchain(report);
      await cleanSdk(report);
    }
    await installToolchain(report);
    await installSdk(report);
  },
};

interface Checker {
  verify: (report: Report) => Promise<void>;
  hasUpdate: (report: Report) => Promise<boolean>;
}

const checkers: Record<BuildToolStep, Checker> = {
  system: {
    verify: verifySystemPackages,
    hasUpdate: () => Promise.resolve(false),
  },
  theos: { verify: verifyTheos, hasUpdate: hasTheosUpdate },
  toolchain: {
    verify: async (report) => {
      await verifyToolchain(report);
      await verifySdk(report);
    },
    hasUpdate: async (report) => {
      const toolchain = await hasToolchainUpdate(report);
      const sdk = await hasSdkUpdate(report);
      return toolchain || sdk;
    },
  },
};

const fractionStep = 0.01;

let running: Promise<BuildToolsSetup> | null = null;
let checking: Promise<BuildToolsCheck> | null = null;

interface StepFailure {
  step: BuildToolStep;
  message: string;
  output: string;
}

export interface BuildToolsListener {
  progress: (progress: BuildToolsProgress) => void;
  log: (line: BuildToolsLogLine) => void;
}

interface Outcome {
  state: Exclude<LogGroupState, "running">;
  lines: string[];
}

export async function readBuildTools(): Promise<BuildToolsStatus> {
  const [system, theos, toolchain, sdk] = await Promise.all([
    readSystemPackages(),
    readTheos(),
    readToolchain(),
    readSdk(),
  ]);
  return { system, theos, toolchain, sdk };
}

function stepFailure(step: BuildToolStep, error: unknown): StepFailure {
  return {
    step,
    message: error instanceof Error ? error.message : String(error),
    output: error instanceof StepError ? lastLines(error.output) : "",
  };
}

function reporter(step: BuildToolStep, listener: BuildToolsListener): Report {
  let last: BuildToolsProgress | null = null;
  return {
    progress: (message, fraction = null) => {
      if (last?.message !== message) {
        listener.log({ kind: "message", text: message });
      }
      const changed =
        last?.message !== message ||
        fraction === null ||
        last.fraction === null ||
        fraction === 1 ||
        Math.abs(fraction - last.fraction) >= fractionStep;
      if (changed) {
        last = { step, message, fraction };
        listener.progress(last);
      }
    },
    log: listener.log,
  };
}

function failedOutcome(step: BuildToolStep, message: string): Outcome {
  return { state: "failed", lines: [`${buildToolLabels[step]}: ${message}`] };
}

function setUpOutcome(result: BuildToolsSetup): Outcome {
  switch (result.state) {
    case "ready":
      return { state: "done", lines: ["Every build tool is ready"] };
    case "password":
      return {
        state: "stopped",
        lines: [
          result.message ??
            `Waiting for a password to install ${result.packages.join(", ")}`,
        ],
      };
    case "failed":
      return failedOutcome(result.step, result.message);
  }
}

function checkOutcome(result: BuildToolsCheck): Outcome {
  if (result.state !== "checked") {
    return failedOutcome(result.step, result.message);
  }
  return {
    state: "done",
    lines: buildToolsCheckSummary(
      buildToolsFindings(result.updates, result.status),
    ),
  };
}

async function recorded<Result>(
  title: string,
  listener: BuildToolsListener,
  run: (listener: BuildToolsListener, group: LogWriter) => Promise<Result>,
  outcome: (result: Result) => Outcome,
): Promise<Result> {
  const group = openLogGroup("computer", title);
  const both: BuildToolsListener = {
    progress: listener.progress,
    log: (line) => {
      listener.log(line);
      group.log(line);
    },
  };
  try {
    const result = await run(both, group);
    const { state, lines } = outcome(result);
    for (const text of lines) {
      group.log({ kind: state === "failed" ? "error" : "message", text });
    }
    group.finish(state, lines.join(" · "));
    return result;
  } catch (error) {
    group.log({ kind: "error", text: describeError(error) });
    group.finish(
      "failed",
      error instanceof Error ? error.message : String(error),
    );
    throw error;
  }
}

async function setUp(
  listener: BuildToolsListener,
  group: LogWriter,
  { password, clean }: BuildToolsSetUpOptions,
): Promise<BuildToolsSetup> {
  for (const step of buildToolSteps) {
    group.log({ kind: "step", text: buildToolLabels[step] });
    try {
      await installers[step](reporter(step, listener), {
        password,
        clean: clean === step,
      });
    } catch (error) {
      if (error instanceof PasswordNeeded) {
        return {
          state: "password",
          account: error.account,
          packages: error.packages,
          message: error.reason,
          status: await readBuildTools(),
        };
      }
      logAppError(`Build tools: the ${step} step failed`, error);
      return {
        state: "failed",
        ...stepFailure(step, error),
        status: await readBuildTools(),
      };
    }
  }
  return { state: "ready", status: await readBuildTools() };
}

export function setUpBuildTools(
  listener: BuildToolsListener,
  options: BuildToolsSetUpOptions = {},
): Promise<BuildToolsSetup> {
  running ??= recorded(
    setUpBuildToolsTitle(options.clean),
    listener,
    (both, group) => setUp(both, group, options),
    setUpOutcome,
  ).finally(() => {
    running = null;
  });
  return running;
}

async function check(
  listener: BuildToolsListener,
  group: LogWriter,
): Promise<BuildToolsCheck> {
  const updates: BuildToolStep[] = [];
  let unreachable: StepFailure | null = null;
  for (const step of buildToolSteps) {
    group.log({ kind: "step", text: buildToolLabels[step] });
    const report = reporter(step, listener);
    try {
      await checkers[step].verify(report);
    } catch (error) {
      logAppError(`Build tools: the ${step} install is damaged`, error);
      return {
        state: "damaged",
        ...stepFailure(step, error),
        status: await readBuildTools(),
      };
    }
    try {
      if (await checkers[step].hasUpdate(report)) {
        updates.push(step);
      }
    } catch (error) {
      logAppError(`Build tools: looking for ${step} updates failed`, error);
      unreachable ??= stepFailure(step, error);
    }
  }
  const status = await readBuildTools();
  return unreachable === null
    ? { state: "checked", updates, status }
    : { state: "failed", ...unreachable, status };
}

export function checkBuildTools(
  listener: BuildToolsListener,
): Promise<BuildToolsCheck> {
  checking ??= recorded(
    checkBuildToolsTitle,
    listener,
    check,
    checkOutcome,
  ).finally(() => {
    checking = null;
  });
  return checking;
}
