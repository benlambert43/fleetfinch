"use client";

import { type ReactNode, useId } from "react";

import type { ThemePreference } from "./themePreference.ts";

const options: { value: ThemePreference; label: string; icon: ReactNode }[] = [
  {
    value: "auto",
    label: "Auto",
    icon: (
      <>
        <circle cx="12" cy="12" r="8" />
        <path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" />
      </>
    ),
  },
  {
    value: "light",
    label: "Light",
    icon: (
      <>
        <circle cx="12" cy="12" r="4" />
        <path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.64 5.64l1.77 1.77M16.6 16.6l1.77 1.77M5.64 18.36l1.77-1.77M16.6 7.4l1.77-1.77" />
      </>
    ),
  },
  {
    value: "dark",
    label: "Dark",
    icon: <path d="M19.9 13.2A8 8 0 1 1 10.8 4.1a6.5 6.5 0 0 0 9.1 9.1Z" />,
  },
];

const styles = {
  icons: {
    group: "flex overflow-hidden rounded-lg border border-border",
    option:
      "flex size-11 items-center justify-center not-first:border-l not-first:border-border",
    icon: "size-5",
  },
  labels: {
    group: "flex overflow-hidden rounded-lg border-2 border-foreground",
    option:
      "flex h-9 items-center gap-1.5 px-3 text-footnote not-first:border-l-2 not-first:border-foreground",
    icon: "size-4.5",
  },
};

export function ThemeToggle({
  value,
  onChange,
  showLabels = false,
}: {
  value: ThemePreference | null;
  onChange: (value: ThemePreference) => void;
  showLabels?: boolean;
}) {
  const name = useId();
  const style = showLabels ? styles.labels : styles.icons;
  return (
    <div role="radiogroup" aria-label="Theme" className={style.group}>
      {options.map((option) => (
        <label
          key={option.value}
          title={showLabels ? undefined : option.label}
          className={`cursor-pointer text-muted
          not-has-checked:hover:bg-foreground/5
          not-has-checked:hover:text-foreground has-checked:bg-foreground
          has-checked:text-background has-focus-visible:outline-2
          has-focus-visible:-outline-offset-4
          has-focus-visible:outline-foreground
          has-checked:has-focus-visible:outline-background ${style.option}`}
        >
          <input
            type="radio"
            name={name}
            value={option.value}
            aria-label={showLabels ? undefined : option.label}
            checked={value === option.value}
            onChange={() => {
              onChange(option.value);
            }}
            className="sr-only"
          />
          <svg
            viewBox="0 0 24 24"
            aria-hidden="true"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className={style.icon}
          >
            {option.icon}
          </svg>
          {showLabels && option.label}
        </label>
      ))}
    </div>
  );
}
