import { useSyncExternalStore } from "react";

export type TaskState = "running" | "waiting" | "done" | "failed";

export const taskStateLabels: Record<TaskState, string> = {
  running: "Running",
  waiting: "Waiting for you",
  done: "Done",
  failed: "Failed",
};

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

export type CommandTarget = "computer" | "device";

export interface CommandRecord {
  id: number;
  text: string;
  target: CommandTarget;
  at: number;
}

interface Activity {
  open: boolean;
  tasks: Task[];
  history: CommandRecord[];
}

const logLimit = 2000;
const historyLimit = 10;

let activity: Activity = { open: false, tasks: [], history: [] };
let nextLogId = 0;
let nextCommandId = 0;
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

function getHistory(): readonly CommandRecord[] {
  return activity.history;
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

export function finishedStep(step: TaskStep): TaskStep {
  return { ...step, state: "done", detail: null, fraction: null };
}

export function settleSteps(
  steps: readonly TaskStep[],
  current: string,
  change: Pick<TaskStep, "state" | "detail" | "fraction">,
): TaskStep[] {
  const index = steps.findIndex((step) => step.id === current);
  return steps.map((step, position) => {
    if (position < index) {
      return finishedStep(step);
    }
    return position === index ? { ...step, ...change } : step;
  });
}

export function useActivityOpen(): boolean {
  return useSyncExternalStore(subscribe, getOpen);
}

export function useActivityTasks(): readonly Task[] {
  return useSyncExternalStore(subscribe, getTasks);
}

export function useCommandHistory(): readonly CommandRecord[] {
  return useSyncExternalStore(subscribe, getHistory);
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
    ...current,
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
      ...current,
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

export function recordCommand(text: string, target: CommandTarget): void {
  const record = { id: nextCommandId++, text, target, at: Date.now() };
  update((current) => ({
    ...current,
    history: [record, ...current.history].slice(0, historyLimit),
  }));
}
