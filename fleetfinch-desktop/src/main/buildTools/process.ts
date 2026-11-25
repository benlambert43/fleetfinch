import { spawn } from "node:child_process";
import { createWriteStream } from "node:fs";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import { finished } from "node:stream/promises";
import { stripVTControlCharacters } from "node:util";

import type {
  BuildToolsLogLine,
  PasswordAccount,
  SystemPackage,
} from "@/buildTools.ts";

export interface ProcessResult {
  code: number | null;
  output: string;
}

export interface ProcessData {
  code: number | null;
  data: Buffer;
  errors: string;
}

export interface ProcessSave {
  code: number | null;
  bytes: number;
  errors: string;
}

const outputLimit = 64 * 1024;
const dataLimit = 64 * 1024 * 1024;
const defaultTimeoutMs = 30 * 60 * 1000;
const plainArgument = /^[\w@%+=:,./-]+$/;

export type Log = (line: BuildToolsLogLine) => void;

export interface Report {
  progress: (message: string, fraction?: number | null) => void;
  log: Log;
}

export interface StepOptions {
  password: string | undefined;
  clean: boolean;
}

export class StepError extends Error {
  readonly output: string;

  constructor(message: string, output = "") {
    super(message);
    this.output = output;
  }
}

export class PasswordNeeded extends Error {
  readonly account: PasswordAccount;
  readonly packages: SystemPackage[];
  readonly reason: string | null;

  constructor(
    account: PasswordAccount,
    packages: SystemPackage[],
    reason: string | null = null,
  ) {
    super(`A password is needed to install ${packages.join(", ")}.`);
    this.account = account;
    this.packages = packages;
    this.reason = reason;
  }
}

export interface ProcessOptions {
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
  input?: string;
  source?: Readable | undefined;
  answer?: { prompt: RegExp; text: string };
  log?: Log | undefined;
  signal?: AbortSignal | undefined;
}

function quote(argument: string): string {
  return plainArgument.test(argument)
    ? argument
    : `'${argument.replaceAll("'", String.raw`'\''`)}'`;
}

export function commandText(file: string, args: string[]): string {
  return [file, ...args].map(quote).join(" ");
}

export function readLines(
  stream: Readable,
  onLine: (text: string) => void,
): void {
  createInterface({ input: stream, crlfDelay: Infinity }).on("line", (line) => {
    const text = stripVTControlCharacters(line).trimEnd();
    if (text !== "") {
      onLine(text);
    }
  });
}

function logLines(stream: Readable, log: Log): void {
  readLines(stream, (text) => {
    log({ kind: "output", text });
  });
}

export function runProcess(
  file: string,
  args: string[],
  {
    env = process.env,
    timeoutMs = defaultTimeoutMs,
    input,
    source,
    answer,
    log,
    signal,
  }: ProcessOptions = {},
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    log?.({ kind: "command", text: commandText(file, args) });
    const child = spawn(file, args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      timeout: timeoutMs,
      signal,
    });
    if (log) {
      logLines(child.stdout, log);
      logLines(child.stderr, log);
    }
    let output = "";
    let waiting = answer;
    const take = (chunk: Buffer) => {
      output = (output + chunk.toString("utf8")).slice(-outputLimit);
      if (waiting?.prompt.test(output)) {
        child.stdin.write(waiting.text);
        waiting = undefined;
      }
    };
    child.stdin.on("error", () => undefined);
    if (source !== undefined) {
      source.on("error", (error) => {
        child.kill();
        reject(error);
      });
      source.pipe(child.stdin);
    } else if (answer === undefined) {
      child.stdin.end(input);
    }
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    child.on("error", reject);
    child.on("close", (code) => {
      source?.destroy();
      resolve({ code, output });
    });
  });
}

export function readProcess(
  file: string,
  args: string[],
  {
    env = process.env,
    timeoutMs = defaultTimeoutMs,
    log,
    signal,
  }: ProcessOptions = {},
): Promise<ProcessData> {
  return new Promise((resolve, reject) => {
    log?.({ kind: "command", text: commandText(file, args) });
    const child = spawn(file, args, {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: timeoutMs,
      signal,
    });
    if (log) {
      logLines(child.stderr, log);
    }
    const chunks: Buffer[] = [];
    let size = 0;
    let errors = "";
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > dataLimit) {
        child.kill();
      } else {
        chunks.push(chunk);
      }
    });
    child.stderr.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString("utf8")).slice(-outputLimit);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        code: size > dataLimit ? null : code,
        data: Buffer.concat(chunks),
        errors,
      });
    });
  });
}

export function saveProcess(
  file: string,
  args: string[],
  target: string,
  {
    env = process.env,
    timeoutMs = defaultTimeoutMs,
    log,
    signal,
  }: ProcessOptions = {},
): Promise<ProcessSave> {
  return new Promise((resolve, reject) => {
    log?.({ kind: "command", text: commandText(file, args) });
    const child = spawn(file, args, {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: timeoutMs,
      signal,
    });
    if (log) {
      logLines(child.stderr, log);
    }
    const sink = createWriteStream(target, { mode: 0o600 });
    const written = finished(sink).then(
      () => null,
      (error: unknown) => {
        child.kill();
        return error instanceof Error ? error : new Error(String(error));
      },
    );
    let bytes = 0;
    let errors = "";
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
    });
    child.stdout.pipe(sink);
    child.stderr.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString("utf8")).slice(-outputLimit);
    });
    child.on("error", (error) => {
      sink.destroy();
      reject(error);
    });
    child.on("close", (code) => {
      void written.then((problem) => {
        if (problem === null) {
          resolve({ code, bytes, errors });
        } else {
          reject(problem);
        }
      });
    });
  });
}

export async function runStep(
  file: string,
  args: string[],
  failure: string,
  options?: ProcessOptions,
): Promise<string> {
  const { code, output } = await runProcess(file, args, options);
  if (code !== 0) {
    throw new StepError(failure, output);
  }
  return output;
}

export function lastLines(text: string, count = 20): string {
  return text
    .trimEnd()
    .split(/\r\n|\r|\n/)
    .slice(-count)
    .join("\n");
}
