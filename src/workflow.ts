import { readFile } from "node:fs/promises";
import { join } from "node:path";

export interface Story {
  id: string;
  title?: string;
  description?: string;
  acceptanceCriteria?: string[];
  priority: number;
  passes: boolean;
  blocked?: boolean;
  attempts?: number;
  notes?: string;
  model?: string;
}

export interface Prd {
  project?: string;
  branchName?: string;
  description?: string;
  jiraTaskId?: string;
  userStories: Story[];
}

export interface PromptInput {
  basePrompt: string;
  rules: string;
  feature: string;
  stateDir: string;
  branch: string;
  story: Story;
  discovered?: string;
  progress?: string;
}

export function nextStory(stories: Story[]): Story | undefined {
  return stories
    .filter((story) => story.passes !== true && story.blocked !== true)
    .sort((left, right) => left.priority - right.priority)[0];
}

export function shouldRetry(
  result: { startup: boolean; retryable?: boolean; status?: "finished" | "error" | "cancelled" },
  attempt: number,
): boolean {
  if (attempt >= 3) return false;
  return result.startup ? result.retryable === true : result.status === "error";
}

export function buildPrompt(input: PromptInput): string {
  const featureDir = `${input.stateDir}/features/${input.feature}`;
  return `# Feature Context
- Feature: ${input.feature}
- Workspace/Project Root: current working directory
- Lazy-dev state directory: ${input.stateDir}
- PRD: ${featureDir}/prd.json
- Progress: ${featureDir}/progress.txt
- Review outputs: ${featureDir}/review-1.md, ${featureDir}/review-2.md
- Shared discovered patterns: ${input.stateDir}/rules/discovered/
- Git Branch: ${input.branch}

# Git: Do not run git commands. The runner commits all changes after you finish.

${input.basePrompt}

---

# Injected Protocol

${input.rules}
${input.discovered ? `\n---\n\n## Observed Patterns\n\n${input.discovered}` : ""}
${input.progress ? `\n---\n\n## Recent Progress\n\n${input.progress}` : ""}

---

## Your Assignment

This iteration you will work EXACTLY one story: ${input.story.id} — ${input.story.title ?? ""}. Its full definition (description, acceptance criteria, notes) is in the PRD. Do not start any other story.

When implementation is complete:
- Update PRD (\`passes: true\` when done), \`progress.txt\`, and any \`rules/discovered/\` patterns
- Do not revert source changes that implement ${input.story.id}
- Do not run git commands — the runner will commit after you end your response

End your response when file updates are complete.`;
}

export async function readPrd(path: string): Promise<Prd> {
  const parsed: unknown = JSON.parse(await readFile(path, "utf8"));
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !Array.isArray((parsed as { userStories?: unknown }).userStories)
  ) {
    throw new Error(`Invalid PRD: ${path}`);
  }
  return parsed as Prd;
}

export type FeatureStatus = "ready" | "in-progress" | "blocked" | "done";

export interface PrdProgress {
  done: number;
  total: number;
  blocked: number;
  status: FeatureStatus;
}

export function prdProgress(prd: Prd): PrdProgress {
  const total = prd.userStories.length;
  const done = prd.userStories.filter((story) => story.passes === true).length;
  const blocked = prd.userStories.filter((story) => story.passes !== true && story.blocked === true).length;
  const started = done > 0 || prd.userStories.some((story) => (story.attempts ?? 0) > 0);
  let status: FeatureStatus = "ready";
  if (total > 0 && done === total) status = "done";
  else if (!nextStory(prd.userStories)) status = "blocked";
  else if (started) status = "in-progress";
  return { done, total, blocked, status };
}

export function isReviewStory(id: string): boolean {
  return /-REVIEW(-2)?$/.test(id);
}

export interface PrdValidation {
  errors: string[];
  warnings: string[];
}

export function validatePrd(prd: Prd, options: { fresh?: boolean } = {}): PrdValidation {
  const errors: string[] = [];
  const warnings: string[] = [];
  const stories = prd.userStories;
  if (stories.length === 0) errors.push("PRD has no user stories.");
  const ids = new Set<string>();
  const priorities = new Set<number>();
  for (const story of stories) {
    if (typeof story.id !== "string" || !story.id) {
      errors.push("A story is missing its id.");
      continue;
    }
    if (ids.has(story.id)) errors.push(`Duplicate story id: ${story.id}`);
    ids.add(story.id);
    if (typeof story.priority !== "number") errors.push(`${story.id} has no numeric priority.`);
    else if (priorities.has(story.priority)) errors.push(`Duplicate priority ${story.priority} (${story.id}).`);
    else priorities.add(story.priority);
    if (options.fresh && story.passes === true) errors.push(`${story.id} is already marked as passing.`);
  }
  const has = (pattern: RegExp): boolean => stories.some((story) => pattern.test(story.id ?? ""));
  if (!has(/-REVIEW$/)) warnings.push("No first review story (*-REVIEW).");
  if (!has(/-REVIEW-2$/)) warnings.push("No second review story (*-REVIEW-2).");
  if (!has(/-IMPL(EMENT)?-RECS$/)) warnings.push("No implement-recommendations story (*-IMPL-RECS).");
  if (!prd.branchName) warnings.push("No branchName; the runner will use feature/<name>.");
  return { errors, warnings };
}

export async function loadRules(installDir: string): Promise<string> {
  const names = ["agent-loop.mdc", "task-breakdown.mdc", "quality-gates.mdc", "pattern-discovery.mdc"];
  const contents = await Promise.all(
    names.map(async (name) => `### rules/${name}\n\n${await readFile(join(installDir, "rules", name), "utf8")}`),
  );
  return contents.join("\n\n");
}
