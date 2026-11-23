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

export function ThemeToggle({
  value,
  onChange,
}: {
  value: ThemePreference | null;
  onChange: (value: ThemePreference) => void;
}) {
  const name = useId();
  return (
    <div
      role="radiogroup"
      aria-label="Theme"
      className="flex overflow-hidden rounded-lg border border-border"
    >
      {options.map((option) => (
        <label
          key={option.value}
          title={option.label}
          className="flex size-10 cursor-pointer items-center justify-center
            text-muted not-first:border-l not-first:border-border
            not-has-checked:hover:text-foreground has-checked:bg-foreground
            has-checked:text-background has-focus-visible:outline-2
            has-focus-visible:-outline-offset-4
            has-focus-visible:outline-foreground
            has-checked:has-focus-visible:outline-background"
        >
          <input
            type="radio"
            name={name}
            value={option.value}
            aria-label={option.label}
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
            className="size-5"
          >
            {option.icon}
          </svg>
        </label>
      ))}
    </div>
  );
}
