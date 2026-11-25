import { randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import path from "node:path";
import { pipeline, Transform } from "node:stream";

import { type BrowserWindow, dialog } from "electron";

import {
  type DeviceInventoryResult,
  type DevicePackageInstall,
  type DevicePackageRemoval,
  type DeviceTaskEvent,
  type DeviceTaskStep,
  type DeviceTaskTarget,
  deviceTaskStepLabels,
  formatKb,
  installSteps,
  installSummary,
  removeSteps,
  systemVolume,
} from "@/deviceApps.ts";
import type { Device } from "@/devices.ts";
import type { LogEntry } from "@/logs.ts";
import {
  commandText,
  lastLines,
  type Log,
  type ProcessResult,
  StepError,
} from "@/main/buildTools/process.ts";
import { type DebFile, readDebFile } from "@/main/debFile.ts";
import { unmetDependencies } from "@/main/dependencies.ts";
import {
  devicePath,
  installedFormat,
  inventoryCommand,
  marker,
  packageFormat,
  parseInstalled,
  parseInventory,
  parsePackages,
  parseVolumes,
  splitOutput,
} from "@/main/deviceInventory.ts";
import {
  connectionFailure,
  noSsh,
  savedDevice,
  sshFailed,
} from "@/main/devices.ts";
import { logAppError, openLogGroup } from "@/main/logs.ts";
import {
  awake,
  hasSsh,
  readAsRoot,
  runAsRoot,
  sendAsRoot,
  withPriority,
} from "@/main/ssh.ts";

const listTimeoutMs = 90_000;
const checkTimeoutMs = 3 * 60_000;
const copyTimeoutMs = 20 * 60_000;
const changeTimeoutMs = 30 * 60_000;
const reserveKb = 8 * 1024;
const fractionStep = 0.01;
const refreshTool = "uicache";
const removalScripts = ["prerm", "postrm"];
const missingCode = "127";
const unknownDevice = "This device is no longer added.";
const busy = "Another app task is still running on this device.";
const refreshing =
  "Rebuilding the icon cache, which can take a few minutes on older devices";
const listedSize = /^\S+\s+\d+\s+\d+\s+\d+\s+(\d+)\s/m;
const trialCode = new RegExp(String.raw`^${marker} code (\d+)$`, "m");
const dpkgCode = new RegExp(String.raw`^${marker} dpkg (\d+)$`, "m");
const refreshCode = new RegExp(
  String.raw`^${marker} ${refreshTool} (\d+)$`,
  "m",
);
const markerLine = new RegExp(String.raw`^${marker} .*\n?`, "gm");
const neededLine = /^ \S+ (?:pre-)?depends on (.+?)(?:; however:|\.)?$/gm;
const dependentLine = /^ (\S+) (?:pre-)?depends on /gm;
const ownedApp = /^\/Applications\/[^/]+\.app$/m;
const refreshUse = /\buicache\b/;
const dpkgBegan = /Reading database|Unpacking|Setting up|Removing/;
const listFormat = new Intl.ListFormat("en", { type: "conjunction" });

const active = new Set<string>();
let lastFolder: string | null = null;

export type DeviceTaskSender = (event: DeviceTaskEvent) => void;

type Installed = Extract<DevicePackageInstall, { state: "installed" }>;
type Removed = Extract<DevicePackageRemoval, { state: "removed" }>;
type Refresh = "run" | "same" | "package" | "none";

interface Failure {
  state: "failed";
  message: string;
  output: string;
}

interface Task {
  step: (
    step: DeviceTaskStep,
    message: string,
    fraction?: number | null,
  ) => void;
  computer: Log;
  device: (command: string, onMarker?: (text: string) => void) => Log;
  finish: (state: "done" | "failed", outcome: string) => void;
}

const skippedRefresh: Record<Exclude<Refresh, "run">, string> = {
  same: "The app's Home screen entry has not changed",
  package: "The package refreshes the Home screen itself",
  none: "The package has no app to show on the Home screen",
};

function displayName(device: Device): string {
  return device.name ?? device.address;
}

function failure(message: string): Failure {
  return { state: "failed", message, output: "" };
}

function sshProblem(address: string, result: ProcessResult): string {
  if (!sshFailed(result)) {
    return "The device answered in a way that was not understood.";
  }
  if (result.output.includes("Permission denied")) {
    return "The device no longer accepts this computer's key. Add it again.";
  }
  return result.output.includes("not responding")
    ? "The device stopped answering. If it is asleep, wake it and try again."
    : connectionFailure(address, result).message;
}

function lostProblem(
  address: string,
  result: ProcessResult,
  doubt: string,
): string {
  return sentence(
    sshProblem(address, result),
    dpkgBegan.test(result.output) ? doubt : null,
  );
}

function withoutMarkers(output: string): string {
  return output.replace(markerLine, "").trim();
}

function dpkgProblem(output: string): string | null {
  const needed = [...output.matchAll(neededLine)]
    .map(([, need = ""]) => need.trim())
    .filter((need) => need !== "");
  if (needed.length > 0) {
    return `It needs ${needed.join(", ")}, which the device does not have.`;
  }
  if (/conflicts with|breaks/.test(output)) {
    return "It conflicts with a package that is already on the device.";
  }
  if (/locked by another process|database area is locked/.test(output)) {
    return "Cydia or another installer is using dpkg on the device. Close it and try again.";
  }
  if (output.includes("No space left on device")) {
    return "The device ran out of room.";
  }
  return output.includes("package architecture")
    ? "It is built for another kind of device."
    : null;
}

function sentence(...parts: (string | null)[]): string {
  return parts.filter((part) => part !== null).join(" ");
}

function refreshWarning(code: string | undefined): string | null {
  if (code === "0") {
    return null;
  }
  if (code === undefined) {
    return "The Home screen refresh did not finish, so the change may not show until the device restarts.";
  }
  return code === missingCode
    ? `The device has no ${refreshTool} to refresh the Home screen with. UIKit Tools in Cydia installs it.`
    : `${refreshTool} could not refresh the Home screen (exit code ${code}).`;
}

function refreshLines(): string[] {
  return [
    'if [ "$code" -eq 0 ]; then',
    `echo '${marker} refresh'`,
    refreshTool,
    `echo "${marker} ${refreshTool} $?"`,
    "fi",
  ];
}

function changeCommand(change: string, after: string[]): string {
  return [
    "trap '' HUP PIPE",
    `export PATH=${devicePath}`,
    change,
    "code=$?",
    ...after,
  ].join("\n");
}

function openTask(
  device: Device,
  title: string,
  steps: readonly DeviceTaskStep[],
  send: DeviceTaskSender,
): Task {
  const { address } = device;
  const group = openLogGroup("computer", title);
  let current: DeviceTaskStep | null = null;
  let lastMessage: string | null = null;
  let lastFraction: number | null = null;
  const emit = (
    { kind, text }: LogEntry,
    target: DeviceTaskTarget = "computer",
  ) => {
    if (kind !== "step" && kind !== "warning") {
      send({ address, type: "log", kind, text, target });
    }
  };
  send({ address, type: "started", title, steps: [...steps] });
  return {
    step: (step, message, fraction = null) => {
      if (step !== current) {
        current = step;
        group.log({ kind: "step", text: deviceTaskStepLabels[step] });
      }
      const fresh = message !== lastMessage;
      if (fresh) {
        lastMessage = message;
        group.log({ kind: "message", text: message });
        emit({ kind: "message", text: message });
      }
      if (
        fresh ||
        fraction === null ||
        lastFraction === null ||
        fraction === 1 ||
        fraction - lastFraction >= fractionStep
      ) {
        lastFraction = fraction;
        send({ address, type: "progress", step, message, fraction });
      }
    },
    computer: (line) => {
      group.log(line);
      emit(line);
    },
    device: (command, onMarker) => (line) => {
      if (line.kind === "output" && line.text.startsWith(`${marker} `)) {
        onMarker?.(line.text.slice(marker.length + 1));
        return;
      }
      group.log(line);
      emit(
        line.kind === "command" ? { ...line, text: command } : line,
        "device",
      );
    },
    finish: (state, outcome) => {
      const kind = state === "failed" ? "error" : "message";
      group.log({ kind, text: outcome });
      emit({ kind, text: outcome });
      group.finish(state, outcome);
      send({ address, type: "finished", state, message: outcome });
    },
  };
}

function taskFailure(task: Task, error: unknown): Failure {
  const message = error instanceof Error ? error.message : String(error);
  if (!(error instanceof StepError)) {
    logAppError("A device app task failed", error);
  }
  task.finish("failed", message);
  return {
    state: "failed",
    message,
    output: error instanceof StepError ? lastLines(error.output) : "",
  };
}

export async function readDeviceApps(
  address: string,
): Promise<DeviceInventoryResult> {
  const device = await savedDevice(address);
  if (device === null) {
    return { state: "failed", message: unknownDevice };
  }
  if (!(await hasSsh())) {
    return { state: "failed", message: noSsh };
  }
  const lines: LogEntry[] = [];
  const result = await awake(address, () =>
    readAsRoot(
      address,
      inventoryCommand,
      (line) => {
        lines.push(line);
      },
      listTimeoutMs,
    ),
  );
  const inventory = parseInventory(result.data, Date.now());
  if (inventory !== null) {
    return { state: "listed", inventory };
  }
  const message = sshProblem(address, {
    code: result.code,
    output: result.errors,
  });
  const group = openLogGroup(
    "computer",
    `Read the apps on ${displayName(device)}`,
  );
  for (const line of lines) {
    group.log(line);
  }
  group.log({ kind: "error", text: message });
  group.finish("failed", message);
  return { state: "failed", message };
}

async function discard(address: string, remote: string): Promise<void> {
  await runAsRoot(address, `rm -f ${remote}`).catch(() => undefined);
}

async function copy(
  device: Device,
  deb: DebFile,
  remote: string,
  task: Task,
): Promise<void> {
  const target = displayName(device);
  const message = `Copying ${formatKb(deb.bytes / 1024)} to ${target}`;
  task.step("copy", message, 0);
  let sent = 0;
  const counter = new Transform({
    transform(chunk: Buffer, _encoding, done) {
      sent += chunk.length;
      task.step("copy", message, Math.min(sent / deb.bytes, 1));
      done(null, chunk);
    },
  });
  pipeline(createReadStream(deb.file), counter, () => undefined);
  const command = `cat > ${remote} && ls -ln ${remote}`;
  const result = await sendAsRoot(
    device.address,
    counter,
    command,
    task.device(command),
    copyTimeoutMs,
  );
  const [, size] = listedSize.exec(result.output) ?? [];
  if (result.code === 0 && Number(size) === deb.bytes) {
    return;
  }
  if (sshFailed(result) && size === undefined) {
    throw new StepError(sshProblem(device.address, result), result.output);
  }
  await discard(device.address, remote);
  throw new StepError(
    size === undefined
      ? `The package could not be copied to ${target}.`
      : `Only ${size} of the package's ${String(deb.bytes)} bytes reached ${target}.`,
    result.output,
  );
}

function refreshPlan(deb: DebFile, current: Map<string, Buffer>): Refresh {
  if (deb.apps.length === 0) {
    return "none";
  }
  if (deb.refreshesItself) {
    return "package";
  }
  const same = deb.apps.every(({ path: bundle, info }) => {
    const installed = current.get(`${bundle}/Info.plist`);
    return info !== null && installed?.equals(info) === true;
  });
  return same ? "same" : "run";
}

async function check(
  device: Device,
  deb: DebFile,
  remote: string,
  task: Task,
): Promise<{ previous: string | null; refresh: Refresh }> {
  const target = displayName(device);
  task.step("check", `Checking that ${target} can take it`);
  const trial = `dpkg --dry-run -i ${remote}`;
  const infoFiles = deb.apps.map((app) => `${app.path}/Info.plist`);
  const command = [
    `export PATH=${devicePath}`,
    `echo '${marker} packages'`,
    `${commandText("dpkg-query", ["-W", `-f=${packageFormat}`, deb.id])} 2>/dev/null`,
    `echo '${marker} installed'`,
    `${commandText("dpkg-query", ["-W", `-f=${installedFormat}`])} 2>/dev/null`,
    `echo '${marker} volumes'`,
    "df -k / /private/var 2>/dev/null",
    `echo '${marker} trial'`,
    `${trial} 2>&1`,
    `echo "${marker} code $?"`,
    `echo '${marker} plists'`,
    ...(infoFiles.length === 0
      ? []
      : [`${commandText("tar", ["-cf", "-", ...infoFiles])} 2>/dev/null`]),
  ].join("\n");
  const log = task.device(trial);
  const result = await readAsRoot(device.address, command, log, checkTimeoutMs);
  const { sections, files } = splitOutput(result.data, [
    "packages",
    "installed",
    "volumes",
    "trial",
  ]);
  const tried = sections.get("trial");
  const [, code] = trialCode.exec(tried ?? "") ?? [];
  if (tried === undefined || code === undefined) {
    throw new StepError(
      sshProblem(device.address, { code: result.code, output: result.errors }),
      result.errors,
    );
  }
  const output = withoutMarkers(tried);
  for (const text of output.split("\n")) {
    if (text.trim() !== "") {
      log({ kind: "output", text });
    }
  }
  const [installed] = parsePackages(sections.get("packages") ?? "");
  if (installed !== undefined && installed.locked !== null) {
    throw new StepError(
      `${installed.name} cannot be replaced from here. ${installed.locked}.`,
    );
  }
  const system = systemVolume(parseVolumes(sections.get("volumes") ?? ""));
  if (system !== null && deb.systemKb + reserveKb > system.freeKb) {
    throw new StepError(
      `${deb.name} takes about ${formatKb(deb.systemKb)} of the system volume on ${target}, which has ${formatKb(system.freeKb)} free. That would leave less than ${formatKb(reserveKb)}.`,
    );
  }
  if (code === missingCode) {
    throw new StepError(
      `${target} has no dpkg to install packages with.`,
      output,
    );
  }
  if (code !== "0") {
    throw new StepError(
      sentence(`${target} would not install ${deb.name}.`, dpkgProblem(output)),
      output,
    );
  }
  const unmet = unmetDependencies(
    deb.depends,
    parseInstalled(sections.get("installed") ?? ""),
  );
  if (unmet.length > 0) {
    throw new StepError(
      `${deb.name} needs ${listFormat.format(unmet)}, which ${target} does not have. Install ${unmet.length === 1 ? "it" : "them"} first.`,
    );
  }
  return {
    previous: installed?.version ?? null,
    refresh: refreshPlan(deb, files),
  };
}

async function install(
  device: Device,
  file: string,
  expected: string | null,
  task: Task,
): Promise<Installed> {
  const { address } = device;
  const base = path.basename(file);
  task.step("read", `Reading ${base}`);
  const deb = await readDebFile(file, task.computer);
  if (expected !== null && deb.id !== expected) {
    throw new StepError(`${base} holds ${deb.id}, not ${expected}.`);
  }
  task.step("read", `${base} holds ${deb.name} ${deb.version} (${deb.id})`);
  const remote = `/tmp/fleetfinch-${randomBytes(8).toString("hex")}.deb`;
  await copy(device, deb, remote, task);
  const copied = { left: true };
  try {
    const { previous, refresh } = await check(device, deb, remote, task);
    task.step("install", `Installing ${deb.name} ${deb.version}`);
    const change = `dpkg --force-confdef --force-confold -i ${remote}`;
    const result = await runAsRoot(
      address,
      changeCommand(change, [
        `rm -f ${remote}`,
        `echo "${marker} dpkg $code"`,
        ...(refresh === "run" ? refreshLines() : []),
      ]),
      task.device(change, (text) => {
        if (text.startsWith("dpkg ")) {
          copied.left = false;
        } else if (text === "refresh") {
          task.step("refresh", refreshing);
        }
      }),
      undefined,
      changeTimeoutMs,
    );
    const [, code] = dpkgCode.exec(result.output) ?? [];
    if (code === undefined) {
      throw new StepError(
        lostProblem(
          address,
          result,
          `${deb.name} may have been installed all the same.`,
        ),
        result.output,
      );
    }
    const output = withoutMarkers(result.output);
    if (code !== "0") {
      throw new StepError(
        sentence(`dpkg could not install ${deb.name}.`, dpkgProblem(output)),
        output,
      );
    }
    if (refresh !== "run") {
      task.step("refresh", skippedRefresh[refresh]);
    }
    return {
      state: "installed",
      id: deb.id,
      name: deb.name,
      version: deb.version,
      previous,
      warning:
        refresh === "run"
          ? refreshWarning(refreshCode.exec(result.output)?.[1])
          : null,
    };
  } finally {
    if (copied.left) {
      await discard(address, remote);
    }
  }
}

async function remove(
  device: Device,
  id: string,
  task: Task,
): Promise<Removed> {
  const { address } = device;
  const target = displayName(device);
  task.step("remove", `Looking up ${id} on ${target}`);
  const lookup = commandText("dpkg-query", ["-W", id]);
  const found = await readAsRoot(
    address,
    [
      `export PATH=${devicePath}`,
      `echo '${marker} packages'`,
      `${commandText("dpkg-query", ["-W", `-f=${packageFormat}`, id])} 2>/dev/null`,
      `echo '${marker} files'`,
      `${commandText("dpkg-query", ["-L", id])} 2>/dev/null`,
      `echo '${marker} scripts'`,
      ...removalScripts.map(
        (script) =>
          `${commandText("dpkg-query", ["--control-show", id, script])} 2>/dev/null`,
      ),
    ].join("\n"),
    task.device(lookup),
    checkTimeoutMs,
  );
  const { sections } = splitOutput(found.data, [
    "packages",
    "files",
    "scripts",
  ]);
  const ownScripts = sections.get("scripts");
  if (ownScripts === undefined) {
    throw new StepError(
      sshProblem(address, { code: found.code, output: found.errors }),
      found.errors,
    );
  }
  const [record] = parsePackages(sections.get("packages") ?? "");
  if (record === undefined) {
    throw new StepError(`${id} is not installed on ${target}.`);
  }
  if (record.locked !== null) {
    throw new StepError(
      `${record.name} cannot be removed from here. ${record.locked}.`,
    );
  }
  const hasApp = ownedApp.test(sections.get("files") ?? "");
  const refreshesItself = refreshUse.test(ownScripts);
  const refresh = hasApp && !refreshesItself;
  task.step("remove", `Removing ${record.name} ${record.version}`);
  const change = commandText("dpkg", ["-r", id]);
  const result = await runAsRoot(
    address,
    changeCommand(change, [
      `echo "${marker} dpkg $code"`,
      ...(refresh ? refreshLines() : []),
    ]),
    task.device(change, (text) => {
      if (text === "refresh") {
        task.step("refresh", refreshing);
      }
    }),
    undefined,
    changeTimeoutMs,
  );
  const [, code] = dpkgCode.exec(result.output) ?? [];
  if (code === undefined) {
    throw new StepError(
      lostProblem(
        address,
        result,
        `${record.name} may have been removed all the same.`,
      ),
      result.output,
    );
  }
  const output = withoutMarkers(result.output);
  if (code !== "0") {
    const dependents = [...output.matchAll(dependentLine)]
      .map(([, dependent = ""]) => dependent)
      .filter((dependent) => dependent !== "");
    throw new StepError(
      sentence(
        `dpkg could not remove ${record.name}.`,
        dependents.length > 0
          ? `${[...new Set(dependents)].join(", ")} still needs it.`
          : dpkgProblem(output),
      ),
      output,
    );
  }
  if (!refresh) {
    task.step("refresh", skippedRefresh[hasApp ? "package" : "none"]);
  }
  return {
    state: "removed",
    id,
    name: record.name,
    warning: refresh
      ? refreshWarning(refreshCode.exec(result.output)?.[1])
      : null,
  };
}

export async function installDevicePackage(
  window: BrowserWindow,
  address: string,
  expected: string | null,
  send: DeviceTaskSender,
): Promise<DevicePackageInstall> {
  const device = await savedDevice(address);
  if (device === null) {
    return failure(unknownDevice);
  }
  if (active.has(address)) {
    return failure(busy);
  }
  if (!(await hasSsh())) {
    return failure(noSsh);
  }
  const { canceled, filePaths } = await dialog.showOpenDialog(window, {
    title: expected === null ? "Install App" : `Update ${expected}`,
    buttonLabel: "Install",
    ...(lastFolder === null ? {} : { defaultPath: lastFolder }),
    properties: ["openFile"],
    filters: [{ name: "Packages", extensions: ["deb"] }],
  });
  const [file] = filePaths;
  if (canceled || file === undefined) {
    return { state: "canceled" };
  }
  lastFolder = path.dirname(file);
  if (active.has(address)) {
    return failure(busy);
  }
  active.add(address);
  const task = openTask(
    device,
    `Install ${path.basename(file)} on ${displayName(device)}`,
    installSteps,
    send,
  );
  try {
    const result = await withPriority(() =>
      awake(address, () => install(device, file, expected, task)),
    );
    task.finish("done", sentence(`${installSummary(result)}.`, result.warning));
    return result;
  } catch (error) {
    return taskFailure(task, error);
  } finally {
    active.delete(address);
  }
}

export async function removeDevicePackage(
  address: string,
  id: string,
  send: DeviceTaskSender,
): Promise<DevicePackageRemoval> {
  const device = await savedDevice(address);
  if (device === null) {
    return failure(unknownDevice);
  }
  if (!(await hasSsh())) {
    return failure(noSsh);
  }
  if (active.has(address)) {
    return failure(busy);
  }
  active.add(address);
  const task = openTask(
    device,
    `Remove ${id} from ${displayName(device)}`,
    removeSteps,
    send,
  );
  try {
    const result = await withPriority(() =>
      awake(address, () => remove(device, id, task)),
    );
    task.finish("done", sentence(`Removed ${result.name}.`, result.warning));
    return result;
  } catch (error) {
    return taskFailure(task, error);
  } finally {
    active.delete(address);
  }
}
