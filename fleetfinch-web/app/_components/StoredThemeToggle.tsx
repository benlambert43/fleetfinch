"use client";

import {
  isThemePreference,
  type ThemePreference,
  ThemeToggle,
} from "@fleetfinch/ui";
import { useLayoutEffect, useSyncExternalStore } from "react";

import { themeStorageKey } from "@/app/_lib/theme.ts";

const listeners = new Set<() => void>();
let preference: ThemePreference | undefined;

function readStoredPreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(themeStorageKey);
    return isThemePreference(stored) ? stored : "auto";
  } catch (error) {
    console.warn("Could not read the saved theme", error);
    return "auto";
  }
}

function subscribe(listener: () => void): () => void {
  function onStorage(event: StorageEvent) {
    if (event.key === themeStorageKey) {
      preference = undefined;
      listener();
    }
  }
  listeners.add(listener);
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", onStorage);
  };
}

function getSnapshot(): ThemePreference {
  preference ??= readStoredPreference();
  return preference;
}

function getServerSnapshot(): null {
  return null;
}

function choose(next: ThemePreference): void {
  preference = next;
  try {
    localStorage.setItem(themeStorageKey, next);
  } catch (error) {
    console.warn("Could not save the theme", error);
  }
  for (const listener of listeners) {
    listener();
  }
}

export function StoredThemeToggle() {
  const value = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);

  useLayoutEffect(() => {
    if (value === "light" || value === "dark") {
      document.documentElement.dataset.theme = value;
    } else if (value === "auto") {
      delete document.documentElement.dataset.theme;
    }
  }, [value]);

  return <ThemeToggle value={value} onChange={choose} />;
}
