import { mkdir, mkdtemp, rename, rm } from "node:fs/promises";
import path from "node:path";

import { downloadAsset, type ReleaseAsset } from "@/main/buildTools/github.ts";
import { exists } from "@/main/buildTools/paths.ts";
import { type Report, runStep, StepError } from "@/main/buildTools/process.ts";

const tarFile = "/usr/bin/tar";

export async function installReleaseArchive({
  asset,
  parent,
  inside,
  marker,
  target,
  report,
  prepare,
}: {
  asset: ReleaseAsset;
  parent: string;
  inside: string;
  marker: string;
  target: string;
  report: Report;
  prepare?: (folder: string) => Promise<void>;
}): Promise<void> {
  await mkdir(parent, { recursive: true });
  const staging = await mkdtemp(path.join(parent, ".installing-"));
  try {
    const file = path.join(staging, asset.name);
    report.progress(`Downloading ${asset.name} from ${asset.release}`, 0);
    await downloadAsset(asset, file, (fraction) => {
      report.progress(
        `Downloading ${asset.name} from ${asset.release}`,
        fraction,
      );
    });
    report.progress(`Unpacking ${asset.name}`);
    const unpacked = path.join(staging, "unpacked");
    await mkdir(unpacked);
    await runStep(
      tarFile,
      ["-x", "-J", "-f", file, "-C", unpacked],
      `${asset.name} could not be unpacked.`,
      { log: report.log },
    );
    const folder = path.join(unpacked, inside);
    if (!(await exists(path.join(folder, marker)))) {
      throw new StepError(
        `${asset.name} does not hold ${path.join(inside, marker)}.`,
      );
    }
    await prepare?.(folder);
    if (await exists(target)) {
      await rename(target, path.join(staging, "previous"));
    }
    await mkdir(path.dirname(target), { recursive: true });
    await rename(folder, target);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}
