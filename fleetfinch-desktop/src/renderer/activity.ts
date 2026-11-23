import { useSyncExternalStore } from "react";

export type TaskState = "running" | "waiting" | "done" | "failed";

export type StepState = "pending" | "running" | "waiting" | "done" | "failed";

export type LogKind = "message" | "command" | "output" | "error";

export interface TaskStep {
  id: string;
  label: string;
  state: StepState;
  detail: string | null;
  fraction: number | null;
}

export interface LogEntry {
  id: number;
  kind: LogKind;
  text: string;
}

export interface Task {
  id: string;
  title: string;
  state: TaskState;
  steps: TaskStep[];
  log: LogEntry[];
}

interface Activity {
  open: boolean;
  tasks: Task[];
}

const logLimit = 2000;

let activity: Activity = { open: false, tasks: [] };
let nextLogId = 0;
const listeners = new Set<() => void>();

function update(change: (current: Activity) => Activity): void {
  const next = change(activity);
  if (next === activity) {
    return;
  }
  activity = next;
  for (const listener of listeners) {
    listener();
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getOpen(): boolean {
  return activity.open;
}

function getTasks(): readonly Task[] {
  return activity.tasks;
}

function hasNews(before: Task, after: Task): boolean {
  return (
    after.state !== before.state ||
    after.steps.some((step, index) => {
      const previous = before.steps[index];
      return step.state !== previous?.state || step.detail !== previous.detail;
    })
  );
}

export function useActivityOpen(): boolean {
  return useSyncExternalStore(subscribe, getOpen);
}

export function useActivityTasks(): readonly Task[] {
  return useSyncExternalStore(subscribe, getTasks);
}

export function setActivityOpen(open: boolean): void {
  update((current) => (current.open === open ? current : { ...current, open }));
}

export function startTask({
  id,
  title,
  steps,
}: {
  id: string;
  title: string;
  steps: { id: string; label: string }[];
}): void {
  const task: Task = {
    id,
    title,
    state: "running",
    steps: steps.map((step) => ({
      ...step,
      state: "pending",
      detail: null,
      fraction: null,
    })),
    log: [],
  };
  update((current) => ({
    open: true,
    tasks: [task, ...current.tasks.filter((other) => other.id !== id)],
  }));
}

export function updateTask(id: string, change: (task: Task) => Task): void {
  update((current) => {
    const before = current.tasks.find((task) => task.id === id);
    if (before === undefined) {
      return current;
    }
    const after = change(before);
    return {
      open: current.open || hasNews(before, after),
      tasks: current.tasks.map((task) => (task === before ? after : task)),
    };
  });
}

export function appendTaskLog(
  id: string,
  lines: { kind: LogKind; text: string }[],
): void {
  const entries = lines.map((line) => ({ ...line, id: nextLogId++ }));
  updateTask(id, (task) => ({
    ...task,
    log: [...task.log, ...entries].slice(-logLimit),
  }));
}
