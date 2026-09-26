#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { render } from "ink";
import { runDoctor, type Check } from "./config/doctor.js";
import { configDir, credentialsFile, globalConfigFile, maskKey, readGlobalConfig, requireApiKey, resolveApiKey } from "./config/global.js";
import { copyFeatureTemplate, featureDir, featureNamePattern, readRepoConfig, resolveModels } from "./config/repo.js";
import { projectRoot, tryProjectRoot } from "./engine/git.js";
import { runFeature, type FeatureRunStatus } from "./engine/loop.js";
import { installDir } from "./paths.js";
import { paint, plainPrinter } from "./plain.js";
import { App, type AppCommand, type AppExit } from "./ui/App.js";

// The SDK's local store uses node:sqlite, which warns on every run in Node 22.
process.removeAllListeners("warning");
process.on("warning", (warning) => {
  if (warning.name !== "ExperimentalWarning") process.stderr.write(`${warning.name}: ${warning.message}\n`);
});

const usage = `${paint("bold", "lazydev")}: PRD-driven Cursor agent loop

${paint("bold", "Usage")}
  lazydev                    Open the TUI in the current repo (sets the repo up on first run)
  lazydev init               One-time global setup: API key, default models, health check
  lazydev run <feature>      Implement a feature (use --no-tui for CI / plain logs)
  lazydev create <feature>   Scaffold a PRD from the template for manual editing
  lazydev doctor             Check installation, credentials, and repo state
  lazydev config             Show resolved configuration

${paint("bold", "Options")}
  --no-tui                   Plain line output instead of the dashboard
  --max-iterations <n>       Iteration cap for run (default 20)
  -h, --help                 Show help
  -v, --version              Show version
`;

const exitCodes: Record<FeatureRunStatus, number> = { complete: 0, blocked: 3, "max-iterations": 4, cancelled: 130 };

function version(): string {
  return (JSON.parse(readFileSync(join(installDir, "package.json"), "utf8")) as { version: string }).version;
}

function requireTty(command: string): void {
  if (process.stdin.isTTY && process.stdout.isTTY) return;
  throw new Error(`\`${["lazydev", command].filter(Boolean).join(" ")}\` is interactive and needs a terminal. For CI use \`lazydev run <feature> --no-tui\`.`);
}

function openEditor(path: string): void {
  const editor = process.env.VISUAL || process.env.EDITOR || "vi";
  const quoted = `'${path.replace(/'/g, "'\\''")}'`;
  spawnSync(`${editor} ${quoted}`, { stdio: "inherit", shell: true });
}

async function runTui(command: AppCommand): Promise<void> {
  requireTty(command.type === "main" ? "" : command.type);
  // Exit handlers (push-blocker restore) run on process.exit.
  process.once("SIGTERM", () => process.exit(143));
  let flash: { tone: "info"; text: string } | undefined;
  for (;;) {
    let result: AppExit = { type: "quit" };
    const instance = render(<App command={command} installDir={installDir} initialFlash={flash} onExit={(exit) => (result = exit)} />, {
      exitOnCtrlC: false,
    });
    await instance.waitUntilExit();
    const exit = result as AppExit;
    if (exit.type !== "edit") return;
    openEditor(join(featureDir(exit.root, exit.feature), "prd.json"));
    flash = { tone: "info", text: `Closed editor for ${exit.feature}.` };
  }
}

async function runPlain(feature: string, maxIterations?: number): Promise<void> {
  const root = projectRoot();
  if (!(await readRepoConfig(root))) throw new Error("This repo is not set up yet. Run `lazydev` here first.");
  const models = await resolveModels(root);
  if (!models) throw new Error("No models configured. Run `lazydev init`.");
  const global = await readGlobalConfig();
  const controller = new AbortController();
  let interrupts = 0;
  const onSignal = (): void => {
    interrupts += 1;
    if (interrupts > 1) process.exit(130);
    process.stderr.write(paint("yellow", "\nCancelling… press ctrl+c again to force quit.\n"));
    controller.abort();
  };
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  try {
    const result = await runFeature({
      root,
      feature,
      apiKey: await requireApiKey(),
      installDir,
      models,
      emit: plainPrinter(),
      signal: controller.signal,
      maxIterations: maxIterations ?? global?.maxIterations,
      timeoutMs: global?.timeoutMinutes ? global.timeoutMinutes * 60_000 : undefined,
    });
    const done = result.prd.userStories.filter((story) => story.passes).length;
    process.stdout.write(`\n${paint("bold", `Result: ${result.status}`)} (${done}/${result.prd.userStories.length} stories)\n`);
    if (result.logFile) process.stdout.write(paint("gray", `Session log: ${result.logFile}\n`));
    process.exitCode = exitCodes[result.status];
  } finally {
    process.removeListener("SIGINT", onSignal);
    process.removeListener("SIGTERM", onSignal);
  }
}

function printChecks(checks: Check[]): void {
  const icon = { ok: paint("green", "✔"), warn: paint("yellow", "⚠"), error: paint("red", "✖") };
  for (const check of checks) process.stdout.write(`${icon[check.level]} ${check.name.padEnd(18)} ${check.detail}\n`);
  if (checks.some((check) => check.level === "error")) process.exitCode = 1;
}

async function printConfig(): Promise<void> {
  const [key, global] = await Promise.all([resolveApiKey(), readGlobalConfig()]);
  const root = tryProjectRoot();
  const repo = root ? await readRepoConfig(root) : undefined;
  const models = root ? await resolveModels(root) : global?.models;
  const rows: Array<[string, string]> = [
    ["config dir", configDir()],
    ["global config", globalConfigFile()],
    ["credentials", credentialsFile()],
    ["api key", key ? `${maskKey(key.key)} (${key.source === "env" ? "CURSOR_API_KEY" : "stored"})` : "not set"],
    ["install dir", installDir],
    ["repo", root ? `${root}${repo ? ` (${repo.tracked ? "tracked" : "local-only"})` : " (not set up)"}` : "not in a git repo"],
    ["impl model", models?.impl ?? "–"],
    ["review model", models?.review ?? "–"],
    ["review-2 model", models?.review2 ?? "–"],
  ];
  for (const [label, value] of rows) process.stdout.write(`${paint("gray", label.padEnd(16))} ${value}\n`);
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      help: { type: "boolean", short: "h" },
      version: { type: "boolean", short: "v" },
      "no-tui": { type: "boolean" },
      "max-iterations": { type: "string" },
      offline: { type: "boolean" },
    },
  });
  const [command, argument] = positionals;
  if (values.help) return void process.stdout.write(usage);
  if (values.version) return void process.stdout.write(`${version()}\n`);
  const maxIterations = values["max-iterations"] ? Number.parseInt(values["max-iterations"], 10) : undefined;
  if (maxIterations !== undefined && (!Number.isInteger(maxIterations) || maxIterations < 1)) throw new Error("--max-iterations must be a positive integer.");

  switch (command) {
    case undefined:
      return runTui({ type: "main" });
    case "init":
      return runTui({ type: "init" });
    case "run": {
      if (!argument) throw new Error("Usage: lazydev run <feature>");
      const plain = values["no-tui"] || !process.stdout.isTTY || !process.stdin.isTTY;
      if (plain) return runPlain(argument, maxIterations);
      return runTui({ type: "run", feature: argument, maxIterations });
    }
    case "create": {
      if (!argument || !featureNamePattern.test(argument)) throw new Error("Usage: lazydev create <feature-name> (kebab-case)");
      await copyFeatureTemplate(projectRoot(), installDir, argument);
      process.stdout.write(`Created ${join(".lazy-dev", "features", argument, "prd.json")}. Edit it, then run \`lazydev\`.\n`);
      return;
    }
    case "doctor":
      return printChecks(await runDoctor({ installDir, online: !values.offline }));
    case "config":
      return printConfig();
    default:
      throw new Error(`Unknown command: ${command}. See \`lazydev --help\`.`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`${paint("red", "Error:")} ${error instanceof Error ? error.message : "Unknown error"}\n`);
  process.exitCode = 1;
});
