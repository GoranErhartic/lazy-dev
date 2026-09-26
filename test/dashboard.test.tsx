import { render } from "ink-testing-library";
import { describe, expect, it, vi } from "vitest";
import type { runFeature } from "../src/engine/loop.js";
import { RunDashboard } from "../src/ui/RunDashboard.js";
import type { Prd } from "../src/workflow.js";

const tick = (ms = 30): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const prd: Prd = {
  userStories: [
    { id: "US-001", title: "Add field", priority: 1, passes: false },
    { id: "US-REVIEW", title: "Review", priority: 997, passes: false },
  ],
};

function baseProps(runner: typeof runFeature, overrides: Partial<Parameters<typeof RunDashboard>[0]> = {}) {
  return {
    root: "/nonexistent",
    feature: "demo",
    apiKey: "k",
    installDir: "/x",
    models: { impl: "impl-m", review: "rev-m", review2: "rev2-m" },
    signal: new AbortController().signal,
    onCancelRequest: vi.fn(),
    onExit: vi.fn(),
    runner,
    ...overrides,
  };
}

describe("RunDashboard", () => {
  it("renders the current story, agent activity, gates, and the outcome", async () => {
    let finish: () => void = () => undefined;
    const runner: typeof runFeature = (options) =>
      new Promise((resolve) => {
        const emit = options.emit!;
        emit({ type: "iteration:start", iteration: 1, story: prd.userStories[0], model: "impl-m", completed: 0, total: 2 });
        emit({ type: "agent:text", text: "Implementing the field\n" });
        emit({ type: "agent:tool", name: "edit", status: "running", summary: "src/task.ts" });
        emit({ type: "gate:start", gate: "build", command: "npm run build" });
        emit({ type: "gate:result", gate: "build", status: "passed" });
        const done: Prd = { userStories: prd.userStories.map((story) => ({ ...story, passes: true })) };
        finish = () => resolve({ status: "complete", iterations: 2, prd: done });
      });
    const props = baseProps(runner);

    const view = render(<RunDashboard {...props} />);
    await tick();
    const frame = view.lastFrame() ?? "";
    expect(frame).toContain("US-001");
    expect(frame).toContain("impl-m");
    expect(frame).toContain("Implementing the field");
    expect(frame).toContain("edit src/task.ts");
    expect(frame).toContain("✔ build");

    finish();
    await tick();
    expect(view.lastFrame()).toContain("All stories pass");
    expect(view.lastFrame()).toContain("2/2");
    view.stdin.write("\r");
    await tick();
    expect(props.onExit).toHaveBeenCalled();
    view.unmount();
  });

  it("asks for confirmation before cancelling", async () => {
    const runner: typeof runFeature = () => new Promise(() => undefined);
    const props = baseProps(runner);
    const view = render(<RunDashboard {...props} />);
    await tick();
    view.stdin.write("c");
    await tick();
    expect(view.lastFrame()).toContain("Cancel the run?");
    view.stdin.write("y");
    await tick();
    expect(props.onCancelRequest).toHaveBeenCalledOnce();
    view.unmount();
  });
});
