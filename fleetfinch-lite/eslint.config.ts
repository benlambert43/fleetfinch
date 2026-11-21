import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import compat from "eslint-plugin-compat";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig([
  js.configs.recommended,
  {
    files: ["**/*.ts"],
    extends: [
      tseslint.configs.strictTypeChecked,
      tseslint.configs.stylisticTypeChecked,
    ],
    languageOptions: {
      globals: globals.node,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/no-deprecated": "error",
    },
  },
  {
    files: ["public/**/*.js"],
    extends: [compat.configs["flat/recommended"]],
    languageOptions: {
      ecmaVersion: 5,
      sourceType: "script",
      globals: { ...globals.es2015, ...globals.browser },
    },
  },
]);
