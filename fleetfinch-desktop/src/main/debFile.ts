import { stat } from "node:fs/promises";
import path from "node:path";

import { packageIdPattern } from "@/deviceApps.ts";
import { isExecutable } from "@/main/buildTools/paths.ts";
import {
  commandText,
  type Log,
  readProcess,
  runProcess,
  StepError,
} from "@/main/buildTools/process.ts";

const dpkgDebFile = "/usr/bin/dpkg-deb";
const tarFile = "/usr/bin/tar";
const shellFile = "/bin/sh";
const timeoutMs = 5 * 60 * 1000;
const sizeLimit = 1024 ** 3;
const blockBytes = 4096;
const architectures = new Set(["iphoneos-arm", "all"]);
const fieldLine = /^([A-Za-z][\w-]*):[ \t]*(.*)$/;
const continuedLine = /^[ \t]+\S/;
const dependencyFields = ["Pre-Depends", "Depends"];
const contentLine = /^(\S)\S*\s+\S+\s+(\d+)\s+\S+\s+\S+\s+(.+)$/;
const linkTarget = / (?:->|link to) .*$/;
const appInfo = /^(\/Applications\/[^/]+\.app)\/Info\.plist$/;
const dataVolume = /^\/(?:private\/)?var\//;
const refreshTool = /\buicache\b/;

export interface DebApp {
  path: string;
  info: Buffer | null;
}

export interface DebFile {
  file: string;
  bytes: number;
  id: string;
  name: string;
  version: string;
  depends: string[];
  apps: DebApp[];
  systemKb: number;
  refreshesItself: boolean;
}

function plainEnvironment(): NodeJS.ProcessEnv {
  return { ...process.env, LC_ALL: "C", LANGUAGE: "C" };
}

function controlFields(text: string): Map<string, string> {
  const fields = new Map<string, string>();
  let current: string | null = null;
  for (const line of text.split("\n")) {
    const [, name, value] = fieldLine.exec(line) ?? [];
    if (name !== undefined && value !== undefined) {
      current = fields.has(name) ? null : name;
      if (current !== null) {
        fields.set(current, value.trim());
      }
    } else if (current !== null && continuedLine.test(line)) {
      fields.set(current, `${fields.get(current) ?? ""} ${line.trim()}`);
    } else {
      current = null;
    }
  }
  return fields;
}

function memberPath(member: string): string {
  return `/${member.replace(/^(?:\.?\/)+/, "").replace(/\/+$/, "")}`;
}

async function readAppInfo(
  file: string,
  member: string,
  log: Log,
): Promise<Buffer | null> {
  const pipeline = [
    commandText(dpkgDebFile, ["--fsys-tarfile", file]),
    commandText(tarFile, ["-x", "-O", "-f", "-", member]),
  ].join(" | ");
  const { code, data } = await readProcess(shellFile, ["-c", pipeline], {
    env: plainEnvironment(),
    timeoutMs,
    log,
  });
  return code === 0 && data.length > 0 ? data : null;
}

export async function readDebFile(file: string, log: Log): Promise<DebFile> {
  const base = path.basename(file);
  const info = await stat(file).catch(() => null);
  if (info?.isFile() !== true) {
    throw new StepError(`${base} could not be read.`);
  }
  if (info.size > sizeLimit) {
    throw new StepError(`${base} is larger than 1 GB.`);
  }
  if (!(await isExecutable(dpkgDebFile))) {
    throw new StepError(
      "This computer has no dpkg-deb to read packages with. FleetFinch Developer needs a Debian-based system, such as Debian or Ubuntu.",
    );
  }
  const env = plainEnvironment();
  const control = await runProcess(dpkgDebFile, ["--field", file], {
    env,
    timeoutMs,
    log,
  });
  if (control.code !== 0) {
    throw new StepError(
      `${base} is not a package that dpkg can read.`,
      control.output,
    );
  }
  const fields = controlFields(control.output);
  const id = fields.get("Package") ?? "";
  const version = fields.get("Version") ?? "";
  const architecture = fields.get("Architecture") ?? "";
  if (!packageIdPattern.test(id) || version === "") {
    throw new StepError(
      `${base} does not name its package and version.`,
      control.output,
    );
  }
  if (!architectures.has(architecture)) {
    throw new StepError(
      `${base} is built for ${architecture === "" ? "an unknown architecture" : architecture}, not for a jailbroken iOS device (iphoneos-arm).`,
    );
  }
  const contents = await readProcess(dpkgDebFile, ["--contents", file], {
    env,
    timeoutMs,
    log,
  });
  if (contents.code !== 0) {
    throw new StepError(
      `The files inside ${base} could not be listed.`,
      contents.errors,
    );
  }
  const members: string[] = [];
  let systemBytes = 0;
  for (const line of contents.data.toString("utf8").split("\n")) {
    const [, type, size, name] = contentLine.exec(line) ?? [];
    if (type === undefined || size === undefined || name === undefined) {
      continue;
    }
    const member = name.replace(linkTarget, "");
    const target = memberPath(member);
    if (type === "-" && !dataVolume.test(target)) {
      systemBytes += Math.ceil(Number(size) / blockBytes) * blockBytes;
    }
    if (type === "-" && appInfo.test(target)) {
      members.push(member);
    }
  }
  const apps: DebApp[] = [];
  for (const member of members) {
    const [, bundle] = appInfo.exec(memberPath(member)) ?? [];
    if (bundle !== undefined) {
      apps.push({ path: bundle, info: await readAppInfo(file, member, log) });
    }
  }
  const scriptArgs = ["--info", file, "postinst"];
  log({ kind: "command", text: commandText(dpkgDebFile, scriptArgs) });
  const script = await runProcess(dpkgDebFile, scriptArgs, { env, timeoutMs });
  return {
    file,
    bytes: info.size,
    id,
    name: fields.get("Name") ?? id,
    version,
    depends: dependencyFields.flatMap((name) => fields.get(name) ?? []),
    apps,
    systemKb: Math.ceil(systemBytes / 1024),
    refreshesItself: script.code === 0 && refreshTool.test(script.output),
  };
}
