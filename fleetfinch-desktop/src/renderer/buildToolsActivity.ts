import {
  type BuildToolsCheck,
  buildToolsCheckSummary,
  buildToolsFindings,
  type BuildToolsLogLine,
  type BuildToolsProgress,
  type BuildToolsSetup,
  type BuildToolStep,
  buildToolLabels,
  buildToolSteps,
} from "@/buildTools.ts";
import {
  appendTaskLog,
  recordCommand,
  startTask,
  type Task,
  type TaskStep,
  updateTask,
} from "@/renderer/activity.ts";

export type BuildToolsOutcome =
  BuildToolsSetup | { state: "error"; message: string };

export type BuildToolsCheckOutcome =
  BuildToolsCheck | { state: "error"; message: string };

const taskId = "build-tools";

function finished(step: TaskStep): TaskStep {
  return { ...step, state: "done", detail: null, fraction: null };
}

function settle(
  steps: readonly TaskStep[],
  current: string,
  change: Pick<TaskStep, "state" | "detail" | "fraction">,
): TaskStep[] {
  const index = steps.findIndex((step) => step.id === current);
  return steps.map((step, position) => {
    if (position < index) {
      return finished(step);
    }
    return position === index ? { ...step, ...change } : step;
  });
}

function runningStep(task: Task): string {
  return (
    task.steps.find((step) => step.state === "running")?.id ?? buildToolSteps[0]
  );
}

function showProgress({ step, message, fraction }: BuildToolsProgress): void {
  updateTask(taskId, (task) => ({
    ...task,
    steps: settle(task.steps, step, {
      state: "running",
      detail: message,
      fraction,
    }),
  }));
}

function showLog(line: BuildToolsLogLine): void {
  appendTaskLog(taskId, [line]);
  if (line.kind === "command") {
    recordCommand(line.text, "computer");
  }
}

function fail(
  step: BuildToolStep | null,
  message: string,
  logged: string,
): void {
  updateTask(taskId, (task) => ({
    ...task,
    state: "failed",
    steps: settle(task.steps, step ?? runningStep(task), {
      state: "failed",
      detail: message,
      fraction: null,
    }),
  }));
  appendTaskLog(taskId, [{ kind: "error", text: logged }]);
}

window.bridge.onBuildToolsProgress(showProgress);
window.bridge.onBuildToolsLog(showLog);

export function startBuildToolsTask(title: string): void {
  startTask({
    id: taskId,
    title,
    steps: buildToolSteps.map((step) => ({
      id: step,
      label: buildToolLabels[step],
    })),
  });
}

export function finishBuildToolsTask(outcome: BuildToolsOutcome): void {
  switch (outcome.state) {
    case "ready":
      updateTask(taskId, (task) => ({
        ...task,
        state: "done",
        steps: task.steps.map(finished),
      }));
      appendTaskLog(taskId, [
        { kind: "message", text: "Every build tool is ready" },
      ]);
      return;
    case "password": {
      const packages = outcome.packages.join(", ");
      updateTask(taskId, (task) => ({
        ...task,
        state: "waiting",
        steps: settle(task.steps, "system", {
          state: "waiting",
          detail: `Enter the password in Computer Info to install ${packages}`,
          fraction: null,
        }),
      }));
      appendTaskLog(taskId, [
        {
          kind: "message",
          text:
            outcome.message ?? `Waiting for a password to install ${packages}`,
        },
      ]);
      return;
    }
    case "failed":
      fail(
        outcome.step,
        outcome.message,
        `${buildToolLabels[outcome.step]}: ${outcome.message}`,
      );
      return;
    case "error":
      fail(null, outcome.message, outcome.message);
  }
}

export function finishBuildToolsCheck(outcome: BuildToolsCheckOutcome): void {
  if (outcome.state === "error") {
    fail(null, outcome.message, outcome.message);
    return;
  }
  if (outcome.state !== "checked") {
    fail(
      outcome.step,
      outcome.message,
      `${buildToolLabels[outcome.step]}: ${outcome.message}`,
    );
    return;
  }
  const found = buildToolsFindings(outcome.updates, outcome.status);
  const findings = new Map<string, string>([
    ...found.unready.map((step) => [step, "Needs setting up"] as const),
    ...found.outdated.map((step) => [step, "Update available"] as const),
  ]);
  updateTask(taskId, (task) => ({
    ...task,
    state: "done",
    steps: task.steps.map((step) => ({
      ...finished(step),
      detail: findings.get(step.id) ?? null,
    })),
  }));
  appendTaskLog(
    taskId,
    buildToolsCheckSummary(found).map((text) => ({ kind: "message", text })),
  );
}
