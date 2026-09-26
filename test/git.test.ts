import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { commitAll, gitPath, installPushBlocker, isDirty, recoverStalePushBlocker } from "../src/engine/git.js";
import { detectPackageManager, qualityGate } from "../src/engine/gates.js";
import type { EngineEvent } from "../src/engine/events.js";
import { makeRepo, sh } from "./helpers.js";

describe("push blocker", () => {
  it("honours core.hooksPath and keeps the blocker out of commits", () => {
    const root = makeRepo();
    sh(root, ["config", "core.hooksPath", ".githooks"]);
    expect(gitPath(root, "hooks")).toBe(join(root, ".githooks"));

    const blocker = installPushBlocker(root);
    expect(blocker.worktreePath).toBe(".githooks/pre-push");
    expect(isDirty(root, [blocker.worktreePath!])).toBe(false);

    writeFileSync(join(root, "change.txt"), "x");
    commitAll(root, "feat: change", [blocker.worktreePath!]);
    expect(sh(root, ["show", "--name-only", "--format=", "HEAD"])).toBe("change.txt");

    blocker.restore();
    expect(existsSync(join(root, ".githooks", "pre-push"))).toBe(false);
  });

  it("recovers a blocker left behind by a crashed session", () => {
    const root = makeRepo();
    const hook = join(root, ".git", "hooks", "pre-push");
    mkdirSync(join(root, ".git", "hooks"), { recursive: true });
    writeFileSync(hook, "#!/bin/sh\necho mine\n");
    installPushBlocker(root);

    expect(recoverStalePushBlocker(root)).toBe(true);
    expect(readFileSync(hook, "utf8")).toContain("echo mine");
  });
});

describe("quality gates", () => {
  it("detects the package manager from packageManager or lockfiles", () => {
    const root = makeRepo();
    expect(detectPackageManager(root)).toBe("npm");
    writeFileSync(join(root, "yarn.lock"), "");
    expect(detectPackageManager(root)).toBe("yarn");
    expect(detectPackageManager(root, { packageManager: "pnpm@9.0.0" })).toBe("pnpm");
  });

  it("captures gate output and stops at the first failure", async () => {
    const root = makeRepo();
    writeFileSync(
      join(root, "package.json"),
      JSON.stringify({ scripts: { build: "echo building", lint: "echo lint-broke && exit 1", test: "echo never" } }),
    );
    const events: EngineEvent[] = [];

    const passed = await qualityGate(root, (event) => events.push(event));

    expect(passed).toBe(false);
    expect(events).toContainEqual({ type: "gate:output", gate: "build", line: "building" });
    expect(events).toContainEqual({ type: "gate:result", gate: "typecheck", status: "skipped" });
    expect(events).toContainEqual({ type: "gate:result", gate: "lint", status: "failed" });
    expect(events.some((event) => event.type === "gate:start" && event.gate === "test")).toBe(false);
  });
});
