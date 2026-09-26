import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { EmitEvent, GateName } from "./events.js";

export type PackageManager = "npm" | "pnpm" | "yarn" | "bun";

export const gateNames: readonly GateName[] = ["build", "typecheck", "lint", "test"];
const gateTimeoutMs = 10 * 60 * 1000;

interface PackageJson {
  packageManager?: string;
  scripts?: Record<string, string>;
}

async function readPackageJson(root: string): Promise<PackageJson | undefined> {
  try {
    return JSON.parse(await readFile(join(root, "package.json"), "utf8")) as PackageJson;
  } catch {
    return undefined;
  }
}

export function detectPackageManager(root: string, packageJson?: PackageJson): PackageManager {
  const declared = packageJson?.packageManager?.split("@")[0];
  if (declared === "pnpm" || declared === "yarn" || declared === "bun" || declared === "npm") return declared;
  if (existsSync(join(root, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(join(root, "yarn.lock"))) return "yarn";
  if (existsSync(join(root, "bun.lock")) || existsSync(join(root, "bun.lockb"))) return "bun";
  return "npm";
}

function runGate(root: string, manager: PackageManager, gate: GateName, emit: EmitEvent, signal?: AbortSignal): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn(manager, ["run", gate], {
      cwd: root,
      env: { ...process.env, CI: "1", FORCE_COLOR: "0" },
      stdio: ["ignore", "pipe", "pipe"],
      signal,
    });
    const timer = setTimeout(() => {
      emit({ type: "gate:output", gate, line: `Timed out after ${gateTimeoutMs / 60000} minutes.` });
      child.kill("SIGTERM");
    }, gateTimeoutMs);
    let pending = "";
    const onData = (chunk: Buffer): void => {
      const lines = (pending + chunk.toString("utf8")).split(/\r?\n/);
      pending = lines.pop() ?? "";
      for (const line of lines) emit({ type: "gate:output", gate, line });
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("error", () => {
      clearTimeout(timer);
      resolve(false);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (pending) emit({ type: "gate:output", gate, line: pending });
      resolve(code === 0);
    });
  });
}

/** Runs every configured package.json gate in order; stops at the first failure. */
export async function qualityGate(root: string, emit: EmitEvent, signal?: AbortSignal): Promise<boolean> {
  const packageJson = await readPackageJson(root);
  const manager = detectPackageManager(root, packageJson);
  for (const gate of gateNames) {
    if (!packageJson?.scripts?.[gate]) {
      emit({ type: "gate:result", gate, status: "skipped" });
      continue;
    }
    emit({ type: "gate:start", gate, command: `${manager} run ${gate}` });
    const passed = await runGate(root, manager, gate, emit, signal);
    emit({ type: "gate:result", gate, status: passed ? "passed" : "failed" });
    if (!passed) return false;
  }
  return true;
}
