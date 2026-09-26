import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { bootstrapRepo } from "../src/config/repo.js";
import { reconcilePrd, runFeature, type FeatureRunOptions } from "../src/engine/loop.js";
import type { runLocalAgent } from "../src/sdk-runner.js";
import type { Prd } from "../src/workflow.js";
import { makeRepo, sh } from "./helpers.js";

const installDir = process.cwd();
const models = { impl: "impl-model", review: "review-model", review2: "review2-model" };

function prdPath(root: string): string {
  return join(root, ".lazy-dev", "features", "demo", "prd.json");
}

async function setup(stories: Prd["userStories"]): Promise<string> {
  const root = makeRepo();
  await bootstrapRepo(root, { tracked: false });
  mkdirSync(join(root, ".lazy-dev", "features", "demo"), { recursive: true });
  writeFileSync(prdPath(root), JSON.stringify({ branchName: "feature/demo", userStories: stories }));
  return root;
}

function readPrdFile(root: string): Prd {
  return JSON.parse(readFileSync(prdPath(root), "utf8")) as Prd;
}

function assignedId(prompt: string): string {
  return /work EXACTLY one story: (\S+)/.exec(prompt)?.[1] ?? "";
}

function options(root: string, runAgent: typeof runLocalAgent, extra: Partial<FeatureRunOptions> = {}): FeatureRunOptions {
  return { root, feature: "demo", apiKey: "key", installDir, models, runAgent, runGates: async () => true, ...extra };
}

describe("runFeature", () => {
  it("keeps agent-written passes, commits each story, and restores the push hook", async () => {
    const root = await setup([
      { id: "US-001", title: "One", priority: 1, passes: false },
      { id: "US-002", title: "Two", priority: 2, passes: false },
    ]);
    const seenModels: string[] = [];
    const runAgent: typeof runLocalAgent = async (run) => {
      seenModels.push(run.model);
      const id = assignedId(run.prompt);
      const prd = readPrdFile(root);
      prd.userStories.find((story) => story.id === id)!.passes = true;
      writeFileSync(prdPath(root), JSON.stringify(prd));
      writeFileSync(join(root, `${id}.txt`), id);
      return { startup: false, status: "finished" };
    };

    const result = await runFeature(options(root, runAgent));

    expect(result.status).toBe("complete");
    expect(readPrdFile(root).userStories.every((story) => story.passes)).toBe(true);
    expect(sh(root, ["branch", "--show-current"])).toBe("feature/demo");
    expect(sh(root, ["log", "--format=%s", "-n", "2"]).split("\n")).toEqual(["feat: US-002 - Two", "feat: US-001 - One"]);
    expect(existsSync(join(root, ".git", "hooks", "pre-push"))).toBe(false);
    expect(seenModels).toEqual(["impl-model", "impl-model"]);
    expect(result.logFile && existsSync(result.logFile)).toBe(true);
  });

  it("parks stories after repeated failures and reports blocked instead of success", async () => {
    const root = await setup([{ id: "US-001", priority: 1, passes: false }]);
    const runAgent: typeof runLocalAgent = async () => ({ startup: false, status: "finished" });

    const result = await runFeature(options(root, runAgent));

    expect(result.status).toBe("blocked");
    expect(readPrdFile(root).userStories[0]).toMatchObject({ attempts: 3, blocked: true, passes: false });
  });

  it("reverts passes when quality gates fail", async () => {
    const root = await setup([{ id: "US-001", priority: 1, passes: false }]);
    const runAgent: typeof runLocalAgent = async () => {
      const prd = readPrdFile(root);
      prd.userStories[0].passes = true;
      writeFileSync(prdPath(root), JSON.stringify(prd));
      return { startup: false, status: "finished" };
    };

    const result = await runFeature(options(root, runAgent, { runGates: async () => false }));

    expect(result.status).toBe("blocked");
    expect(readPrdFile(root).userStories[0].passes).toBe(false);
  });

  it("stops on abort and restores an existing pre-push hook", async () => {
    const root = await setup([{ id: "US-001", priority: 1, passes: false }]);
    const hook = join(root, ".git", "hooks", "pre-push");
    writeFileSync(hook, "#!/bin/sh\necho original\n", { mode: 0o755 });
    const controller = new AbortController();
    const runAgent: typeof runLocalAgent = async () => {
      expect(readFileSync(hook, "utf8")).toContain("lazy-dev temporary push blocker");
      controller.abort();
      return { startup: false, status: "cancelled" };
    };

    const result = await runFeature(options(root, runAgent, { signal: controller.signal }));

    expect(result.status).toBe("cancelled");
    expect(readFileSync(hook, "utf8")).toContain("echo original");
  });

  it("stops without charging an attempt when the agent cannot start", async () => {
    const root = await setup([{ id: "US-001", priority: 1, passes: false }]);
    const runAgent: typeof runLocalAgent = async () => ({ startup: true, retryable: false, message: "Invalid User API Key" });

    await expect(runFeature(options(root, runAgent))).rejects.toThrow(/could not start \(Invalid User API Key\)/);
    expect(readPrdFile(root).userStories[0].attempts ?? 0).toBe(0);
    expect(existsSync(join(root, ".git", "hooks", "pre-push"))).toBe(false);
  });

  it("refuses to start on a dirty working tree", async () => {
    const root = await setup([{ id: "US-001", priority: 1, passes: false }]);
    writeFileSync(join(root, "README.md"), "changed\n");
    await expect(runFeature(options(root, async () => ({ startup: false, status: "finished" })))).rejects.toThrow(/uncommitted/);
  });
});

describe("reconcilePrd", () => {
  it("only lets the agent complete its assigned story and keeps runner-owned fields", () => {
    const previous: Prd = {
      userStories: [
        { id: "A", priority: 1, passes: false, attempts: 1 },
        { id: "B", priority: 2, passes: false },
      ],
    };
    const written: Prd = {
      userStories: [
        { id: "A", priority: 1, passes: true, attempts: 0, blocked: true, notes: "done" },
        { id: "B", priority: 2, passes: true },
      ],
    };

    const merged = reconcilePrd(previous, written, "A");

    expect(merged.userStories[0]).toMatchObject({ passes: true, attempts: 1, blocked: undefined, notes: "done" });
    expect(merged.userStories[1].passes).toBe(false);
  });

  it("restores stories the agent deleted", () => {
    const previous: Prd = { userStories: [{ id: "A", priority: 1, passes: false }, { id: "B", priority: 2, passes: false }] };
    const merged = reconcilePrd(previous, { userStories: [{ id: "A", priority: 1, passes: true }] }, "A");
    expect(merged.userStories.map((story) => story.id)).toEqual(["A", "B"]);
  });
});
