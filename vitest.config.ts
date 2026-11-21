import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      "fleetfinch-shared",
      "fleetfinch-ui",
      "fleetfinch-server",
      "fleetfinch-web",
      "fleetfinch-desktop",
    ],
    coverage: {
      reporter: ["text", "html"],
      include: [
        "fleetfinch-shared/src/**",
        "fleetfinch-ui/src/**",
        "fleetfinch-server/src/**",
        "fleetfinch-web/app/**",
        "fleetfinch-desktop/src/**",
      ],
    },
  },
});
