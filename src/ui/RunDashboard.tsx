import { Spinner } from "@inkjs/ui";
import { Box, Text, useInput, useStdout } from "ink";
import { join } from "node:path";
import { useEffect, useRef, useState } from "react";
import type { ModelConfig } from "../config/global.js";
import { featureDir } from "../config/repo.js";
import type { EngineEvent, GateName, GateStatus } from "../engine/events.js";
import { gateNames } from "../engine/gates.js";
import { runFeature, type FeatureRunResult } from "../engine/loop.js";
import { readPrd, type Story } from "../workflow.js";
import { Header, KeyHints, Notice, Panel, ProgressBar, StatusBar } from "./components.js";
import { formatDuration, symbols, theme, truncate } from "./theme.js";
import { TranscriptView, useTranscript } from "./transcript.js";

export interface RunDashboardProps {
  root: string;
  feature: string;
  apiKey: string;
  installDir: string;
  models: ModelConfig;
  maxIterations?: number;
  timeoutMs?: number;
  /** Aborted by the app on ctrl+c. */
  signal: AbortSignal;
  onCancelRequest: () => void;
  onExit: () => void;
  /** Test seam: replaces the engine. */
  runner?: typeof runFeature;
}

type GateState = Partial<Record<GateName, GateStatus | "running">>;

const outcomeCopy: Record<FeatureRunResult["status"], { tone: "success" | "warn" | "error" | "info"; text: string }> = {
  complete: { tone: "success", text: "All stories pass. Review the branch and push when ready." },
  blocked: { tone: "warn", text: "Remaining stories are blocked after repeated failures. Press u on the home screen to retry them." },
  "max-iterations": { tone: "warn", text: "Reached the iteration limit. Run again to continue." },
  cancelled: { tone: "info", text: "Run cancelled. Any uncommitted agent changes are still in the working tree." },
};

function StoryRow({ story, active, width }: { story: Story; active: boolean; width: number }) {
  const icon = story.passes ? symbols.done : story.blocked ? symbols.blocked : active ? symbols.active : symbols.pending;
  const color = story.passes ? theme.success : story.blocked ? theme.danger : active ? theme.accent : theme.muted;
  const attempts = story.attempts ? ` ×${story.attempts}` : "";
  return (
    <Text color={active ? theme.accent : undefined}>
      <Text color={color}>{icon} </Text>
      {truncate(`${story.id}${story.title ? ` ${story.title}` : ""}`, width - 4 - attempts.length)}
      <Text color={theme.warn}>{attempts}</Text>
    </Text>
  );
}

function GateStrip({ gates }: { gates: GateState }) {
  const style = {
    passed: { icon: symbols.done, color: theme.success },
    failed: { icon: symbols.failed, color: theme.danger },
    skipped: { icon: "–", color: theme.muted },
    running: { icon: "…", color: theme.warn },
  } as const;
  return (
    <Box paddingX={1}>
      <Text color={theme.muted}>gates </Text>
      {gateNames.map((gate) => {
        const state = gates[gate];
        const entry = state ? style[state] : { icon: "·", color: theme.muted };
        return (
          <Box key={gate} marginRight={2}>
            <Text color={entry.color}>
              {entry.icon} {gate}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}

export function RunDashboard(props: RunDashboardProps) {
  const { root, feature } = props;
  const { stdout } = useStdout();
  const { lines, onEvent } = useTranscript();
  const [stories, setStories] = useState<Story[]>([]);
  const [current, setCurrent] = useState<{ id: string; model: string; iteration: number } | undefined>();
  const [gates, setGates] = useState<GateState>({});
  const [result, setResult] = useState<FeatureRunResult | undefined>();
  const [error, setError] = useState<string | undefined>();
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [fullLog, setFullLog] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const startedAt = useRef(Date.now());
  const started = useRef(false);

  useEffect(() => {
    void readPrd(join(featureDir(root, feature), "prd.json"))
      .then((prd) => setStories(prd.userStories))
      .catch(() => undefined);
  }, [root, feature]);

  useEffect(() => {
    if (result || error) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [result, error]);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const handle = (event: EngineEvent): void => {
      onEvent(event);
      if (event.type === "iteration:start") {
        setCurrent({ id: event.story.id, model: event.model, iteration: event.iteration });
        setGates({});
      } else if (event.type === "story:update") setStories([...event.prd.userStories]);
      else if (event.type === "gate:start") setGates((state) => ({ ...state, [event.gate]: "running" }));
      else if (event.type === "gate:result") setGates((state) => ({ ...state, [event.gate]: event.status }));
    };
    (props.runner ?? runFeature)({
      root,
      feature,
      apiKey: props.apiKey,
      installDir: props.installDir,
      models: props.models,
      maxIterations: props.maxIterations,
      timeoutMs: props.timeoutMs,
      signal: props.signal,
      emit: handle,
    }).then(
      (outcome) => {
        setStories(outcome.prd.userStories);
        setResult(outcome);
      },
      (failure: unknown) => setError(failure instanceof Error ? failure.message : "Run failed."),
    );
  }, [root, feature, props]);

  const finished = Boolean(result || error);
  useInput((input, key) => {
    if (finished) {
      if (key.return || input === "q" || key.escape) props.onExit();
      else if (input === "l") setFullLog((value) => !value);
      return;
    }
    if (confirmCancel) {
      if (input === "y") {
        setConfirmCancel(false);
        props.onCancelRequest();
      } else if (input === "n" || key.escape) setConfirmCancel(false);
      return;
    }
    if (input === "c") setConfirmCancel(true);
    else if (input === "l") setFullLog((value) => !value);
  });

  const columns = stdout.columns || 100;
  const rows = stdout.rows || 30;
  const paneHeight = Math.max(8, rows - 11);
  const storyWidth = fullLog ? 0 : Math.min(42, Math.max(28, Math.floor(columns * 0.32)));
  const logWidth = columns - storyWidth - 6;
  const done = stories.filter((story) => story.passes).length;
  const cancelling = props.signal.aborted && !finished;

  return (
    <Box flexDirection="column">
      <Header
        context={`run ${feature}`}
        right={
          finished ? (
            <Text color={theme.muted}>{formatDuration(now - startedAt.current)}</Text>
          ) : (
            <Spinner label={cancelling ? "cancelling" : formatDuration(now - startedAt.current)} />
          )
        }
      />
      <StatusBar
        items={[
          { label: "progress", value: <ProgressBar done={done} total={stories.length} /> },
          { label: "iteration", value: current ? String(current.iteration) : "–" },
          { label: "story", value: current?.id ?? "–" },
          { label: "model", value: current?.model ?? "–" },
        ]}
      />
      <Box height={paneHeight + 3}>
        {fullLog ? null : (
          <Panel title="Stories" width={storyWidth}>
            {stories.map((story) => (
              <StoryRow key={story.id} story={story} active={story.id === current?.id && !finished} width={storyWidth - 2} />
            ))}
          </Panel>
        )}
        <Panel title={fullLog ? "Agent (full width)" : "Agent"} flexGrow={1}>
          {lines.length === 0 ? <Text color={theme.muted}>Preparing branch, push guard, and first story…</Text> : null}
          <TranscriptView lines={lines} height={paneHeight} width={logWidth} />
        </Panel>
      </Box>
      <GateStrip gates={gates} />
      {result ? <Notice tone={outcomeCopy[result.status].tone}>{outcomeCopy[result.status].text}</Notice> : null}
      {result?.logFile ? (
        <Box paddingX={1}>
          <Text color={theme.muted}>Session log: {result.logFile}</Text>
        </Box>
      ) : null}
      {error ? <Notice tone="error">{error}</Notice> : null}
      {confirmCancel ? <Notice tone="warn">Cancel the run? The current agent will be stopped. (y/n)</Notice> : null}
      <KeyHints
        hints={
          finished
            ? [["enter", "back to home"], ["l", "toggle full log"]]
            : [["c", "cancel run"], ["l", "toggle full log"], ["ctrl+c", "cancel now · twice to quit"]]
        }
      />
    </Box>
  );
}
