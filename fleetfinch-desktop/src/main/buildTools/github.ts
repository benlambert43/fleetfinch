import { createHash } from "node:crypto";
import { open } from "node:fs/promises";

import { net } from "electron";
import { z } from "zod";

import { type Report, StepError } from "@/main/buildTools/process.ts";

const releaseSchema = z.object({
  tag_name: z.string().min(1),
  assets: z.array(
    z.object({
      name: z.string(),
      browser_download_url: z.url({ protocol: /^https$/ }),
      size: z.number().int().positive(),
      digest: z.string().nullish(),
    }),
  ),
});

export interface ReleaseAsset {
  release: string;
  name: string;
  url: string;
  size: number;
  sha256: string | null;
}

export async function latestReleaseAsset(
  repository: string,
  assetName: string,
): Promise<ReleaseAsset> {
  const address = `https://api.github.com/repos/${repository}/releases/latest`;
  const response = await net
    .fetch(address, { headers: { Accept: "application/vnd.github+json" } })
    .catch((error: unknown) => {
      throw new StepError(
        `GitHub could not be reached to find the newest release of ${repository}.`,
        error instanceof Error ? error.message : String(error),
      );
    });
  if (!response.ok) {
    throw new StepError(
      `GitHub answered ${String(response.status)} when asked for the newest release of ${repository}.`,
      await response.text().catch(() => ""),
    );
  }
  const parsed = releaseSchema.safeParse(await response.json());
  if (!parsed.success) {
    throw new StepError(
      `GitHub's description of the newest release of ${repository} was not understood.`,
      parsed.error.message,
    );
  }
  const asset = parsed.data.assets.find(({ name }) => name === assetName);
  if (!asset) {
    throw new StepError(
      `The newest release of ${repository}, ${parsed.data.tag_name}, has no ${assetName}.`,
    );
  }
  const sha256 = asset.digest?.startsWith("sha256:")
    ? asset.digest.slice("sha256:".length)
    : null;
  return {
    release: parsed.data.tag_name,
    name: asset.name,
    url: asset.browser_download_url,
    size: asset.size,
    sha256,
  };
}

export function isNewerRelease(
  report: Report,
  asset: ReleaseAsset,
  installed: string | undefined,
): boolean {
  const newer = asset.release !== installed;
  report.progress(
    newer
      ? `${asset.release} is newer than the installed ${installed ?? "release"}`
      : `${asset.release} is the newest release and is installed`,
    1,
  );
  return newer;
}

export async function downloadAsset(
  asset: ReleaseAsset,
  file: string,
  onFraction: (fraction: number) => void,
): Promise<void> {
  const response = await net.fetch(asset.url).catch((error: unknown) => {
    throw new StepError(
      `${asset.name} could not be downloaded.`,
      error instanceof Error ? error.message : String(error),
    );
  });
  if (!response.ok || !response.body) {
    throw new StepError(
      `${asset.name} could not be downloaded: the server answered ${String(response.status)}.`,
    );
  }
  const hash = createHash("sha256");
  const handle = await open(file, "wx", 0o600);
  let received = 0;
  try {
    for await (const chunk of response.body) {
      if (!(chunk instanceof Uint8Array)) {
        throw new StepError(`${asset.name} arrived in a form not understood.`);
      }
      received += chunk.byteLength;
      if (received > asset.size) {
        throw new StepError(
          `${asset.name} is larger than the ${String(asset.size)} bytes GitHub lists.`,
        );
      }
      hash.update(chunk);
      await handle.write(chunk);
      onFraction(received / asset.size);
    }
  } finally {
    await handle.close();
  }
  if (received !== asset.size) {
    throw new StepError(
      `${asset.name} stopped after ${String(received)} of its ${String(asset.size)} bytes.`,
    );
  }
  if (asset.sha256 !== null && hash.digest("hex") !== asset.sha256) {
    throw new StepError(
      `${asset.name} does not match the SHA-256 that GitHub lists for it.`,
    );
  }
}
