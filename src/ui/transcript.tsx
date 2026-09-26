import { Box, Text } from "ink";
import { useCallback, useRef, useState } from "react";
import type { EngineEvent } from "../engine/events.js";
import { symbols, theme, truncate } from "./theme.js";

export type LineKind = "text" | "tool" | "tool-error" | "info" | "warn" | "gate" | "user";

export interface Line {
  id: number;
  kind: LineKind;
  text: string;
}

const maxLines = 1000;

/** Folds streamed engine events into a bounded list of display lines. */
export function appendEvent(lines: Line[], event: EngineEvent, nextId: () => number): Line[] {
  const push = (kind: LineKind, text: string): Line[] => [...lines, { id: nextId(), kind, text }].slice(-maxLines);
  switch (event.type) {
    case "agent:text": {
      const next = [...lines];
      const parts = event.text.split("\n");
      const last = next[next.length - 1];
      if (last && last.kind === "text") next[next.length - 1] = { ...last, text: last.text + parts[0] };
      else next.push({ id: nextId(), kind: "text", text: parts[0] });
      for (const part of parts.slice(1)) next.push({ id: nextId(), kind: "text", text: part });
      return next.slice(-maxLines);
    }
    case "agent:tool":
      if (event.status === "running") return push("tool", `${event.name}${event.summary ? ` ${event.summary}` : ""}`);
      if (event.status === "error") return push("tool-error", `${event.name} failed`);
      return lines;
    case "agent:retry":
      return push("warn", `Retrying agent in ${Math.round(event.delayMs / 1000)}s (attempt ${event.attempt + 1})`);
    case "info":
      return push("info", event.message);
    case "warn":
      return push("warn", event.message);
    case "branch":
      return push("info", `${event.created ? "Created" : "Checked out"} branch ${event.branch}`);
    case "iteration:start":
      return push("info", `Iteration ${event.iteration}: ${event.story.id} ${event.story.title ?? ""} (${event.model})`);
    case "gate:start":
      return push("gate", `$ ${event.command}`);
    case "gate:result":
      return event.status === "skipped" ? lines : push(event.status === "passed" ? "info" : "warn", `${event.gate} ${event.status}`);
    case "commit":
      return push("info", `Committed ${event.hash}: ${event.message}`);
    default:
      return lines;
  }
}

export function useTranscript() {
  const [lines, setLines] = useState<Line[]>([]);
  const counter = useRef(0);
  const nextId = useCallback(() => (counter.current += 1), []);
  const onEvent = useCallback((event: EngineEvent) => setLines((current) => appendEvent(current, event, nextId)), [nextId]);
  const addLine = useCallback(
    (kind: LineKind, text: string) => setLines((current) => [...current, { id: nextId(), kind, text }].slice(-maxLines)),
    [nextId],
  );
  return { lines, onEvent, addLine };
}

export function TranscriptView({ lines, height, width }: { lines: Line[]; height: number; width: number }) {
  const visible = lines.filter((line, index) => line.kind !== "text" || line.text.trim() !== "" || index === lines.length - 1).slice(-Math.max(1, height));
  return (
    <Box flexDirection="column">
      {visible.map((line) => {
        switch (line.kind) {
          case "tool":
            return (
              <Text key={line.id} color={theme.muted}>
                {symbols.tool} {truncate(line.text, width - 2)}
              </Text>
            );
          case "tool-error":
            return (
              <Text key={line.id} color={theme.danger}>
                {symbols.failed} {truncate(line.text, width - 2)}
              </Text>
            );
          case "info":
            return (
              <Text key={line.id} color={theme.accent}>
                {symbols.dot} {truncate(line.text, width - 2)}
              </Text>
            );
          case "warn":
            return (
              <Text key={line.id} color={theme.warn}>
                ⚠ {truncate(line.text, width - 2)}
              </Text>
            );
          case "gate":
            return (
              <Text key={line.id} color={theme.muted}>
                {truncate(line.text, width)}
              </Text>
            );
          case "user":
            return (
              <Text key={line.id} color={theme.brand}>
                {symbols.pointer} {truncate(line.text, width - 2)}
              </Text>
            );
          default:
            return (
              <Text key={line.id} wrap="truncate-end">
                {line.text || " "}
              </Text>
            );
        }
      })}
    </Box>
  );
}
