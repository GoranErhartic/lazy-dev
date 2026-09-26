import { describe, expect, it, vi } from "vitest";
import type { EngineEvent } from "../src/engine/events.js";

const send = vi.fn();
const dispose = vi.fn();

vi.mock("@cursor/sdk", () => ({
  Agent: { create: vi.fn(async () => ({ agentId: "agent-1", send, [Symbol.asyncDispose]: dispose })) },
  CursorAgentError: class CursorAgentError extends Error {
    isRetryable = false;
  },
}));

import { runLocalAgent } from "../src/sdk-runner.js";

function fakeRun(events: unknown[], cancel = vi.fn(), wait = vi.fn(async () => ({ status: "finished", result: "done" }))) {
  return {
    id: "run-1",
    supports: () => true,
    cancel,
    async *stream() {
      for (const event of events) yield event;
    },
    wait,
  };
}

describe("runLocalAgent", () => {
  it("emits text and tool events, waits for the terminal result, and disposes the agent", async () => {
    const cancel = vi.fn(async () => undefined);
    send.mockResolvedValueOnce(
      fakeRun(
        [
          { type: "assistant", message: { content: [{ type: "text", text: "working" }] } },
          { type: "tool_call", name: "edit", status: "running", args: { path: "src/a.ts" } },
        ],
        cancel,
      ),
    );
    const events: EngineEvent[] = [];

    const outcome = await runLocalAgent({
      apiKey: "test-key",
      cwd: "/workspace",
      model: "composer-2.5",
      prompt: "Do the work",
      timeoutMs: 1_000,
      emit: (event) => events.push(event),
    });

    expect(outcome).toMatchObject({ startup: false, status: "finished", agentId: "agent-1", runId: "run-1" });
    expect(events).toContainEqual({ type: "agent:text", text: "working" });
    expect(events).toContainEqual({ type: "agent:tool", name: "edit", status: "running", summary: "src/a.ts" });
    expect(dispose).toHaveBeenCalled();
    expect(cancel).not.toHaveBeenCalled();
  });

  it("cancels the run when the signal aborts", async () => {
    const cancel = vi.fn(async () => undefined);
    const controller = new AbortController();
    controller.abort();
    send.mockResolvedValueOnce(fakeRun([], cancel, vi.fn(async () => ({ status: "cancelled" }))));

    const outcome = await runLocalAgent({
      apiKey: "k",
      cwd: "/w",
      model: "m",
      prompt: "p",
      timeoutMs: 1_000,
      signal: controller.signal,
    });

    expect(cancel).toHaveBeenCalled();
    expect(outcome.status).toBe("cancelled");
  });
});
