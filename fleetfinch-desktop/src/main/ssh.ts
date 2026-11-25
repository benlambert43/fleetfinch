import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { Readable } from "node:stream";

import { app } from "electron";

import { exists, isExecutable } from "@/main/buildTools/paths.ts";
import {
  commandText,
  type Log,
  type ProcessData,
  type ProcessResult,
  type ProcessSave,
  readProcess,
  runProcess,
  runStep,
  saveProcess,
} from "@/main/buildTools/process.ts";

const sshFile = "/usr/bin/ssh";
const keygenFile = "/usr/bin/ssh-keygen";
const scriptFile = "/usr/bin/script";
const shellFile = "/bin/sh";
const connectTimeoutSeconds = 10;
const aliveSeconds = 15;
const aliveCount = 3;
const timeoutMs = 30_000;
const wakeEveryMs = 4000;
const wakeTimeoutMs = 15_000;
const passwordPrompt = /'s password: $/;
const identityName = /^id_ed25519(?:-[\da-f]{8})?$/;

export const passwordPromptText = "'s password: ";
export const sshFailedCode = 255;

export interface SshKey {
  privateKey: string;
  publicKey: string;
}

let keyReady: Promise<string> | null = null;
let priorityTasks = 0;
const priorityListeners = new Set<(running: boolean) => void>();

function sshFolder(): string {
  return path.join(app.getPath("userData"), "ssh");
}

function keyFile(): string {
  return path.join(sshFolder(), "id_ed25519");
}

function knownHostsFile(): string {
  return path.join(sshFolder(), "known_hosts");
}

function notifyPriority(running: boolean): void {
  for (const listener of priorityListeners) {
    listener(running);
  }
}

export function priorityRunning(): boolean {
  return priorityTasks > 0;
}

export function onPriorityChange(
  listener: (running: boolean) => void,
): () => void {
  priorityListeners.add(listener);
  return () => {
    priorityListeners.delete(listener);
  };
}

export async function withPriority<Result>(
  run: () => Promise<Result>,
): Promise<Result> {
  priorityTasks += 1;
  if (priorityTasks === 1) {
    notifyPriority(true);
  }
  try {
    return await run();
  } finally {
    priorityTasks -= 1;
    if (priorityTasks === 0) {
      notifyPriority(false);
    }
  }
}

export async function hasSsh(): Promise<boolean> {
  const tools = await Promise.all([sshFile, keygenFile].map(isExecutable));
  return tools.every(Boolean);
}

async function createKey(log: Log): Promise<string> {
  const file = keyFile();
  if (!(await exists(file))) {
    await mkdir(sshFolder(), { recursive: true, mode: 0o700 });
    await runStep(
      keygenFile,
      [
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-C",
        `fleetfinch@${os.hostname()}`,
        "-f",
        file,
      ],
      "Could not create an SSH key for this computer.",
      { timeoutMs: 10_000, log },
    );
  }
  return (await readFile(`${file}.pub`, "utf8")).trim();
}

export function publicKey(log: Log): Promise<string> {
  keyReady ??= createKey(log).catch((error: unknown) => {
    keyReady = null;
    throw error;
  });
  return keyReady;
}

async function identityFiles(): Promise<string[]> {
  const names = await readdir(sshFolder()).catch((): string[] => []);
  return names
    .filter((name) => identityName.test(name))
    .sort()
    .map((name) => path.join(sshFolder(), name));
}

function keyId(publicKey: string): string {
  return publicKey.split(" ").slice(0, 2).join(" ");
}

export async function readKeys(): Promise<SshKey[]> {
  return Promise.all(
    (await identityFiles()).map(async (file) => ({
      privateKey: await readFile(file, "utf8"),
      publicKey: (await readFile(`${file}.pub`, "utf8")).trim(),
    })),
  );
}

export async function addKey(key: SshKey): Promise<boolean> {
  const saved = await readKeys();
  if (
    saved.some(({ publicKey }) => keyId(publicKey) === keyId(key.publicKey))
  ) {
    return false;
  }
  const suffix = createHash("sha256")
    .update(keyId(key.publicKey))
    .digest("hex")
    .slice(0, 8);
  const file = (await exists(keyFile())) ? `${keyFile()}-${suffix}` : keyFile();
  await mkdir(sshFolder(), { recursive: true, mode: 0o700 });
  await writeFile(file, key.privateKey, { mode: 0o600 });
  await writeFile(`${file}.pub`, `${key.publicKey}\n`);
  keyReady = null;
  return true;
}

function hostsOf(line: string): string[] {
  return (line.split(" ")[0] ?? "").split(",");
}

export function readKnownHosts(): Promise<string> {
  return readFile(knownHostsFile(), "utf8").catch(() => "");
}

export async function forgetHostKey(address: string): Promise<void> {
  const lines = (await readKnownHosts()).split("\n");
  const kept = lines.filter((line) => !hostsOf(line).includes(address));
  if (kept.length !== lines.length) {
    await writeFile(knownHostsFile(), kept.join("\n"));
  }
}

export async function mergeKnownHosts(text: string): Promise<void> {
  const current = await readKnownHosts();
  const known = new Set(current.split("\n").flatMap(hostsOf));
  const added = text
    .split("\n")
    .filter(
      (line) =>
        line.trim() !== "" &&
        !line.startsWith("#") &&
        !hostsOf(line).some((host) => known.has(host)),
    );
  if (added.length > 0) {
    const kept =
      current === "" || current.endsWith("\n") ? current : `${current}\n`;
    await mkdir(sshFolder(), { recursive: true, mode: 0o700 });
    await writeFile(knownHostsFile(), `${kept}${added.join("\n")}\n`);
  }
}

function sshEnvironment(): NodeJS.ProcessEnv {
  const {
    SSH_ASKPASS: _askpass,
    SSH_ASKPASS_REQUIRE: _askpassRequire,
    ...rest
  } = process.env;
  return { ...rest, LC_ALL: "C", LANGUAGE: "C", SHELL: shellFile };
}

function sshArgs(
  address: string,
  options: string[],
  command: string,
  input = false,
): string[] {
  return [
    "-F",
    "none",
    ...(input ? [] : ["-n"]),
    "-T",
    "-l",
    "root",
    "-o",
    `ConnectTimeout=${String(connectTimeoutSeconds)}`,
    "-o",
    `UserKnownHostsFile="${knownHostsFile()}"`,
    "-o",
    "GlobalKnownHostsFile=/dev/null",
    "-o",
    "HostKeyAlgorithms=+ssh-rsa",
    "-o",
    "KexAlgorithms=+diffie-hellman-group14-sha1",
    "-o",
    "LogLevel=ERROR",
    ...options,
    "--",
    address,
    command,
  ];
}

export function runWithPassword(
  address: string,
  password: string,
  command: string,
  log: Log,
): Promise<ProcessResult> {
  const sshCommand = commandText(
    sshFile,
    sshArgs(
      address,
      [
        "-o",
        "PreferredAuthentications=password",
        "-o",
        "NumberOfPasswordPrompts=1",
        "-o",
        "StrictHostKeyChecking=accept-new",
      ],
      command,
    ),
  );
  return runProcess(
    scriptFile,
    ["--quiet", "--return", "--command", sshCommand, "/dev/null"],
    {
      env: sshEnvironment(),
      timeoutMs,
      answer: { prompt: passwordPrompt, text: `${password}\n` },
      log: (line) => {
        log(line.kind === "command" ? { ...line, text: sshCommand } : line);
      },
    },
  );
}

async function keyOptions(probes = true): Promise<string[]> {
  const identities = (await identityFiles()).flatMap((file) => ["-i", file]);
  return [
    ...identities,
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "BatchMode=yes",
    "-o",
    "PreferredAuthentications=publickey",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    `ServerAliveInterval=${String(probes ? aliveSeconds : 0)}`,
    "-o",
    `ServerAliveCountMax=${String(aliveCount)}`,
  ];
}

export async function runAsRoot(
  address: string,
  command: string,
  log?: Log,
  signal?: AbortSignal,
  limitMs = timeoutMs,
): Promise<ProcessResult> {
  return runProcess(sshFile, sshArgs(address, await keyOptions(), command), {
    env: sshEnvironment(),
    timeoutMs: limitMs,
    log,
    signal,
  });
}

export async function followAsRoot(
  address: string,
  command: string,
  log: Log,
  signal: AbortSignal,
): Promise<ProcessResult> {
  return runProcess(
    sshFile,
    sshArgs(address, await keyOptions(false), command),
    { env: sshEnvironment(), timeoutMs: 0, log, signal },
  );
}

export async function readAsRoot(
  address: string,
  command: string,
  log?: Log,
  limitMs = timeoutMs,
): Promise<ProcessData> {
  return readProcess(sshFile, sshArgs(address, await keyOptions(), command), {
    env: sshEnvironment(),
    timeoutMs: limitMs,
    log,
  });
}

export async function sendAsRoot(
  address: string,
  source: Readable,
  command: string,
  log?: Log,
  limitMs = timeoutMs,
): Promise<ProcessResult> {
  return runProcess(
    sshFile,
    sshArgs(address, await keyOptions(), command, true),
    { env: sshEnvironment(), timeoutMs: limitMs, log, source },
  );
}

export async function saveAsRoot(
  address: string,
  command: string,
  target: string,
  log?: Log,
  limitMs = timeoutMs,
): Promise<ProcessSave> {
  return saveProcess(
    sshFile,
    sshArgs(address, await keyOptions(), command),
    target,
    { env: sshEnvironment(), timeoutMs: limitMs, log },
  );
}

function keepAwake(address: string): () => void {
  const stopped = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const wake = () => {
    void runAsRoot(address, ":", undefined, stopped.signal, wakeTimeoutMs)
      .catch(() => undefined)
      .finally(() => {
        if (!stopped.signal.aborted) {
          timer = setTimeout(wake, wakeEveryMs);
        }
      });
  };
  timer = setTimeout(wake, wakeEveryMs);
  return () => {
    stopped.abort();
    clearTimeout(timer);
  };
}

export async function awake<Result>(
  address: string,
  run: () => Promise<Result>,
): Promise<Result> {
  const rest = keepAwake(address);
  try {
    return await run();
  } finally {
    rest();
  }
}
