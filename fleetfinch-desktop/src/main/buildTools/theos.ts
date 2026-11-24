import { mkdir, readdir, rename, rm, rmdir } from "node:fs/promises";
import path from "node:path";

import type { BuildToolsStatus } from "@/buildTools.ts";
import {
  buildToolsFolder,
  exists,
  iosToolchainFolder,
  isExecutable,
  sdkFolder,
  theosFolder,
} from "@/main/buildTools/paths.ts";
import {
  type Log,
  type Report,
  runProcess,
  runStep,
  StepError,
  type StepOptions,
} from "@/main/buildTools/process.ts";

const theosRepository = "https://github.com/theos/theos.git";
const gitFile = "/usr/bin/git";

function gitEnvironment(): NodeJS.ProcessEnv {
  return { ...process.env, GIT_TERMINAL_PROMPT: "0" };
}

function git(args: string[], failure: string, log: Log): Promise<string> {
  return runStep(gitFile, args, failure, { env: gitEnvironment(), log });
}

async function isTheos(folder: string): Promise<boolean> {
  return exists(path.join(folder, "makefiles"));
}

async function canCheck(folder: string): Promise<boolean> {
  return (await isTheos(folder)) && (await isExecutable(gitFile));
}

export async function readTheos(): Promise<BuildToolsStatus["theos"]> {
  const folder = theosFolder();
  if (!(await isTheos(folder))) {
    return null;
  }
  const { code, output } = await runProcess(
    gitFile,
    ["-C", folder, "log", "-1", "--format=%h %cs"],
    { env: gitEnvironment() },
  ).catch(() => ({ code: null, output: "" }));
  const match = code === 0 ? /^(\S+) (\S+)$/.exec(output.trim()) : null;
  return { commit: match?.[1] ?? null, date: match?.[2] ?? null };
}

export async function verifyTheos(report: Report): Promise<void> {
  const folder = theosFolder();
  if (!(await canCheck(folder))) {
    return;
  }
  report.progress("Checking Theos's git repository");
  await git(
    ["-C", folder, "fsck", "--no-progress"],
    `Theos's git repository in ${folder} is damaged.`,
    report.log,
  );
  report.progress("Checking Theos's files against its newest commit");
  const changed = await git(
    [
      "-C",
      folder,
      "status",
      "--porcelain",
      "--untracked-files=no",
      "--ignore-submodules=all",
    ],
    `Theos's files in ${folder} could not be checked.`,
    report.log,
  );
  if (changed.trim() !== "") {
    throw new StepError(`Theos in ${folder} has changed files.`, changed);
  }
  report.progress("Checking Theos's submodules");
  const submodules = await git(
    ["-C", folder, "submodule", "status", "--recursive"],
    `Theos's submodules in ${folder} could not be checked.`,
    report.log,
  );
  const wrong = submodules
    .split("\n")
    .filter((line) => /^[-+U]/.test(line))
    .map((line) => line.slice(1).split(" ")[1] ?? line);
  if (wrong.length > 0) {
    const subject = wrong.length === 1 ? "submodule is" : "submodules are";
    throw new StepError(
      `Theos's ${wrong.join(", ")} ${subject} missing or at the wrong commit.`,
      submodules,
    );
  }
}

export async function hasTheosUpdate(report: Report): Promise<boolean> {
  const folder = theosFolder();
  if (!(await canCheck(folder))) {
    return false;
  }
  report.progress("Looking for new Theos commits");
  await git(
    ["-C", folder, "fetch", "--quiet"],
    `Theos in ${folder} could not fetch its newest commits.`,
    report.log,
  );
  const behind = await git(
    ["-C", folder, "rev-list", "--count", "HEAD..@{upstream}"],
    `Theos in ${folder} follows no branch to compare its commits with.`,
    report.log,
  );
  const newer = Number(behind.trim()) !== 0;
  report.progress(
    newer ? "Theos has newer commits" : "Theos is on its newest commit",
    1,
  );
  return newer;
}

async function updateTheos(folder: string, report: Report): Promise<void> {
  report.progress("Updating Theos to the newest commit");
  await git(
    ["-C", folder, "pull", "--ff-only", "--recurse-submodules"],
    `Theos in ${folder} could not be brought up to date.`,
    report.log,
  );
  report.progress("Updating Theos's submodules");
  await git(
    ["-C", folder, "submodule", "sync", "--recursive"],
    "Theos's submodules could not be synced.",
    report.log,
  );
  await git(
    ["-C", folder, "submodule", "update", "--init", "--recursive"],
    "Theos's submodules could not be updated.",
    report.log,
  );
}

async function cloneTheos(folder: string, report: Report): Promise<void> {
  const entries = await readdir(folder).catch((): string[] => []);
  if (entries.length > 0) {
    throw new StepError(
      `${folder} holds something other than Theos. Move it somewhere else and try again.`,
    );
  }
  await rmdir(folder).catch(() => undefined);
  await mkdir(buildToolsFolder(), { recursive: true });
  const staging = `${folder}.cloning`;
  await rm(staging, { recursive: true, force: true });
  try {
    report.progress("Cloning Theos and its submodules");
    await git(
      ["clone", "--recursive", theosRepository, staging],
      "Theos could not be cloned.",
      report.log,
    );
    if (!(await isTheos(staging))) {
      throw new StepError(`The clone of ${theosRepository} is not Theos.`);
    }
    await rename(staging, folder);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function replaceTheos(folder: string, report: Report): Promise<void> {
  const staging = `${folder}.cloning`;
  const previous = `${folder}.previous`;
  const kept = [iosToolchainFolder(), sdkFolder()].map((inside) =>
    path.relative(folder, inside),
  );
  await rm(staging, { recursive: true, force: true });
  await rm(previous, { recursive: true, force: true });
  await mkdir(buildToolsFolder(), { recursive: true });
  try {
    report.progress("Cloning a fresh copy of Theos and its submodules");
    await git(
      ["clone", "--recursive", theosRepository, staging],
      "Theos could not be cloned.",
      report.log,
    );
    if (!(await isTheos(staging))) {
      throw new StepError(`The clone of ${theosRepository} is not Theos.`);
    }
    for (const inside of kept) {
      if (await exists(path.join(folder, inside))) {
        await mkdir(path.dirname(path.join(staging, inside)), {
          recursive: true,
        });
        await rename(path.join(folder, inside), path.join(staging, inside));
      }
    }
    if (await exists(folder)) {
      await rename(folder, previous);
    }
    await rename(staging, folder);
  } finally {
    await rm(staging, { recursive: true, force: true });
    await rm(previous, { recursive: true, force: true });
  }
}

export async function installTheos(
  report: Report,
  { clean }: StepOptions,
): Promise<void> {
  const folder = theosFolder();
  if (clean) {
    await replaceTheos(folder, report);
  } else if (await isTheos(folder)) {
    await updateTheos(folder, report);
  } else {
    await cloneTheos(folder, report);
  }
}
