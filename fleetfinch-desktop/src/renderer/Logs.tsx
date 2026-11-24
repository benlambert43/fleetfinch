import { AppShell } from "@fleetfinch/ui";
import {
  ArrowPathIcon,
  CheckCircleIcon,
  DevicePhoneMobileIcon,
  ExclamationCircleIcon,
  PauseCircleIcon,
  QueueListIcon,
  WindowIcon,
} from "@heroicons/react/20/solid";
import {
  Activity,
  type KeyboardEvent,
  type ReactNode,
  use,
  useDeferredValue,
  useEffect,
  useId,
  useState,
} from "react";

import {
  type LogGroup,
  type LogGroupState,
  logGroupStateLabels,
  type LogKind,
  type LogLine,
  type LogSource,
  logSourceLabels,
  logSources,
} from "@/logs.ts";
import {
  logsLoaded,
  selectLogGroup,
  setLogSource,
  useLogs,
  useLogSource,
} from "@/renderer/logs.ts";
import { StatusRow } from "@/renderer/Panel.tsx";

const descriptions: Record<LogSource, string> = {
  app: "What FleetFinch Developer reports about itself: its window's console, and anything that goes wrong in the window or the main process",
  computer:
    "Each task the app runs on this computer, with every command it starts and each line those programs print",
  device:
    "The system log of each iPhone or iPad while it is connected by USB, kept apart for each time it connects",
};

const groupNouns: Record<LogSource, string> = {
  app: "Launches",
  computer: "Tasks",
  device: "Connections",
};

const lineStyles: Record<LogKind, string> = {
  step: "mt-3 border-b border-border pb-0.5 font-medium first:mt-0",
  message: "font-medium",
  command: "text-muted",
  output: "",
  warning: "bg-accent-soft text-accent-soft-foreground",
  error: "bg-danger/10 text-danger",
};

const lineLabels: Partial<Record<LogKind, string>> = {
  warning: "Warning: ",
  error: "Error: ",
};

const timeFormat = new Intl.DateTimeFormat(undefined, { timeStyle: "medium" });
const numberFormat = new Intl.NumberFormat();
const copiedMs = 2000;

const inputStyle = `h-9 w-48 min-w-0 rounded-lg border-2 border-border
  bg-background px-2 text-subheadline focus-visible:outline-2
  focus-visible:outline-offset-2 focus-visible:outline-foreground`;

const secondaryButton = `h-9 rounded-lg border-2 border-border px-3
  text-subheadline hover:bg-foreground/5 focus-visible:outline-2
  focus-visible:outline-offset-2 focus-visible:outline-foreground
  disabled:opacity-60`;

function lineCount(count: number): string {
  return `${numberFormat.format(count)} ${count === 1 ? "line" : "lines"}`;
}

function lineText(line: LogLine, showTimes: boolean): string {
  const text = line.kind === "command" ? `$ ${line.text}` : line.text;
  return showTimes ? `${timeFormat.format(line.at)} ${text}` : text;
}

function shownLines(group: LogGroup, matching: number, filtered: boolean) {
  const kept = group.lines.length;
  const base =
    group.written > kept
      ? `the last ${numberFormat.format(kept)} of ${lineCount(group.written)}`
      : lineCount(kept);
  if (filtered) {
    return `${numberFormat.format(matching)} of ${base} match`;
  }
  return base.charAt(0).toUpperCase() + base.slice(1);
}

function timespan(group: LogGroup): string {
  const started = timeFormat.format(group.startedAt);
  return group.endedAt === null
    ? `Started ${started}`
    : `${started} to ${timeFormat.format(group.endedAt)}`;
}

function StateIcon({ state }: { state: LogGroupState }) {
  switch (state) {
    case "running":
      return (
        <ArrowPathIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-primary-border motion-safe:animate-spin"
        />
      );
    case "done":
      return (
        <CheckCircleIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-foreground"
        />
      );
    case "stopped":
      return (
        <PauseCircleIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-accent"
        />
      );
    case "failed":
      return (
        <ExclamationCircleIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-danger"
        />
      );
  }
}

function LogRow({ line, showTime }: { line: LogLine; showTime: boolean }) {
  const flagged = line.kind === "warning" || line.kind === "error";
  return (
    <p className={`flex gap-3 rounded-sm px-1 ${lineStyles[line.kind]}`}>
      {showTime && (
        <time
          dateTime={new Date(line.at).toISOString()}
          className={`shrink-0 tabular-nums ${flagged ? "" : "text-muted"}`}
        >
          {timeFormat.format(line.at)}
        </time>
      )}
      <span className="min-w-0 flex-1 wrap-break-word whitespace-pre-wrap">
        {lineLabels[line.kind] !== undefined && (
          <span className="sr-only">{lineLabels[line.kind]}</span>
        )}
        {line.kind === "command" ? `$ ${line.text}` : line.text}
      </span>
    </p>
  );
}

function LogView({
  group,
  filter,
  onFilterChange,
  showTimes,
}: {
  group: LogGroup;
  filter: string;
  onFilterChange: (filter: string) => void;
  showTimes: boolean;
}) {
  const headingId = useId();
  const [copied, setCopied] = useState(false);
  const deferredFilter = useDeferredValue(filter);
  const needle = deferredFilter.trim().toLowerCase();
  const visible =
    needle === ""
      ? group.lines
      : group.lines.filter((line) => line.text.toLowerCase().includes(needle));

  useEffect(() => {
    if (!copied) {
      return;
    }
    const timer = setTimeout(() => {
      setCopied(false);
    }, copiedMs);
    return () => {
      clearTimeout(timer);
    };
  }, [copied]);

  function copy() {
    const text = visible.map((line) => lineText(line, showTimes)).join("\n");
    void navigator.clipboard.writeText(text).then(
      () => {
        setCopied(true);
      },
      (error: unknown) => {
        console.error("The log could not be copied", error);
      },
    );
  }

  return (
    <section
      aria-labelledby={headingId}
      className="flex min-w-0 flex-1 flex-col gap-3"
    >
      <header
        className="flex flex-wrap items-start justify-between gap-x-6 gap-y-3"
      >
        <div className="flex min-w-0 flex-1 basis-64 flex-col gap-0.5">
          <h2 id={headingId} className="text-headline wrap-break-word">
            {group.title}
          </h2>
          <p className="text-footnote wrap-break-word text-muted">
            {[group.detail, timespan(group)]
              .filter((part) => part !== null)
              .join(" · ")}
          </p>
          <p
            role="status"
            className={`text-footnote wrap-break-word ${
              group.state === "failed" ? "text-danger" : "text-muted"
            }`}
          >
            {logGroupStateLabels[group.state]}
            {group.outcome !== null && `: ${group.outcome}`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <input
            type="search"
            value={filter}
            onChange={(event) => {
              onFilterChange(event.target.value);
            }}
            placeholder="Filter lines"
            aria-label="Filter lines"
            className={inputStyle}
          />
          <button
            type="button"
            onClick={copy}
            disabled={visible.length === 0}
            title="Copy the lines shown"
            className={secondaryButton}
          >
            {copied ? "Copied" : "Copy"}
          </button>
          <span role="status" className="sr-only">
            {copied ? "Copied the lines shown" : ""}
          </span>
        </div>
      </header>
      <div
        className="flex min-h-64 flex-1 flex-col-reverse overflow-y-auto
          rounded-lg border border-border bg-foreground/5 p-2 font-mono
          text-footnote contain-size"
      >
        <div>
          {visible.length === 0 ? (
            <p className="px-1 text-muted">
              {needle === "" ? "No output yet" : "No lines match the filter"}
            </p>
          ) : (
            visible.map((line) => (
              <LogRow key={line.id} line={line} showTime={showTimes} />
            ))
          )}
        </div>
      </div>
      <p className="text-footnote text-muted">
        {shownLines(group, visible.length, needle !== "")}
      </p>
    </section>
  );
}

function GroupButton({
  group,
  selected,
  onSelect,
}: {
  group: LogGroup;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        aria-current={selected ? "true" : undefined}
        onClick={onSelect}
        className="flex w-full items-start gap-2 rounded-lg px-3 py-2 text-left
          hover:bg-foreground/5 focus-visible:outline-2
          focus-visible:-outline-offset-2 focus-visible:outline-foreground
          aria-current:bg-foreground/10"
      >
        <StateIcon state={group.state} />
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-subheadline">
            {group.title}
            <span className="sr-only">
              , {logGroupStateLabels[group.state]}
            </span>
          </span>
          <span className="truncate text-footnote text-muted">
            {timeFormat.format(group.startedAt)} · {lineCount(group.written)}
          </span>
        </span>
      </button>
    </li>
  );
}

function EmptyLogs({ source }: { source: LogSource }) {
  const { canReadDevices } = useLogs();
  const empty: Record<
    LogSource,
    { icon: ReactNode; title: string; description: string }
  > = {
    app: {
      icon: (
        <WindowIcon aria-hidden="true" className="size-5 shrink-0 text-muted" />
      ),
      title: "No messages yet",
      description: "What the app reports about itself shows up here",
    },
    computer: {
      icon: (
        <QueueListIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-muted"
        />
      ),
      title: "No tasks yet",
      description:
        "Tasks you run, such as setting up build tools, show up here",
    },
    device: {
      icon: (
        <DevicePhoneMobileIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-muted"
        />
      ),
      ...(canReadDevices
        ? {
            title: "No devices yet",
            description:
              "Connect an iPhone or iPad by USB to read its log here",
          }
        : {
            title: "Device logs need libimobiledevice-utils",
            description:
              "Set Up Build Tools in Computer Info on Home installs it",
          }),
    },
  };
  return (
    <dl className="flex min-h-64 flex-1 flex-col items-center justify-center">
      <StatusRow {...empty[source]} />
    </dl>
  );
}

function SourcePanel({
  source,
  tabId,
  panelId,
}: {
  source: LogSource;
  tabId: string;
  panelId: string;
}) {
  const logs = useLogs();
  const [filter, setFilter] = useState("");
  const groups = logs.groups
    .filter((group) => group.source === source)
    .toReversed();
  const selectedId = logs.selected[source];
  const selected =
    groups.find((group) => group.id === selectedId) ?? groups.at(0);
  return (
    <div
      role="tabpanel"
      id={panelId}
      aria-labelledby={tabId}
      className="flex min-h-0 flex-1 flex-col gap-4"
    >
      <p className="text-footnote text-muted">{descriptions[source]}</p>
      {selected === undefined ? (
        <EmptyLogs source={source} />
      ) : (
        <div className="flex min-h-80 flex-1 gap-6">
          <ol
            aria-label={groupNouns[source]}
            className="flex w-60 shrink-0 flex-col gap-1 overflow-y-auto
              contain-size"
          >
            {groups.map((group) => (
              <GroupButton
                key={group.id}
                group={group}
                selected={group === selected}
                onSelect={() => {
                  selectLogGroup(source, group.id);
                }}
              />
            ))}
          </ol>
          <LogView
            key={selected.id}
            group={selected}
            filter={filter}
            onFilterChange={setFilter}
            showTimes={source !== "device"}
          />
        </div>
      )}
    </div>
  );
}

function moveBetweenTabs(event: KeyboardEvent<HTMLButtonElement>): void {
  const index = logSources.findIndex(
    (source) => source === event.currentTarget.value,
  );
  const last = logSources.length - 1;
  const targets: Record<string, number> = {
    ArrowRight: index === last ? 0 : index + 1,
    ArrowLeft: index === 0 ? last : index - 1,
    Home: 0,
    End: last,
  };
  const target = logSources[targets[event.key] ?? -1];
  if (target === undefined) {
    return;
  }
  event.preventDefault();
  setLogSource(target);
  event.currentTarget.parentElement
    ?.querySelector<HTMLButtonElement>(`[value="${target}"]`)
    ?.focus();
}

export function Logs() {
  use(logsLoaded);
  const current = useLogSource();
  const baseId = useId();
  const tabId = (source: LogSource) => `${baseId}-tab-${source}`;
  const panelId = (source: LogSource) => `${baseId}-panel-${source}`;
  return (
    <AppShell title="Logs">
      <div className="flex min-h-0 flex-1 flex-col gap-4">
        <div
          role="tablist"
          aria-label="Log sources"
          className="flex self-start overflow-hidden rounded-lg border-2
            border-foreground"
        >
          {logSources.map((source) => (
            <button
              key={source}
              type="button"
              role="tab"
              id={tabId(source)}
              value={source}
              aria-selected={source === current}
              aria-controls={panelId(source)}
              tabIndex={source === current ? 0 : -1}
              onClick={() => {
                setLogSource(source);
              }}
              onKeyDown={moveBetweenTabs}
              className="flex h-9 items-center px-3 text-subheadline text-muted
                not-first:border-l-2 not-first:border-foreground
                not-aria-selected:hover:bg-foreground/5
                not-aria-selected:hover:text-foreground focus-visible:outline-2
                focus-visible:-outline-offset-4 focus-visible:outline-foreground
                aria-selected:bg-foreground aria-selected:text-background
                aria-selected:focus-visible:outline-background"
            >
              {logSourceLabels[source]}
            </button>
          ))}
        </div>
        {logSources.map((source) => (
          <Activity
            key={source}
            mode={source === current ? "visible" : "hidden"}
          >
            <SourcePanel
              source={source}
              tabId={tabId(source)}
              panelId={panelId(source)}
            />
          </Activity>
        ))}
      </div>
    </AppShell>
  );
}
