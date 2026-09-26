import type { Prd, Story } from "../workflow.js";

export type GateName = "build" | "typecheck" | "lint" | "test";
export type GateStatus = "passed" | "failed" | "skipped";

export type EngineEvent =
  | { type: "info"; message: string }
  | { type: "warn"; message: string }
  | { type: "branch"; branch: string; created: boolean }
  | { type: "iteration:start"; iteration: number; story: Story; model: string; completed: number; total: number }
  | { type: "agent:start"; agentId: string; runId: string }
  | { type: "agent:text"; text: string }
  | { type: "agent:tool"; name: string; status: "running" | "completed" | "error"; summary?: string }
  | { type: "agent:retry"; attempt: number; delayMs: number }
  | { type: "agent:end"; status: string }
  | { type: "gate:start"; gate: GateName; command: string }
  | { type: "gate:output"; gate: GateName; line: string }
  | { type: "gate:result"; gate: GateName; status: GateStatus }
  | { type: "story:update"; prd: Prd; story: Story }
  | { type: "commit"; hash: string; message: string };

export type EmitEvent = (event: EngineEvent) => void;
