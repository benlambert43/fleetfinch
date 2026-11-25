import { use, useSyncExternalStore } from "react";

import { type Device, withDevice } from "@/devices.ts";

export const devicesHref = "#/devices";

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

export function deviceHref(address: string): string {
  return `${devicesHref}/${encodeURIComponent(address)}`;
}

export function isDevicesHash(hash: string): boolean {
  return hash === devicesHref || hash.startsWith(`${devicesHref}/`);
}

function subscribeToHash(listener: () => void): () => void {
  window.addEventListener("hashchange", listener);
  return () => {
    window.removeEventListener("hashchange", listener);
  };
}

function shownAddress(): string | null {
  const { hash } = window.location;
  if (!hash.startsWith(`${devicesHref}/`)) {
    return null;
  }
  try {
    return decodeURIComponent(hash.slice(devicesHref.length + 1));
  } catch {
    return null;
  }
}

export function useShownDeviceAddress(): string | null {
  return useSyncExternalStore(subscribeToHash, shownAddress);
}

export function showDevices(): void {
  if (shownAddress() !== null) {
    window.location.replace(devicesHref);
  }
}
