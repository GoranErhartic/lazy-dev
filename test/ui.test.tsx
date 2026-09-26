import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { render } from "ink-testing-library";
import { describe, expect, it, vi } from "vitest";
import { bootstrapRepo } from "../src/config/repo.js";
import { fuzzyFilter } from "../src/config/models.js";
import { Home } from "../src/ui/Home.js";
import { ModelPicker } from "../src/ui/ModelPicker.js";
import { makeRepo } from "./helpers.js";

const down = "\u001B[B";
const enter = "\r";

async function waitFor(check: () => boolean, timeoutMs = 3000): Promise<void> {
  const started = Date.now();
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error("Timed out waiting for UI");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 30));

describe("Home", () => {
  it("lists features with progress and status, and runs the selected one", async () => {
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });
    const dir = join(root, ".lazy-dev", "features", "task-priority");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "prd.json"),
      JSON.stringify({
        description: "Priority levels for tasks",
        userStories: [
          { id: "US-001", priority: 1, passes: true },
          { id: "US-002", priority: 2, passes: false },
        ],
      }),
    );
    const onAction = vi.fn();

    const view = render(<Home root={root} onAction={onAction} />);
    await waitFor(() => view.lastFrame()?.includes("task-priority") ?? false);

    const frame = view.lastFrame() ?? "";
    expect(frame).toContain("New feature PRD");
    expect(frame).toContain("1/2");
    expect(frame).toContain("in progress");
    expect(frame).toContain("● clean");

    await tick();
    view.stdin.write(down);
    await tick();
    view.stdin.write(enter);
    await tick();
    expect(onAction).toHaveBeenCalledWith({ type: "run", feature: "task-priority" });
    view.unmount();
  });

  it("opens the PRD flow from the n shortcut", async () => {
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });
    const onAction = vi.fn();
    const view = render(<Home root={root} onAction={onAction} />);
    await waitFor(() => view.lastFrame()?.includes("No features yet") ?? false);
    await tick();
    view.stdin.write("n");
    await tick();
    expect(onAction).toHaveBeenCalledWith({ type: "new-prd" });
    view.unmount();
  });
});

describe("ModelPicker", () => {
  const models = [
    { id: "composer-2.5", label: "composer-2.5" },
    { id: "gpt-5.6-sol", label: "gpt-5.6-sol" },
    { id: "claude-opus-5", label: "claude-opus-5" },
  ];

  it("fuzzy-filters by subsequence", () => {
    expect(fuzzyFilter(models, "opus").map((model) => model.id)).toEqual(["claude-opus-5"]);
    expect(fuzzyFilter(models, "g56").map((model) => model.id)).toEqual(["gpt-5.6-sol"]);
    expect(fuzzyFilter(models, "")).toHaveLength(3);
  });

  it("selects the filtered match on enter", async () => {
    const onSelect = vi.fn();
    const view = render(<ModelPicker label="Implementation model" models={models} defaultId="composer-2.5" onSelect={onSelect} />);
    for (const char of "opus") {
      view.stdin.write(char);
      await tick();
    }
    expect(view.lastFrame()).not.toContain("gpt-5.6-sol");
    view.stdin.write(enter);
    await tick();
    expect(onSelect).toHaveBeenCalledWith("claude-opus-5");
    view.unmount();
  });
});
