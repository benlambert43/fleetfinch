import type {
  DeviceApp,
  DeviceInventory,
  DevicePackage,
  DevicePackageState,
  DeviceService,
  DeviceVolume,
} from "@/deviceApps.ts";
import type { InstalledPackage } from "@/main/dependencies.ts";
import {
  parsePlist,
  parseStrings,
  type PlistValue,
  plistText,
} from "@/main/plist.ts";
import { readTar } from "@/main/tar.ts";

export const devicePath =
  "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
export const marker = "@@fleetfinch";

const recordEnd = `${marker} end`;
const archiveSection = "plists";
const listFolder = "/var/lib/dpkg/info";
const daemonFolder = "/Library/LaunchDaemons";
const infoFile = "Info.plist";
const stringsFolders = ["en.lproj", "English.lproj"];
const stringsFile = "InfoPlist.strings";
const hiddenTag = "hidden";
const virtualTag = "role::cydia";

const packageFields = [
  "Package",
  "Version",
  "Status",
  "Essential",
  "Priority",
  "Section",
  "Installed-Size",
  "Tag",
  "Name",
  "Author",
  "Maintainer",
  "Description",
] as const;

export const packageFormat = [
  packageFields.map((name) => `\${${name}}`).join(String.raw`\t`),
  String.raw`\n`,
  recordEnd,
  String.raw`\n`,
].join("");

const installedFields = ["Package", "Version", "Status", "Provides"];

export const installedFormat = [
  installedFields.map((name) => `\${${name}}`).join(String.raw`\t`),
  String.raw`\n`,
].join("");

const ownedPattern = String.raw`^/Applications/[^/]+\.app(/Info\.plist)?$|^/Library/LaunchDaemons/[^/]+\.plist$`;

const plistRoots = [
  "/Applications",
  "/var/containers/Bundle/Application",
  "/var/mobile/Containers/Bundle/Application",
  daemonFolder,
];

const plistTests = [
  `*.app/${infoFile}`,
  ...stringsFolders.map((folder) => `*.app/${folder}/${stringsFile}`),
  `${daemonFolder}/*.plist`,
];

export const inventoryCommand = [
  `export PATH=${devicePath}`,
  `echo '${marker} packages'`,
  `dpkg-query -W -f='${packageFormat}' 2>/dev/null`,
  `echo '${marker} files'`,
  `grep -H -E '${ownedPattern}' ${listFolder}/*.list 2>/dev/null`,
  `echo '${marker} volumes'`,
  "df -k / /private/var 2>/dev/null",
  `echo '${marker} services'`,
  "launchctl list 2>/dev/null",
  `echo '${marker} ${archiveSection}'`,
  `find ${plistRoots.join(" ")} -maxdepth 4 \\( ${plistTests
    .map((test) => `-path '${test}'`)
    .join(" -o ")} \\) -print0 2>/dev/null | tar -cf - --null -T - 2>/dev/null`,
].join("\n");

const basePriorities = new Set(["required", "important", "standard"]);
const configuredStates = new Set<string | undefined>([
  "installed",
  "triggers-pending",
]);
const connectionPackages = new Set(["openssh", "openssl", "dropbear"]);
const jailbreakWords = /untether|jailbreak/i;
const ownedLine = /^\/var\/lib\/dpkg\/info\/(.+?)\.list:(.+)$/;
const systemAppInfo = /^\/Applications\/([^/]+)\.app\/Info\.plist$/;
const userAppInfo =
  /^\/var\/(?:containers|mobile\/Containers)\/Bundle\/Application\/([^/]+\/([^/]+)\.app)\/Info\.plist$/;
const daemonPlist = /^\/Library\/LaunchDaemons\/([^/]+)\.plist$/;
const volumeLine = /^\S+\s+(\d+)\s+\d+\s+(\d+)\s+\S+\s+(\/.*)$/;
const serviceLine = /^(-|\d+)\s+\S+\s+(\S.*)$/;
const contact = /\s*<[^>]*>\s*$/;

export interface PackageRecord {
  id: string;
  name: string;
  version: string;
  section: string | null;
  summary: string | null;
  author: string | null;
  installedKb: number | null;
  state: DevicePackageState;
  virtual: boolean;
  locked: string | null;
}

export interface DeviceOutput {
  sections: Map<string, string>;
  files: Map<string, Buffer>;
}

function filled(text: string | undefined): string | null {
  const trimmed = (text ?? "").trim();
  return trimmed === "" ? null : trimmed;
}

function packageState(status: string): DevicePackageState | null {
  const state = status.trim().split(/\s+/).at(-1);
  if (state === "installed") {
    return "installed";
  }
  return state === undefined ||
    state === "" ||
    state === "not-installed" ||
    state === "config-files"
    ? null
    : "unfinished";
}

function lockReason(
  id: string,
  name: string,
  section: string | null,
  essential: boolean,
  priority: string,
): string | null {
  if (essential || basePriorities.has(priority)) {
    return "Part of the device's base system";
  }
  if (connectionPackages.has(id)) {
    return "FleetFinch reaches the device through it";
  }
  return jailbreakWords.test(`${id} ${name} ${section ?? ""}`)
    ? "Keeps the device jailbroken"
    : null;
}

function packageRecord(record: string): PackageRecord | null {
  const [
    id = "",
    version = "",
    status = "",
    essential,
    priority = "",
    section,
    size,
    tags = "",
    name,
    author,
    maintainer,
    ...description
  ] = record.split("\t");
  const state = packageState(status);
  if (id.trim() === "" || state === null) {
    return null;
  }
  const shownName = filled(name) ?? id;
  const shownSection = filled(section);
  const installedKb = Number.parseInt(size ?? "", 10);
  return {
    id,
    name: shownName,
    version,
    section: shownSection,
    summary: filled(description.join("\t").split("\n")[0]),
    author: filled((filled(author) ?? maintainer ?? "").replace(contact, "")),
    installedKb: Number.isNaN(installedKb) ? null : installedKb,
    state,
    virtual: tags.split(",").some((tag) => tag.trim() === virtualTag),
    locked: lockReason(
      id,
      shownName,
      shownSection,
      essential?.trim() === "yes",
      priority.trim(),
    ),
  };
}

export function parsePackages(text: string): PackageRecord[] {
  const records: PackageRecord[] = [];
  let lines: string[] = [];
  for (const line of text.split("\n")) {
    if (line !== recordEnd) {
      lines.push(line);
      continue;
    }
    const record = packageRecord(lines.join("\n"));
    if (record !== null) {
      records.push(record);
    }
    lines = [];
  }
  return records;
}

export function parseInstalled(text: string): InstalledPackage[] {
  return text.split("\n").flatMap((line) => {
    const [id = "", version = "", status = "", provides = ""] =
      line.split("\t");
    return id !== "" && configuredStates.has(status.trim().split(" ").at(-1))
      ? [{ id, version, provides }]
      : [];
  });
}

export function parseVolumes(text: string): DeviceVolume[] {
  const volumes = new Map<string, DeviceVolume>();
  for (const line of text.split("\n")) {
    const [, total, free, mount] = volumeLine.exec(line.trim()) ?? [];
    if (total !== undefined && free !== undefined && mount !== undefined) {
      volumes.set(mount, {
        mount,
        totalKb: Number(total),
        freeKb: Number(free),
      });
    }
  }
  return [...volumes.values()];
}

function parseOwners(text: string): Map<string, string[]> {
  const owners = new Map<string, string[]>();
  for (const line of text.split("\n")) {
    const [, list, file] = ownedLine.exec(line) ?? [];
    const [id] = (list ?? "").split(":");
    if (id === undefined || id === "" || file === undefined) {
      continue;
    }
    const known = owners.get(file);
    if (known === undefined) {
      owners.set(file, [id]);
    } else if (!known.includes(id)) {
      known.push(id);
    }
  }
  return owners;
}

function parseServices(text: string): Map<string, number | null> {
  const services = new Map<string, number | null>();
  for (const line of text.split("\n")) {
    const [, pid, label] = serviceLine.exec(line.trim()) ?? [];
    if (pid !== undefined && label !== undefined) {
      services.set(label, pid === "-" ? null : Number(pid));
    }
  }
  return services;
}

function dictionary(data: Buffer): Map<string, PlistValue> | null {
  const plist = parsePlist(data);
  return plist instanceof Map ? plist : null;
}

function localizedName(
  bundle: string,
  files: Map<string, Buffer>,
): string | null {
  for (const folder of stringsFolders) {
    const data = files.get(`${bundle}/${folder}/${stringsFile}`);
    if (data !== undefined) {
      const strings = parseStrings(data);
      return (
        filled(strings.get("CFBundleDisplayName")) ??
        filled(strings.get("CFBundleName"))
      );
    }
  }
  return null;
}

function isHidden(tags: PlistValue | undefined): boolean {
  return Array.isArray(tags) && tags.includes(hiddenTag);
}

function bundleOwner(
  bundle: string,
  owners: Map<string, string[]>,
): string | null {
  const [owner] =
    owners.get(`${bundle}/${infoFile}`) ?? owners.get(bundle) ?? [];
  return owner ?? null;
}

function parseApps(
  files: Map<string, Buffer>,
  owners: Map<string, string[]>,
): DeviceApp[] {
  const apps = new Map<string, DeviceApp>();
  for (const [file, data] of files) {
    const system = systemAppInfo.exec(file);
    const user = system === null ? userAppInfo.exec(file) : null;
    const folder = system?.[1] ?? user?.[2];
    const info = folder === undefined ? null : dictionary(data);
    if (folder === undefined || info === null) {
      continue;
    }
    const bundle = file.slice(0, -(infoFile.length + 1));
    const owner = system === null ? null : bundleOwner(bundle, owners);
    const build = plistText(info.get("CFBundleVersion"));
    const key = user?.[1] ?? bundle;
    if (apps.has(key)) {
      continue;
    }
    apps.set(key, {
      path: bundle,
      identifier: plistText(info.get("CFBundleIdentifier")),
      name:
        localizedName(bundle, files) ??
        plistText(info.get("CFBundleDisplayName")) ??
        plistText(info.get("CFBundleName")) ??
        folder,
      version: plistText(info.get("CFBundleShortVersionString")) ?? build,
      build,
      source: user !== null ? "user" : owner === null ? "system" : "package",
      packageId: owner,
      hidden: isHidden(info.get("SBAppTags")),
    });
  }
  return [...apps.values()];
}

function serviceLabel(file: string, files: Map<string, Buffer>): string {
  const data = files.get(file);
  const label =
    data === undefined ? null : plistText(dictionary(data)?.get("Label"));
  return label ?? daemonPlist.exec(file)?.[1] ?? file;
}

function byName<Item extends { name: string }>(items: Item[]): Item[] {
  return items.toSorted((first, second) =>
    first.name.localeCompare(second.name, undefined, { sensitivity: "base" }),
  );
}

export function splitOutput(
  data: Buffer,
  names: readonly string[],
): DeviceOutput {
  const header = Buffer.from(`${marker} ${archiveSection}\n`);
  let start = data.indexOf(header);
  while (start > 0 && data[start - 1] !== 0x0a) {
    start = data.indexOf(header, start + 1);
  }
  const text = (start === -1 ? data : data.subarray(0, start)).toString("utf8");
  const archive =
    start === -1 ? Buffer.alloc(0) : data.subarray(start + header.length);
  const known = new Map(names.map((name) => [`${marker} ${name}`, name]));
  const sections = new Map<string, string>();
  let current: string | null = null;
  let lines: string[] = [];
  const close = () => {
    if (current !== null) {
      sections.set(current, lines.join("\n"));
    }
    lines = [];
  };
  for (const line of text.split("\n")) {
    const name = known.get(line);
    if (name === undefined) {
      lines.push(line);
    } else {
      close();
      current = name;
    }
  }
  close();
  const files = new Map<string, Buffer>();
  for (const [name, body] of readTar(archive)) {
    files.set(`/${name.replace(/^(?:\.?\/)+/, "")}`, body);
  }
  return { sections, files };
}

export function parseInventory(
  data: Buffer,
  readAt: number,
): DeviceInventory | null {
  const { sections, files } = splitOutput(data, [
    "packages",
    "files",
    "volumes",
    "services",
  ]);
  const listed = sections.get("packages");
  if (listed === undefined || !sections.has("services")) {
    return null;
  }
  const owners = parseOwners(sections.get("files") ?? "");
  const running = parseServices(sections.get("services") ?? "");
  const apps = byName(parseApps(files, owners));
  const packages = parsePackages(listed)
    .filter((record) => !record.virtual)
    .map(({ virtual: _virtual, ...record }): DevicePackage => {
      const services = [...owners]
        .filter(
          ([file, ids]) => daemonPlist.test(file) && ids.includes(record.id),
        )
        .map(([file]): DeviceService => {
          const label = serviceLabel(file, files);
          return {
            label,
            file,
            loaded: running.has(label),
            pid: running.get(label) ?? null,
          };
        });
      return {
        ...record,
        apps: apps
          .filter((app) => app.packageId === record.id)
          .map((app) => app.path),
        services,
      };
    });
  return {
    apps,
    packages: byName(packages),
    volumes: parseVolumes(sections.get("volumes") ?? ""),
    readAt,
  };
}
