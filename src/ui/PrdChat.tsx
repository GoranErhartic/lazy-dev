import { Select, Spinner, TextInput } from "@inkjs/ui";
import { Box, Text, useInput, useStdout } from "ink";
import { relative } from "node:path";
import { useEffect, useRef, useState } from "react";
import { featureDir, featureNamePattern, listFeatures } from "../config/repo.js";
import { commitPaths } from "../engine/git.js";
import { PrdSession, type PrdSessionOptions, type TurnResult, type UserQuestion } from "../prd/session.js";
import type { Prd, PrdValidation } from "../workflow.js";
import { Header, KeyHints, Notice, Panel } from "./components.js";
import { symbols, theme, truncate } from "./theme.js";
import { TranscriptView, useTranscript } from "./transcript.js";

export type PrdChatResult = { type: "run"; feature: string } | { type: "home"; flash?: { tone: "info" | "success" | "warn" | "error"; text: string } };

export interface PrdChatProps {
  root: string;
  apiKey: string;
  installDir: string;
  model: string;
  tracked: boolean;
  signal: AbortSignal;
  onDone: (result: PrdChatResult) => void;
  /** Test seam: replaces `Agent.create`. */
  createAgent?: PrdSessionOptions["createAgent"];
}

type Stage =
  | { name: "feature" }
  | { name: "description"; feature: string }
  | { name: "working"; feature: string }
  | { name: "reply"; feature: string; turn: TurnResult }
  | { name: "review"; feature: string; prd: Prd; validation: PrdValidation }
  | { name: "error"; message: string };

interface PendingQuestion extends UserQuestion {
  resolve: (answer: string) => void;
}

const otherValue = "__other__";

function QuestionPrompt({ pending, onAnswer }: { pending: PendingQuestion; onAnswer: (answer: string) => void }) {
  const [typing, setTyping] = useState(pending.options.length === 0);
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.accent} paddingX={1}>
      <Text bold color={theme.accent}>
        ? {pending.question}
      </Text>
      {typing ? (
        <Box>
          <Text color={theme.accent}>{symbols.pointer} </Text>
          <TextInput placeholder="Type your answer and press enter" onSubmit={(value) => value.trim() && onAnswer(value.trim())} />
        </Box>
      ) : (
        <Select
          visibleOptionCount={8}
          options={[
            ...pending.options.map((option) => ({ label: option, value: option })),
            ...(pending.allowOther ? [{ label: "Other (type your own answer)", value: otherValue }] : []),
          ]}
          onChange={(value) => (value === otherValue ? setTyping(true) : onAnswer(value))}
        />
      )}
    </Box>
  );
}

function PrdSummary({ feature, prd, validation, width }: { feature: string; prd: Prd; validation: PrdValidation; width: number }) {
  return (
    <Panel title={`PRD ready: ${feature}`}>
      {prd.description ? <Text>{prd.description}</Text> : null}
      {prd.branchName ? <Text color={theme.muted}>branch {prd.branchName}</Text> : null}
      <Box flexDirection="column" marginTop={1}>
        {[...prd.userStories]
          .sort((left, right) => left.priority - right.priority)
          .map((story) => (
            <Text key={story.id}>
              <Text color={theme.muted}>{symbols.pending} </Text>
              <Text color={theme.accent}>{story.id}</Text> {truncate(story.title ?? "", width - story.id.length - 6)}
            </Text>
          ))}
      </Box>
      {validation.warnings.map((warning) => (
        <Text key={warning} color={theme.warn}>
          ⚠ {warning}
        </Text>
      ))}
    </Panel>
  );
}

export function PrdChat(props: PrdChatProps) {
  const { root } = props;
  const { stdout } = useStdout();
  const { lines, onEvent, addLine } = useTranscript();
  const [stage, setStage] = useState<Stage>({ name: "feature" });
  const [existing, setExisting] = useState<string[]>([]);
  const [inputError, setInputError] = useState<string | undefined>();
  const [pending, setPending] = useState<PendingQuestion | undefined>();
  const session = useRef<PrdSession | undefined>(undefined);

  useEffect(() => {
    void listFeatures(root).then(setExisting);
    return () => {
      void session.current?.close();
    };
  }, [root]);

  useEffect(() => {
    const abort = (): void => {
      session.current?.cancel();
      pending?.resolve("The user cancelled the session. Stop now without writing further files.");
    };
    props.signal.addEventListener("abort", abort);
    return () => props.signal.removeEventListener("abort", abort);
  }, [props.signal, pending]);

  const afterTurn = (feature: string, turn: TurnResult): void => {
    if (turn.error) addLine("warn", turn.error);
    if (props.signal.aborted || turn.status === "cancelled") {
      props.onDone({ type: "home", flash: { tone: "info", text: "PRD session cancelled." } });
      return;
    }
    if (turn.prd && turn.validation && turn.validation.errors.length === 0) {
      setStage({ name: "review", feature, prd: turn.prd, validation: turn.validation });
      return;
    }
    for (const problem of turn.validation?.errors ?? []) addLine("warn", `PRD check: ${problem}`);
    setStage({ name: "reply", feature, turn });
  };

  const start = (feature: string, description: string): void => {
    setStage({ name: "working", feature });
    const created = new PrdSession({
      apiKey: props.apiKey,
      root,
      installDir: props.installDir,
      model: props.model,
      feature,
      description: description || undefined,
      tracked: props.tracked,
      emit: onEvent,
      askUser: (question) => new Promise<string>((resolve) => setPending({ ...question, resolve })),
      createAgent: props.createAgent,
    });
    session.current = created;
    created.start().then(
      (turn) => afterTurn(feature, turn),
      (error: unknown) => setStage({ name: "error", message: error instanceof Error ? error.message : "PRD session failed." }),
    );
  };

  const reply = (feature: string, text: string): void => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (trimmed === "/cancel") {
      props.onDone({ type: "home", flash: { tone: "info", text: "PRD session closed." } });
      return;
    }
    const message =
      trimmed === "/done"
        ? "Finalize now: write prd.json and progress.txt following the skill, validate them, and end your turn."
        : trimmed;
    addLine("user", trimmed);
    setStage({ name: "working", feature });
    session.current!.reply(message).then(
      (turn) => afterTurn(feature, turn),
      (error: unknown) => setStage({ name: "error", message: error instanceof Error ? error.message : "PRD session failed." }),
    );
  };

  const finishReview = async (feature: string, choice: string): Promise<void> => {
    if (choice === "refine") {
      setStage({ name: "reply", feature, turn: { status: "finished" } });
      return;
    }
    let committed = "";
    if (props.tracked) {
      const hash = commitPaths(root, [relative(root, featureDir(root, feature))], `chore: add ${feature} PRD`);
      if (hash) committed = ` Committed as ${hash}.`;
    }
    if (choice === "run") props.onDone({ type: "run", feature });
    else props.onDone({ type: "home", flash: { tone: "success", text: `PRD for ${feature} is ready.${committed}` } });
  };

  useInput(
    (_input, key) => {
      if (key.escape) props.onDone({ type: "home" });
    },
    { isActive: stage.name === "feature" || stage.name === "description" || stage.name === "error" },
  );

  const columns = stdout.columns || 100;
  const rows = stdout.rows || 30;
  const feature = "feature" in stage ? stage.feature : undefined;

  return (
    <Box flexDirection="column">
      <Header context={feature ? `new PRD ${symbols.dot} ${feature}` : "new PRD"} right={<Text color={theme.muted}>{props.model}</Text>} />
      <Box flexDirection="column" paddingX={1}>
        {stage.name === "feature" ? (
          <Box flexDirection="column">
            <Text bold>Feature name</Text>
            <Text color={theme.muted}>kebab-case, used for the folder and the default branch (feature/&lt;name&gt;)</Text>
            {inputError ? <Notice tone="error">{inputError}</Notice> : null}
            <Box>
              <Text color={theme.accent}>{symbols.pointer} </Text>
              <TextInput
                placeholder="task-priority"
                onSubmit={(value) => {
                  const name = value.trim();
                  if (!featureNamePattern.test(name)) setInputError("Use lowercase letters, digits, and single dashes.");
                  else if (existing.includes(name)) setInputError(`A feature named ${name} already exists.`);
                  else {
                    setInputError(undefined);
                    setStage({ name: "description", feature: name });
                  }
                }}
              />
            </Box>
          </Box>
        ) : null}

        {stage.name === "description" ? (
          <Box flexDirection="column">
            <Text bold>What should this feature do?</Text>
            <Text color={theme.muted}>A sentence or two, or a Jira key. The agent will ask follow-up questions. Enter to skip.</Text>
            <Box>
              <Text color={theme.accent}>{symbols.pointer} </Text>
              <TextInput placeholder="Let users set task priority and filter by it" onSubmit={(value) => start(stage.feature, value.trim())} />
            </Box>
          </Box>
        ) : null}

        {stage.name === "working" || stage.name === "reply" ? (
          <Box flexDirection="column">
            <Panel title="Conversation">
              {lines.length === 0 ? <Text color={theme.muted}>Starting the PRD agent…</Text> : null}
              <TranscriptView lines={lines} height={Math.max(6, rows - (pending ? 20 : 12))} width={columns - 6} />
            </Panel>
            {pending ? (
              <QuestionPrompt
                key={pending.question}
                pending={pending}
                onAnswer={(answer) => {
                  addLine("user", `${pending.question} → ${answer}`);
                  setPending(undefined);
                  pending.resolve(answer);
                }}
              />
            ) : null}
            {stage.name === "working" && !pending ? <Spinner label="Agent is working" /> : null}
            {stage.name === "reply" ? (
              <Box flexDirection="column">
                <Text color={theme.muted}>The agent is waiting for you. Reply, /done to finalize the PRD, or /cancel to leave.</Text>
                <Box>
                  <Text color={theme.accent}>{symbols.pointer} </Text>
                  <TextInput key={lines.length} placeholder="Your reply" onSubmit={(value) => reply(stage.feature, value)} />
                </Box>
              </Box>
            ) : null}
          </Box>
        ) : null}

        {stage.name === "review" ? (
          <Box flexDirection="column">
            <PrdSummary feature={stage.feature} prd={stage.prd} validation={stage.validation} width={columns - 6} />
            <Select
              options={[
                { label: "Implement now", value: "run" },
                { label: "Keep refining with the agent", value: "refine" },
                { label: "Back to home", value: "home" },
              ]}
              onChange={(value) => void finishReview(stage.feature, value)}
            />
          </Box>
        ) : null}

        {stage.name === "error" ? <Notice tone="error">{stage.message}</Notice> : null}
      </Box>
      <KeyHints
        hints={
          stage.name === "feature" || stage.name === "description" || stage.name === "error"
            ? [["enter", "continue"], ["esc", "back"]]
            : [["enter", "submit"], ["ctrl+c", "cancel session"]]
        }
      />
    </Box>
  );
}
