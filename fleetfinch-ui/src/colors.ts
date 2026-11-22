export const palette = {
  sandLight: "#f0e2d6",
  sandMid: "#d4bba6",
  sandDeep: "#765e49",
  sandDark: "#5a422c",
  blueLight: "#c6edf6",
  blueMid: "#47cfea",
  blueDeep: "#4e97a7",
  blueDark: "#434c6b",
  orangeLight: "#ffdbbd",
  orangeMid: "#fa880d",
  orangeDark: "#5b2700",
} as const;

export const lightColors = {
  background: palette.sandLight,
  foreground: palette.sandDark,
  muted: palette.sandDeep,
  border: palette.sandMid,
  primary: palette.blueMid,
  primaryForeground: palette.blueDark,
  primarySoft: palette.blueLight,
  primarySoftForeground: palette.blueDark,
  primaryBorder: palette.blueDeep,
  accent: palette.orangeMid,
  accentForeground: palette.orangeDark,
  accentSoft: palette.orangeLight,
  accentSoftForeground: palette.orangeDark,
  accentBorder: palette.orangeMid,
} as const;

export const darkColors = {
  ...lightColors,
  background: palette.sandDark,
  foreground: palette.sandLight,
  muted: palette.sandMid,
  primarySoft: palette.blueDark,
  primarySoftForeground: palette.blueLight,
  primaryBorder: palette.blueMid,
  accentSoft: palette.orangeDark,
  accentSoftForeground: palette.orangeLight,
} as const;
