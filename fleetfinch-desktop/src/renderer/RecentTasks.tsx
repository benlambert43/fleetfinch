import {
  ArrowPathIcon,
  CheckCircleIcon,
  CommandLineIcon,
  ExclamationCircleIcon,
  PauseCircleIcon,
  QueueListIcon,
} from "@heroicons/react/20/solid";

import {
  setActivityOpen,
  type Task,
  type TaskState,
  taskStateLabels,
  useActivityOpen,
  useActivityTasks,
  useCommandHistory,
} from "@/renderer/activity.ts";
import { CommandRows } from "@/renderer/CommandHistory.tsx";
import {
  PanelActions,
  PanelBody,
  PanelSection,
  primaryButton,
  SectionEmptyState,
  StatusList,
  StatusRow,
} from "@/renderer/Panel.tsx";

function TaskIcon({ state }: { state: TaskState }) {
  switch (state) {
    case "running":
      return (
        <ArrowPathIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-primary-border motion-safe:animate-spin"
        />
      );
    case "waiting":
      return (
        <PauseCircleIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-accent"
        />
      );
    case "done":
      return (
        <CheckCircleIcon
          aria-hidden="true"
          className="size-5 shrink-0 text-foreground"
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

function describe(task: Task): string {
  const step = task.steps.find(
    (candidate) =>
      candidate.state === "running" ||
      candidate.state === "waiting" ||
      candidate.state === "failed",
  );
  return [taskStateLabels[task.state], step?.label, step?.detail]
    .filter((part): part is string => typeof part === "string")
    .join(" · ");
}

export function RecentTasks() {
  const [latestTask] = useActivityTasks();
  const [latestCommand] = useCommandHistory();
  const open = useActivityOpen();
  return (
    <PanelBody>
      <PanelSection title="Tasks">
        {latestTask === undefined ? (
          <SectionEmptyState
            icon={
              <QueueListIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-muted"
              />
            }
            title="No tasks yet"
            description="Tasks you run, such as setting up build tools, show up here"
          />
        ) : (
          <StatusList>
            <StatusRow
              icon={<TaskIcon state={latestTask.state} />}
              title={latestTask.title}
              description={describe(latestTask)}
            />
          </StatusList>
        )}
      </PanelSection>
      <PanelSection title="Commands" divided>
        {latestCommand === undefined ? (
          <SectionEmptyState
            icon={
              <CommandLineIcon
                aria-hidden="true"
                className="size-5 shrink-0 text-muted"
              />
            }
            title="No commands yet"
            description="Commands run on this computer or a device show up here"
          />
        ) : (
          <ol className="flex flex-col gap-1">
            <CommandRows commands={[latestCommand]} tone="page" />
          </ol>
        )}
      </PanelSection>
      <PanelActions>
        <button
          type="button"
          onClick={() => {
            setActivityOpen(!open);
          }}
          className={primaryButton}
        >
          {open ? "Hide Activity" : "Show Activity"}
        </button>
      </PanelActions>
    </PanelBody>
  );
}
