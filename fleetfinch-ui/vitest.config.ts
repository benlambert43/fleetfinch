import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  test: {
    name: { label: "fleetfinch-ui", color: "yellow" },
    environment: "jsdom",
    setupFiles: ["./vitest.setup.ts"],
  },
});
