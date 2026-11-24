import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  scrypt,
} from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { app, type BrowserWindow, dialog } from "electron";
import { z } from "zod";

import type { BackupExport, BackupRestore } from "@/devices.ts";
import { devicesSchema, mergeDevices, readDevices } from "@/main/devices.ts";
import { openLogGroup } from "@/main/logs.ts";
import {
  addKey,
  mergeKnownHosts,
  readKeys,
  readKnownHosts,
} from "@/main/ssh.ts";

const format = "fleetfinch-device-backup";
const cipherName = "aes-256-gcm";
const scryptOptions = { N: 2 ** 16, r: 8, p: 1, maxmem: 2 ** 28 };
const fileFilters = [{ name: "FleetFinch backup", extensions: ["json"] }];

const envelopeSchema = z.strictObject({
  format: z.literal(format),
  version: z.literal(1),
  salt: z.base64(),
  iv: z.base64(),
  tag: z.base64(),
  data: z.base64(),
});

const payloadSchema = z.strictObject({
  keys: z
    .array(
      z.strictObject({
        privateKey: z
          .string()
          .startsWith("-----BEGIN OPENSSH PRIVATE KEY-----"),
        publicKey: z.string().regex(/^ssh-[\w-]+ [\w+/=]+(?: [^\n]*)?$/),
      }),
    )
    .min(1),
  knownHosts: z.string(),
  devices: devicesSchema,
});

type Envelope = z.infer<typeof envelopeSchema>;

function deriveKey(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, 32, scryptOptions, (error, key) => {
      if (error) {
        reject(error);
      } else {
        resolve(key);
      }
    });
  });
}

async function encrypt(text: string, password: string): Promise<Envelope> {
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const cipher = createCipheriv(
    cipherName,
    await deriveKey(password, salt),
    iv,
  );
  const data = Buffer.concat([cipher.update(text, "utf8"), cipher.final()]);
  return {
    format,
    version: 1,
    salt: salt.toString("base64"),
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    data: data.toString("base64"),
  };
}

async function decrypt(
  { salt, iv, tag, data }: Envelope,
  password: string,
): Promise<string | null> {
  const key = await deriveKey(password, Buffer.from(salt, "base64"));
  try {
    const decipher = createDecipheriv(
      cipherName,
      key,
      Buffer.from(iv, "base64"),
    );
    decipher.setAuthTag(Buffer.from(tag, "base64"));
    return Buffer.concat([
      decipher.update(Buffer.from(data, "base64")),
      decipher.final(),
    ]).toString("utf8");
  } catch {
    return null;
  }
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function record(title: string, failed: boolean, text: string): void {
  const group = openLogGroup("computer", title);
  group.log({ kind: failed ? "error" : "message", text });
  group.finish(failed ? "failed" : "done", text);
}

export async function exportBackup(
  window: BrowserWindow,
  password: string,
): Promise<BackupExport> {
  const keys = await readKeys();
  if (keys.length === 0) {
    return {
      state: "failed",
      message: "Add a device first. There is no key to back up yet.",
    };
  }
  const { canceled, filePath } = await dialog.showSaveDialog(window, {
    title: "Export Backup",
    defaultPath: path.join(app.getPath("documents"), "fleetfinch-backup.json"),
    filters: fileFilters,
  });
  if (canceled || filePath === "") {
    return { state: "canceled" };
  }
  try {
    const payload = JSON.stringify({
      keys,
      knownHosts: await readKnownHosts(),
      devices: await readDevices(),
    });
    const envelope = await encrypt(payload, password);
    await writeFile(filePath, `${JSON.stringify(envelope, null, 2)}\n`, {
      mode: 0o600,
    });
  } catch (error) {
    const message = `Could not save the backup: ${errorText(error)}`;
    record("Export device backup", true, message);
    return { state: "failed", message };
  }
  record("Export device backup", false, `Saved ${filePath}`);
  return { state: "saved", file: filePath };
}

export async function restoreBackup(
  window: BrowserWindow,
  password: string,
): Promise<BackupRestore> {
  const { canceled, filePaths } = await dialog.showOpenDialog(window, {
    title: "Restore Backup",
    defaultPath: app.getPath("documents"),
    properties: ["openFile"],
    filters: fileFilters,
  });
  const [file] = filePaths;
  if (canceled || file === undefined) {
    return { state: "canceled" };
  }
  const envelope = envelopeSchema.safeParse(
    parseJson(await readFile(file, "utf8").catch(() => "")),
  );
  if (!envelope.success) {
    return {
      state: "failed",
      message: "That file is not a FleetFinch backup.",
    };
  }
  const text = await decrypt(envelope.data, password);
  if (text === null) {
    return { state: "failed", message: "That backup password did not work." };
  }
  const payload = payloadSchema.safeParse(parseJson(text));
  if (!payload.success) {
    return { state: "failed", message: "That backup is damaged." };
  }
  try {
    let keys = 0;
    for (const key of payload.data.keys) {
      if (await addKey(key)) {
        keys += 1;
      }
    }
    await mergeKnownHosts(payload.data.knownHosts);
    const { added, devices } = await mergeDevices(payload.data.devices);
    record(
      "Restore device backup",
      false,
      `Restored ${String(keys)} keys and ${String(added)} devices from ${file}`,
    );
    return { state: "restored", keys, added, devices };
  } catch (error) {
    const message = `Could not restore the backup: ${errorText(error)}`;
    record("Restore device backup", true, message);
    return { state: "failed", message };
  }
}
