import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { app, nativeTheme } from "electron";

import {
  isThemePreference,
  type ThemePreference,
} from "@fleetfinch/ui/theme-preference";

const themeSources = {
  auto: "system",
  light: "light",
  dark: "dark",
} as const satisfies Record<ThemePreference, typeof nativeTheme.themeSource>;

function themeFile(): string {
  return path.join(app.getPath("userData"), "theme.json");
}

export function getThemePreference(): ThemePreference {
  const source = nativeTheme.themeSource;
  return source === "system" ? "auto" : source;
}

export async function setThemePreference(theme: unknown): Promise<void> {
  if (!isThemePreference(theme)) {
    throw new Error("Refused an unknown theme");
  }
  nativeTheme.themeSource = themeSources[theme];
  await writeFile(themeFile(), JSON.stringify(theme));
}

export async function restoreThemePreference(): Promise<void> {
  const saved: unknown = await readFile(themeFile(), "utf8")
    .then((text): unknown => JSON.parse(text))
    .catch(() => null);
  nativeTheme.themeSource =
    themeSources[isThemePreference(saved) ? saved : "auto"];
}
