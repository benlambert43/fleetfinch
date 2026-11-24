export interface DeviceLogin {
  address: string;
  password: string;
}

export type DeviceField = "address" | "password";

export interface Device {
  address: string;
  name: string | null;
  model: string | null;
  version: string | null;
}

export type DeviceConnection =
  | { state: "connected"; device: Device }
  | { state: "failed"; field: DeviceField | null; message: string };

export type DeviceRemoval =
  | { state: "removed"; devices: Device[] }
  | { state: "failed"; message: string };

export type BackupExport =
  | { state: "saved"; file: string }
  | { state: "canceled" }
  | { state: "failed"; message: string };

export type BackupRestore =
  | { state: "restored"; keys: number; added: number; devices: Device[] }
  | { state: "canceled" }
  | { state: "failed"; message: string };

export function withDevice(
  devices: readonly Device[],
  device: Device,
): Device[] {
  return devices.some((saved) => saved.address === device.address)
    ? devices.map((saved) =>
        saved.address === device.address ? device : saved,
      )
    : [...devices, device];
}

export function deviceDetails({ address, model, version }: Device): string {
  return [model, version === null ? null : `iOS ${version}`, address]
    .filter((part) => part !== null)
    .join(" · ");
}

export function deviceSummary(device: Device): string {
  return device.name === null
    ? deviceDetails(device)
    : `${device.name} · ${deviceDetails(device)}`;
}
