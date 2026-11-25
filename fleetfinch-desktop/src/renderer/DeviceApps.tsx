import { SectionHeading } from "@fleetfinch/ui";
import {
  ArchiveBoxIcon,
  ArrowPathIcon,
  LockClosedIcon,
  Squares2X2Icon,
} from "@heroicons/react/20/solid";
import { ArrowDownTrayIcon } from "@heroicons/react/24/outline";
import {
  type KeyboardEvent,
  type ReactNode,
  useEffect,
  useId,
  useRef,
  useState,
} from "react";

import {
  type DeviceApp,
  type DeviceInventory,
  type DevicePackage,
  type DeviceService,
  deviceTaskStepLabels,
  formatKb,
} from "@/deviceApps.ts";
import type { Device } from "@/devices.ts";
import {
  installOnDevice,
  loadDeviceApps,
  removeFromDevice,
  useDeviceApps,
} from "@/renderer/deviceApps.ts";
import {
  dialogButton,
  primaryButton,
  secondaryButton,
} from "@/renderer/Panel.tsx";

const views = ["installed", "builtIn", "packages"] as const;

type View = (typeof views)[number];

const viewLabels: Record<View, string> = {
  installed: "Installed",
  builtIn: "Built In",
  packages: "Packages",
};

const viewDescriptions: Record<View, string> = {
  installed: "Apps added to this device, from a package or the App Store",
  builtIn: "Apps that came with iOS",
  packages:
    "Everything dpkg has installed, including command-line tools and services",
};

const emptyViews: Record<View, string> = {
  installed:
    "No apps added yet. Install App copies a package to the device and installs it.",
  builtIn: "No built-in apps were found.",
  packages: "dpkg lists no packages on this device.",
};

const timeFormat = new Intl.DateTimeFormat(undefined, { timeStyle: "short" });
const numberFormat = new Intl.NumberFormat();

const inputStyle = `h-9 w-48 min-w-0 rounded-lg border-2 border-border
  bg-background px-2 text-subheadline focus-visible:outline-2
  focus-visible:outline-offset-2 focus-visible:outline-foreground`;

const updateButton = `flex h-7 shrink-0 items-center rounded-md bg-secondary
  px-2.5 text-footnote text-secondary-foreground hover:opacity-90
  focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-foreground disabled:opacity-60`;

const removeButton = `flex h-7 shrink-0 items-center rounded-md px-2
  text-footnote text-danger transition-colors hover:bg-danger/10
  focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-foreground active:bg-danger/20 disabled:opacity-60
  disabled:hover:bg-transparent`;

function matches(needle: string, ...fields: (string | null)[]): boolean {
  return (
    needle === "" ||
    fields.some((field) => field?.toLowerCase().includes(needle) === true)
  );
}

function joined(...parts: (string | null)[]): string {
  return parts.filter((part) => part !== null).join(" · ");
}

function count(amount: number, noun: string): string {
  return `${numberFormat.format(amount)} ${noun}${amount === 1 ? "" : "s"}`;
}

function appVersion({ version, build }: DeviceApp): string | null {
  return version !== null && build !== null && build !== version
    ? `${version} (${build})`
    : version;
}

function serviceState({ loaded, pid }: DeviceService): string {
  if (pid !== null) {
    return "running";
  }
  return loaded ? "loaded" : "not loaded";
}

function appNames(
  paths: readonly string[],
  apps: readonly DeviceApp[],
): string[] {
  return paths.map(
    (path) => apps.find((app) => app.path === path)?.name ?? path,
  );
}

function removalEffect(
  target: DevicePackage,
  apps: readonly DeviceApp[],
  deviceName: string,
): string {
  const parts = [
    ...appNames(target.apps, apps).map((name) => `the app ${name}`),
    ...target.services.map((service) => `the service ${service.label}`),
  ];
  const extras =
    parts.length === 0
      ? ""
      : `, with ${new Intl.ListFormat(undefined, { type: "conjunction" }).format(parts)}`;
  return `Takes ${target.id} ${target.version} off ${deviceName}${extras}. Installing it again needs its package file.`;
}

function RemovePackageDialog({
  target,
  effect,
  onRemove,
  onClosed,
}: {
  target: DevicePackage;
  effect: string;
  onRemove: () => void;
  onClosed: () => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const headingId = useId();
  const descriptionId = useId();

  useEffect(() => {
    const dialog = dialogRef.current;
    dialog?.showModal();
    return () => {
      dialog?.close();
    };
  }, []);

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby={headingId}
      aria-describedby={descriptionId}
      onClose={() => {
        if (dialogRef.current?.open !== true) {
          onClosed();
        }
      }}
      className="m-auto w-[calc(100%-2rem)] max-w-sm rounded-2xl border-2
        border-menu-border bg-menu p-5 text-menu-foreground shadow-lg
        backdrop:bg-background/60 backdrop:backdrop-blur-xs"
    >
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <h2 id={headingId} className="text-headline">
            Remove {target.name}?
          </h2>
          <p
            id={descriptionId}
            className="text-footnote wrap-break-word text-menu-muted"
          >
            {effect}
          </p>
        </div>
        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={() => {
              dialogRef.current?.close();
            }}
            className={`${dialogButton} hover:bg-menu-border/50
              active:bg-menu-border/80`}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => {
              onRemove();
              dialogRef.current?.close();
            }}
            className={`${dialogButton} bg-danger text-background
              hover:opacity-90`}
          >
            Remove
          </button>
        </div>
      </div>
    </dialog>
  );
}

function PackageActions({
  target,
  busy,
  onUpdate,
  onRemove,
}: {
  target: DevicePackage;
  busy: boolean;
  onUpdate: (target: DevicePackage) => void;
  onRemove: (target: DevicePackage) => void;
}) {
  if (target.locked !== null) {
    return (
      <p className="flex shrink-0 items-center gap-1 text-footnote text-muted">
        <LockClosedIcon aria-hidden="true" className="size-4 shrink-0" />
        {target.locked}
      </p>
    );
  }
  return (
    <div className="flex shrink-0 items-center gap-2">
      <button
        type="button"
        disabled={busy}
        aria-label={`Update ${target.name}`}
        title="Install a newer package file over it"
        onClick={() => {
          onUpdate(target);
        }}
        className={updateButton}
      >
        Update…
      </button>
      <button
        type="button"
        disabled={busy}
        aria-haspopup="dialog"
        aria-label={`Remove ${target.name}`}
        onClick={() => {
          onRemove(target);
        }}
        className={removeButton}
      >
        Remove…
      </button>
    </div>
  );
}

function Row({
  icon,
  name,
  version,
  lines,
  flag,
  children,
}: {
  icon: ReactNode;
  name: string;
  version: string | null;
  lines: string[];
  flag?: string | null;
  children?: ReactNode;
}) {
  return (
    <li className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      {icon}
      <div className="flex min-w-0 flex-1 basis-56 flex-col">
        <p className="flex flex-wrap items-baseline gap-x-2">
          <span className="text-subheadline wrap-break-word">{name}</span>
          {version !== null && (
            <span className="text-footnote text-muted">{version}</span>
          )}
          {flag !== undefined && flag !== null && (
            <span
              className="rounded-sm bg-accent-soft px-1.5 text-footnote
                text-accent-soft-foreground"
            >
              {flag}
            </span>
          )}
        </p>
        {[...new Set(lines)].map((line) => (
          <p key={line} className="text-footnote wrap-break-word text-muted">
            {line}
          </p>
        ))}
      </div>
      {children}
    </li>
  );
}

function appIcon(): ReactNode {
  return (
    <Squares2X2Icon
      aria-hidden="true"
      className="size-5 shrink-0 text-foreground"
    />
  );
}

function packageIcon(): ReactNode {
  return (
    <ArchiveBoxIcon
      aria-hidden="true"
      className="size-5 shrink-0 text-foreground"
    />
  );
}

function moveBetweenViews(
  event: KeyboardEvent<HTMLButtonElement>,
  onChange: (view: View) => void,
): void {
  const index = views.findIndex((view) => view === event.currentTarget.value);
  const last = views.length - 1;
  const targets: Record<string, number> = {
    ArrowRight: index === last ? 0 : index + 1,
    ArrowLeft: index === 0 ? last : index - 1,
    Home: 0,
    End: last,
  };
  const target = views[targets[event.key] ?? -1];
  if (target === undefined) {
    return;
  }
  event.preventDefault();
  onChange(target);
  event.currentTarget.parentElement
    ?.querySelector<HTMLButtonElement>(`[value="${target}"]`)
    ?.focus();
}

function Listing({
  view,
  inventory,
  needle,
  showHidden,
  busy,
  onUpdate,
  onRemove,
}: {
  view: View;
  inventory: DeviceInventory;
  needle: string;
  showHidden: boolean;
  busy: boolean;
  onUpdate: (target: DevicePackage) => void;
  onRemove: (target: DevicePackage) => void;
}) {
  const { apps, packages } = inventory;
  const shownApps = apps.filter(
    (app) =>
      (view === "installed"
        ? app.source !== "system"
        : app.source === "system" && (showHidden || !app.hidden)) &&
      matches(needle, app.name, app.identifier, app.packageId),
  );
  const shownPackages = packages.filter((target) =>
    matches(needle, target.name, target.id, target.summary),
  );
  const total = view === "packages" ? shownPackages.length : shownApps.length;
  if (total === 0) {
    return (
      <p
        className="rounded-2xl border-2 border-border px-4 py-6 text-center
          text-footnote text-muted"
      >
        {needle === "" ? emptyViews[view] : "Nothing matches the filter."}
      </p>
    );
  }
  return (
    <ul
      aria-label={viewLabels[view]}
      className="flex flex-col divide-y divide-border rounded-2xl border-2
        border-border"
    >
      {view === "packages"
        ? shownPackages.map((target) => (
            <Row
              key={target.id}
              icon={packageIcon()}
              name={target.name}
              version={target.version}
              flag={
                target.state === "unfinished" ? "Not fully installed" : null
              }
              lines={[
                joined(
                  target.id,
                  target.section,
                  target.installedKb === null
                    ? null
                    : formatKb(target.installedKb),
                ),
                ...(target.summary === null ? [] : [target.summary]),
                ...appNames(target.apps, apps).map((name) => `App: ${name}`),
                ...target.services.map(
                  (service) =>
                    `Service: ${service.label}, ${serviceState(service)}`,
                ),
              ]}
            >
              <PackageActions
                target={target}
                busy={busy}
                onUpdate={onUpdate}
                onRemove={onRemove}
              />
            </Row>
          ))
        : shownApps.map((app) => {
            const owner = packages.find(
              (target) => target.id === app.packageId,
            );
            return (
              <Row
                key={app.path}
                icon={appIcon()}
                name={app.name}
                version={appVersion(app)}
                flag={app.hidden ? "Hidden" : null}
                lines={[
                  joined(
                    app.identifier,
                    owner === undefined
                      ? null
                      : `Package ${owner.id} ${owner.version}`,
                  ),
                ]}
              >
                {owner !== undefined && (
                  <PackageActions
                    target={owner}
                    busy={busy}
                    onUpdate={onUpdate}
                    onRemove={onRemove}
                  />
                )}
                {app.source === "user" && (
                  <p className="shrink-0 text-footnote text-muted">
                    Remove it on the device
                  </p>
                )}
              </Row>
            );
          })}
    </ul>
  );
}

export function DeviceApps({ device }: { device: Device }) {
  const { address } = device;
  const name = device.name ?? address;
  const { inventory, loading, problem, busy, progress, notice } =
    useDeviceApps(address);
  const [view, setView] = useState<View>("installed");
  const [filter, setFilter] = useState("");
  const [showHidden, setShowHidden] = useState(false);
  const [removing, setRemoving] = useState<DevicePackage | null>(null);
  const baseId = useId();
  const tabId = (id: View) => `${baseId}-tab-${id}`;
  const panelId = `${baseId}-panel`;

  return (
    <section aria-label="Apps" className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <SectionHeading>Apps</SectionHeading>
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            disabled={loading}
            onClick={() => {
              loadDeviceApps(address);
            }}
            className={secondaryButton}
          >
            {loading && inventory !== null ? "Refreshing…" : "Refresh"}
          </button>
          <button
            type="button"
            disabled={busy}
            title="Choose a .deb package on this computer to install or update"
            onClick={() => {
              void installOnDevice(address, null);
            }}
            className={`flex items-center gap-1.5 ${primaryButton}`}
          >
            <ArrowDownTrayIcon
              aria-hidden="true"
              className="size-4.5"
              strokeWidth={2}
            />
            Install App…
          </button>
        </div>
      </div>
      {busy && progress !== null && (
        <div role="status" className="flex flex-col gap-1">
          <p className="text-footnote wrap-break-word">{progress.message}</p>
          <progress
            max={1}
            value={progress.fraction ?? undefined}
            aria-label={`${deviceTaskStepLabels[progress.step]} progress`}
            className="h-1.5 w-full accent-primary"
          />
        </div>
      )}
      {notice !== null && (
        <div role={notice.tone} className="flex flex-col gap-1">
          <p
            className={`text-footnote wrap-break-word ${
              notice.tone === "alert" ? "text-danger" : ""
            }`}
          >
            {notice.text}
          </p>
          {notice.output !== "" && (
            <pre
              className="max-h-48 overflow-y-auto rounded-lg border
                border-border p-2 font-mono text-footnote wrap-break-word
                whitespace-pre-wrap"
            >
              {notice.output}
            </pre>
          )}
        </div>
      )}
      {problem !== null && (
        <p role="alert" className="text-footnote wrap-break-word text-danger">
          {inventory === null
            ? problem
            : `The list below could not be refreshed. ${problem}`}
        </p>
      )}
      {inventory === null ? (
        loading && (
          <p
            role="status"
            className="flex items-center gap-2 text-footnote text-muted"
          >
            <ArrowPathIcon
              aria-hidden="true"
              className="size-5 shrink-0 text-primary-border
                motion-safe:animate-spin"
            />
            Reading the apps on {name}…
          </p>
        )
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
            <div
              role="tablist"
              aria-label="Kinds of apps"
              className="flex overflow-hidden rounded-lg border-2
                border-foreground"
            >
              {views.map((id) => (
                <button
                  key={id}
                  type="button"
                  role="tab"
                  id={tabId(id)}
                  value={id}
                  aria-selected={id === view}
                  aria-controls={panelId}
                  tabIndex={id === view ? 0 : -1}
                  onClick={() => {
                    setView(id);
                  }}
                  onKeyDown={(event) => {
                    moveBetweenViews(event, setView);
                  }}
                  className="flex h-9 items-center px-3 text-subheadline
                    text-muted not-first:border-l-2 not-first:border-foreground
                    not-aria-selected:hover:bg-foreground/5
                    not-aria-selected:hover:text-foreground
                    focus-visible:outline-2 focus-visible:-outline-offset-4
                    focus-visible:outline-foreground aria-selected:bg-secondary
                    aria-selected:text-secondary-foreground
                    aria-selected:focus-visible:outline-secondary-foreground"
                >
                  {viewLabels[id]}
                </button>
              ))}
            </div>
            <input
              type="search"
              value={filter}
              onChange={(event) => {
                setFilter(event.target.value);
              }}
              placeholder="Filter"
              aria-label="Filter apps and packages"
              className={inputStyle}
            />
            {view === "builtIn" && (
              <label className="flex items-center gap-2 text-subheadline">
                <input
                  type="checkbox"
                  checked={showHidden}
                  onChange={(event) => {
                    setShowHidden(event.target.checked);
                  }}
                  className="size-4 accent-primary"
                />
                Show hidden system apps
              </label>
            )}
          </div>
          <div
            role="tabpanel"
            id={panelId}
            aria-labelledby={tabId(view)}
            className="flex flex-col gap-3"
          >
            <p className="text-footnote text-muted">{viewDescriptions[view]}</p>
            <Listing
              view={view}
              inventory={inventory}
              needle={filter.trim().toLowerCase()}
              showHidden={showHidden}
              busy={busy}
              onUpdate={(target) => {
                void installOnDevice(address, target.id);
              }}
              onRemove={setRemoving}
            />
            <p className="text-footnote text-muted">
              {joined(
                count(inventory.apps.length, "app"),
                count(inventory.packages.length, "package"),
                `Read at ${timeFormat.format(inventory.readAt)}`,
              )}
            </p>
          </div>
        </>
      )}
      {inventory === null && !loading && problem !== null && (
        <button
          type="button"
          onClick={() => {
            loadDeviceApps(address);
          }}
          className={`self-start ${primaryButton}`}
        >
          Try Again
        </button>
      )}
      {removing !== null && (
        <RemovePackageDialog
          key={removing.id}
          target={removing}
          effect={removalEffect(removing, inventory?.apps ?? [], name)}
          onRemove={() => {
            void removeFromDevice(address, removing.id);
          }}
          onClosed={() => {
            setRemoving(null);
          }}
        />
      )}
    </section>
  );
}
