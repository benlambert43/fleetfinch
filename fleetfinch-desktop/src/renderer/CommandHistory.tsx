import {
  ComputerDesktopIcon,
  DevicePhoneMobileIcon,
} from "@heroicons/react/16/solid";
import { CommandLineIcon } from "@heroicons/react/20/solid";
import { useId } from "react";

import {
  type CommandRecord,
  type CommandTarget,
  setActivityOpen,
  useCommandHistory,
} from "@/renderer/activity.ts";
import { logsHref, showLogs } from "@/renderer/logs.ts";

const targets: Record<
  CommandTarget,
  { label: string; Icon: typeof ComputerDesktopIcon }
> = {
  computer: { label: "On this computer", Icon: ComputerDesktopIcon },
  device: { label: "On a device", Icon: DevicePhoneMobileIcon },
};

const timeFormat = new Intl.DateTimeFormat(undefined, { timeStyle: "medium" });

const mutedTones = {
  menu: "text-menu-muted",
  page: "text-muted",
} as const;

function CommandRow({
  command,
  muted,
}: {
  command: CommandRecord;
  muted: string;
}) {
  const { label, Icon } = targets[command.target];
  return (
    <li className="flex items-center gap-2 text-footnote">
      <span title={label} className={`shrink-0 ${muted}`}>
        <Icon aria-hidden="true" className="size-4" />
        <span className="sr-only">{label}: </span>
      </span>
      <code title={command.text} className="min-w-0 flex-1 truncate font-mono">
        {command.text}
      </code>
      <time
        dateTime={new Date(command.at).toISOString()}
        className={`shrink-0 tabular-nums ${muted}`}
      >
        {timeFormat.format(command.at)}
      </time>
    </li>
  );
}

export function CommandRows({
  commands,
  tone,
}: {
  commands: readonly CommandRecord[];
  tone: keyof typeof mutedTones;
}) {
  return commands.map((command) => (
    <CommandRow key={command.id} command={command} muted={mutedTones[tone]} />
  ));
}

export function CommandHistory() {
  const history = useCommandHistory();
  const headingId = useId();
  return (
    <section
      aria-labelledby={headingId}
      className="flex h-1/4 shrink-0 flex-col gap-2 border-t border-menu-border
        px-4 py-3"
    >
      <h3 id={headingId} className="text-subheadline">
        Command History
      </h3>
      {history.length === 0 ? (
        <p
          className="flex min-h-0 flex-1 items-center gap-2 text-footnote
            text-menu-muted"
        >
          <CommandLineIcon aria-hidden="true" className="size-5 shrink-0" />
          Commands run on this computer or a device show up here
        </p>
      ) : (
        <ol className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
          <CommandRows commands={history} tone="menu" />
        </ol>
      )}
      <div className="flex justify-end">
        <a
          href={logsHref}
          onClick={() => {
            showLogs("computer");
            setActivityOpen(false);
          }}
          className="flex h-7 items-center rounded-md bg-secondary px-2.5
            text-footnote text-secondary-foreground hover:opacity-90
            focus-visible:outline-2 focus-visible:outline-offset-2
            focus-visible:outline-menu-foreground"
        >
          View Logs
        </a>
      </div>
    </section>
  );
}
