import {
  type BuildToolsCheck,
  type BuildToolsLogLine,
  type BuildToolsProgress,
  type BuildToolsSetup,
  type BuildToolsSetUpOptions,
  type BuildToolsStatus,
  type BuildToolStep,
  buildToolSteps,
} from "@/buildTools.ts";
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

async function setUp(
  listener: BuildToolsListener,
  { password, clean }: BuildToolsSetUpOptions,
): Promise<BuildToolsSetup> {
  for (const step of buildToolSteps) {
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
      console.error(`Build tools: the ${step} step failed`, error);
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
  running ??= setUp(listener, options).finally(() => {
    running = null;
  });
  return running;
}

async function check(listener: BuildToolsListener): Promise<BuildToolsCheck> {
  const updates: BuildToolStep[] = [];
  let unreachable: StepFailure | null = null;
  for (const step of buildToolSteps) {
    const report = reporter(step, listener);
    try {
      await checkers[step].verify(report);
    } catch (error) {
      console.error(`Build tools: the ${step} install is damaged`, error);
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
      console.error(`Build tools: looking for ${step} updates failed`, error);
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
  checking ??= check(listener).finally(() => {
    checking = null;
  });
  return checking;
}
