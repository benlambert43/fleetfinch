import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
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

const outputLimit = 64 * 1024;
const defaultTimeoutMs = 30 * 60 * 1000;
const plainArgument = /^[\w@%+=:,./-]+$/;

export type Log = (line: BuildToolsLogLine) => void;

export interface Report {
  progress: (message: string, fraction?: number | null) => void;
  log: Log;
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
  answer?: { prompt: RegExp; text: string };
  log?: Log;
}

function quote(argument: string): string {
  return plainArgument.test(argument)
    ? argument
    : `'${argument.replaceAll("'", String.raw`'\''`)}'`;
}

function logLines(stream: Readable, log: Log): void {
  createInterface({ input: stream, crlfDelay: Infinity }).on("line", (line) => {
    const text = stripVTControlCharacters(line).trimEnd();
    if (text !== "") {
      log({ kind: "output", text });
    }
  });
}

export function runProcess(
  file: string,
  args: string[],
  {
    env = process.env,
    timeoutMs = defaultTimeoutMs,
    input,
    answer,
    log,
  }: ProcessOptions = {},
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    log?.({ kind: "command", text: [file, ...args].map(quote).join(" ") });
    const child = spawn(file, args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      timeout: timeoutMs,
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
    if (answer === undefined) {
      child.stdin.end(input);
    }
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({ code, output });
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
