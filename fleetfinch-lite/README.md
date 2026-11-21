# FleetFinch Lite

The web app's home page written for Safari 9, the browser on iOS 9: Safari 9.0 up to iOS 9.2, and Safari 9.1 on iOS 9.3 through 9.3.6. It is plain HTML, CSS, and JavaScript with no build step, so `public` is the site, and any static file server can host it.

```sh
python3 -m http.server 8000 --directory fleetfinch-lite/public   # from the repository root; reachable from an iOS 9 device on the same network
```

## Files

| File                    | What it holds                                                                                                                    |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `public/index.html`     | The page, with the same title and description as the web app                                                                     |
| `public/styles.css`     | The styles, in the system font, which is San Francisco on iOS 9                                                                  |
| `public/script.js`      | Replaces the `no-js` class on `<html>` with `js`, so CSS can tell whether the script has run                                     |
| `package.json`          | `browserslist`, set to `iOS >= 9`, which the checks below read; the `lint` and `typecheck` scripts; the checks' own dependencies |
| `eslint.config.ts`      | ES5 syntax and the browser-API check for `public/**/*.js`, and the repository's type-aware rules for the config files            |
| `prettier.config.ts`    | `trailingComma: "es5"`                                                                                                           |
| `stylelint.config.ts`   | The CSS feature check                                                                                                            |
| `lint-staged.config.ts` | What the pre-commit hook runs on files staged here                                                                               |
| `tsconfig.json`         | Type-checks the config files                                                                                                     |

## Checks

ESLint, Prettier, Stylelint, and lint-staged each use the config closest to a file and do not merge it with the one at the root, so the configs here replace the repository's for this folder. The root commands, and with them preflight, CI, and the pre-commit hook, pick them up:

| From the root       | What it does here                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------- |
| `npm run lint`      | Runs this folder's `lint` script, Stylelint over `public/**/*.css`, then ESLint with `eslint.config.ts` |
| `npm run format`    | Formats with `prettier.config.ts`                                                                       |
| `npm run typecheck` | Type-checks the config files through this folder's `typecheck` script                                   |

```sh
npm run lint --workspace fleetfinch-lite   # Stylelint alone
npx eslint fleetfinch-lite                 # ESLint alone
```

## Safari 9

- **Safari 9.0 is the floor.** Use only what Safari 9.0 supports, so the site works on every iOS 9 release, and check anything new on [Can I use](https://caniuse.com) against Safari on iOS 9.0–9.2 first.
- **JavaScript syntax is ES5.** ESLint parses `public/**/*.js` as ES5 browser scripts, so `let`, `const`, arrow functions, classes, template literals, modules, and a trailing comma after a call's last argument all fail the lint. Safari 9 understands some ES2015 syntax, but not enough to be a safe line. Wrap each file in a function that starts with `"use strict"`, and load it with a plain `<script>` tag.
- **Prettier's `trailingComma` is `es5` here.** The repository's default puts a comma after a call's last argument when it wraps one, and Safari 9 then refuses to run the whole file.
- **Browser APIs are checked against Safari 9.** `eslint-plugin-compat` fails the lint on globals, constructors, and static methods that Safari 9 lacks, such as `fetch`, `URLSearchParams`, `IntersectionObserver`, `Object.values`, `Proxy`, and `Intl`, and lets through the ES2015 ones it has, such as `Promise`, `Map`, `Set`, and `Symbol`. Globals newer than ES2015, such as `globalThis`, are undefined to ESLint.
- **The API check has gaps.** It cannot tell what kind of object a method is called on, so it misses methods such as `NodeList.prototype.forEach`, `Element.prototype.append`, and `Promise.prototype.finally`, and its data leaves out a few globals, such as `requestIdleCallback` and `customElements`. Use `XMLHttpRequest` for requests. Pass `addEventListener` a boolean as its third argument, because Safari 9 reads an options object such as `{ passive: true }` as `true`, which means capture.
- **CSS is checked by Stylelint.** `stylelint-no-unsupported-browser-features` looks up every property, value, selector, and media query in the Can I use data, and fails on grid, `gap` in flexbox, custom properties, `object-fit`, `min()`, `:focus-visible`, `prefers-color-scheme`, and the like. It counts a feature that works with a prefix as supported, so write `position: -webkit-sticky` and `-webkit-text-size-adjust` yourself. Flexbox needs no prefix.
