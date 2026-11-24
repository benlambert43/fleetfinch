export const buildToolsProgressChannel = "buildToolsProgress";
export const buildToolsLogChannel = "buildToolsLog";

export const buildTarget = {
  sdk: "iPhoneOS9.3",
  sdkVersion: "9.3",
  minimumVersion: "9.0",
  architecture: "armv7",
} as const;

export const systemPackages = [
  "git",
  "make",
  "perl",
  "rsync",
  "xz-utils",
  "ca-certificates",
  "openssh-client",
  "usbmuxd",
] as const;

export type SystemPackage = (typeof systemPackages)[number];

export type PasswordAccount = "yours" | "root";

export const buildToolSteps = ["system", "theos", "toolchain"] as const;

export type BuildToolStep = (typeof buildToolSteps)[number];

export const buildToolLabels: Record<BuildToolStep, string> = {
  system: "System packages",
  theos: "Theos",
  toolchain: `iOS toolchain and ${buildTarget.sdkVersion} SDK`,
};

export interface BuildToolsStatus {
  system: { name: SystemPackage; installed: boolean }[];
  theos: { commit: string | null; date: string | null } | null;
  toolchain: {
    release: string | null;
    clang: string | null;
    armv7: boolean;
    missing: string[];
  } | null;
  sdk: { release: string | null; adjusted: boolean } | null;
}

export interface BuildToolsSetUpOptions {
  password?: string | undefined;
  clean?: BuildToolStep | undefined;
}

export interface BuildToolsProgress {
  step: BuildToolStep;
  message: string;
  fraction: number | null;
}

export interface BuildToolsLogLine {
  kind: "message" | "command" | "output";
  text: string;
}

export type BuildToolsSetup =
  | { state: "ready"; status: BuildToolsStatus }
  | {
      state: "password";
      account: PasswordAccount;
      packages: SystemPackage[];
      message: string | null;
      status: BuildToolsStatus;
    }
  | {
      state: "failed";
      step: BuildToolStep;
      message: string;
      output: string;
      status: BuildToolsStatus;
    };

export type BuildToolsCheck =
  | { state: "checked"; updates: BuildToolStep[]; status: BuildToolsStatus }
  | {
      state: "damaged" | "failed";
      step: BuildToolStep;
      message: string;
      output: string;
      status: BuildToolsStatus;
    };

export function readyBuildTools(
  status: BuildToolsStatus,
): Record<BuildToolStep, boolean> {
  return {
    system: status.system.every((item) => item.installed),
    theos: status.theos !== null,
    toolchain:
      status.toolchain !== null &&
      status.toolchain.clang !== null &&
      status.toolchain.armv7 &&
      status.toolchain.missing.length === 0 &&
      status.sdk?.adjusted === true,
  };
}

export function areBuildToolsReady(status: BuildToolsStatus): boolean {
  return Object.values(readyBuildTools(status)).every(Boolean);
}
