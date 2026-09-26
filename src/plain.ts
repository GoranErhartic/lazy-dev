import { styleText } from "node:util";
import type { EmitEvent } from "./engine/events.js";

type Style = Parameters<typeof styleText>[0];

export function paint(style: Style, text: string): string {
  return process.stdout.isTTY ? styleText(style, text) : text;
}

/** Line-oriented renderer for CI logs and `--no-tui`. */
export function plainPrinter(write: (text: string) => void = (text) => process.stdout.write(text)): EmitEvent {
  let midLine = false;
  const line = (text: string): void => {
    write(`${midLine ? "\n" : ""}${text}\n`);
    midLine = false;
  };
  return (event) => {
    switch (event.type) {
      case "agent:text":
        write(event.text);
        midLine = !event.text.endsWith("\n");
        return;
      case "agent:tool":
        if (event.status === "running") line(paint("gray", `  ⚙ ${event.name}${event.summary ? ` ${event.summary}` : ""}`));
        else if (event.status === "error") line(paint("red", `  ✖ ${event.name} failed`));
        return;
      case "iteration:start":
        line(paint(["bold", "cyan"], `\n▶ Iteration ${event.iteration} · ${event.story.id} ${event.story.title ?? ""} · ${event.model} · ${event.completed}/${event.total} done`));
        return;
      case "agent:start":
        line(paint("gray", `  agent=${event.agentId} run=${event.runId}`));
        return;
      case "agent:end":
        line(paint("gray", `  agent run ${event.status}`));
        return;
      case "agent:retry":
        line(paint("yellow", `  retrying in ${Math.round(event.delayMs / 1000)}s`));
        return;
      case "gate:start":
        line(paint("gray", `  $ ${event.command}`));
        return;
      case "gate:output":
        line(paint("gray", `    ${event.line}`));
        return;
      case "gate:result":
        if (event.status !== "skipped") line(event.status === "passed" ? paint("green", `  ✔ ${event.gate}`) : paint("red", `  ✖ ${event.gate}`));
        return;
      case "story:update":
        line(event.story.passes ? paint("green", `  ✔ ${event.story.id} passes`) : paint("yellow", `  ○ ${event.story.id} not passing (attempt ${event.story.attempts ?? 0})`));
        return;
      case "commit":
        line(paint("gray", `  committed ${event.hash} ${event.message}`));
        return;
      case "branch":
        line(paint("cyan", `${event.created ? "Created" : "Checked out"} branch ${event.branch}`));
        return;
      case "info":
        line(event.message);
        return;
      case "warn":
        line(paint("yellow", `⚠ ${event.message}`));
        return;
    }
  };
}
