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

const backupsSegment = "backups";

export function deviceBackupsHref(address: string): string {
  return `${deviceHref(address)}/${backupsSegment}`;
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

function shownSegments(): string[] {
  const { hash } = window.location;
  if (!hash.startsWith(`${devicesHref}/`)) {
    return [];
  }
  return hash.slice(devicesHref.length + 1).split("/");
}

function shownAddress(): string | null {
  const [address] = shownSegments();
  if (address === undefined) {
    return null;
  }
  try {
    return decodeURIComponent(address);
  } catch {
    return null;
  }
}

function showingBackups(): boolean {
  const [, page, ...rest] = shownSegments();
  return page === backupsSegment && rest.length === 0;
}

export function useShownDeviceAddress(): string | null {
  return useSyncExternalStore(subscribeToHash, shownAddress);
}

export function useShowingDeviceBackups(): boolean {
  return useSyncExternalStore(subscribeToHash, showingBackups);
}

export function showDevices(): void {
  if (shownAddress() !== null) {
    window.location.replace(devicesHref);
  }
}
