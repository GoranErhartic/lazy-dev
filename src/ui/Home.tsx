import { Spinner } from "@inkjs/ui";
import { Box, Text, useInput, useStdout } from "ink";
import { basename } from "node:path";
import { useCallback, useEffect, useState } from "react";
import { summarizeFeatures, unblockFeature, type FeatureSummary } from "../config/repo.js";
import { currentBranch, isDirty } from "../engine/git.js";
import { Header, KeyHints, Notice, ProgressBar, StatusBadge } from "./components.js";
import { symbols, theme, truncate } from "./theme.js";

export type HomeAction = { type: "new-prd" } | { type: "run"; feature: string } | { type: "edit"; feature: string } | { type: "quit" };

export interface HomeProps {
  root: string;
  flash?: { tone: "info" | "success" | "warn" | "error"; text: string };
  onAction: (action: HomeAction) => void;
}

interface RepoState {
  branch: string;
  dirty: boolean;
  features: FeatureSummary[];
}

async function loadState(root: string): Promise<RepoState> {
  return { branch: currentBranch(root) || "(detached)", dirty: isDirty(root), features: await summarizeFeatures(root) };
}

export function Home({ root, flash, onAction }: HomeProps) {
  const { stdout } = useStdout();
  const [state, setState] = useState<RepoState | undefined>();
  const [cursor, setCursor] = useState(0);
  const [message, setMessage] = useState(flash);

  const refresh = useCallback(() => {
    void loadState(root).then(setState, (error: unknown) =>
      setMessage({ tone: "error", text: error instanceof Error ? error.message : "Could not read repo state." }),
    );
  }, [root]);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 3000);
    return () => clearInterval(timer);
  }, [refresh]);

  const features = state?.features ?? [];
  const itemCount = features.length + 1;
  const selected = cursor === 0 ? undefined : features[cursor - 1];

  const runSelected = (feature: FeatureSummary): void => {
    if (feature.error) setMessage({ tone: "error", text: `${feature.name}: ${feature.error}` });
    else if (feature.progress?.status === "done") setMessage({ tone: "success", text: `${feature.name} is already complete.` });
    else if (feature.progress?.status === "blocked") setMessage({ tone: "warn", text: `${feature.name} is blocked. Press u to retry its parked stories.` });
    else if (state?.dirty) setMessage({ tone: "warn", text: "Working tree has uncommitted changes. Commit or stash them first." });
    else onAction({ type: "run", feature: feature.name });
  };

  useInput((input, key) => {
    if (key.upArrow || input === "k") setCursor((value) => (value - 1 + itemCount) % itemCount);
    else if (key.downArrow || input === "j") setCursor((value) => (value + 1) % itemCount);
    else if (input === "n") onAction({ type: "new-prd" });
    else if (input === "q" || key.escape) onAction({ type: "quit" });
    else if (input === "r") refresh();
    else if (key.return) {
      if (!selected) onAction({ type: "new-prd" });
      else runSelected(selected);
    } else if (input === "o" && selected) onAction({ type: "edit", feature: selected.name });
    else if (input === "u" && selected) {
      void unblockFeature(root, selected.name).then(
        (count) => {
          setMessage(count ? { tone: "success", text: `Reset ${count} stor${count === 1 ? "y" : "ies"} in ${selected.name}.` } : { tone: "info", text: "Nothing to unblock." });
          refresh();
        },
        (error: unknown) => setMessage({ tone: "error", text: error instanceof Error ? error.message : "Unblock failed." }),
      );
    }
  });

  const columns = stdout.columns || 100;
  const nameWidth = Math.min(28, Math.max(12, ...features.map((feature) => feature.name.length)));
  const descriptionWidth = Math.max(10, columns - nameWidth - 42);

  return (
    <Box flexDirection="column">
      <Header
        context={basename(root)}
        right={
          state ? (
            <Text>
              <Text color={theme.muted}>⎇ </Text>
              <Text>{state.branch}</Text>
              <Text color={state.dirty ? theme.warn : theme.success}> {state.dirty ? "● uncommitted changes" : "● clean"}</Text>
            </Text>
          ) : null
        }
      />
      {!state ? (
        <Box paddingX={1}>
          <Spinner label="Loading features" />
        </Box>
      ) : (
        <Box flexDirection="column" paddingX={1}>
          <Text color={cursor === 0 ? theme.accent : undefined} bold={cursor === 0}>
            {cursor === 0 ? `${symbols.pointer} ` : "  "}+ New feature PRD
          </Text>
          <Box marginTop={1} flexDirection="column">
            {features.length === 0 ? (
              <Text color={theme.muted}>  No features yet. Create a PRD to get started.</Text>
            ) : (
              <Text color={theme.muted}>  Features</Text>
            )}
            {features.map((feature, index) => {
              const active = cursor === index + 1;
              return (
                <Box key={feature.name}>
                  <Text color={active ? theme.accent : undefined}>{active ? `${symbols.pointer} ` : "  "}</Text>
                  <Box width={nameWidth + 2}>
                    <Text bold={active} color={active ? theme.accent : undefined}>
                      {truncate(feature.name, nameWidth)}
                    </Text>
                  </Box>
                  {feature.progress ? (
                    <>
                      <Box width={20}>
                        <ProgressBar done={feature.progress.done} total={feature.progress.total} width={10} />
                      </Box>
                      <Box width={15}>
                        <StatusBadge status={feature.progress.status} />
                      </Box>
                      <Text color={theme.muted}>{truncate(feature.description ?? "", descriptionWidth)}</Text>
                    </>
                  ) : (
                    <Text color={theme.danger}>{symbols.failed} invalid PRD</Text>
                  )}
                </Box>
              );
            })}
          </Box>
        </Box>
      )}
      {message ? (
        <Box marginTop={1}>
          <Notice tone={message.tone}>{message.text}</Notice>
        </Box>
      ) : null}
      <KeyHints
        hints={[
          ["↑↓", "move"],
          ["enter", selected ? "implement" : "create"],
          ["n", "new PRD"],
          ...(selected ? ([["o", "open PRD"], ["u", "unblock"]] as Array<[string, string]>) : []),
          ["r", "refresh"],
          ["q", "quit"],
        ]}
      />
    </Box>
  );
}
