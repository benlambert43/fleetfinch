# FleetFinch

A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices

| Workspace            | What it is                                                                       |
| -------------------- | -------------------------------------------------------------------------------- |
| `fleetfinch-web`     | Next.js web app: the lite site's page, with modern browser features              |
| `fleetfinch-server`  | Express API on Node.js, with Drizzle ORM and PostgreSQL                          |
| `fleetfinch-shared`  | Zod schemas, types, and the API client, imported as `@fleetfinch/shared`         |
| `fleetfinch-ui`      | React components and the Tailwind theme, imported as `@fleetfinch/ui`            |
| `fleetfinch-desktop` | FleetFinch Developer, the Electron desktop app, built from the shared components |
| `fleetfinch-lite`    | Plain HTML, CSS, and JS site for Safari 9, with its own lint configs             |
| `fleetfinch-logs`    | Finch Logs: an iOS 9 logging service and app for the device, built with Theos    |

## Getting started

Requires Node.js 26 (see `.nvmrc`), Docker, and [ShellCheck](https://www.shellcheck.net/) (`brew install shellcheck`).

```sh
npm install          # installs every workspace and the Husky pre-commit hook
npm run db:start     # starts PostgreSQL, waits for it, and applies the migrations
npm run dev          # web app on http://localhost:3000
npm run dev:server   # API on http://localhost:4000, in a second terminal
```

### Environment

A `.env` beside each `.env.template` was written with local defaults when the project was generated. On a fresh clone, copy each template and fill in `<username>`, `<password>`, and `<database_name>`:

```sh
for file in .env.template */.env.template; do cp "$file" "${file%.template}"; done
```

| File                      | Variables                                                                                                                                             |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.env`                    | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, and `POSTGRES_PORT`, the port PostgreSQL listens on from your machine. Docker Compose reads them |
| `fleetfinch-server/.env`  | The same four, which must match the root file, and `POSTGRES_HOST`, `API_PORT`, and `BASE_FRONTEND_URL`, the web app's address                        |
| `fleetfinch-web/.env`     | `API_BASE_URL`, where the web app finds the API, and `SITE_URL`, the web app's public address                                                         |
| `fleetfinch-desktop/.env` | `VITE_API_BASE_URL`, where the desktop app finds the API                                                                                              |

Git ignores every `.env*` file except the templates.

## Commands

Run everything from the repository root.

### Develop and build

| Command                 | What it does                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------ |
| `npm run dev`           | Starts the Next.js dev server                                                              |
| `npm run dev:server`    | Starts the API with `node --watch`, restarting on changes to the server or shared sources  |
| `npm run dev:desktop`   | Starts the desktop app in `fleetfinch-desktop` with a hot-reloading window                 |
| `npm run start:lite`    | Serves the lite site from `fleetfinch-lite/public` on http://localhost:8000                |
| `npm run build`         | Builds the web app                                                                         |
| `npm run build:desktop` | Packages the desktop app for this machine into `fleetfinch-desktop/out`                    |
| `npm run make:desktop`  | Packages the desktop app and zips it into `fleetfinch-desktop/out/make`, ready to hand out |
| `npm run build:logs`    | Builds the Finch Logs package for iOS 9 into `fleetfinch-logs/packages`, using Theos       |

Nothing is compiled during development. Node.js runs the server's TypeScript directly, and shared code is imported straight from its sources. Between the API and the web app, only the web app has a build step.

```sh
npm run dev --workspace fleetfinch-web -- --port 3001   # dev server on another port
npm run start --workspace fleetfinch-web                # serves the output of npm run build
npm run start --workspace fleetfinch-server             # API without --watch
```

Scripts such as `dev`, `build`, and `db:generate` hand over to a workspace's script of the same name. To give the tool behind one an argument, call the workspace's script as above: `npm run <script> --workspace <workspace> -- <arguments>`. Scripts that run a tool themselves, such as `lint` and `test`, take arguments straight after `--`.

### Database

| Command               | What it does                                                                                                          |
| --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `npm run db:start`    | Starts PostgreSQL in Docker, waits until it is healthy, and applies pending migrations                                |
| `npm run db:stop`     | Stops PostgreSQL and keeps its data                                                                                   |
| `npm run db:generate` | Generates a SQL migration in `fleetfinch-server/drizzle` from the Drizzle schema in `fleetfinch-server/src/schema.ts` |
| `npm run db:migrate`  | Applies pending migrations to a running database; `db:start` runs it for you                                          |
| `npm run db:studio`   | Opens Drizzle Studio to browse the database                                                                           |

To change the schema, edit `schema.ts`, then run `db:generate` and `db:migrate`.

```sh
npm run db:generate --workspace fleetfinch-server -- --name add_tags              # names the migration file
npm run db:generate --workspace fleetfinch-server -- --custom --name seed_data    # empty migration for SQL of your own
npm run db:studio --workspace fleetfinch-server -- --port 5000                    # Drizzle Studio on another port
```

### Checks

| Command               | What it does                                                                                                                                               |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run preflight`   | Everything CI runs: format check, typecheck, lint, ShellCheck, the editor-settings check, tests, and the build. `preflight:no-build` skips the build       |
| `npm run format`      | Formats the whole repository with Prettier; `format:check` only reports                                                                                    |
| `npm run lint`        | Runs ESLint over the whole repository, including the React, accessibility, and Tailwind class rules and the deprecated-API check; `lint:fix` applies fixes |
| `npm run lint:shell`  | Runs ShellCheck over the shell scripts and the pre-commit hook                                                                                             |
| `npm run lint:editor` | Fails on `.vscode/settings.json` keys that the installed VS Code or its extensions mark as deprecated; skipped where VS Code is absent, as in CI           |
| `npm run typecheck`   | Type-checks the root config files and scripts, then every workspace; the web one generates the Next.js route types first                                   |

```sh
npm run preflight:no-build                         # every check, without the build
npm run lint -- fleetfinch-web                       # one folder
npm run lint:fix -- fleetfinch-web/app/page.tsx      # one file
npx prettier --write README.md                     # formats one file
npm run typecheck --workspace fleetfinch-server      # one workspace
```

The pre-commit hook runs lint-staged on the staged files: every workspace is type-checked, ESLint and Prettier fix what they can, the tests that cover the staged files run, and staged shell scripts go through ShellCheck. CI runs the same checks as `npm run preflight`, split into parallel jobs. `npm run lint` first runs any workspace's own `lint` script, which in `fleetfinch-lite` is Stylelint, and files staged in that folder follow its own lint-staged config; see [its README](fleetfinch-lite/README.md).

### Tests

| Command                 | What it does                                                                                    |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| `npm test`              | Runs Vitest once across every workspace; a workspace with no tests yet passes                   |
| `npm run test:watch`    | Reruns tests as files change                                                                    |
| `npm run test:coverage` | Reports coverage in the terminal and as HTML in `coverage/`                                     |
| `npm run test:shared`   | Runs one workspace; the others have a script of their own, such as `test:server` and `test:web` |

```sh
npm test -- fleetfinch-ui/src/AppShell.test.tsx    # one file
npm test -- -t "Hello World"                    # tests whose name matches
npm run test:watch -- --project fleetfinch-ui     # watches one workspace
```

### Cleaning up

| Command                 | What it does                                                                                                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run clean:dry-run` | Lists what `clean` would remove and deletes nothing                                                                                                                                       |
| `npm run clean`         | Removes dependencies, ignored files such as build output, and the dev database with its data. `.env` files are kept. Refuses while untracked files exist, because Git has no copy of them |
| `npm run clean:force`   | Does the same and deletes the untracked files too                                                                                                                                         |
| `npm run reset`         | Rebuilds the development environment: `clean`, `npm install`, then `db:start`                                                                                                             |

```sh
npm run clean:dry-run -- --force   # lists what clean:force would remove
```

## API

`fleetfinch-server` serves JSON on `http://localhost:4000`. Errors are JSON as well, in the form `{"error": "..."}`: 404 for an unknown route, 400 for a body that is not valid JSON, and 500 for a failure the API did not expect, which it logs.

| Route                | What it does                                                               |
| -------------------- | -------------------------------------------------------------------------- |
| `GET /api/v1/health` | Reports whether the API reaches the database; answers 503 when it does not |

```sh
curl http://localhost:4000/api/v1/health
```

## Where the code lives

A feature runs through these layers, from the database to the components.

| Layer                      | Where                                                                     |
| -------------------------- | ------------------------------------------------------------------------- |
| Tables and migrations      | `fleetfinch-server/src/schema.ts` and `fleetfinch-server/drizzle`         |
| Routes                     | `fleetfinch-server/src/index.ts`                                          |
| Database health check      | `fleetfinch-server/src/health.ts`                                         |
| Error responses            | `fleetfinch-server/src/errors.ts`                                         |
| Server environment         | `fleetfinch-server/src/serverEnv.ts`, parsed with Zod when the API starts |
| Schemas and types          | `fleetfinch-shared/src/health.ts`                                         |
| API client                 | `fleetfinch-shared/src/apiClient.ts`                                      |
| Components and theme       | `fleetfinch-ui/src`                                                       |
| Web pages and data loading | `fleetfinch-web/app`, with the API client in `app/_lib/api.ts`            |

## Shared components

`fleetfinch-ui` holds the components that look and behave the same wherever they are shown. An app only decides what data they get and what happens when they are used.

- **Props only.** Components take their data and their actions as props. They never fetch, read the environment, or import a framework, and ESLint refuses `next` and `node:` imports in the package.
- **Logic sits beside the schemas.** In `fleetfinch-shared`, `createApiClient` builds the client that each app gives its API address. The package runs in Node.js and in browser windows alike, so ESLint refuses browser-only globals there.
- **The web app supplies data from the server.** Server components load data through the API client in `app/_lib/api.ts` and hand it to the shared components.
- **The desktop app supplies data from the window.** Components in `fleetfinch-desktop/src/renderer` load data through the API client in `src/renderer/api.ts`, which calls the API directly.
- **`"use client"` where needed.** Components with state or event handlers start with it, which lets the App Router render them from server components. The others have no directive, so they can render on the server as well.
- **One theme.** `src/theme.css` is the one place for colors and fonts, and it tells Tailwind to scan the package for class names. It replaces Tailwind's default colors with four ramps and two reds: `slate-light`, `slate-mid`, `slate-deep`, `slate-dark`, and `slate-night`, which are `#434c6b` (`slate-dark`), its tints with white, and a shade of it with 50% black (`slate-night`); `orange-light`, `orange-bright`, `orange-mid`, `orange-deep`, and `orange-dark`, built on `#fa880d`; `cyan-light`, `cyan-mid`, `cyan-deep`, and `cyan-dark`, built on `#47cfea`; `sand-light`, `sand-mid`, `sand-deep`, and `sand-dark`, built on `#d4bba6`; and `red-light` and `red-deep`. Components use the roles mapped onto them, which switch for dark mode: `background`, `foreground`, `muted`, and `border` for the page, which is `slate-night` in dark mode and `slate-light` in light mode, `chrome` for the sidebar and the desktop title bar and its menus, a shade darker than the page that still keeps `muted` text at 4.5:1, `primary` for a panel's main action, checkboxes, progress bars, and spinners, in orange so they stand out against the slate, `secondary` for every other button, for links that leave the page, and for the selected option of a toggle or tab bar, in cyan, `accent` for warnings and for tasks that wait or stop, in sand, and `danger` for error messages. Dark mode applies when `<html>` has `data-theme="dark"`, or when the system is dark and `<html>` does not have `data-theme="light"`; the file redefines Tailwind's `dark:` variant the same way, and sets `color-scheme` to match. A solid button is `bg-primary text-primary-foreground`, which is `orange-deep` with `slate-light` text in light mode and `orange-bright` with `slate-night` text in dark mode, so its text is the page's color, and a soft one is `bg-primary-soft text-primary-soft-foreground border-primary-border` that turns solid on hover. The `secondary` roles work the same way, with `cyan-deep` and `cyan-mid` in place of the oranges. An icon takes `text-primary-border` or `text-accent-border`, which are a shade deeper in light mode so they stand 3:1 from the page, and a warning line is `bg-accent-soft text-accent-soft-foreground`. Every text pairing reaches at least 4.5:1 in both modes. `src/colors.ts`, imported from `@fleetfinch/ui/colors`, holds the same values for code that cannot read CSS, such as the preview image and the desktop window's background, and `fleetfinch-lite` writes the light- and dark-mode values out as hex because Safari 9 lacks custom properties.
- **Sidebar.** `Sidebar` runs down the left of the desktop app with an icon and a link to each page: Home, which shows the name and the description, Devices, which lists the added devices and opens each one to manage its apps, Logs, which shows what the app, this computer and a connected device report, and Settings, which holds the theme toggle. Below Tailwind's `xl` breakpoint, on a narrow or zoomed-in window, it collapses to its icons, showing each label as a tooltip, and it expands again above the breakpoint; a button beside the menu button in the desktop title bar collapses or expands it by hand until the window next crosses the breakpoint. It renders whatever link component the app gives it and marks the current page with `aria-current="page"`. The desktop app passes a plain `<a>` and keeps the page in the address's hash, so a reload stays on it.
- **Theme toggle.** `ThemeToggle` offers Auto, Light, and Dark, while the app decides where the choice is kept. The web app shows it at the top right as three 44-pixel icons, as `fleetfinch-lite` does, and the desktop app shows it on its Settings page with `showLabels`, which puts each option's name beside its icon. The selected option is filled with the solid `secondary` cyan, which stands 5.75:1 from the page in light mode and 8.14:1 in dark mode, since the soft fills are too close to the page to mark a state. The web app saves it in `localStorage` and sets `data-theme` on `<html>`, and an inline script in `app/layout.tsx` applies the saved choice before the first paint, as the Next.js guide to preventing a flash before hydration describes, so pages stay prerendered. The desktop app sends it over the bridge to the main process, which sets Electron's `nativeTheme.themeSource`; the window's `prefers-color-scheme` follows that, so it needs no `data-theme`.
- **No build step.** The apps compile the package from source, as they do `@fleetfinch/shared`, so an edit hot-reloads in every app that is running.
- **Linted like the web app.** The web app gets its React and accessibility rules from `eslint-config-next`. React code outside it is held to the React, hooks, and accessibility rule sets of the same plugins, and may not use Node.js globals.
- **Tests beside the components.** They run in jsdom with Testing Library; `npm run test:ui` runs them alone.

A component belongs in `fleetfinch-ui` when more than one app shows it, or could. Create it in `src`, export it from `src/index.ts`, and import it from `@fleetfinch/ui`. Pages and the components that load data stay in the app they belong to.

## Fonts

`fleetfinch-ui/src/theme.css` has a Tailwind font utility for each Latin-script typeface that [iOS 7 added](https://thomasdenney.co.uk/blog/2013/10/8/new-fonts-in-ios-7/). The apps target English only for now, so the typefaces for Arabic, Hebrew, Korean, and Thai are left out. Each one names the Apple font first, which iOS and macOS have installed, then the closest free Google font, which each app supplies under the variable in the last column. Three of them are also Tailwind's defaults, which its base styles apply to the page and to code: `font-sans` is Helvetica Neue, `font-serif` is Iowan Old Style, and `font-mono` is Menlo.

- **The web app** loads them with `next/font/google` in `app/_lib/fonts.ts`. It preloads Inter, the page font wherever Helvetica Neue is missing; any other font downloads only when a page uses it. `next/font/google` keeps every character set a font has, but the browser downloads only those a page's text needs, so an English page fetches only the Latin files.
- **The preview image** has no Apple fonts on the server that draws it, so `app/opengraph-image.tsx` draws its text in Inter, from the Latin subset in `fleetfinch-web/assets`, beside the font's license.
- **The desktop app** bundles only their Latin files, from the Fontsource packages that `src/renderer/globals.css` uses. It imports the Latin stylesheet of each static font, and declares each variable font's Latin file itself, since the variable packages have no stylesheet for a single character set.
- **`fleetfinch-lite`** sets its page in Helvetica Neue and has a class of the same name for each in `public/styles.css`. It ships no font files: every iOS 9 device has the Apple fonts, and Safari 9 cannot read the WOFF2, variable, and `unicode-range` fonts that Google serves.

| Utility                | Apple font (styles new in iOS 7)                   | Google font               | Variable                       |
| ---------------------- | -------------------------------------------------- | ------------------------- | ------------------------------ |
| `font-din-alternate`   | DIN Alternate (Bold)                               | Barlow 700                | `--font-barlow`                |
| `font-din-condensed`   | DIN Condensed (Bold)                               | Saira Extra Condensed 700 | `--font-saira-extra-condensed` |
| `font-helvetica-neue`  | Helvetica Neue (Thin, Thin Italic, Medium Italic)  | Inter                     | `--font-inter`                 |
| `font-iowan-old-style` | Iowan Old Style (Roman, Italic, Bold, Bold Italic) | Spectral 400 and 700      | `--font-spectral`              |
| `font-menlo`           | Menlo (Regular, Italic, Bold, Bold Italic)         | Noto Sans Mono            | `--font-noto-sans-mono`        |
| `font-savoye-let`      | Savoye LET                                         | Tangerine 400             | `--font-tangerine`             |
| `font-superclarendon`  | Superclarendon (Light to Black, with italics)      | Besley                    | `--font-besley`                |

Two substitutes fall short of their Apple font. Besley starts at Regular, so Superclarendon Light falls back to it. Noto Sans Mono has no italic, so the browser slants the upright, as Menlo's italic does.

The desktop app sets its text in the Dynamic Type styles of iOS 7, at the sizes iOS 7 gives them by default, and `theme.css` has a size utility for each one it uses. Page titles are `text-3xl font-light`, in the large, light type that iOS 7 used for display text. The weights are Light, Regular, and Medium, never Semibold, since Helvetica Neue has no Semibold and shows Bold in its place.

| Utility            | Size and weight    | Used for                           |
| ------------------ | ------------------ | ---------------------------------- |
| `text-headline`    | 17 pixels, Medium  | The title bar and section headings |
| `text-body`        | 17 pixels, Regular | Sidebar links and menu commands    |
| `text-subheadline` | 15 pixels, Regular | Keyboard shortcuts in the menu     |
| `text-footnote`    | 13 pixels, Regular | The labels of the theme toggle     |

## Web app

The web app's home page has the same content as `fleetfinch-lite`, the version of it for Safari 9, so change the two together. It keeps the lite site's look and behavior but uses what a current browser offers:

| What                    | `fleetfinch-lite`                                 | `fleetfinch-web`                                                                                                    |
| ----------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Colors and dark mode    | Hex values, with a `theme-dark` class on `<html>` | The theme's roles and `dark:` variant, following `prefers-color-scheme` under Auto                                  |
| Finch sketch            | Two PNG files in a `srcset`                       | `next/image` from `assets/finch.png`, served as AVIF or WebP at the width the screen needs                          |
| Accordions              | `<details>`, with a chevron drawn from borders    | `<details>` in `app/_components/Accordion.tsx`, which grows and shrinks through `::details-content` where supported |
| Prerequisite checklist  | `public/script.js` reads and writes the boxes     | `app/_components/InstallChecklist.tsx`, a React store in `localStorage` that follows changes made in other tabs     |
| Theme toggle before JS  | Hidden while `<html>` has the `no-js` class       | Hidden by the `noscript:` variant, which is `@media (scripting: none)`                                              |
| Spacing and focus rings | Margins, and outlines on `:focus`                 | Flexbox `gap`, and outlines on `:focus-visible`                                                                     |

Both save the checklist under `fleetfinch-prerequisites` and the theme under `fleetfinch-theme`, in the same formats.

## Search engines and link previews

The web app describes itself to search engines and to the apps that show a preview when a link is pasted into them. All of it is prerendered when the app is built. The files are in `fleetfinch-web`.

| File                      | What it does                                                                                                                                                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/_lib/site.ts`        | Holds the name and the description, which the layout, the home page, and the preview image all read, and `siteUrl()`, the public address from `SITE_URL`                                                                        |
| `app/layout.tsx`          | Sets what every page shares: the base address, the title and its template, the description, and the Open Graph and Twitter card settings. A page whose `metadata` has a `title` of `About` is titled "About \| FleetFinch"      |
| `app/page.tsx`            | States its own address in `alternates.canonical` and `openGraph.url`, and spreads `siteOpenGraph` into the latter, because a page's `openGraph` replaces the layout's instead of merging with it. Do the same in every new page |
| `app/opengraph-image.tsx` | Draws the 1200 by 630 preview image in Inter, which Next.js attaches to every page for Open Graph and Twitter. An `opengraph-image.tsx` in a route's folder gives that route its own                                            |
| `app/robots.ts`           | Lets crawlers in and points them at the sitemap                                                                                                                                                                                 |
| `app/sitemap.ts`          | Lists the pages. Add each new public page to it                                                                                                                                                                                 |

`SITE_URL` is compiled into the pages, so a production build needs the real address and fails without any. CI builds with a local address, only to prove that the app builds.

```sh
SITE_URL=https://example.com npm run build
```

## Tooling notes

- **Two TypeScript versions, on purpose.** The workspaces type-check with TypeScript 7, the native compiler, which `next build` also uses. The root keeps TypeScript 6 because typescript-eslint's type-aware rules still need the JavaScript compiler API. VS Code uses that copy too (`js/ts.tsdk.path` in `.vscode/settings.json`), because the TypeScript 7 package ships no language server. Dependabot leaves TypeScript's major and minor versions alone for the same reason; bump them by hand.
- **One config for the repository.** ESLint, Prettier, and lint-staged are configured at the root and cover every workspace but `fleetfinch-lite`, whose own configs hold its files to Safari 9. Run them from the root either way, since each tool uses the config closest to a file. Vitest's root config lists the workspace projects, each of which keeps its own `vitest.config.ts`. Every config file is TypeScript: Node.js 26 loads them directly, and ESLint reads `eslint.config.ts` through `jiti`.
- **The editor agrees with preflight.** A passing `npm run preflight` should leave nothing underlined in VS Code. ESLint fails on deprecated APIs and lints Tailwind classes with `eslint-plugin-better-tailwindcss`, which makes the same checks as the Tailwind CSS IntelliSense extension, so `.vscode/settings.json` turns those three IntelliSense lints off. Prettier wraps long class lists, so the plugin's line-wrapping rule is the one rule switched off.
- **ShellCheck reads `.shellcheckrc`**, so a script checked on its own in the editor follows `scripts/lib.sh` just as `lint:shell` does.
- **`overrides` in `package.json`.** One entry points every `eslint` peer dependency at the root ESLint 10, because some plugins bundled with `eslint-config-next` still declare ESLint 9. The other lets `@esbuild-kit/core-utils`, a deprecated package that `drizzle-kit` lists but never loads, share the esbuild already installed instead of adding an old release with a known advisory.
- **`allowScripts` in `package.json`** is npm's install-script policy and names the packages whose install scripts may run. When `npm install` reports an unreviewed package, look at what its script does and approve it. `prune` drops the entries that an update has made unnecessary.

  ```sh
  npm install-scripts approve <package>
  npm install-scripts prune
  ```

- **`.npmrc` sets `engine-strict`**, so `npm install` stops on a Node.js older than 26.

## Debugging

`.vscode/launch.json` starts the API or an app under the VS Code debugger from Run and Debug. Breakpoints in the TypeScript sources bind in the Node.js processes, such as the API and the Next.js server; code that runs in a browser window is debugged with the window's developer tools.

## Desktop app

`fleetfinch-desktop` is FleetFinch Developer, an Electron app with pages of its own, Home, Devices, Logs and Settings, built from the shared components. Its window is a React app compiled by Vite that calls the API directly: the server that sits between the web app and the API is there for caching and search engines, which a desktop app has no use for. The main process owns the window and its security rules, and answers the window over a small typed bridge.

```text
window (React, sandboxed) → API
window → window.bridge → preload script → IPC → main process
```

### Commands

```sh
npm run dev:server      # the API, which the window calls directly
npm run dev:desktop     # starts the app; press r in this terminal to restart the main process
npm run test:desktop    # runs its tests alone
npm run build:desktop   # packages an unsigned app for this machine
npm run make:desktop    # packages it and zips it
```

`npm run preflight` packages the app after the web build, and CI packages it in a job of its own. Arguments for Electron Forge go to the workspace's scripts:

```sh
npm run dev --workspace fleetfinch-desktop -- --inspect-electron   # main process under a debugger
npm run make --workspace fleetfinch-desktop -- --arch x64          # another architecture
VITE_API_BASE_URL=https://api.example.com npm run make:desktop   # a release that calls the production API
```

### Files

Paths are inside `fleetfinch-desktop`.

| File                                 | What it holds                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/renderer/api.ts`                | The shared API client, pointed at `VITE_API_BASE_URL`                                                                                                                                                                                                                                                                                                                                  |
| `src/env.ts`                         | The environment, parsed with Zod when the app starts                                                                                                                                                                                                                                                                                                                                   |
| `src/bridge.ts`                      | The `BridgeMethods` interface, which lists every call the window can make to the main process, and `Bridge`, which adds the platform name and listeners for the window being maximized or restored, for the build tools setup's progress and log, and for new lines on the Logs page; the two files below are typed against them                                                       |
| `src/preload/index.ts`               | Exposes `Bridge` as `window.bridge`, and nothing else                                                                                                                                                                                                                                                                                                                                  |
| `src/main/handlers.ts`               | Implements each method, given the window that called it                                                                                                                                                                                                                                                                                                                                |
| `src/menu.ts`                        | The File, Edit, View, and Window commands, with their labels and keyboard shortcuts, shared by the main process and the window                                                                                                                                                                                                                                                         |
| `src/main/menu.ts`                   | Builds the application menu from those commands, and runs one when the window asks, refusing any it does not know                                                                                                                                                                                                                                                                      |
| `src/renderer/App.tsx`               | The sidebar and the four pages, Home, Devices, Logs and Settings. Each page stays mounted inside React's `<Activity>`, hidden while another is shown, as Next.js keeps routes in the web app, so the theme toggle and the Logs page's tab, filter and selection keep their state                                                                                                       |
| `src/renderer/TitleBar.tsx`          | The title bar that replaces the system's: the menu button from `AppMenu.tsx`, the sidebar button from `SidebarToggle.tsx`, and the window buttons from `WindowControls.tsx`, with a second row below for smaller buttons, starting with the Activity button from `ActivityToggle.tsx`                                                                                                  |
| `src/renderer/activity.ts`           | The tasks the Activity pane shows, each with its steps and log, the ten most recent commands and whether each ran on this computer or a device, and whether the pane is out. A task that starts, or a step whose state or text changes, slides the pane out; nothing slides it back                                                                                                    |
| `src/renderer/ActivityPane.tsx`      | The Activity pane, which slides out from the right over the page: each task's steps as they run, and its log, above the command history from `CommandHistory.tsx`                                                                                                                                                                                                                      |
| `src/renderer/CommandHistory.tsx`    | The bottom quarter of the Activity pane: the ten most recent commands, newest first, each with where it ran and when, and a View Logs link that puts the pane away and opens the Logs page on This Computer. Its rows are `CommandRows`, which the Recent Tasks panel shows too                                                                                                        |
| `src/main/theme.ts`                  | Saves the theme to `theme.json` in the app's data folder, restores it before the window opens, and refuses unknown values                                                                                                                                                                                                                                                              |
| `src/buildTools.ts`                  | What a build for the iPad targets, the system tools with their Debian packages, the setup's steps, and the status, progress and log types that the window and the main process share                                                                                                                                                                                                   |
| `src/main/buildTools`                | The build tools setup: `setup.ts` runs the steps in order, one run at a time, and `system.ts`, `theos.ts`, `toolchain.ts` and `sdk.ts` each read and install one of them, using the release lookup and download in `github.ts`, and the programs they run through `process.ts`, which passes each command and line of output to the log. Each run is also a task on the Logs page      |
| `src/renderer/Panel.tsx`             | The parts every Home panel is built from: the list of rows, each an icon, a title and a description that share a line when there is room, the empty state, a single row centred in the space between the title and the bottom or the actions, the titled sections a panel can be split into, each with an empty state of its own, and the actions that stay at the bottom of the panel |
| `src/renderer/RecentTasks.tsx`       | The Recent Tasks panel on Home, in two sections: Tasks, the most recent task from the Activity pane with its state and current step, and Commands, the most recent command from the history the pane shows. The button at its bottom shows or hides the pane                                                                                                                           |
| `src/renderer/RecentProjects.tsx`    | The Recent Projects panel on Home, which says there are no projects yet                                                                                                                                                                                                                                                                                                                |
| `src/renderer/Devices.tsx`           | The Devices panel on Home: the added devices, each a link to its page, above Add Device                                                                                                                                                                                                                                                                                                |
| `src/deviceApps.ts`                  | The shape of a device's apps, packages and storage, the steps of an install and of a removal, and the events the main process sends while one runs, shared by the window and the main process                                                                                                                                                                                          |
| `src/main/deviceInventory.ts`        | The one command that lists a device's packages, apps, services and storage over SSH, and the reading of what it prints                                                                                                                                                                                                                                                                 |
| `src/main/plist.ts`                  | Reads the binary and XML property lists that describe each app on a device                                                                                                                                                                                                                                                                                                             |
| `src/main/tar.ts`                    | Reads the tar archive those property lists arrive in                                                                                                                                                                                                                                                                                                                                   |
| `src/main/debFile.ts`                | Reads a `.deb` on this computer with `dpkg-deb`: its name, version and dependencies, the apps inside it, and how much of the system volume it takes                                                                                                                                                                                                                                    |
| `src/main/dependencies.ts`           | Debian's version ordering, and the check that everything a package depends on is installed on a device                                                                                                                                                                                                                                                                                 |
| `src/main/deviceApps.ts`             | Reads a device's apps, and installs, updates or removes a package on it, one task at a time for each device                                                                                                                                                                                                                                                                            |
| `src/renderer/deviceApps.ts`         | The window's copy of each device's apps, and the Activity task that follows an install or a removal                                                                                                                                                                                                                                                                                    |
| `src/renderer/DevicesPage.tsx`       | The Devices page: a card for each added device, and Add Device                                                                                                                                                                                                                                                                                                                         |
| `src/renderer/DevicePage.tsx`        | A device's own page: its model, iOS version and address, how full its volumes are, its apps, and Remove Device                                                                                                                                                                                                                                                                         |
| `src/renderer/DeviceApps.tsx`        | The Apps section of a device's page: the Installed, Built In and Packages views, the filter, Install App, and Update and Remove on each row                                                                                                                                                                                                                                            |
| `src/renderer/BuildTools.tsx`        | The Computer Info panel on Home: what each build tool is, the button that sets them all up, and the run's progress                                                                                                                                                                                                                                                                     |
| `src/renderer/buildToolsActivity.ts` | Turns a build tools run into a task in the Activity pane, from the progress and log the main process sends, and adds each command it runs to the command history                                                                                                                                                                                                                       |
| `src/logs.ts`                        | The Logs page's tabs, the shape of a group of lines and of the updates the main process sends, and how many groups and lines are kept, shared by the window and the main process                                                                                                                                                                                                       |
| `src/main/logs.ts`                   | Keeps every group of log lines, sends new ones to the window in batches, and holds this launch's App log, which `logApp` and `logAppError` write to                                                                                                                                                                                                                                    |
| `src/main/deviceLogs.ts`             | Watches for iPhones and iPads connected by USB and reads each one's system log into a group of its own while it stays connected                                                                                                                                                                                                                                                        |
| `src/main/finchLogLines.ts`          | Reads the lines Finch Logs writes on a device, and turns each into a line of the Logs page with its time, its log and its level                                                                                                                                                                                                                                                        |
| `src/main/finchLogTail.ts`           | Tails each added device that runs Finch Logs: one SSH session for each device runs `finchlog read --follow` and outlasts the device's sleep, a silent device is looked in on at growing intervals, and the tail pauses while another SSH task runs                                                                                                                                     |
| `src/main/logDump.ts`                | Reads a Finch Logs dump, a tar archive that may be compressed, as a stream, keeping the newest lines of each log and the newest snapshot of each kind                                                                                                                                                                                                                                  |
| `src/main/finchLogImport.ts`         | Import Log Dump: copies a device's whole store to a file with `finchlog dump`, or opens a dump file, and shows its logs and snapshots under Device                                                                                                                                                                                                                                     |
| `src/renderer/logs.ts`               | The window's copy of the logs, kept current from the main process, with the tab and the group shown on each                                                                                                                                                                                                                                                                            |
| `src/renderer/Logs.tsx`              | The Logs page: a tab for the app, this computer and the device, each listing its launches, tasks or logs beside the selected one's lines, with a filter and a copy button, and under Device the switch that tails devices and Import Log Dump                                                                                                                                          |
| `src/main/index.ts`                  | The window, and the security rules listed below                                                                                                                                                                                                                                                                                                                                        |
| `forge.config.ts`                    | Electron Forge: packaging, the Vite builds, and the fuses                                                                                                                                                                                                                                                                                                                              |

The bridge is for what only the main process can do, such as reading the app version and reading or saving the theme. To add a call, add it to `BridgeMethods`. TypeScript then fails until the preload script exposes it and `handlers.ts` implements it.

### Build tools

Building for iOS 9 takes Theos, an iOS toolchain that runs on Linux (clang, the ld64 linker and `ldid`), and the iOS 9.3 SDK, with `TARGET = iphone:clang:9.3:9.0` and `ARCHS = armv7`. The Computer Info panel on Home sets all of them up with one button.

- **One button, three steps.** Set Up Build Tools runs System packages, then Theos, then iOS toolchain and 9.3 SDK, which installs the toolchain and then the SDK. A step that is already current says so and passes, and the first step that fails stops the run with a sentence and the last lines its programs printed. Only one run happens at a time, and the button turns into Update Build Tools once everything is in place.
- **The Activity pane follows the run.** It slides out when the run starts and lists the three steps, ticking each one off as the next begins, with what the running step is doing and how far along a download or the SDK adjustment is. Below them, the log shows each step's messages, every command the run starts, and each line that command prints, as it prints it. Messages and new steps slide the pane out again if it was put away, but log lines and progress do not. The log keeps the last 2,000 lines, and a new run starts it afresh.
- **A failed step can be retried.** When a step fails, Retry takes the place of Set Up Build Tools. It cleans up what the failed step left and runs the setup again, which passes over the steps that are already done. For System packages it first runs `dpkg --configure -a` and `apt-get install --fix-broken` in the same shell as the install, so there is still one password prompt. For Theos it clones a fresh copy beside the old one, moves the installed toolchain and SDK into it so neither is downloaded again, and swaps it in only once the clone is complete. For the toolchain and SDK it deletes both, any half-finished downloads beside them, and their recorded releases, then downloads them again. The Activity pane shows the run as a retry of that step.
- **Nothing is bundled or pinned.** Each run asks upstream for its newest version. Theos is cloned with its submodules from its default branch, and later runs bring it up to date with `git pull --ff-only`. The toolchain comes from the newest stable release of `L1ghtmann/llvm-project` and the SDK from that of `theos/sdks`: GitHub's latest release, which skips prereleases, as Theos's own installer does. The release that was installed is kept in `~/.fleetfinch/releases.json`, and a run downloads again only when GitHub names a newer one.
- **System packages** are everything a bare Debian or Ubuntu lacks: `git`, `make`, `perl`, `rsync` and `xz-utils` for Theos and the downloads, `ca-certificates` so that `git` can trust GitHub, and `openssh-client`, `usbmuxd` and `libimobiledevice-utils` for reaching the device and reading its log. `src/buildTools.ts` lists them. They are read with `dpkg-query`, not from files in `/usr/bin`, because a bare system has `/usr/bin/perl` from `perl-base` without the `perl` package. The missing ones are installed in one shell that runs `apt-get update`, then `apt-get install --no-install-recommends`, waiting up to five minutes for another apt to let go of its lock. A failed `apt-get update`, such as one for a `cdrom:` source left by the installer, does not stop the install.
- **Getting administrator rights** goes the first way that works. An app running as root runs the shell itself. Otherwise `pkexec` runs it, so the system's own dialog asks for a password and the app never sees it; turning the dialog down stops the run. Where there is no `pkexec`, or it cannot ask because no polkit agent is running, the panel asks for the password itself and the main process hands it to the shell's standard input, never to its arguments or a file. That is the user's own password for `sudo -S` when `sudo` is installed and the user is in the `sudo`, `admin` or `wheel` group, and the root password for `su` otherwise. `su` reads only from a terminal, so it runs inside `script`, which gives it one; `su`, `script` and `dpkg-query` are part of every Debian system. A password that is not accepted asks again.
- **Tested from nothing** in containers: `debian:trixie-slim` as root, as a user with only the root password, and as a `sudo` user whose `pkexec` has no polkit agent, and `ubuntu:26.04` as root. Each finished every step, and the tool, application, tweak and library templates then built and packaged for armv7. The toolchain needs only libraries every Debian system has, such as `libtinfo6`, `libuuid1` and `zlib1g`.
- **Downloads are checked** against the size that GitHub lists, and against the SHA-256 when GitHub lists one; releases uploaded before mid-2025 have none. Each archive is unpacked in a folder beside its destination and moved into place only once complete, so a failed run leaves the previous version as it was. A new toolchain counts as installed only if its clang runs, its linker lists `armv7`, and it has `ldid`.
- **The SDK is adjusted** before it is moved into place, as in the earlier Finch-K93 app: the `liblaunch` re-export that the linker cannot resolve is taken out of `libSystem.B.tbd`, thirteen functions such as `memcpy` and `memset` are added to `libsystem_c.tbd`, the simulator architectures are taken out of the stubs, and the old `module.map` files are renamed `module.modulemap`.
- **Everything lives in `~/.fleetfinch`**, which the development and packaged apps share: Theos in `theos`, the toolchain in `theos/toolchain/linux/iphone`, and the SDK in `theos/sdks`. The path has no spaces because Theos's Makefiles `include $(THEOS)/…`, which `make` splits at a space. Nothing outside that folder is changed, apart from the system packages.

### Logs

The Logs page shows what the app reports in three tabs, each split into groups: App has one for each launch, This Computer one for each task, and Device one for each time a device connects by USB, one for each device being tailed, and one for each log and snapshot of an imported dump. The newest group is shown until another is picked, the log stays scrolled to its newest line unless you scroll up, the filter keeps the lines that contain its text, and Copy copies the lines shown.

- **The main process keeps the logs**, in memory, so they last through a reload of the window but not a restart of the app. App and This Computer keep their 20 most recent groups and Device its 60, dropping the oldest finished one first, and each group its last 5,000 lines, saying how many there were in all. New lines reach the window in batches every 100 milliseconds, numbered so that the copy the window asks for when it loads and the batches after it never overlap.
- **App** records the launch, every message the window writes to its console, the window loading, failing to load, crashing or hanging, a bridge call that fails or comes from a page other than the app's, and any exception the main process does not catch. Warnings and errors stand out, and an error from the main process carries its stack. `logAppError` in `src/main/logs.ts` also prints to the terminal, as `console.error` did.
- **This Computer** records each build tools run, check or retry as a task of its own, with a heading for each step above its messages, commands and output, and the outcome at the end. A new task that runs programs opens a group with `openLogGroup("computer", title)` and passes its `log` to `runProcess`.
- **Device, by USB,** reads the log with `idevicesyslog` from `libimobiledevice-utils`, which the System packages step installs; until it is there, the tab says so. Every two seconds, while `usbmuxd` is running, `idevice_id -l` lists the devices connected by USB. A new one is named with `ideviceinfo -s`, which reads its name, model and iOS version without pairing, and `idevicesyslog -u <UDID> -x` reads its log until it is unplugged, with `--syslog-relay` where the installed version has it, since newer versions otherwise read iOS 9 through `os_trace_relay`. While the device is locked or has not yet trusted the computer, the reader logs the error once with what to do and tries again every five seconds. `<Error>` and `<Fault>` lines are marked as errors.
- **Device, over SSH,** tails devices that run [Finch Logs](fleetfinch-logs/README.md), once Tail devices that run Finch Logs is ticked. For each added device the main process keeps one SSH session running `finchlog read --follow`, which prints each new line of every log the service keeps, and a cursor to carry on from. The session is kept open for up to an hour, with nothing sent to the device, so it survives the device going to sleep and carries on the moment it wakes: on battery an iOS device wakes for any packet sent to it, a keep-alive probe as much as a new connection, and a tail that probed its session every 15 seconds, as the app's other SSH sessions do, would wake it four times a minute. When nothing has come from the device for 45 seconds the tail says it is probably asleep. To find a device that has restarted, it opens a new session after 2 minutes of silence, then after 5, 10, 20 and 30 minutes, and every 30 minutes from then on; a minute of hearing from the device again starts that count afresh. Each of these wakes a sleeping device for about five seconds. Each session starts where the last one stopped. A device that cannot be reached, or has no Finch Logs, says so once and is tried again later. The tail pauses while an install, a removal or an import is using the device. Warnings and errors keep their levels.
- **Import Log Dump…** copies everything Finch Logs has kept on a device to a file you choose, by saving what `finchlog dump --gzip` writes, or opens such a file. The main process reads the archive as a stream and shows the newest 5,000 lines of each log and the newest snapshot of each kind as groups under Device; the file keeps the rest. The copy and the reading are a task under This Computer.
- **Nothing on the device but our own code.** The tail and the import run only `finchlog`, which the Finch Logs package installs. The earlier refresh over SSH read `/var/log/syslog` with `wc`, `head` and `tail`, none of which a stock jailbroken device has, and is gone.

### Devices

The Devices page lists every device added over SSH, and each one opens a page of its own with its model, iOS version and address, how full its system and data volumes are, its apps, and the button that removes the device. The page's address is `#/devices/` followed by the device's IP address.

- **One command reads the device.** In a single SSH session, `src/main/deviceInventory.ts` asks for dpkg's packages, the app and launch daemon files each package owns, `df`, `launchctl list`, and a tar archive of each app's `Info.plist` and English name. It runs only `dpkg-query`, `grep`, `find`, `tar`, `df` and `launchctl`, because the jailbroken iPad 2 it was written against has no `wc`, `head`, `tail`, `awk` or `plutil`. The main process reads the property lists itself, binary or XML.
- **Three views.** Installed has the apps that came from a package or the App Store. Built In has the apps iOS came with, with the hidden system ones behind a checkbox. Packages has everything dpkg installed, with the app and the services each one brings and whether launchd has loaded them. The placeholder packages Cydia writes for the device's capabilities, tagged `role::cydia`, are left out.
- **Install App** takes a `.deb` picked in the system's file dialog, so the window never names a file. The main process reads it with `dpkg-deb`, copies it to `/tmp` on the device through the SSH session's standard input, and checks it there before changing anything: that it does not replace a protected package, that the system volume keeps 8 MB free, that `dpkg --dry-run` accepts it, and that everything it depends on is installed, compared by Debian's version rules, since the dry run does not look at dependencies. Only then does `dpkg -i` install it. Update on a row does the same and refuses a file that holds a different package.
- **Remove** asks first, then runs `dpkg -r`. A package is protected when it is essential or of required, important or standard priority, when the connection depends on it, or when it is the untether. It shows a lock in place of the buttons, and the main process refuses to replace or remove it whatever the window asks.
- **The Home screen is refreshed only when needed.** `uicache` can take minutes on an iPad 2, so it runs after an install only when the package holds an app whose `Info.plist` differs from the one already on the device, and never when the package's own scripts run it.
- **Each install or removal is a task.** The Activity pane shows its steps, the Logs page keeps it as a group under This Computer, and the commands that ran on the device go into the command history as device commands. One runs at a time for each device, and the tail of its logs pauses meanwhile. The end of a task reaches the window on the same channel as its progress, because the reply to the window's call can overtake the last progress message.
- **A sleeping device is kept awake while the app works on it.** A locked iPad on battery wakes for any packet sent to it and goes back to sleep about five seconds later, whatever an open session is doing, so a long step would run only in the seconds after each keep-alive probe, and those come 15 seconds apart. While the app reads a device's apps or changes a package, it opens a short SSH connection every four seconds, which keeps the device awake throughout. A session whose device has not answered for 45 seconds ends, instead of waiting out its time limit.
- **A dropped connection does not stop dpkg.** The change runs with the hangup and broken-pipe signals ignored, and deletes the copied file itself.

### Configuration

- **`VITE_API_BASE_URL`** in `fleetfinch-desktop/.env` is compiled into the app. A release build needs the production address in the environment or in `.env.production`, and packaging fails without a valid one. CI packages with a local address, only to prove that the app builds.
- **`EXTRA_ALLOWED_ORIGINS`** in `fleetfinch-server/.env` lists where the window is served from, because the API answers only the origins it knows: `http://localhost:5173` for the dev server and `app://renderer` for the packaged app. The server reduces each entry to the origin a browser sends, so a trailing slash or capital letters do no harm.
- **Shipping.** `npm run build:desktop` produces an unsigned app with the default icon. Signing, notarization, installers, an icon, a bundle identifier of your own, and updates are all [Electron Forge](https://www.electronforge.io) configuration, to add in `forge.config.ts` when the app ships.

### Development

- **Forge and Vite.** Electron Forge runs development, packaging, and distribution, and its Vite plugin bundles from `vite.main.config.ts`, `vite.preload.config.ts`, and `vite.renderer.config.ts`. Forge emits the first two as CommonJS, because a sandboxed preload script cannot load ES modules.
- **Reloading.** The window hot-reloads, including after an edit to `fleetfinch-shared` or `fleetfinch-ui`, and a change to the preload script reloads it. A change to the main process is rebuilt at once but takes effect when the app restarts: press `r` in the terminal that runs `npm run dev:desktop`, or type `rs` and Enter where that terminal is not interactive. Forge's `hotRestart` option is meant to do this by itself but does not restart the app as of Forge 8.0.1; turn it on in `forge.config.ts` once it does.
- **Workspace packages load from source.** Electron Forge's Vite plugin turns on `resolve.preserveSymlinks` for the window, which makes Vite treat `@fleetfinch/ui` and `@fleetfinch/shared` as installed packages: it pre-bundles them into a cache that edits never refresh, so a new export fails with "does not provide an export named" until that cache is deleted. `vite.renderer.config.ts` sets it back to `false`.
- **Port 5173.** The dev server is fixed to it, because that address is on the API's list.
- **Imports** inside the app start from `src` with `@/`, as they start from the app folder in the web app. Stack traces from the main process point at the TypeScript source.
- **One copy runs.** A second launch brings the first one's window forward. The app started by `npm run dev:desktop` keeps its own data folder, with `(development)` after the name, so it runs beside an installed copy.
- **Fast startup.** Each process loads one bundled file, compiled for the Chromium and Node.js that Electron ships rather than for older browsers. The [fonts](#fonts) are bundled instead of fetched, `app://` is registered so that V8 keeps the window's compiled script from the first launch on, and the window opens at once in the page's background color.
- **The title bar is the app's own.** The window is frameless, so the system draws no title bar, menu bar, or window buttons, and `src/renderer/TitleBar.tsx` draws them instead: the area between the buttons drags the window, a menu button at the top left lists File, Edit, View, and Window with a submenu for each, a button beside it collapses or expands the sidebar, and [Heroicons](https://heroicons.com) buttons at the top right minimize, maximize or restore, and close it. A second row below holds smaller buttons, starting with one that slides the Activity pane out from the right side or back in. The pane floats over the page rather than pushing it aside, and stays out until that button puts it away. The menu follows the keyboard as a system menu does, and runs Edit commands on the field that had focus before it opened.
- **The application menu stays**, built in `src/main/menu.ts` from the commands in `src/menu.ts`, so the hamburger menu and the keyboard shortcuts always match. A frameless window does not show it on Windows or Linux, but its shortcuts still work, and on macOS it stays in the menu bar, where Electron's roles are what make copy, paste, and undo work in text fields. To add a command, add it to `src/menu.ts`, then give it a role, if Electron has one, and a function in `src/main/menu.ts`.
- **Electron's binary** is not downloaded by `npm install`. The `electron` package fetches it the first time the app is started or packaged, and caches it for later installs.
- **`@types/node` is held at 24** here because Electron 45 embeds Node.js 24, whatever runs the rest of the repository. Dependabot leaves major versions of `@types/node` alone for that reason, so raise this one by hand when an Electron upgrade brings a newer Node.js.

### Security

- **The window has no access to Node.js or Electron.** Every renderer is sandboxed and context-isolated, and the preload script exposes named functions instead of `ipcRenderer`. The main process accepts calls only from the app's own page.
- **Lint and types draw the same line.** ESLint keeps `electron`, `node:` modules, Node.js globals, and the main process's own files out of `src/renderer`. `src/renderer/tsconfig.json` checks the window's code without the Node.js types, and `tsconfig.json` checks everything else without the DOM types.
- **A packaged app loads its window from `app://renderer`**, a protocol the main process serves from the app's own files, since `file://` pages have no origin to build rules on.
- **Content-Security-Policy.** The page may load its own files, connect to the API's address, and show `data:` images, with no plugins, `<base>` element, or form posts, and with inline scripts and styles allowed only for Vite's dev server. `src/contentSecurityPolicy.ts` builds the policy, Vite's dev server sends it in development, and the `app://` handler sends it with every file of a packaged app.
- **Navigation.** Leaving the app and opening new windows are refused, and `https` addresses, whether from a link or `window.open`, open in the default browser.
- **Permissions** are refused, both when the page asks for one and when Chromium only checks it, except writing to the clipboard and going fullscreen. Add to `grantedPermissions` in `src/main/index.ts` as the app needs more.
- **Zod without `eval`.** `src/renderer/zod.ts` runs first and switches Zod to interpreting its schemas, because the compiled parsers it prefers need `eval`, which the policy forbids. The main process has no such policy and keeps the compiled parsers.
- **Fuses.** The fuses in `forge.config.ts` are flipped when the app is packaged. They stop the binary from running as plain Node.js or taking debugger and `NODE_OPTIONS` flags, and make it load code only from `app.asar`. On macOS and Windows it also verifies that archive before loading it; Electron has no such check on Linux.
