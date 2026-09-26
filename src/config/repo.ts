import { access, cp, mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";
import { commitPaths, ensureExcluded } from "../engine/git.js";
import { prdProgress, readPrd, type Prd, type PrdProgress } from "../workflow.js";
import { isModelConfig, readGlobalConfig, type ModelConfig } from "./global.js";

export interface RepoConfig {
  tracked: boolean;
  models?: Partial<ModelConfig>;
}

export const logsExcludePattern = "/.lazy-dev/features/*/logs/";

export function stateDir(root: string): string {
  return join(root, ".lazy-dev");
}

export function featureDir(root: string, feature: string): string {
  return join(stateDir(root), "features", feature);
}

export async function readRepoConfig(root: string): Promise<RepoConfig | undefined> {
  try {
    const parsed = JSON.parse(await readFile(join(stateDir(root), "config"), "utf8")) as Partial<RepoConfig>;
    if (typeof parsed.tracked !== "boolean") return undefined;
    return { tracked: parsed.tracked, models: parsed.models };
  } catch {
    return undefined;
  }
}

/** Repo overrides win over global defaults; returns undefined until a full set exists. */
export async function resolveModels(root: string): Promise<ModelConfig | undefined> {
  const [global, repo] = await Promise.all([readGlobalConfig(), readRepoConfig(root)]);
  const merged = { ...global?.models, ...repo?.models };
  return isModelConfig(merged) ? merged : undefined;
}

export interface BootstrapResult {
  commit?: string;
}

export async function bootstrapRepo(root: string, options: { tracked: boolean; commit?: boolean }): Promise<BootstrapResult> {
  const dir = stateDir(root);
  await mkdir(join(dir, "features"), { recursive: true });
  await mkdir(join(dir, "rules", "discovered"), { recursive: true });
  const existing = await readRepoConfig(root);
  const config: RepoConfig = { ...existing, tracked: options.tracked };
  await writeFile(join(dir, "config"), `${JSON.stringify(config, null, 2)}\n`);
  ensureExcluded(root, logsExcludePattern);
  if (!options.tracked) {
    ensureExcluded(root, "/.lazy-dev/");
    return {};
  }
  await writeFile(join(dir, "rules", "discovered", ".gitkeep"), "");
  if (!options.commit) return {};
  return { commit: commitPaths(root, [".lazy-dev"], "chore: initialize lazy-dev") };
}

export interface FeatureSummary {
  name: string;
  description?: string;
  branchName?: string;
  progress?: PrdProgress;
  error?: string;
}

export async function listFeatures(root: string): Promise<string[]> {
  const featuresDir = join(stateDir(root), "features");
  const entries = await readdir(featuresDir, { withFileTypes: true }).catch(() => []);
  const names = await Promise.all(
    entries.filter((entry) => entry.isDirectory()).map(async (entry) => {
      try {
        await access(join(featuresDir, entry.name, "prd.json"), constants.R_OK);
        return entry.name;
      } catch {
        return undefined;
      }
    }),
  );
  return names.filter((name): name is string => Boolean(name)).sort();
}

export async function summarizeFeatures(root: string): Promise<FeatureSummary[]> {
  const names = await listFeatures(root);
  return Promise.all(
    names.map(async (name): Promise<FeatureSummary> => {
      try {
        const prd = await readPrd(join(featureDir(root, name), "prd.json"));
        return { name, description: prd.description, branchName: prd.branchName, progress: prdProgress(prd) };
      } catch (error) {
        return { name, error: error instanceof Error ? error.message : "Unreadable PRD" };
      }
    }),
  );
}

export async function writePrd(path: string, prd: Prd): Promise<void> {
  const tmp = `${path}.tmp`;
  await writeFile(tmp, `${JSON.stringify(prd, null, 2)}\n`);
  await rename(tmp, path);
}

/** Clears runner-owned blocking state so parked stories get another try. */
export async function unblockFeature(root: string, feature: string): Promise<number> {
  const path = join(featureDir(root, feature), "prd.json");
  const prd = await readPrd(path);
  let count = 0;
  for (const story of prd.userStories) {
    if (story.passes === true || (!story.blocked && !story.attempts)) continue;
    story.blocked = false;
    story.attempts = 0;
    count += 1;
  }
  if (count === 0) return 0;
  await writePrd(path, prd);
  const config = await readRepoConfig(root);
  if (config?.tracked) commitPaths(root, [path], `chore: unblock ${feature} stories`);
  return count;
}

export async function copyFeatureTemplate(root: string, installDir: string, name: string): Promise<void> {
  const target = featureDir(root, name);
  await mkdir(target, { recursive: true });
  await cp(join(installDir, "examples", "prd.json"), join(target, "prd.json"));
  await writeFile(join(target, "progress.txt"), "# Progress Log\n\n## Session Log\n\n");
}

export const featureNamePattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
