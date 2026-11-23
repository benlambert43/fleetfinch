import { type ThemePreference, ThemeToggle } from "@fleetfinch/ui";
import { use, useState } from "react";

const savedTheme = window.bridge.getTheme();

export function NativeThemeToggle() {
  const [theme, setTheme] = useState(use(savedTheme));

  function choose(next: ThemePreference) {
    setTheme(next);
    void window.bridge.setTheme(next);
  }

  return <ThemeToggle value={theme} onChange={choose} />;
}
