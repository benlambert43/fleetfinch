const blockSize = 512;
const fileTypes = new Set(["0", "\0", "7"]);
const longNameType = "L";
const posixMagic = "ustar";

function field(block: Buffer, start: number, length: number): string {
  const end = block.indexOf(0, start);
  const stop = end === -1 || end > start + length ? start + length : end;
  return block.toString("utf8", start, stop);
}

export function readTar(archive: Buffer): Map<string, Buffer> {
  const files = new Map<string, Buffer>();
  let offset = 0;
  let longName: string | null = null;
  while (offset + blockSize <= archive.length) {
    const header = archive.subarray(offset, offset + blockSize);
    offset += blockSize;
    if (header.every((byte) => byte === 0)) {
      continue;
    }
    const size = Number.parseInt(field(header, 124, 12).trim() || "0", 8);
    if (!Number.isSafeInteger(size) || offset + size > archive.length) {
      break;
    }
    const body = archive.subarray(offset, offset + size);
    offset += Math.ceil(size / blockSize) * blockSize;
    const type = field(header, 156, 1) || "\0";
    if (type === longNameType) {
      longName = body.toString("utf8").replace(/\0+$/, "");
      continue;
    }
    const prefix =
      field(header, 257, 6) === posixMagic ? field(header, 345, 155) : "";
    const short = field(header, 0, 100);
    const name = longName ?? (prefix === "" ? short : `${prefix}/${short}`);
    longName = null;
    if (fileTypes.has(type)) {
      files.set(name, body);
    }
  }
  return files;
}
