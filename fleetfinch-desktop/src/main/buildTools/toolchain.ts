import path from "node:path";

import { type BuildToolsStatus, buildTarget } from "@/buildTools.ts";
import {
  installReleaseArchive,
  removeArchiveInstall,
} from "@/main/buildTools/archive.ts";
import { latestReleaseAsset } from "@/main/buildTools/github.ts";
import {
  forgetRelease,
  iosToolchainFolder,
  isExecutable,
  readReleases,
  saveRelease,
  toolchainParentFolder,
} from "@/main/buildTools/paths.ts";
import {
  type Report,
  runProcess,
  StepError,
} from "@/main/buildTools/process.ts";

const toolchainRepository = "L1ghtmann/llvm-project";
const architectures: Partial<Record<string, string>> = {
  x64: "x86_64",
  arm64: "aarch64",
};
const insideArchive = path.join("linux", "iphone");
const compiler = path.join("bin", "clang");

function tool(name: string): string {
  return path.join(iosToolchainFolder(), "bin", name);
}

async function printed(file: string, args: string[]): Promise<string | null> {
  const { code, output } = await runProcess(file, args, {
    timeoutMs: 10_000,
  }).catch(() => ({ code: null, output: "" }));
  return code === 0 ? output : null;
}

export async function readToolchain(): Promise<BuildToolsStatus["toolchain"]> {
  if (!(await isExecutable(tool("clang")))) {
    return null;
  }
  const [clang, linker, ldid, releases] = await Promise.all([
    printed(tool("clang"), ["--version"]),
    printed(tool("ld"), ["-v"]),
    isExecutable(tool("ldid")),
    readReleases(),
  ]);
  return {
    release: releases.toolchain ?? null,
    clang: /clang version (\S+)/.exec(clang ?? "")?.[1] ?? null,
    armv7: new RegExp(
      String.raw`support archs:.*\b${buildTarget.architecture}\b`,
    ).test(linker ?? ""),
    ldid,
  };
}

export async function cleanToolchain(report: Report): Promise<void> {
  report.progress("Removing the failed iOS toolchain install");
  await removeArchiveInstall(iosToolchainFolder(), toolchainParentFolder());
  await forgetRelease("toolchain");
}

export async function installToolchain(report: Report): Promise<void> {
  const architecture = architectures[process.arch];
  if (!architecture) {
    throw new StepError(
      `${toolchainRepository} publishes no iOS toolchain for ${process.arch} computers.`,
    );
  }
  report.progress("Looking for the newest stable iOS toolchain");
  const asset = await latestReleaseAsset(
    toolchainRepository,
    `iOSToolchain-${architecture}.tar.xz`,
  );
  const current = await readToolchain();
  if (
    current?.release === asset.release &&
    current.clang !== null &&
    current.armv7 &&
    current.ldid
  ) {
    report.progress(
      `${asset.release} is the newest release and is installed`,
      1,
    );
    return;
  }
  await installReleaseArchive({
    asset,
    parent: toolchainParentFolder(),
    inside: insideArchive,
    marker: compiler,
    target: iosToolchainFolder(),
    report,
  });
  await saveRelease("toolchain", asset.release);
  const installed = await readToolchain();
  if (installed === null) {
    throw new StepError(`${asset.release} holds no clang.`);
  }
  if (installed.clang === null) {
    throw new StepError(
      `The clang in ${asset.release} does not run on this computer.`,
    );
  }
  if (!installed.armv7) {
    throw new StepError(
      `The linker in ${asset.release} cannot link ${buildTarget.architecture}, which iOS ${buildTarget.sdkVersion} devices need.`,
    );
  }
  if (!installed.ldid) {
    throw new StepError(`${asset.release} has no ldid.`);
  }
}
