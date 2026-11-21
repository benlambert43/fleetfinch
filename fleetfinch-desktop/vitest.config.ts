import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  resolve: { tsconfigPaths: true },
  test: {
    name: { label: "fleetfinch-desktop", color: "cyan" },
    environment: "jsdom",
    setupFiles: ["./vitest.setup.ts"],
  },
});
