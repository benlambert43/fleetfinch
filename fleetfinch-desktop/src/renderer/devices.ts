import { use, useSyncExternalStore } from "react";

import { type Device, withDevice } from "@/devices.ts";

let devices: readonly Device[] = [];
const listeners = new Set<() => void>();

const loaded = window.bridge.getDevices().then((saved) => {
  devices = saved;
});

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function currentDevices(): readonly Device[] {
  return devices;
}

export function setDevices(next: readonly Device[]): void {
  devices = next;
  for (const listener of listeners) {
    listener();
  }
}

export function rememberDevice(device: Device): void {
  setDevices(withDevice(devices, device));
}

export function useDevices(): readonly Device[] {
  use(loaded);
  return useSyncExternalStore(subscribe, currentDevices);
}
