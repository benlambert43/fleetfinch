import {
  type BuildToolsLogLine,
  type BuildToolsProgress,
  type BuildToolsSetup,
  type BuildToolsStatus,
  type BuildToolStep,
  buildToolSteps,
} from "@/buildTools.ts";
import {
  lastLines,
  PasswordNeeded,
  type Report,
  StepError,
} from "@/main/buildTools/process.ts";
import { installSdk, readSdk } from "@/main/buildTools/sdk.ts";
import {
  installSystemPackages,
  readSystemPackages,
} from "@/main/buildTools/system.ts";
import { installTheos, readTheos } from "@/main/buildTools/theos.ts";
import {
  installToolchain,
  readToolchain,
} from "@/main/buildTools/toolchain.ts";

const installers: Record<
  BuildToolStep,
  (report: Report, password: string | undefined) => Promise<void>
> = {
  system: installSystemPackages,
  theos: installTheos,
  toolchain: async (report) => {
    await installToolchain(report);
    await installSdk(report);
  },
};

const fractionStep = 0.01;

let running: Promise<BuildToolsSetup> | null = null;

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
  password: string | undefined,
): Promise<BuildToolsSetup> {
  for (const step of buildToolSteps) {
    try {
      await installers[step](reporter(step, listener), password);
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
        step,
        message: error instanceof Error ? error.message : String(error),
        output: error instanceof StepError ? lastLines(error.output) : "",
        status: await readBuildTools(),
      };
    }
  }
  return { state: "ready", status: await readBuildTools() };
}

export function setUpBuildTools(
  listener: BuildToolsListener,
  password?: string,
): Promise<BuildToolsSetup> {
  running ??= setUp(listener, password).finally(() => {
    running = null;
  });
  return running;
}
