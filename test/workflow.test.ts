import { describe, expect, it } from "vitest";
import { buildPrompt, nextStory, prdProgress, shouldRetry, validatePrd } from "../src/workflow.js";

describe("workflow", () => {
  it("selects the lowest-priority incomplete, unblocked story", () => {
    expect(
      nextStory([
        { id: "US-2", priority: 2, passes: false },
        { id: "US-1", priority: 1, passes: false, blocked: true },
        { id: "US-3", priority: 3, passes: true }
      ])
    ).toEqual({ id: "US-2", priority: 2, passes: false });
  });

  it("builds an assigned-story prompt with durable context", () => {
    const prompt = buildPrompt({
      basePrompt: "Act autonomously.",
      rules: "Rule text",
      feature: "demo",
      stateDir: ".lazy-dev",
      branch: "feature/demo",
      story: { id: "US-1", title: "Add feature", priority: 1, passes: false }
    });

    expect(prompt).toContain("US-1 — Add feature");
    expect(prompt).toContain("Act autonomously.");
    expect(prompt).toContain("Rule text");
    expect(prompt).toContain(".lazy-dev/features/demo/prd.json");
  });

  it("validates PRDs for duplicates, fresh state, and missing review stories", () => {
    const result = validatePrd(
      {
        userStories: [
          { id: "US-001", priority: 1, passes: true },
          { id: "US-001", priority: 1, passes: false },
        ],
      },
      { fresh: true },
    );
    expect(result.errors).toEqual(
      expect.arrayContaining(["Duplicate story id: US-001", "Duplicate priority 1 (US-001).", "US-001 is already marked as passing."]),
    );
    expect(result.errors).toHaveLength(3);
    expect(result.warnings).toHaveLength(4);
  });

  it("derives feature status from story state", () => {
    expect(prdProgress({ userStories: [{ id: "A", priority: 1, passes: false }] }).status).toBe("ready");
    expect(prdProgress({ userStories: [{ id: "A", priority: 1, passes: false, attempts: 1 }] }).status).toBe("in-progress");
    expect(prdProgress({ userStories: [{ id: "A", priority: 1, passes: false, blocked: true }] })).toMatchObject({ status: "blocked", blocked: 1 });
    expect(prdProgress({ userStories: [{ id: "A", priority: 1, passes: true }] })).toMatchObject({ status: "done", done: 1, total: 1 });
  });

  it("retries retryable runtime failures but not configuration failures", () => {
    expect(shouldRetry({ startup: true, retryable: true }, 1)).toBe(true);
    expect(shouldRetry({ startup: true, retryable: false }, 1)).toBe(false);
    expect(shouldRetry({ startup: false, status: "error" }, 2)).toBe(true);
    expect(shouldRetry({ startup: false, status: "finished" }, 1)).toBe(false);
  });
});
