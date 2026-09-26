import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, sep } from "node:path";
import type { Prd, Story } from "../workflow.js";
import type { EmitEvent } from "./events.js";

export function git(root: string, args: string[]): string {
  return execFileSync("git", ["-C", root, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function gitSucceeds(root: string, args: string[]): boolean {
  return spawnSync("git", ["-C", root, ...args], { stdio: "ignore" }).status === 0;
}

export function projectRoot(cwd = process.cwd()): string {
  try {
    return git(cwd, ["rev-parse", "--show-toplevel"]);
  } catch {
    throw new Error("lazydev must run inside a git repository.");
  }
}

export function tryProjectRoot(cwd = process.cwd()): string | undefined {
  try {
    return projectRoot(cwd);
  } catch {
    return undefined;
  }
}

/** Resolves a path inside the git dir, honouring worktrees and `core.hooksPath`. */
export function gitPath(root: string, name: string): string {
  const resolved = git(root, ["rev-parse", "--git-path", name]);
  return isAbsolute(resolved) ? resolved : join(root, resolved);
}

function changedPaths(root: string): string[] {
  const entries = execFileSync("git", ["-C", root, "status", "--porcelain", "-z", "--untracked-files=all"], { encoding: "utf8" }).split("\0");
  const paths: string[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    if (!entry) continue;
    paths.push(entry.slice(3));
    // Renames and copies are followed by their original path as a separate entry.
    if (/^[RC]|^.[RC]/.test(entry)) index += 1;
  }
  return paths;
}

export function isDirty(root: string, ignore: readonly string[] = []): boolean {
  return changedPaths(root).some((path) => !ignore.includes(path));
}

export function currentBranch(root: string): string {
  return git(root, ["branch", "--show-current"]);
}

export function mainBranch(root: string): string | undefined {
  return ["main", "master"].find((candidate) => gitSucceeds(root, ["show-ref", "--verify", "--quiet", `refs/heads/${candidate}`]));
}

export function ensureBranch(root: string, prd: Prd, feature: string, emit: EmitEvent): string {
  const current = currentBranch(root);
  const main = mainBranch(root);
  const target = prd.branchName || `feature/${feature}`;
  if (current === target) return current;
  if (current === "" || current === main) {
    if (!gitSucceeds(root, ["check-ref-format", "--branch", target])) {
      throw new Error(`Invalid branchName in PRD: '${target}'.`);
    }
    const exists = gitSucceeds(root, ["show-ref", "--verify", "--quiet", `refs/heads/${target}`]);
    git(root, exists ? ["checkout", target] : ["checkout", "-b", target]);
    emit({ type: "branch", branch: target, created: !exists });
    return target;
  }
  emit({ type: "warn", message: `On branch '${current}', but the PRD expects '${target}'. Continuing on '${current}'.` });
  return current;
}

export function commitMessage(story: Story, prd: Prd): string {
  const prefix = story.id.includes("-REVIEW") ? "chore" : "feat";
  const title = story.title ?? story.id;
  const scope = prd.jiraTaskId ? `(${prd.jiraTaskId}) ${title}` : `${story.id} - ${title}`;
  return `${prefix}: ${scope}`;
}

export function commitAll(root: string, message: string, exclude: readonly string[] = []): string | undefined {
  if (!isDirty(root, exclude)) return undefined;
  git(root, ["add", "-A", "--", ".", ...exclude.map((path) => `:(exclude)${path}`)]);
  if (gitSucceeds(root, ["diff", "--cached", "--quiet"])) return undefined;
  git(root, ["commit", "-m", message]);
  return git(root, ["rev-parse", "--short", "HEAD"]);
}

export function commitPaths(root: string, paths: string[], message: string): string | undefined {
  git(root, ["add", "--", ...paths]);
  if (gitSucceeds(root, ["diff", "--cached", "--quiet", "--", ...paths])) return undefined;
  git(root, ["commit", "-m", message, "--", ...paths]);
  return git(root, ["rev-parse", "--short", "HEAD"]);
}

/** Appends `pattern` to `.git/info/exclude` (shared across worktrees) if missing. */
export function ensureExcluded(root: string, pattern: string): void {
  const excludePath = gitPath(root, "info/exclude");
  const previous = existsSync(excludePath) ? readFileSync(excludePath, "utf8") : "";
  if (previous.split(/\r?\n/).includes(pattern)) return;
  mkdirSync(dirname(excludePath), { recursive: true });
  const prefix = previous === "" || previous.endsWith("\n") ? previous : `${previous}\n`;
  writeFileSync(excludePath, `${prefix}${pattern}\n`);
}

const blockerMarker = "# lazy-dev temporary push blocker";
const blockerScript = `#!/bin/sh\n${blockerMarker}\nprintf '%s\\n' 'lazy-dev blocks git push during an active feature run.' >&2\nexit 1\n`;

export interface PushBlocker {
  /** Path of the hook relative to the repo root when it lives inside the worktree. */
  worktreePath?: string;
  restore: () => void;
}

/** Removes a blocker left behind by a crashed session, restoring any backed-up hook. */
export function recoverStalePushBlocker(root: string): boolean {
  const hookPath = join(gitPath(root, "hooks"), "pre-push");
  const backupPath = gitPath(root, "lazy-dev-pre-push.backup");
  if (!existsSync(hookPath) || !readFileSync(hookPath, "utf8").includes(blockerMarker)) return false;
  if (existsSync(backupPath)) {
    writeFileSync(hookPath, readFileSync(backupPath), { mode: 0o755 });
    rmSync(backupPath, { force: true });
  } else {
    rmSync(hookPath, { force: true });
  }
  return true;
}

export function installPushBlocker(root: string): PushBlocker {
  recoverStalePushBlocker(root);
  const hooksDir = gitPath(root, "hooks");
  const hookPath = join(hooksDir, "pre-push");
  const backupPath = gitPath(root, "lazy-dev-pre-push.backup");
  const existing = existsSync(hookPath) ? readFileSync(hookPath) : undefined;
  if (existing) writeFileSync(backupPath, existing);
  mkdirSync(hooksDir, { recursive: true });
  writeFileSync(hookPath, blockerScript, { mode: 0o755 });

  const rel = relative(root, hookPath);
  const insideWorktree = !rel.startsWith("..") && !isAbsolute(rel);
  let restored = false;
  const restore = (): void => {
    if (restored) return;
    restored = true;
    if (existing) writeFileSync(hookPath, existing, { mode: 0o755 });
    else rmSync(hookPath, { force: true });
    rmSync(backupPath, { force: true });
  };
  return { worktreePath: insideWorktree ? rel.split(sep).join("/") : undefined, restore };
}
