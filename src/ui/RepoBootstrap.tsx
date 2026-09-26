import { ConfirmInput, Select, Spinner } from "@inkjs/ui";
import { Box, Text } from "ink";
import { basename } from "node:path";
import { useState } from "react";
import { bootstrapRepo } from "../config/repo.js";
import { Header, KeyHints, Notice } from "./components.js";
import { theme } from "./theme.js";

type Step = { name: "track" } | { name: "commit" } | { name: "working" } | { name: "error"; message: string };

export function RepoBootstrap({ root, onDone }: { root: string; onDone: (message: string) => void }) {
  const [step, setStep] = useState<Step>({ name: "track" });

  const finish = async (tracked: boolean, commit: boolean): Promise<void> => {
    setStep({ name: "working" });
    try {
      const result = await bootstrapRepo(root, { tracked, commit });
      if (!tracked) onDone("lazy-dev is ready. State stays local (ignored via .git/info/exclude).");
      else if (result.commit) onDone(`lazy-dev is ready. Committed .lazy-dev/ as ${result.commit}.`);
      else onDone("lazy-dev is ready. Commit .lazy-dev/ before implementing a feature.");
    } catch (error) {
      setStep({ name: "error", message: error instanceof Error ? error.message : "Setup failed." });
    }
  };

  return (
    <Box flexDirection="column" paddingX={1}>
      <Header context={`set up ${basename(root)}`} />
      <Box flexDirection="column" paddingX={1}>
        {step.name === "track" ? (
          <Box flexDirection="column">
            <Text bold>Where should this repo’s PRDs and progress live?</Text>
            <Box marginTop={1}>
              <Select
                options={[
                  { label: "Local only (recommended): nothing to commit, ignored via .git/info/exclude", value: "local" },
                  { label: "Tracked in git: share PRDs and progress with your team", value: "tracked" },
                ]}
                onChange={(value) => {
                  if (value === "local") void finish(false, false);
                  else setStep({ name: "commit" });
                }}
              />
            </Box>
          </Box>
        ) : null}
        {step.name === "commit" ? (
          <Box flexDirection="column">
            <Text>
              Commit the new <Text color={theme.accent}>.lazy-dev/</Text> folder now? The loop needs a clean tree.{" "}
            </Text>
            <ConfirmInput defaultChoice="confirm" onConfirm={() => void finish(true, true)} onCancel={() => void finish(true, false)} />
          </Box>
        ) : null}
        {step.name === "working" ? <Spinner label="Setting up .lazy-dev/" /> : null}
        {step.name === "error" ? <Notice tone="error">{step.message}</Notice> : null}
      </Box>
      <KeyHints hints={[["↑↓", "move"], ["enter", "select"], ["ctrl+c", "quit"]]} />
    </Box>
  );
}
