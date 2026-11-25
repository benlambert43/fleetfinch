export interface InstalledPackage {
  id: string;
  version: string;
  provides: string;
}

interface Requirement {
  name: string;
  relation: string | null;
  version: string | null;
}

const digit = /^\d$/;
const letter = /^[A-Za-z]$/;
const requirement =
  /^([^\s(:]+)(?::[^\s(]+)?\s*(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^\s)]+)\s*\))?/;
const versionParts = /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/;

const relations: Record<string, (order: number) => boolean> = {
  "<<": (order) => order < 0,
  "<=": (order) => order <= 0,
  "<": (order) => order <= 0,
  "=": (order) => order === 0,
  ">=": (order) => order >= 0,
  ">": (order) => order >= 0,
  ">>": (order) => order > 0,
};

function isDigit(character: string | undefined): boolean {
  return character !== undefined && digit.test(character);
}

function weight(character: string | undefined): number {
  if (character === undefined || isDigit(character)) {
    return 0;
  }
  if (character === "~") {
    return -1;
  }
  const code = character.charCodeAt(0);
  return letter.test(character) ? code : code + 256;
}

function comparePart(first: string, second: string): number {
  let left = 0;
  let right = 0;
  while (left < first.length || right < second.length) {
    while (
      (left < first.length && !isDigit(first[left])) ||
      (right < second.length && !isDigit(second[right]))
    ) {
      const difference = weight(first[left]) - weight(second[right]);
      if (difference !== 0) {
        return difference;
      }
      left += 1;
      right += 1;
    }
    while (first[left] === "0") {
      left += 1;
    }
    while (second[right] === "0") {
      right += 1;
    }
    let difference = 0;
    while (isDigit(first[left]) && isDigit(second[right])) {
      if (difference === 0) {
        difference = first.charCodeAt(left) - second.charCodeAt(right);
      }
      left += 1;
      right += 1;
    }
    if (isDigit(first[left])) {
      return 1;
    }
    if (isDigit(second[right])) {
      return -1;
    }
    if (difference !== 0) {
      return difference;
    }
  }
  return 0;
}

function parts(version: string): [number, string, string] {
  const [, epoch = "0", upstream = "", revision = ""] =
    versionParts.exec(version.trim()) ?? [];
  return [Number(epoch), upstream, revision];
}

export function compareVersions(first: string, second: string): number {
  const [firstEpoch, firstUpstream, firstRevision] = parts(first);
  const [secondEpoch, secondUpstream, secondRevision] = parts(second);
  if (firstEpoch !== secondEpoch) {
    return firstEpoch - secondEpoch;
  }
  return (
    comparePart(firstUpstream, secondUpstream) ||
    comparePart(firstRevision, secondRevision)
  );
}

function parseRequirement(text: string): Requirement | null {
  const [, name, relation, version] = requirement.exec(text.trim()) ?? [];
  return name === undefined
    ? null
    : { name, relation: relation ?? null, version: version ?? null };
}

function holds(
  { relation, version }: Requirement,
  installed: string | null,
): boolean {
  if (relation === null || version === null) {
    return true;
  }
  return (
    installed !== null &&
    relations[relation]?.(compareVersions(installed, version)) === true
  );
}

function satisfied(
  wanted: Requirement,
  installed: readonly InstalledPackage[],
): boolean {
  return installed.some(
    ({ id, version, provides }) =>
      (id === wanted.name && holds(wanted, version)) ||
      provides.split(",").some((entry) => {
        const provided = parseRequirement(entry);
        return (
          provided?.name === wanted.name && holds(wanted, provided.version)
        );
      }),
  );
}

export function unmetDependencies(
  depends: readonly string[],
  installed: readonly InstalledPackage[],
): string[] {
  return depends
    .flatMap((field) => field.split(","))
    .map((clause) => clause.trim())
    .filter(
      (clause) =>
        clause !== "" &&
        !clause.split("|").some((alternative) => {
          const wanted = parseRequirement(alternative);
          return wanted !== null && satisfied(wanted, installed);
        }),
    );
}
