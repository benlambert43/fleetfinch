import { createReadStream } from "node:fs";
import { open } from "node:fs/promises";
import type { Readable } from "node:stream";
import { createGunzip, gunzipSync } from "node:zlib";

export interface DumpLog {
  stream: string;
  lines: string[];
  total: number;
}

export interface DumpSnapshot {
  kind: string;
  name: string;
  lines: string[];
  total: number;
}

export interface LogDump {
  details: Record<string, string>;
  logs: DumpLog[];
  snapshots: DumpSnapshot[];
  files: number;
}

interface Entry {
  name: string;
  remaining: number;
  padding: number;
  chunks: Buffer[] | null;
}

const blockSize = 512;
const entryLimit = 128 * 1024 * 1024;
const fileTypes = new Set(["0", "\0", "7"]);
const posixMagic = "ustar";
const manifestName = "finchlogs.txt";
const packed = ".gz";
const gzipMagic = [0x1f, 0x8b];
const logName = /^(?:archive|live)\/([^/]+)\/[^/]+\.log(?:\.gz)?$/u;
const snapshotName =
  /^(?:archive|live)\/snapshots\/([^/]+)\/([^/]+)\.txt(?:\.gz)?$/u;
const detailLine = /^([^:]+): (.*)$/u;
const otherFolders = new Set(["snapshots", "imports"]);

function field(block: Buffer, start: number, length: number): string {
  const end = block.indexOf(0, start);
  const stop = end === -1 || end > start + length ? start + length : end;
  return block.toString("utf8", start, stop);
}

function wanted(name: string): boolean {
  const stream = logName.exec(name)?.[1];
  return (
    name === manifestName ||
    snapshotName.test(name) ||
    (stream !== undefined && !otherFolders.has(stream))
  );
}

function startEntry(header: Buffer): Entry | null {
  const size = Number.parseInt(field(header, 124, 12).trim() || "0", 8);
  if (!Number.isSafeInteger(size) || size < 0) {
    return null;
  }
  const prefix =
    field(header, 257, 6) === posixMagic ? field(header, 345, 155) : "";
  const short = field(header, 0, 100);
  const name = prefix === "" ? short : `${prefix}/${short}`;
  const type = field(header, 156, 1) || "\0";
  const keep = fileTypes.has(type) && size <= entryLimit && wanted(name);
  return {
    name,
    remaining: size,
    padding: (blockSize - (size % blockSize)) % blockSize,
    chunks: keep ? [] : null,
  };
}

function textLines(name: string, data: Buffer): string[] | null {
  let plain = data;
  if (name.endsWith(packed)) {
    try {
      plain = gunzipSync(data);
    } catch {
      return null;
    }
  }
  const lines = plain.toString("utf8").split("\n");
  if (lines.at(-1) === "") {
    lines.pop();
  }
  return lines;
}

async function isPacked(file: string): Promise<boolean> {
  const handle = await open(file, "r");
  try {
    const { bytesRead, buffer } = await handle.read(Buffer.alloc(2), 0, 2, 0);
    return (
      bytesRead === 2 &&
      buffer[0] === gzipMagic[0] &&
      buffer[1] === gzipMagic[1]
    );
  } finally {
    await handle.close();
  }
}

export async function readLogDump(
  file: string,
  keep: number,
): Promise<LogDump> {
  const source = createReadStream(file);
  const input: Readable = (await isPacked(file))
    ? source.pipe(createGunzip())
    : source;
  const logs = new Map<string, DumpLog>();
  const snapshots = new Map<string, DumpSnapshot>();
  const details: Record<string, string> = {};
  let files = 0;
  const seen = { manifest: false };

  const finish = (entry: Entry) => {
    if (entry.chunks === null) {
      return;
    }
    const lines = textLines(entry.name, Buffer.concat(entry.chunks));
    if (lines === null) {
      return;
    }
    if (entry.name === manifestName) {
      seen.manifest = true;
      for (const line of lines) {
        const [, key, value] = detailLine.exec(line) ?? [];
        if (key !== undefined && value !== undefined) {
          details[key] = value;
        }
      }
      return;
    }
    const snapshot = snapshotName.exec(entry.name);
    if (snapshot !== null) {
      const [, kind = "", name = ""] = snapshot;
      snapshots.set(kind, {
        kind,
        name,
        lines: lines.slice(0, keep),
        total: lines.length,
      });
      return;
    }
    const stream = logName.exec(entry.name)?.[1] ?? "";
    const log = logs.get(stream) ?? { stream, lines: [], total: 0 };
    log.total += lines.length;
    log.lines = [...log.lines, ...lines].slice(-keep);
    logs.set(stream, log);
  };

  let buffer: Buffer = Buffer.alloc(0);
  let entry: Entry | null = null;
  let skip = 0;
  try {
    for await (const chunk of input) {
      buffer =
        buffer.length === 0
          ? (chunk as Buffer)
          : Buffer.concat([buffer, chunk as Buffer]);
      for (;;) {
        if (skip > 0) {
          const dropped = Math.min(skip, buffer.length);
          buffer = buffer.subarray(dropped);
          skip -= dropped;
          if (skip > 0) {
            break;
          }
        }
        if (entry === null) {
          if (buffer.length < blockSize) {
            break;
          }
          const header = buffer.subarray(0, blockSize);
          buffer = buffer.subarray(blockSize);
          if (header.every((byte) => byte === 0)) {
            continue;
          }
          entry = startEntry(header);
          if (entry === null) {
            throw new Error("The archive is damaged.");
          }
          files += 1;
        }
        const taken = Math.min(entry.remaining, buffer.length);
        if (taken > 0) {
          entry.chunks?.push(Buffer.from(buffer.subarray(0, taken)));
          buffer = buffer.subarray(taken);
          entry.remaining -= taken;
        }
        if (entry.remaining > 0) {
          break;
        }
        finish(entry);
        skip = entry.padding;
        entry = null;
      }
    }
  } finally {
    source.destroy();
  }
  if (!seen.manifest && logs.size === 0 && snapshots.size === 0) {
    throw new Error("That file is not a Finch Logs dump.");
  }
  return {
    details,
    logs: [...logs.values()],
    snapshots: [...snapshots.values()],
    files,
  };
}
