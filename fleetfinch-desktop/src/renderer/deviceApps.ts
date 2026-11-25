import { useSyncExternalStore } from "react";

import {
  type DeviceInventory,
  type DevicePackageInstall,
  type DevicePackageRemoval,
  type DeviceTaskEvent,
  type DeviceTaskStep,
  deviceTaskStepLabels,
  installSummary,
} from "@/deviceApps.ts";
import {
  appendTaskLog,
  finishedStep,
  recordCommand,
  settleSteps,
  startTask,
  updateTask,
} from "@/renderer/activity.ts";

export interface DeviceNotice {
  tone: "status" | "alert";
  text: string;
  output: string;
}

export interface DeviceProgress {
  step: DeviceTaskStep;
  message: string;
  fraction: number | null;
}

export interface DeviceAppsState {
  inventory: DeviceInventory | null;
  loading: boolean;
  problem: string | null;
  busy: boolean;
  progress: DeviceProgress | null;
  notice: DeviceNotice | null;
}

const idle: DeviceAppsState = {
  inventory: null,
  loading: false,
  problem: null,
  busy: false,
  progress: null,
  notice: null,
};

const states = new Map<string, DeviceAppsState>();
const queued = new Set<string>();
const listeners = new Set<() => void>();

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function stateOf(address: string): DeviceAppsState {
  return states.get(address) ?? idle;
}

function change(address: string, next: Partial<DeviceAppsState>): void {
  states.set(address, { ...stateOf(address), ...next });
  for (const listener of listeners) {
    listener();
  }
}

function taskId(address: string): string {
  return `device-apps-${address}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function showEvent(event: DeviceTaskEvent): void {
  const id = taskId(event.address);
  switch (event.type) {
    case "started":
      startTask({
        id,
        title: event.title,
        steps: event.steps.map((step) => ({
          id: step,
          label: deviceTaskStepLabels[step],
        })),
      });
      change(event.address, { progress: null });
      return;
    case "progress": {
      const { step, message, fraction } = event;
      updateTask(id, (task) =>
        task.state === "running"
          ? {
              ...task,
              steps: settleSteps(task.steps, step, {
                state: "running",
                detail: message,
                fraction,
              }),
            }
          : task,
      );
      change(event.address, { progress: { step, message, fraction } });
      return;
    }
    case "log":
      appendTaskLog(id, [{ kind: event.kind, text: event.text }]);
      if (event.kind === "command") {
        recordCommand(event.text, event.target);
      }
      return;
    case "finished":
      finishTask(id, event.state === "failed" ? event.message : null);
      change(event.address, { progress: null });
  }
}

function finishTask(id: string, problem: string | null): void {
  updateTask(id, (task) => {
    if (task.state !== "running") {
      return task;
    }
    if (problem === null) {
      return { ...task, state: "done", steps: task.steps.map(finishedStep) };
    }
    const current =
      task.steps.find((step) => step.state === "running") ?? task.steps[0];
    return {
      ...task,
      state: "failed",
      steps:
        current === undefined
          ? task.steps
          : settleSteps(task.steps, current.id, {
              state: "failed",
              detail: problem,
              fraction: null,
            }),
    };
  });
}

function sentence(...parts: (string | null)[]): string {
  return parts.filter((part) => part !== null).join(" ");
}

function installNotice(result: DevicePackageInstall): DeviceNotice | null {
  switch (result.state) {
    case "installed":
      return {
        tone: "status",
        text: sentence(`${installSummary(result)}.`, result.warning),
        output: "",
      };
    case "canceled":
      return null;
    case "failed":
      return { tone: "alert", text: result.message, output: result.output };
  }
}

function removalNotice(result: DevicePackageRemoval): DeviceNotice {
  return result.state === "removed"
    ? {
        tone: "status",
        text: sentence(`Removed ${result.name}.`, result.warning),
        output: "",
      }
    : { tone: "alert", text: result.message, output: result.output };
}

window.bridge.onDeviceTask(showEvent);

export function useDeviceApps(address: string): DeviceAppsState {
  return useSyncExternalStore(subscribe, () => stateOf(address));
}

export function loadDeviceApps(address: string): void {
  if (stateOf(address).loading) {
    queued.add(address);
    return;
  }
  change(address, { loading: true });
  const settle = (next: Partial<DeviceAppsState>) => {
    change(address, { loading: false, ...next });
    if (queued.delete(address)) {
      loadDeviceApps(address);
    }
  };
  window.bridge.getDeviceApps(address).then(
    (result) => {
      settle(
        result.state === "listed"
          ? { problem: null, inventory: result.inventory }
          : { problem: result.message },
      );
    },
    (error: unknown) => {
      settle({ problem: errorMessage(error) });
    },
  );
}

export function ensureDeviceApps(address: string): void {
  const { inventory, loading } = stateOf(address);
  if (inventory === null && !loading) {
    loadDeviceApps(address);
  }
}

export async function installOnDevice(
  address: string,
  expected: string | null,
): Promise<void> {
  if (stateOf(address).busy) {
    return;
  }
  change(address, { busy: true, progress: null, notice: null });
  const result = await window.bridge
    .installDevicePackage(address, expected)
    .catch((error: unknown): DevicePackageInstall => ({
      state: "failed",
      message: errorMessage(error),
      output: "",
    }));
  change(address, { busy: false, notice: installNotice(result) });
  if (result.state !== "canceled") {
    loadDeviceApps(address);
  }
}

export async function removeFromDevice(
  address: string,
  id: string,
): Promise<void> {
  if (stateOf(address).busy) {
    return;
  }
  change(address, { busy: true, progress: null, notice: null });
  const result = await window.bridge
    .removeDevicePackage(address, id)
    .catch((error: unknown): DevicePackageRemoval => ({
      state: "failed",
      message: errorMessage(error),
      output: "",
    }));
  change(address, { busy: false, notice: removalNotice(result) });
  loadDeviceApps(address);
}
