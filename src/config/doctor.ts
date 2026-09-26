import { execFileSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { delimiter, join } from "node:path";
import { credentialsFile, maskKey, readGlobalConfig, resolveApiKey } from "./global.js";
import { fetchModels } from "./models.js";
import { readRepoConfig, resolveModels } from "./repo.js";
import { tryProjectRoot } from "../engine/git.js";

export type CheckLevel = "ok" | "warn" | "error";

export interface Check {
  name: string;
  level: CheckLevel;
  detail: string;
}

const requiredAssets = [
  "prompt.md",
  "rules/agent-loop.mdc",
  "rules/task-breakdown.mdc",
  "rules/quality-gates.mdc",
  "rules/pattern-discovery.mdc",
  "skills/generate-prd/SKILL.md",
  "examples/prd.json",
];

function nodeCheck(): Check {
  const [major, minor] = process.versions.node.split(".").map(Number);
  const ok = major > 22 || (major === 22 && minor >= 13);
  return { name: "Node.js", level: ok ? "ok" : "error", detail: ok ? `v${process.versions.node}` : `v${process.versions.node} (22.13+ required)` };
}

function gitCheck(): Check {
  try {
    const version = execFileSync("git", ["--version"], { encoding: "utf8" }).trim();
    return { name: "git", level: "ok", detail: version };
  } catch {
    return { name: "git", level: "error", detail: "git not found on PATH" };
  }
}

function pathCheck(): Check {
  const dirs = (process.env.PATH ?? "").split(delimiter);
  const found = dirs.find((dir) => dir && existsSync(join(dir, "lazydev")));
  return found
    ? { name: "CLI on PATH", level: "ok", detail: join(found, "lazydev") }
    : { name: "CLI on PATH", level: "warn", detail: "lazydev not on PATH. Add ~/.local/bin: export PATH=\"$HOME/.local/bin:$PATH\"" };
}

function assetsCheck(installDir: string): Check {
  const missing = requiredAssets.filter((asset) => !existsSync(join(installDir, asset)));
  return missing.length === 0
    ? { name: "Toolkit assets", level: "ok", detail: installDir }
    : { name: "Toolkit assets", level: "error", detail: `Missing in ${installDir}: ${missing.join(", ")}. Re-run install.sh.` };
}

function credentialsPermissionCheck(): Check | undefined {
  const file = credentialsFile();
  if (!existsSync(file)) return undefined;
  const mode = statSync(file).mode & 0o777;
  return mode & 0o077
    ? { name: "Credentials file", level: "warn", detail: `${file} is mode ${mode.toString(8)}; run chmod 600` }
    : { name: "Credentials file", level: "ok", detail: `${file} (600)` };
}

export async function runDoctor(options: { installDir: string; online?: boolean; cwd?: string }): Promise<Check[]> {
  const checks: Check[] = [nodeCheck(), gitCheck(), pathCheck(), assetsCheck(options.installDir)];
  const key = await resolveApiKey();
  if (!key) {
    checks.push({ name: "API key", level: "error", detail: "Missing. Run `lazydev init` or export CURSOR_API_KEY." });
  } else {
    const source = key.source === "env" ? "CURSOR_API_KEY" : "stored credentials";
    checks.push({ name: "API key", level: "ok", detail: `${maskKey(key.key)} from ${source}` });
    if (options.online) {
      try {
        const models = await fetchModels(key.key);
        checks.push({ name: "Cursor API", level: models.length ? "ok" : "error", detail: `${models.length} models available` });
      } catch (error) {
        checks.push({ name: "Cursor API", level: "error", detail: error instanceof Error ? error.message : "Request failed" });
      }
    }
  }
  const permissions = credentialsPermissionCheck();
  if (permissions) checks.push(permissions);
  const global = await readGlobalConfig();
  checks.push(
    global
      ? { name: "Default models", level: "ok", detail: `${global.models.impl} / ${global.models.review} / ${global.models.review2}` }
      : { name: "Default models", level: "error", detail: "Not configured. Run `lazydev init`." },
  );
  const root = tryProjectRoot(options.cwd);
  if (root) {
    const repo = await readRepoConfig(root);
    const models = await resolveModels(root);
    checks.push({
      name: "This repo",
      level: repo && models ? "ok" : "warn",
      detail: repo ? `${root} (${repo.tracked ? "tracked" : "local-only"})` : `${root} is not set up yet; run lazydev here`,
    });
  }
  return checks;
}
