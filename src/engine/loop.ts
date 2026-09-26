import { createWriteStream, type WriteStream } from "node:fs";
import { mkdir, readFile, readdir } from "node:fs/promises";
import { join, relative } from "node:path";
import type { ModelConfig } from "../config/global.js";
import { featureDir, logsExcludePattern, stateDir, writePrd } from "../config/repo.js";
import { runLocalAgent, type RunOutcome } from "../sdk-runner.js";
import { buildPrompt, loadRules, nextStory, readPrd, shouldRetry, type Prd, type Story } from "../workflow.js";
import type { EmitEvent, EngineEvent } from "./events.js";
import { qualityGate } from "./gates.js";
import { commitAll, commitMessage, currentBranch, ensureBranch, ensureExcluded, installPushBlocker, isDirty } from "./git.js";
import { keepAwake } from "./keep-awake.js";

export const maxAttempts = 3;
const retryDelaysMs = [5000, 15000, 45000];

export type FeatureRunStatus = "complete" | "blocked" | "max-iterations" | "cancelled";

export interface FeatureRunResult {
  status: FeatureRunStatus;
  iterations: number;
  prd: Prd;
  logFile?: string;
}

export interface FeatureRunOptions {
  root: string;
  feature: string;
  apiKey: string;
  installDir: string;
  models: ModelConfig;
  emit?: EmitEvent;
  signal?: AbortSignal;
  maxIterations?: number;
  timeoutMs?: number;
  /** Test seam: replaces the SDK call. */
  runAgent?: typeof runLocalAgent;
  /** Test seam: replaces the package.json quality gates. */
  runGates?: typeof qualityGate;
}

export function modelForStory(story: Story, models: ModelConfig): string {
  if (story.model) return story.model;
  if (story.id.endsWith("-REVIEW-2")) return models.review2;
  if (story.id.endsWith("-REVIEW")) return models.review;
  return models.impl;
}

async function readOptional(path: string, limit = 8192): Promise<string> {
  try {
    return (await readFile(path, "utf8")).slice(-limit);
  } catch {
    return "";
  }
}

async function discoveredPatterns(root: string): Promise<string> {
  const dir = join(stateDir(root), "rules", "discovered");
  const files = (await readdir(dir).catch(() => [])).filter((file) => file.endsWith(".mdc")).slice(-10);
  const chunks = await Promise.all(files.map((file) => readOptional(join(dir, file))));
  return chunks.filter(Boolean).join("\n\n");
}

function recordAttempt(story: Story, note?: string): void {
  story.attempts = (story.attempts ?? 0) + 1;
  if (story.attempts >= maxAttempts) story.blocked = true;
  if (note) story.notes = story.notes ? `${story.notes}\n${note}` : note;
}

/**
 * Merges the agent-written PRD with runner-owned state: the agent may only flip
 * `passes` (and edit notes) on its assigned story; attempts/blocked and every
 * other story's completion stay as the runner last recorded them.
 */
export function reconcilePrd(previous: Prd, written: Prd | undefined, assignedId: string): Prd {
  const fresh: Prd = written ?? structuredClone(previous);
  const priorById = new Map(previous.userStories.map((story) => [story.id, story]));
  for (const story of fresh.userStories) {
    const prior = priorById.get(story.id);
    if (!prior) continue;
    story.attempts = prior.attempts ?? 0;
    story.blocked = prior.blocked;
    if (story.id !== assignedId) story.passes = prior.passes;
  }
  for (const prior of previous.userStories) {
    if (!fresh.userStories.some((story) => story.id === prior.id)) fresh.userStories.push(structuredClone(prior));
  }
  return fresh;
}

function openLog(dir: string): { stream: WriteStream; path: string } {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const path = join(dir, "logs", `${stamp}.log`);
  return { stream: createWriteStream(path, { flags: "a" }), path };
}

function formatLogLine(event: EngineEvent): string | undefined {
  switch (event.type) {
    case "agent:text":
      return event.text;
    case "agent:tool":
      return event.status === "running" ? `\n[tool] ${event.name}${event.summary ? ` ${event.summary}` : ""}\n` : undefined;
    case "gate:output":
      return `[${event.gate}] ${event.line}\n`;
    case "story:update":
      return `\n[story] ${event.story.id} passes=${event.story.passes} attempts=${event.story.attempts ?? 0}\n`;
    case "iteration:start":
      return `\n\n=== Iteration ${event.iteration}: ${event.story.id} (${event.model}) ===\n`;
    default:
      return `\n[${event.type}] ${JSON.stringify(event)}\n`;
  }
}

async function runWithRetries(
  options: FeatureRunOptions,
  model: string,
  prompt: string,
  emit: EmitEvent,
): Promise<RunOutcome> {
  const runAgent = options.runAgent ?? runLocalAgent;
  for (let attempt = 1; ; attempt += 1) {
    const outcome = await runAgent({
      apiKey: options.apiKey,
      cwd: options.root,
      model,
      prompt,
      timeoutMs: options.timeoutMs ?? 30 * 60 * 1000,
      emit,
      signal: options.signal,
    });
    if (outcome.startup && outcome.message) emit({ type: "warn", message: `Agent failed to start: ${outcome.message}` });
    if (options.signal?.aborted || !shouldRetry(outcome, attempt)) return outcome;
    const delayMs = retryDelaysMs[attempt - 1] ?? retryDelaysMs[retryDelaysMs.length - 1];
    emit({ type: "agent:retry", attempt, delayMs });
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
}

async function runSession(options: FeatureRunOptions, emit: EmitEvent, exclude: string[]): Promise<Omit<FeatureRunResult, "logFile">> {
  const { root, feature } = options;
  const dir = featureDir(root, feature);
  const prdPath = join(dir, "prd.json");
  const progressPath = join(dir, "progress.txt");
  const rules = await loadRules(options.installDir);
  const basePrompt = await readFile(join(options.installDir, "prompt.md"), "utf8");
  const runGates = options.runGates ?? qualityGate;
  const maxIterations = options.maxIterations ?? 20;
  let prd = await readPrd(prdPath);

  for (let iteration = 1; iteration <= maxIterations; iteration += 1) {
    if (options.signal?.aborted) return { status: "cancelled", iterations: iteration - 1, prd };
    prd = await readPrd(prdPath);
    const story = nextStory(prd.userStories);
    if (!story) {
      const complete = prd.userStories.every((candidate) => candidate.passes === true);
      return { status: complete ? "complete" : "blocked", iterations: iteration - 1, prd };
    }
    const model = modelForStory(story, options.models);
    const completed = prd.userStories.filter((candidate) => candidate.passes === true).length;
    emit({ type: "iteration:start", iteration, story, model, completed, total: prd.userStories.length });

    const prompt = buildPrompt({
      basePrompt,
      rules,
      feature,
      stateDir: relative(root, stateDir(root)) || ".lazy-dev",
      branch: currentBranch(root),
      story,
      discovered: await discoveredPatterns(root),
      progress: await readOptional(progressPath, 12000),
    });
    const outcome = await runWithRetries(options, model, prompt, emit);
    if (outcome.startup) {
      throw new Error(`The Cursor agent could not start (${outcome.message ?? "unknown error"}). Run \`lazydev doctor\` to check your setup.`);
    }
    if (options.signal?.aborted) {
      emit({ type: "warn", message: "Run cancelled. Uncommitted agent changes were left in the working tree for review." });
      return { status: "cancelled", iterations: iteration, prd };
    }

    let written: Prd | undefined;
    try {
      written = await readPrd(prdPath);
    } catch {
      emit({ type: "warn", message: "Agent left prd.json unreadable; restoring the runner's copy." });
    }
    prd = reconcilePrd(prd, written, story.id);
    const current = prd.userStories.find((candidate) => candidate.id === story.id) ?? story;

    if (outcome.status !== "finished") {
      current.passes = false;
      recordAttempt(current, `Runner: agent run ended with status '${outcome.status}'.`);
    } else if (current.passes === true) {
      if (!(await runGates(root, emit, options.signal))) {
        current.passes = false;
        recordAttempt(current, "Runner: quality gates failed; see the session log.");
      }
    } else {
      recordAttempt(current);
    }
    await writePrd(prdPath, prd);
    emit({ type: "story:update", prd, story: current });

    const hash = commitAll(root, commitMessage(current, prd), exclude);
    if (hash) emit({ type: "commit", hash, message: commitMessage(current, prd) });
  }
  return { status: "max-iterations", iterations: maxIterations, prd };
}

export async function runFeature(options: FeatureRunOptions): Promise<FeatureRunResult> {
  const { root, feature } = options;
  const dir = featureDir(root, feature);
  if (isDirty(root)) throw new Error("Working tree has uncommitted changes. Commit or stash them before running a feature.");
  ensureExcluded(root, logsExcludePattern);
  await mkdir(join(dir, "logs"), { recursive: true });

  const log = openLog(dir);
  const emit: EmitEvent = (event) => {
    const line = formatLogLine(event);
    if (line) log.stream.write(line);
    options.emit?.(event);
  };

  const prd = await readPrd(join(dir, "prd.json"));
  ensureBranch(root, prd, feature, emit);

  const blocker = installPushBlocker(root);
  const restoreOnExit = (): void => blocker.restore();
  process.once("exit", restoreOnExit);
  const release = keepAwake();
  try {
    const result = await runSession(options, emit, blocker.worktreePath ? [blocker.worktreePath] : []);
    return { ...result, logFile: log.path };
  } finally {
    blocker.restore();
    process.removeListener("exit", restoreOnExit);
    release();
    await new Promise<void>((resolve) => log.stream.end(resolve));
  }
}
