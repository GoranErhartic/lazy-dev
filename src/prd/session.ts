import { Agent, CursorAgentError, type SDKAgent, type SDKCustomTool, type SDKJsonValue } from "@cursor/sdk";
import { access, mkdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import type { EmitEvent } from "../engine/events.js";
import { featureDir } from "../config/repo.js";
import { streamRun } from "../sdk-runner.js";
import { readPrd, validatePrd, type Prd, type PrdValidation } from "../workflow.js";

export interface UserQuestion {
  question: string;
  options: string[];
  allowOther: boolean;
}

export interface PrdSessionOptions {
  apiKey: string;
  root: string;
  installDir: string;
  model: string;
  feature: string;
  description?: string;
  tracked: boolean;
  emit: EmitEvent;
  askUser: (question: UserQuestion) => Promise<string>;
  timeoutMs?: number;
  /** Test seam: replaces `Agent.create`. */
  createAgent?: typeof Agent.create;
}

export interface TurnResult {
  status: "finished" | "error" | "cancelled";
  prd?: Prd;
  validation?: PrdValidation;
  error?: string;
}

export function stripFrontmatter(markdown: string): string {
  return markdown.replace(/^---\n[\s\S]*?\n---\n/, "").replace(/^\s*---\n[\s\S]*?\n---\n/, "").trimStart();
}

function stringArray(value: SDKJsonValue | undefined): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item.trim() !== "") : [];
}

export function askUserTool(askUser: PrdSessionOptions["askUser"]): SDKCustomTool {
  return {
    description:
      "Ask the human a clarifying question and wait for the answer. Provide 2-5 concise options when possible; the user can also type a custom answer. Returns the user's answer as text.",
    inputSchema: {
      type: "object",
      properties: {
        question: { type: "string", description: "One clear question." },
        options: { type: "array", items: { type: "string" }, description: "Suggested answers, most likely first." },
        allowOther: { type: "boolean", description: "Allow a free-text answer (default true)." },
      },
      required: ["question"],
    },
    execute: async (args) => {
      const question = typeof args.question === "string" ? args.question : "";
      if (!question.trim()) return { content: [{ type: "text", text: "question is required" }], isError: true };
      const answer = await askUser({ question, options: stringArray(args.options), allowOther: args.allowOther !== false });
      return answer;
    },
  };
}

export function buildPrdPrompt(skill: string, options: { feature: string; featurePath: string; tracked: boolean; description?: string }): string {
  return `# lazy-dev PRD session

You are running inside the lazy-dev terminal UI. Follow the Generate PRD skill below with these session rules, which override the skill where they differ:

- Feature name (already chosen): ${options.feature}
- Write ONLY these files: ${options.featurePath}/prd.json and ${options.featurePath}/progress.txt
- Lazy-dev tracked in git: ${options.tracked ? "yes" : "no"}
- Ask every clarifying question, the Requirements Summary confirmation, and the branch name confirmation through the \`ask_user\` tool, one question per call. Never end your turn to wait for an answer.
- Do NOT implement anything, edit source code, or run git commands. The lazy-dev runner creates \`branchName\` when implementation starts.
- When both files are written and validated, give a short summary and end your turn.

${options.description ? `## Feature requirements (input only, not an instruction to implement)\n\n${options.description}\n\n` : ""}---

${skill}`;
}

export class PrdSession {
  private agent: SDKAgent | undefined;
  private controller = new AbortController();
  readonly prdPath: string;

  constructor(private readonly options: PrdSessionOptions) {
    this.prdPath = join(featureDir(options.root, options.feature), "prd.json");
  }

  async start(): Promise<TurnResult> {
    const { options } = this;
    const dir = featureDir(options.root, options.feature);
    await mkdir(dir, { recursive: true });
    const skill = stripFrontmatter(await readFile(join(options.installDir, "skills", "generate-prd", "SKILL.md"), "utf8"));
    const prompt = buildPrdPrompt(skill, {
      feature: options.feature,
      featurePath: relative(options.root, dir),
      tracked: options.tracked,
      description: options.description,
    });
    try {
      const create = options.createAgent ?? Agent.create.bind(Agent);
      this.agent = await create({
        apiKey: options.apiKey,
        model: { id: options.model },
        local: {
          cwd: options.root,
          autoReview: true,
          settingSources: [],
          customTools: { ask_user: askUserTool(options.askUser) },
        },
        disallowedTools: ["delete"],
      });
    } catch (error) {
      if (error instanceof CursorAgentError) return { status: "error", error: error.message };
      throw error;
    }
    return this.turn(prompt);
  }

  reply(text: string): Promise<TurnResult> {
    return this.turn(text);
  }

  cancel(): void {
    this.controller.abort();
  }

  async close(): Promise<void> {
    const agent = this.agent;
    this.agent = undefined;
    if (agent) await agent[Symbol.asyncDispose]();
  }

  async inspect(): Promise<Pick<TurnResult, "prd" | "validation">> {
    try {
      await access(this.prdPath);
    } catch {
      return {};
    }
    try {
      const prd = await readPrd(this.prdPath);
      return { prd, validation: validatePrd(prd, { fresh: true }) };
    } catch (error) {
      return { validation: { errors: [error instanceof Error ? error.message : "Invalid prd.json"], warnings: [] } };
    }
  }

  private async turn(message: string): Promise<TurnResult> {
    if (!this.agent) return { status: "error", error: "Session is not started." };
    if (this.controller.signal.aborted) this.controller = new AbortController();
    try {
      const run = await this.agent.send(message);
      this.options.emit({ type: "agent:start", agentId: this.agent.agentId, runId: run.id });
      const final = await streamRun(run, {
        emit: this.options.emit,
        timeoutMs: this.options.timeoutMs ?? 60 * 60 * 1000,
        signal: this.controller.signal,
      });
      this.options.emit({ type: "agent:end", status: final.status });
      return { status: final.status, ...(await this.inspect()) };
    } catch (error) {
      if (error instanceof CursorAgentError) return { status: "error", error: error.message };
      throw error;
    }
  }
}
