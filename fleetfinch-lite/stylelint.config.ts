import type { Config } from "stylelint";

const config: Config = {
  plugins: ["stylelint-no-unsupported-browser-features"],
  rules: {
    "plugin/no-unsupported-browser-features": true,
  },
};

export default config;
