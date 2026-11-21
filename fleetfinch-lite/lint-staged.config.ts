import { defineConfig } from "lint-staged/config";

export default defineConfig({
  "*.ts": [
    () => "npm run typecheck",
    "eslint --max-warnings 0 --fix --no-warn-ignored",
    "prettier --write",
  ],
  "*.js": [
    "eslint --max-warnings 0 --fix --no-warn-ignored",
    "prettier --write",
  ],
  "*.css": ["stylelint", "prettier --write"],
  "!(*.ts|*.js|*.css)": "prettier --write --ignore-unknown",
});
