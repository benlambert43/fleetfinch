import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { app } from "electron";
import { z } from "zod";

import {
  type Device,
  type DeviceConnection,
  type DeviceField,
  type DeviceLogin,
  type DeviceRemoval,
  deviceSummary,
  withDevice,
} from "@/devices.ts";
import {
  commandText,
  lastLines,
  type ProcessResult,
  StepError,
} from "@/main/buildTools/process.ts";
import { describeError, type LogWriter, openLogGroup } from "@/main/logs.ts";
import {
  forgetHostKey,
  hasSsh,
  passwordPromptText,
  publicKey,
  readKeys,
  runAsRoot,
  runWithPassword,
  sshFailedCode,
  withPriority,
} from "@/main/ssh.ts";

const authorizedKeys = ".ssh/authorized_keys";
const savedMarker = "key=saved";
const savedLine = /^key=saved$/m;
const removedMarker = "key=removed";
const removedLine = /^key=removed$/m;
const keptKeys = ".ssh/authorized_keys.fleetfinch";
const noSsh =
  "SSH is not installed. Set Up Build Tools in Computer Info installs it.";
const versionFile = "/System/Library/CoreServices/SystemVersion.plist";
const testCommand = `echo "name=$(uname -n)"; echo "model=$(uname -m)"; cat ${versionFile}`;
const nameLine = /^name=(.*)$/m;
const modelLine = /^model=(.*)$/m;
const versionKey = /<key>ProductVersion<\/key>\s*<string>([^<]*)<\/string>/;
const unreachable =
  /timed out|No route to host|Network is unreachable|Host is down|Could not resolve/i;

const addressSchema = z.union([z.ipv4(), z.ipv6()]);

export const devicesSchema = z.array(
  z.strictObject({
    address: z.string(),
    name: z.string().nullable(),
    model: z.string().nullable(),
    version: z.string().nullable(),
  }),
);

function devicesFile(): string {
  return path.join(app.getPath("userData"), "devices.json");
}

export async function readDevices(): Promise<Device[]> {
  const saved: unknown = await readFile(devicesFile(), "utf8")
    .then((text): unknown => JSON.parse(text))
    .catch(() => null);
  const parsed = devicesSchema.safeParse(saved);
  return parsed.success ? parsed.data : [];
}

async function writeDevices(devices: readonly Device[]): Promise<void> {
  await writeFile(devicesFile(), `${JSON.stringify(devices, null, 2)}\n`);
}

export async function mergeDevices(
  restored: readonly Device[],
): Promise<{ added: number; devices: Device[] }> {
  const current = await readDevices();
  const added = restored.filter(
    (device) => !current.some((saved) => saved.address === device.address),
  );
  const devices = [...current, ...added];
  await writeDevices(devices);
  return { added: added.length, devices };
}

type DeviceFailure = Extract<DeviceConnection, { state: "failed" }>;

function failed(field: DeviceField | null, message: string): DeviceFailure {
  return { state: "failed", field, message };
}

export function sshFailed({ code }: ProcessResult): boolean {
  return code === null || code === sshFailedCode;
}

function installKeyCommand(key: string): string {
  return [
    "cd",
    "mkdir -p .ssh",
    "chmod 700 .ssh",
    `touch ${authorizedKeys}`,
    `chmod 600 ${authorizedKeys}`,
    `{ ${commandText("grep", ["-qxF", key, authorizedKeys])} || ${commandText("printf", [String.raw`\n%s\n`, key])} >> ${authorizedKeys}; }`,
    `echo ${savedMarker}`,
  ].join(" && ");
}

function revokeKeysCommand(publicKeys: readonly string[]): string {
  const blobs = publicKeys.flatMap((key) => ["-e", key.split(" ")[1] ?? key]);
  return [
    "cd",
    `touch ${authorizedKeys}`,
    `{ ${commandText("grep", ["-vF", ...blobs, authorizedKeys])} > ${keptKeys}; [ $? -le 1 ]; }`,
    `mv ${keptKeys} ${authorizedKeys}`,
    `chmod 600 ${authorizedKeys}`,
    `echo ${removedMarker}`,
  ].join(" && ");
}

function found(pattern: RegExp, output: string): string | null {
  const text = pattern.exec(output)?.[1]?.trim() ?? "";
  return text === "" ? null : text;
}

export function connectionFailure(
  address: string,
  { code, output }: ProcessResult,
): DeviceFailure {
  if (code === null) {
    return failed(null, "The device stopped responding.");
  }
  if (output.includes("Permission denied")) {
    return output.includes(passwordPromptText)
      ? failed("password", "That root password did not work.")
      : failed(null, "The device does not let root sign in with a password.");
  }
  if (output.includes("Connection refused")) {
    return failed(
      "address",
      "The device refused the connection. Check that OpenSSH is installed on it.",
    );
  }
  if (unreachable.test(output)) {
    return failed(
      "address",
      `Could not reach ${address}. Check the address and that the device is on the same network.`,
    );
  }
  const detail = lastLines(output, 1);
  return failed(
    null,
    detail === ""
      ? `Could not connect to ${address}.`
      : `Could not connect to ${address}: ${detail}`,
  );
}

async function connect(
  address: string,
  password: string,
  group: LogWriter,
): Promise<DeviceConnection> {
  const key = await publicKey(group.log);

  group.log({ kind: "step", text: "Sign in with the root password" });
  await forgetHostKey(address);
  const signIn = await runWithPassword(
    address,
    password,
    installKeyCommand(key),
    group.log,
  );
  if (!savedLine.test(signIn.output)) {
    return sshFailed(signIn)
      ? connectionFailure(address, signIn)
      : failed(null, "Signed in, but could not save this computer's key.");
  }

  group.log({ kind: "step", text: "Sign in with this computer's key" });
  const test = await runAsRoot(address, testCommand, group.log);
  if (!nameLine.test(test.output)) {
    if (!sshFailed(test)) {
      return failed(null, "Signed in, but the test command did not run.");
    }
    return test.output.includes("Permission denied")
      ? failed(null, "The device did not accept this computer's key.")
      : connectionFailure(address, test);
  }

  const device: Device = {
    address,
    name: found(nameLine, test.output),
    model: found(modelLine, test.output),
    version: found(versionKey, test.output),
  };
  await writeDevices(withDevice(await readDevices(), device));
  return { state: "connected", device };
}

export async function addDevice({
  address,
  password,
}: DeviceLogin): Promise<DeviceConnection> {
  const parsed = addressSchema.safeParse(address.trim());
  if (!parsed.success) {
    return failed("address", "Enter an IP address, such as 192.168.1.20.");
  }
  if (!(await hasSsh())) {
    return failed(null, noSsh);
  }
  const group = openLogGroup("computer", `Add device ${parsed.data}`);
  try {
    const result = await withPriority(() =>
      connect(parsed.data, password, group),
    );
    if (result.state === "connected") {
      group.log({
        kind: "message",
        text: `Added ${deviceSummary(result.device)}`,
      });
      group.finish("done", "Added");
    } else {
      group.log({ kind: "error", text: result.message });
      group.finish("failed", result.message);
    }
    return result;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    group.log({ kind: "error", text: describeError(error) });
    group.finish("failed", message);
    if (error instanceof StepError) {
      return failed(null, message);
    }
    throw error;
  }
}

function revokeProblem(address: string, result: ProcessResult): string | null {
  if (removedLine.test(result.output)) {
    return null;
  }
  if (!sshFailed(result)) {
    return "Could not remove this computer's key from the device.";
  }
  return result.output.includes("Permission denied")
    ? null
    : connectionFailure(address, result).message;
}

async function revokeKeys(address: string): Promise<string | null> {
  const keys = await readKeys();
  if (keys.length === 0) {
    return null;
  }
  if (!(await hasSsh())) {
    return noSsh;
  }
  const group = openLogGroup("computer", `Remove device ${address}`);
  group.log({
    kind: "step",
    text: "Remove this computer's keys from the device",
  });
  try {
    const result = await withPriority(() =>
      runAsRoot(
        address,
        revokeKeysCommand(keys.map(({ publicKey }) => publicKey)),
        group.log,
      ),
    );
    const problem = revokeProblem(address, result);
    if (problem === null) {
      group.finish("done", "Removed");
    } else {
      group.log({ kind: "error", text: problem });
      group.finish("failed", problem);
    }
    return problem;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    group.log({ kind: "error", text: describeError(error) });
    group.finish("failed", message);
    return message;
  }
}

export async function removeDevice(
  address: string,
  revoke: boolean,
): Promise<DeviceRemoval> {
  if (revoke) {
    const problem = await revokeKeys(address);
    if (problem !== null) {
      return { state: "failed", message: problem };
    }
  }
  const devices = (await readDevices()).filter(
    (device) => device.address !== address,
  );
  await writeDevices(devices);
  await forgetHostKey(address);
  return { state: "removed", devices };
}
