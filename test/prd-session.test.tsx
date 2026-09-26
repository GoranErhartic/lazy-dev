import type { AgentOptions, SDKCustomTool } from "@cursor/sdk";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { render } from "ink-testing-library";
import { describe, expect, it, vi } from "vitest";
import { bootstrapRepo } from "../src/config/repo.js";
import { buildPrdPrompt, PrdSession, stripFrontmatter, type PrdSessionOptions } from "../src/prd/session.js";
import { PrdChat } from "../src/ui/PrdChat.js";
import { makeRepo } from "./helpers.js";

const tick = (ms = 30): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(check: () => boolean, timeoutMs = 3000): Promise<void> {
  const started = Date.now();
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error("Timed out waiting");
    await tick(20);
  }
}

const validPrd = {
  branchName: "feature/task-priority",
  description: "Priority levels",
  userStories: [
    { id: "US-001", title: "Add priority field", priority: 1, passes: false, attempts: 0 },
    { id: "US-REVIEW", title: "Review", priority: 997, passes: false, attempts: 0 },
    { id: "US-REVIEW-2", title: "Review 2", priority: 998, passes: false, attempts: 0 },
    { id: "US-IMPL-RECS", title: "Implement recs", priority: 999, passes: false, attempts: 0 },
  ],
};

/** Fake agent whose first turn asks one question through ask_user, then writes the PRD. */
function scriptedAgent(root: string, feature: string) {
  const prompts: string[] = [];
  let tools: Record<string, SDKCustomTool> = {};
  const answers: unknown[] = [];
  const create = vi.fn(async (options: AgentOptions) => {
    tools = options.local?.customTools ?? {};
    return {
      agentId: "agent-prd",
      send: vi.fn(async (message: string) => {
        prompts.push(message);
        return {
          id: `run-${prompts.length}`,
          supports: () => true,
          cancel: vi.fn(async () => undefined),
          async *stream() {
            yield { type: "assistant", message: { content: [{ type: "text", text: "Let me clarify scope.\n" }] } };
            answers.push(await tools.ask_user.execute({ question: "Which priority levels?", options: ["High/Low", "High/Medium/Low"] }, {}));
            writeFileSync(join(root, ".lazy-dev", "features", feature, "prd.json"), JSON.stringify(validPrd));
          },
          wait: vi.fn(async () => ({ status: "finished" })),
        };
      }),
      [Symbol.asyncDispose]: vi.fn(async () => undefined),
    };
  });
  return { create: create as unknown as NonNullable<PrdSessionOptions["createAgent"]>, prompts, answers };
}

describe("PRD prompt", () => {
  it("strips both frontmatter blocks and pins the session contract", () => {
    const skill = stripFrontmatter("---\nname: x\n---\n\n---\ntitle: y\n---\n\nBody text");
    expect(skill).toBe("Body text");
    const prompt = buildPrdPrompt(skill, { feature: "demo", featurePath: ".lazy-dev/features/demo", tracked: false });
    expect(prompt).toContain(".lazy-dev/features/demo/prd.json");
    expect(prompt).toContain("`ask_user` tool");
    expect(prompt).toContain("Body text");
  });
});

describe("PrdSession", () => {
  it("routes ask_user to the host, inlines the skill, and validates the written PRD", async () => {
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });
    const agent = scriptedAgent(root, "task-priority");
    const askUser = vi.fn(async () => "High/Medium/Low");

    const session = new PrdSession({
      apiKey: "k",
      root,
      installDir: process.cwd(),
      model: "m",
      feature: "task-priority",
      tracked: false,
      emit: () => undefined,
      askUser,
      createAgent: agent.create,
    });
    const turn = await session.start();
    await session.close();

    expect(askUser).toHaveBeenCalledWith({ question: "Which priority levels?", options: ["High/Low", "High/Medium/Low"], allowOther: true });
    expect(agent.answers).toEqual(["High/Medium/Low"]);
    expect(agent.prompts[0]).toContain("PHASE 1: Gather Requirements");
    expect(turn.status).toBe("finished");
    expect(turn.validation).toEqual({ errors: [], warnings: [] });
  });
});

describe("PrdChat", () => {
  it("renders agent questions as options and offers to implement the finished PRD", async () => {
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });
    const agent = scriptedAgent(root, "task-priority");
    const onDone = vi.fn();

    const view = render(
      <PrdChat
        root={root}
        apiKey="k"
        installDir={process.cwd()}
        model="m"
        tracked={false}
        signal={new AbortController().signal}
        onDone={onDone}
        createAgent={agent.create}
      />,
    );
    await tick();
    for (const char of "task-priority") view.stdin.write(char);
    await tick();
    view.stdin.write("\r");
    await waitFor(() => view.lastFrame()?.includes("What should this feature do?") ?? false);
    await tick(50);
    view.stdin.write("\r");

    await waitFor(() => view.lastFrame()?.includes("Which priority levels?") ?? false);
    expect(view.lastFrame()).toContain("High/Medium/Low");
    expect(view.lastFrame()).toContain("Other (type your own answer)");
    await tick(50);
    view.stdin.write("\u001B[B");
    await tick();
    view.stdin.write("\r");

    await waitFor(() => view.lastFrame()?.includes("PRD ready") ?? false);
    expect(agent.answers).toEqual(["High/Medium/Low"]);
    expect(view.lastFrame()).toContain("US-IMPL-RECS");
    await tick(50);
    view.stdin.write("\r");
    await tick();
    expect(onDone).toHaveBeenCalledWith({ type: "run", feature: "task-priority" });
    view.unmount();
  });
});
