export type PlistValue =
  | string
  | number
  | boolean
  | Date
  | Buffer
  | null
  | PlistValue[]
  | Map<string, PlistValue>;

const binaryMagic = "bplist00";
const trailerSize = 32;
const appleEpochMs = Date.UTC(2001, 0, 1);
const depthLimit = 64;
const nodeLimit = 200_000;
const highestCodePoint = 0x10ffff;

const xmlToken =
  /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[([\s\S]*?)\]\]>|<![^>]*>|<(\/?)([A-Za-z]+)[^>]*?(\/?)>|([^<]+)/g;
const xmlEntity = /&(#x[\dA-Fa-f]+|#\d+|[A-Za-z]+);/g;
const stringsEntry =
  /(?:"((?:[^"\\]|\\[\s\S])*)"|([\w.-]+))\s*=\s*"((?:[^"\\]|\\[\s\S])*)"\s*;/g;
const stringsEscape = /\\([\s\S])/g;

const entities: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
};

const escapes: Record<string, string> = { n: "\n", t: "\t", r: "\r" };

class Malformed extends Error {}

function parseBinary(data: Buffer): PlistValue {
  if (data.length < binaryMagic.length + trailerSize) {
    throw new Malformed();
  }
  const trailer = data.length - trailerSize;
  const offsetSize = data.readUInt8(trailer + 6);
  const refSize = data.readUInt8(trailer + 7);
  const count = Number(data.readBigUInt64BE(trailer + 8));
  const top = Number(data.readBigUInt64BE(trailer + 16));
  const table = Number(data.readBigUInt64BE(trailer + 24));
  let nodes = 0;

  const span = (offset: number, length: number): Buffer => {
    if (offset < 0 || length < 0 || offset + length > data.length) {
      throw new Malformed();
    }
    return data.subarray(offset, offset + length);
  };

  const uint = (offset: number, size: number): number => {
    if (size < 1 || size > 8) {
      throw new Malformed();
    }
    let value = 0;
    for (const byte of span(offset, size)) {
      value = value * 256 + byte;
    }
    return value;
  };

  const sized = (offset: number, info: number): [number, number] => {
    if (info !== 0x0f) {
      return [info, offset + 1];
    }
    const marker = uint(offset + 1, 1);
    if (marker >> 4 !== 0x1) {
      throw new Malformed();
    }
    const size = 1 << (marker & 0x0f);
    return [uint(offset + 2, size), offset + 2 + size];
  };

  const refs = (start: number, length: number): number[] =>
    Array.from({ length }, (_, index) =>
      uint(start + index * refSize, refSize),
    );

  const read = (ref: number, depth: number): PlistValue => {
    nodes += 1;
    if (depth > depthLimit || nodes > nodeLimit || ref >= count) {
      throw new Malformed();
    }
    const offset = uint(table + ref * offsetSize, offsetSize);
    const marker = uint(offset, 1);
    const info = marker & 0x0f;
    switch (marker >> 4) {
      case 0x0:
        if (info === 0x08) {
          return false;
        }
        return info === 0x09 ? true : null;
      case 0x1: {
        const size = 1 << info;
        if (size === 8) {
          return Number(span(offset + 1, size).readBigInt64BE());
        }
        if (size === 16) {
          return Number(span(offset + 1, size).readBigInt64BE(8));
        }
        return uint(offset + 1, size);
      }
      case 0x2:
        if (info === 2) {
          return span(offset + 1, 4).readFloatBE();
        }
        if (info === 3) {
          return span(offset + 1, 8).readDoubleBE();
        }
        throw new Malformed();
      case 0x3:
        return new Date(
          appleEpochMs + span(offset + 1, 8).readDoubleBE() * 1000,
        );
      case 0x4: {
        const [length, start] = sized(offset, info);
        return Buffer.from(span(start, length));
      }
      case 0x5: {
        const [length, start] = sized(offset, info);
        return span(start, length).toString("latin1");
      }
      case 0x6: {
        const [length, start] = sized(offset, info);
        return Buffer.from(span(start, length * 2))
          .swap16()
          .toString("utf16le");
      }
      case 0x7: {
        const [length, start] = sized(offset, info);
        return span(start, length).toString("utf8");
      }
      case 0x8:
        return uint(offset + 1, info + 1);
      case 0xa:
      case 0xc: {
        const [length, start] = sized(offset, info);
        return refs(start, length).map((item) => read(item, depth + 1));
      }
      case 0xd: {
        const [length, start] = sized(offset, info);
        const keys = refs(start, length);
        const values = refs(start + length * refSize, length);
        const entries = new Map<string, PlistValue>();
        keys.forEach((keyRef, index) => {
          const key = read(keyRef, depth + 1);
          const valueRef = values[index];
          if (typeof key !== "string" || valueRef === undefined) {
            throw new Malformed();
          }
          entries.set(key, read(valueRef, depth + 1));
        });
        return entries;
      }
      default:
        throw new Malformed();
    }
  };

  return read(top, 0);
}

function decodeEntities(text: string): string {
  return text.replace(xmlEntity, (whole, name: string) => {
    if (!name.startsWith("#")) {
      return entities[name] ?? whole;
    }
    const code = name.startsWith("#x")
      ? Number.parseInt(name.slice(2), 16)
      : Number.parseInt(name.slice(1), 10);
    return code <= highestCodePoint ? String.fromCodePoint(code) : whole;
  });
}

interface XmlToken {
  tag: string | null;
  close: boolean;
  empty: boolean;
  text: string;
}

function xmlTokens(source: string): XmlToken[] {
  const tokens: XmlToken[] = [];
  for (const match of source.matchAll(xmlToken)) {
    const [, cdata, slash, tag, selfClosing, text] = match;
    if (cdata !== undefined) {
      tokens.push({ tag: null, close: false, empty: false, text: cdata });
    } else if (tag !== undefined) {
      tokens.push({
        tag,
        close: slash === "/",
        empty: selfClosing === "/",
        text: "",
      });
    } else if (text !== undefined) {
      tokens.push({
        tag: null,
        close: false,
        empty: false,
        text: decodeEntities(text),
      });
    }
  }
  return tokens;
}

function parseXml(source: string): PlistValue {
  const tokens = xmlTokens(source);
  let position = 0;

  const take = (): XmlToken => {
    const token = tokens[position];
    position += 1;
    if (token === undefined) {
      throw new Malformed();
    }
    return token;
  };

  const next = (): XmlToken => {
    for (;;) {
      const token = take();
      if (token.tag !== null || token.text.trim() !== "") {
        return token;
      }
    }
  };

  const content = ({ tag, empty }: XmlToken): string => {
    let text = "";
    if (empty) {
      return text;
    }
    for (;;) {
      const token = take();
      if (token.tag === null) {
        text += token.text;
      } else if (token.close && token.tag === tag) {
        return text;
      } else {
        throw new Malformed();
      }
    }
  };

  const number = (token: XmlToken): number => {
    const value = Number(content(token).trim());
    if (Number.isNaN(value)) {
      throw new Malformed();
    }
    return value;
  };

  const value = (token: XmlToken, depth: number): PlistValue => {
    if (token.tag === null || token.close || depth > depthLimit) {
      throw new Malformed();
    }
    switch (token.tag) {
      case "dict": {
        const entries = new Map<string, PlistValue>();
        if (token.empty) {
          return entries;
        }
        for (;;) {
          const key = next();
          if (key.close && key.tag === "dict") {
            return entries;
          }
          if (key.close || key.tag !== "key") {
            throw new Malformed();
          }
          entries.set(content(key), value(next(), depth + 1));
        }
      }
      case "array": {
        const items: PlistValue[] = [];
        if (token.empty) {
          return items;
        }
        for (;;) {
          const item = next();
          if (item.close && item.tag === "array") {
            return items;
          }
          items.push(value(item, depth + 1));
        }
      }
      case "string":
        return content(token);
      case "integer":
      case "real":
        return number(token);
      case "true":
        content(token);
        return true;
      case "false":
        content(token);
        return false;
      case "date":
        return new Date(content(token).trim());
      case "data":
        return Buffer.from(content(token).replace(/\s+/g, ""), "base64");
      default:
        throw new Malformed();
    }
  };

  const first = next();
  if (first.tag !== "plist") {
    return value(first, 0);
  }
  if (first.close || first.empty) {
    throw new Malformed();
  }
  return value(next(), 0);
}

function decodeText(data: Buffer): string {
  if (data.length >= 2 && data[0] === 0xff && data[1] === 0xfe) {
    return data.subarray(2).toString("utf16le");
  }
  if (data.length >= 2 && data[0] === 0xfe && data[1] === 0xff) {
    const body = Buffer.from(data.subarray(2, data.length - (data.length % 2)));
    return body.swap16().toString("utf16le");
  }
  const text = data.toString("utf8");
  return text.startsWith("﻿") ? text.slice(1) : text;
}

export function parsePlist(data: Buffer): PlistValue | undefined {
  try {
    if (
      data.subarray(0, binaryMagic.length).toString("latin1") === binaryMagic
    ) {
      return parseBinary(data);
    }
    const text = decodeText(data);
    return text.trimStart().startsWith("<") ? parseXml(text) : undefined;
  } catch (error) {
    if (error instanceof Malformed || error instanceof RangeError) {
      return undefined;
    }
    throw error;
  }
}

function unescape(text: string): string {
  return text.replace(
    stringsEscape,
    (_whole, character: string) => escapes[character] ?? character,
  );
}

export function parseStrings(data: Buffer): Map<string, string> {
  const strings = new Map<string, string>();
  const plist = parsePlist(data);
  if (plist instanceof Map) {
    for (const [key, value] of plist) {
      if (typeof value === "string") {
        strings.set(key, value);
      }
    }
    return strings;
  }
  for (const match of decodeText(data).matchAll(stringsEntry)) {
    const [, quoted, bare, value] = match;
    const key = quoted === undefined ? bare : unescape(quoted);
    if (key !== undefined && value !== undefined) {
      strings.set(key, unescape(value));
    }
  }
  return strings;
}

export function plistText(value: PlistValue | undefined): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const text = value.trim();
  return text === "" ? null : text;
}
