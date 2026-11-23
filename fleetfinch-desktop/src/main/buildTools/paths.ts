import { constants } from "node:fs";
import { access, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { z } from "zod";

import { buildTarget } from "@/buildTools.ts";

const releasesSchema = z.object({
  toolchain: z.string().optional(),
  sdk: z.string().optional(),
});

export type InstalledReleases = z.infer<typeof releasesSchema>;

export function buildToolsFolder(): string {
  return path.join(os.homedir(), ".fleetfinch");
}

export function theosFolder(): string {
  return path.join(buildToolsFolder(), "theos");
}

export function toolchainParentFolder(): string {
  return path.join(theosFolder(), "toolchain");
}

export function iosToolchainFolder(): string {
  return path.join(toolchainParentFolder(), "linux", "iphone");
}

export function sdksFolder(): string {
  return path.join(theosFolder(), "sdks");
}

export function sdkFolder(): string {
  return path.join(sdksFolder(), `${buildTarget.sdk}.sdk`);
}

function releasesFile(): string {
  return path.join(buildToolsFolder(), "releases.json");
}

export async function exists(file: string): Promise<boolean> {
  return access(file).then(
    () => true,
    () => false,
  );
}

export async function isExecutable(file: string): Promise<boolean> {
  return access(file, constants.X_OK).then(
    () => true,
    () => false,
  );
}

export async function readReleases(): Promise<InstalledReleases> {
  const saved: unknown = await readFile(releasesFile(), "utf8")
    .then((text): unknown => JSON.parse(text))
    .catch(() => null);
  const parsed = releasesSchema.safeParse(saved);
  return parsed.success ? parsed.data : {};
}

export async function saveRelease(
  tool: keyof InstalledReleases,
  release: string,
): Promise<void> {
  const releases = { ...(await readReleases()), [tool]: release };
  await writeFile(releasesFile(), `${JSON.stringify(releases, null, 2)}\n`);
}
