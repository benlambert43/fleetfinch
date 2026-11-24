import { mkdir, readdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

import { type BuildToolsStatus, buildTarget } from "@/buildTools.ts";
import {
  installReleaseArchive,
  removeArchiveInstall,
} from "@/main/buildTools/archive.ts";
import {
  isNewerRelease,
  latestReleaseAsset,
} from "@/main/buildTools/github.ts";
import {
  exists,
  forgetRelease,
  readReleases,
  saveRelease,
  sdkFolder,
  sdksFolder,
} from "@/main/buildTools/paths.ts";
import { type Report, StepError } from "@/main/buildTools/process.ts";

const sdkRepository = "theos/sdks";
const sdkName = `${buildTarget.sdk}.sdk`;
const sdkArchive = `${sdkName}.tar.xz`;
const stubExtension = ".tbd";
const frameworkExtension = ".framework";
const oldModuleMap = "module.map";
const moduleMap = "module.modulemap";
const cLibraryStub = "usr/lib/system/libsystem_c.tbd";
const systemLibraryStub = "usr/lib/libSystem.B.tbd";
const launchLibrary = "/usr/lib/system/liblaunch.dylib";
const launchLibraryStub = "usr/lib/system/liblaunch.tbd";
const objcModuleMap = path.join("usr/include/objc", oldModuleMap);
const architectureList = /(archs:\s*\[)([^\]]*)(\])/g;
const reExportList = /(re-exports:\s*\[)([^\]]*)(\])/g;
const firstSymbolList = /(?<![\w-])symbols:\s*\[/;
const sectionStart = "- archs:";
const simulatorArchitectures = new Set(["i386", "x86_64", "x86_64h"]);

const aliasedFunctions = [
  "_bzero",
  "_memccpy",
  "_memchr",
  "_memcmp",
  "_memcpy",
  "_memmove",
  "_memset",
  "_memset_pattern16",
  "_memset_pattern4",
  "_memset_pattern8",
  "_strchr",
  "_strcmp",
  "_strncmp",
];

function listNames(list: string): string[] {
  return list
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
}

function listsSimulators(stub: string): boolean {
  return [...stub.matchAll(architectureList)].some(([, , list = ""]) =>
    listNames(list).some((name) => simulatorArchitectures.has(name)),
  );
}

function withoutSimulators(stub: string): string {
  return stub.replaceAll(
    architectureList,
    (match, open: string, list: string, close: string) => {
      const kept = listNames(list).filter(
        (name) => !simulatorArchitectures.has(name),
      );
      return kept.length > 0 ? `${open} ${kept.join(", ")} ${close}` : match;
    },
  );
}

function reExportsLaunchLibrary(stub: string): boolean {
  return [...stub.matchAll(reExportList)].some(([, , list = ""]) =>
    listNames(list).includes(launchLibrary),
  );
}

function withoutLaunchLibrary(stub: string): string {
  return stub.replaceAll(
    reExportList,
    (match, open: string, list: string, close: string) => {
      const names = listNames(list);
      const kept = names.filter((name) => name !== launchLibrary);
      return kept.length > 0 && kept.length < names.length
        ? `${open} ${kept.join(", ")} ${close}`
        : match;
    },
  );
}

function exportsFunction(stub: string, name: string): boolean {
  return new RegExp(String.raw`[\[\s,]${name}[\],\s]`).test(stub);
}

function withAliasedFunctions(stub: string): string {
  const missing = aliasedFunctions.filter(
    (name) => !exportsFunction(stub, name),
  );
  const list = firstSymbolList.exec(stub);
  const section = stub.slice(
    stub.lastIndexOf(sectionStart, list?.index),
    list?.index,
  );
  if (
    missing.length === 0 ||
    !list ||
    !section.includes(buildTarget.architecture)
  ) {
    return stub;
  }
  const start = list.index + list[0].length;
  return `${stub.slice(0, start)} ${missing.join(", ")},${stub.slice(start)}`;
}

async function readText(file: string): Promise<string> {
  return readFile(file, "utf8").catch(() => "");
}

async function rewrite(
  file: string,
  change: (text: string) => string,
): Promise<void> {
  const text = await readFile(file, "utf8");
  const changed = change(text);
  if (changed !== text) {
    await writeFile(file, changed);
  }
}

async function renameModuleMap(folder: string): Promise<void> {
  const target = folder.endsWith(frameworkExtension)
    ? path.join(folder, "Modules", moduleMap)
    : path.join(folder, moduleMap);
  if (!(await exists(target))) {
    await mkdir(path.dirname(target), { recursive: true });
    await rename(path.join(folder, oldModuleMap), target);
  }
}

async function lacksLaunchLibrary(folder: string): Promise<boolean> {
  return !(await exists(path.join(folder, launchLibraryStub)));
}

async function isSdkAdjusted(folder: string): Promise<boolean> {
  const stub = await readText(path.join(folder, cLibraryStub));
  const systemStub = await readText(path.join(folder, systemLibraryStub));
  return (
    stub !== "" &&
    !listsSimulators(stub) &&
    aliasedFunctions.every((name) => exportsFunction(stub, name)) &&
    !(await exists(path.join(folder, objcModuleMap))) &&
    !((await lacksLaunchLibrary(folder)) && reExportsLaunchLibrary(systemStub))
  );
}

async function adjustSdk(folder: string, report: Report): Promise<void> {
  await applyAdjustments(folder, report);
  if (!(await isSdkAdjusted(folder))) {
    throw new StepError(
      `The iOS ${buildTarget.sdkVersion} SDK could not be adjusted for this toolchain.`,
    );
  }
}

async function applyAdjustments(folder: string, report: Report): Promise<void> {
  report.progress(
    `Adjusting the iOS ${buildTarget.sdkVersion} SDK for this toolchain`,
    0,
  );
  const files = (
    await readdir(folder, { recursive: true, withFileTypes: true })
  ).filter((entry) => entry.isFile());
  const stubs = files.filter(({ name }) => name.endsWith(stubExtension));
  const adjustStub = (await lacksLaunchLibrary(folder))
    ? (stub: string) => withoutLaunchLibrary(withoutSimulators(stub))
    : withoutSimulators;
  for (const [index, { parentPath, name }] of stubs.entries()) {
    await rewrite(path.join(parentPath, name), adjustStub);
    report.progress(
      `Adjusting the iOS ${buildTarget.sdkVersion} SDK for this toolchain`,
      (index + 1) / stubs.length,
    );
  }
  for (const { parentPath, name } of files) {
    if (name === oldModuleMap) {
      await renameModuleMap(parentPath);
    }
  }
  await rewrite(path.join(folder, cLibraryStub), withAliasedFunctions);
}

export async function readSdk(): Promise<BuildToolsStatus["sdk"]> {
  const folder = sdkFolder();
  if (!(await exists(folder))) {
    return null;
  }
  return {
    release: (await readReleases()).sdk ?? null,
    adjusted: await isSdkAdjusted(folder),
  };
}

export async function verifySdk(report: Report): Promise<void> {
  report.progress(
    `Checking that the iOS ${buildTarget.sdkVersion} SDK is adjusted for this toolchain`,
  );
  await readSdk();
}

export async function hasSdkUpdate(report: Report): Promise<boolean> {
  if (!(await exists(sdkFolder()))) {
    return false;
  }
  report.progress(`Looking for a newer iOS ${buildTarget.sdkVersion} SDK`);
  const asset = await latestReleaseAsset(sdkRepository, sdkArchive);
  return isNewerRelease(report, asset, (await readReleases()).sdk);
}

export async function cleanSdk(report: Report): Promise<void> {
  report.progress(
    `Removing the failed iOS ${buildTarget.sdkVersion} SDK install`,
  );
  await removeArchiveInstall(sdkFolder(), sdksFolder());
  await forgetRelease("sdk");
}

export async function installSdk(report: Report): Promise<void> {
  report.progress(`Looking for the newest iOS ${buildTarget.sdkVersion} SDK`);
  const asset = await latestReleaseAsset(sdkRepository, sdkArchive);
  const current = await readSdk();
  if (current?.release === asset.release) {
    if (!current.adjusted) {
      await adjustSdk(sdkFolder(), report);
    }
    report.progress(
      `${asset.release} is the newest release and is installed`,
      1,
    );
    return;
  }
  await installReleaseArchive({
    asset,
    parent: sdksFolder(),
    inside: sdkName,
    marker: cLibraryStub,
    target: sdkFolder(),
    report,
    prepare: (folder) => adjustSdk(folder, report),
  });
  await saveRelease("sdk", asset.release);
}
