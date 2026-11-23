import {
  ArrowPathIcon,
  CheckCircleIcon,
  ExclamationCircleIcon,
  PauseCircleIcon,
} from "@heroicons/react/20/solid";
import { useId } from "react";

import {
  type LogEntry,
  type LogKind,
  type StepState,
  type Task,
  type TaskState,
  type TaskStep,
  useActivityTasks,
} from "@/renderer/activity.ts";

const taskStateLabels: Record<TaskState, string> = {
  running: "Running",
  waiting: "Waiting for you",
  done: "Done",
  failed: "Failed",
};

const stepStateLabels: Record<StepState, string> = {
  pending: "not started",
  running: "in progress",
  waiting: "waiting for you",
  done: "done",
  failed: "failed",
};

const logStyles: Record<LogKind, string> = {
  message: "mt-2 font-semibold first:mt-0",
  command: "text-menu-muted",
  output: "",
  error: "mt-2 font-semibold text-danger first:mt-0",
};

function StepIcon({ state }: { state: StepState }) {
  switch (state) {
    case "pending":
      return (
        <svg
          viewBox="0 0 20 20"
          aria-hidden="true"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          className="size-5 shrink-0 text-menu-muted"
        >
          <circle cx="10" cy="10" r="7" />
        </svg>
      );
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
          className="size-5 shrink-0 text-menu-foreground"
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

function StepRow({ step }: { step: TaskStep }) {
  return (
    <li className="flex items-start gap-2">
      <StepIcon state={step.state} />
      <div className="min-w-0 flex-1">
        <p className="text-subheadline">
          {step.label}
          <span className="sr-only">, {stepStateLabels[step.state]}</span>
        </p>
        {step.detail !== null && (
          <p
            className={`text-footnote wrap-break-word ${
              step.state === "failed" ? "text-danger" : "text-menu-muted"
            }`}
          >
            {step.detail}
          </p>
        )}
        {step.state === "running" && (
          <progress
            max={1}
            value={step.fraction ?? undefined}
            aria-label={`${step.label} progress`}
            className="mt-1.5 h-1.5 w-full accent-primary"
          />
        )}
      </div>
    </li>
  );
}

function LogLine({ entry }: { entry: LogEntry }) {
  return (
    <p
      className={`wrap-break-word whitespace-pre-wrap ${logStyles[entry.kind]}`}
    >
      {entry.kind === "command" ? `$ ${entry.text}` : entry.text}
    </p>
  );
}

function TaskView({ task }: { task: Task }) {
  const headingId = useId();
  const logHeadingId = useId();
  return (
    <article aria-labelledby={headingId} className="flex flex-1 flex-col gap-4">
      <header className="flex items-baseline justify-between gap-3">
        <h3 id={headingId} className="text-headline">
          {task.title}
        </h3>
        <p
          role="status"
          className={`shrink-0 text-footnote ${
            task.state === "failed" ? "text-danger" : "text-menu-muted"
          }`}
        >
          {taskStateLabels[task.state]}
        </p>
      </header>
      <ol aria-label="Steps" className="flex flex-col gap-3">
        {task.steps.map((step) => (
          <StepRow key={step.id} step={step} />
        ))}
      </ol>
      <section
        aria-labelledby={logHeadingId}
        className="flex min-h-48 flex-1 flex-col gap-1.5"
      >
        <h4 id={logHeadingId} className="text-footnote text-menu-muted">
          Log
        </h4>
        <div
          className="flex flex-1 flex-col-reverse overflow-y-auto rounded-lg
            border border-menu-border bg-menu-foreground/5 p-2 font-mono
            text-footnote contain-size"
        >
          <div>
            {task.log.length === 0 ? (
              <p className="text-menu-muted">No output yet</p>
            ) : (
              task.log.map((entry) => <LogLine key={entry.id} entry={entry} />)
            )}
          </div>
        </div>
      </section>
    </article>
  );
}

export function ActivityPane({ open }: { open: boolean }) {
  const tasks = useActivityTasks();
  const headingId = useId();
  return (
    <aside
      aria-labelledby={headingId}
      inert={!open}
      className={`absolute inset-y-2 right-2 z-10 flex
        w-[min(26rem,calc(100%-1rem))] flex-col rounded-xl border
        border-menu-border bg-menu text-menu-foreground shadow-xl
        transition-[translate,visibility] duration-200 ease-out
        motion-reduce:transition-none ${
          open ? "" : "invisible translate-x-[calc(100%+(--spacing(2)))]"
        }`}
    >
      <header
        className="flex h-11 shrink-0 items-center border-b border-menu-border
          px-4"
      >
        <h2 id={headingId} className="text-headline">
          Activity
        </h2>
      </header>
      <div className="flex min-h-0 flex-1 flex-col gap-8 overflow-y-auto p-4">
        {tasks.length === 0 ? (
          <p className="text-footnote text-menu-muted">
            Running tasks and their output show up here.
          </p>
        ) : (
          tasks.map((task) => <TaskView key={task.id} task={task} />)
        )}
      </div>
    </aside>
  );
}
