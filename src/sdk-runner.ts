import { Agent, CursorAgentError, type Run, type SDKAgent, type SDKCustomTool, type ToolName } from "@cursor/sdk";
import type { EmitEvent } from "./engine/events.js";

export interface RunOutcome {
  startup: boolean;
  retryable?: boolean;
  status?: "finished" | "error" | "cancelled";
  agentId?: string;
  runId?: string;
  result?: string;
  message?: string;
}

export interface SdkRunOptions {
  apiKey: string;
  cwd: string;
  model: string;
  prompt: string;
  timeoutMs: number;
  emit?: EmitEvent;
  signal?: AbortSignal;
  customTools?: Record<string, SDKCustomTool>;
  disallowedTools?: ToolName[];
}

const summaryKeys = ["path", "file", "target_file", "command", "pattern", "query", "url"];

function summarizeArgs(args: unknown): string | undefined {
  if (typeof args !== "object" || args === null) return undefined;
  const record = args as Record<string, unknown>;
  for (const key of summaryKeys) {
    const value = record[key];
    if (typeof value === "string" && value) return value.length > 80 ? `${value.slice(0, 77)}...` : value;
  }
  return undefined;
}

export function emitMessage(event: unknown, emit: EmitEvent): void {
  if (typeof event !== "object" || event === null) return;
  const message = event as {
    type?: string;
    name?: string;
    status?: "running" | "completed" | "error";
    args?: unknown;
    message?: { content?: Array<{ type?: string; text?: string }> };
  };
  if (message.type === "assistant") {
    for (const block of message.message?.content ?? []) {
      if (block.type === "text" && block.text) emit({ type: "agent:text", text: block.text });
    }
  } else if (message.type === "tool_call" && message.name && message.status) {
    emit({ type: "agent:tool", name: message.name, status: message.status, summary: summarizeArgs(message.args) });
  }
}

/** Streams a run to `emit`, cancelling it on abort or timeout, and returns its terminal state. */
export async function streamRun(
  run: Run,
  options: { emit: EmitEvent; timeoutMs: number; signal?: AbortSignal },
): Promise<{ status: "finished" | "error" | "cancelled"; result?: string }> {
  const cancel = (): void => {
    if (run.supports("cancel")) void run.cancel().catch(() => undefined);
  };
  const timeout = setTimeout(cancel, options.timeoutMs);
  options.signal?.addEventListener("abort", cancel, { once: true });
  try {
    if (options.signal?.aborted) cancel();
    for await (const event of run.stream()) emitMessage(event, options.emit);
    const final = await run.wait();
    return { status: final.status, result: final.result };
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", cancel);
  }
}

export async function runLocalAgent(options: SdkRunOptions): Promise<RunOutcome> {
  const emit: EmitEvent = options.emit ?? (() => undefined);
  let agent: SDKAgent | undefined;
  try {
    agent = await Agent.create({
      apiKey: options.apiKey,
      model: { id: options.model },
      local: { cwd: options.cwd, autoReview: true, settingSources: [], customTools: options.customTools },
      disallowedTools: options.disallowedTools,
    });
    const run = await agent.send(options.prompt);
    emit({ type: "agent:start", agentId: agent.agentId, runId: run.id });
    const final = await streamRun(run, { emit, timeoutMs: options.timeoutMs, signal: options.signal });
    emit({ type: "agent:end", status: final.status });
    return { startup: false, status: final.status, agentId: agent.agentId, runId: run.id, result: final.result };
  } catch (error) {
    if (error instanceof CursorAgentError) {
      return { startup: true, retryable: error.isRetryable, message: error.message };
    }
    throw error;
  } finally {
    if (agent) await agent[Symbol.asyncDispose]();
  }
}
