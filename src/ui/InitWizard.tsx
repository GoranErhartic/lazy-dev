import { ConfirmInput, PasswordInput, Spinner } from "@inkjs/ui";
import { Box, Text, useInput } from "ink";
import { useEffect, useState } from "react";
import { runDoctor, type Check } from "../config/doctor.js";
import {
  maskKey,
  readGlobalConfig,
  resolveApiKey,
  saveApiKey,
  writeGlobalConfig,
  type ApiKeySource,
  type GlobalConfig,
  type ModelConfig,
} from "../config/global.js";
import { defaultModels, fetchModels, type ModelChoice } from "../config/models.js";
import { Header, KeyHints, Notice } from "./components.js";
import { ModelPicker } from "./ModelPicker.js";
import { symbols, theme } from "./theme.js";

type Step =
  | { name: "loading" }
  | { name: "key-keep"; key: string }
  | { name: "key-input"; error?: string }
  | { name: "validating"; key: string; source: ApiKeySource | "input" }
  | { name: "fatal"; message: string }
  | { name: "models"; key: string; source: ApiKeySource | "input"; models: ModelChoice[]; picked: Partial<ModelConfig>; slot: keyof ModelConfig }
  | { name: "saving" }
  | { name: "doctor"; checks?: Check[] };

const slots: Array<{ slot: keyof ModelConfig; label: string; hint: string }> = [
  { slot: "impl", label: "Implementation model", hint: "writes code for each story" },
  { slot: "review", label: "First review model", hint: "runs *-REVIEW stories" },
  { slot: "review2", label: "Second review model", hint: "runs *-REVIEW-2 stories; pick a different family for independence" },
];

export function CheckList({ checks }: { checks: Check[] }) {
  const color = { ok: theme.success, warn: theme.warn, error: theme.danger } as const;
  const icon = { ok: symbols.done, warn: "⚠", error: symbols.failed } as const;
  return (
    <Box flexDirection="column">
      {checks.map((check) => (
        <Box key={check.name}>
          <Text color={color[check.level]}>{icon[check.level]} </Text>
          <Box width={18}>
            <Text bold>{check.name}</Text>
          </Box>
          <Text color={check.level === "ok" ? theme.muted : undefined}>{check.detail}</Text>
        </Box>
      ))}
    </Box>
  );
}

export function InitWizard({ installDir, onDone, firstRun }: { installDir: string; onDone: () => void; firstRun?: boolean }) {
  const [step, setStep] = useState<Step>({ name: "loading" });
  const [existing, setExisting] = useState<GlobalConfig | undefined>();

  useEffect(() => {
    void (async () => {
      setExisting(await readGlobalConfig());
      const resolved = await resolveApiKey();
      if (!resolved) setStep({ name: "key-input" });
      else if (resolved.source === "env") setStep({ name: "validating", key: resolved.key, source: "env" });
      else setStep({ name: "key-keep", key: resolved.key });
    })();
  }, []);

  useEffect(() => {
    if (step.name !== "validating") return;
    let active = true;
    fetchModels(step.key).then(
      (models) => {
        if (!active) return;
        if (models.length === 0) setStep({ name: "fatal", message: "No models are available to this API key." });
        else setStep({ name: "models", key: step.key, source: step.source, models, picked: {}, slot: "impl" });
      },
      (error: unknown) => {
        if (!active) return;
        const message = error instanceof Error ? error.message : "Could not reach the Cursor API.";
        if (step.source === "env") setStep({ name: "fatal", message: `CURSOR_API_KEY was rejected: ${message}` });
        else setStep({ name: "key-input", error: message });
      },
    );
    return () => {
      active = false;
    };
  }, [step]);

  useEffect(() => {
    if (step.name !== "doctor" || step.checks) return;
    void runDoctor({ installDir }).then((checks) => setStep({ name: "doctor", checks }));
  }, [step, installDir]);

  useInput(
    (_input, key) => {
      if (key.return) onDone();
    },
    { isActive: (step.name === "doctor" && Boolean(step.checks)) || step.name === "fatal" },
  );

  const choose = async (current: Extract<Step, { name: "models" }>, id: string): Promise<void> => {
    const picked = { ...current.picked, [current.slot]: id };
    const nextIndex = slots.findIndex((entry) => entry.slot === current.slot) + 1;
    if (nextIndex < slots.length) {
      setStep({ ...current, picked, slot: slots[nextIndex].slot });
      return;
    }
    setStep({ name: "saving" });
    await writeGlobalConfig({ ...existing, version: 1, models: picked as ModelConfig });
    if (current.source === "input") await saveApiKey(current.key);
    setStep({ name: "doctor" });
  };

  return (
    <Box flexDirection="column" paddingX={1}>
      <Header context={firstRun ? "first-time setup" : "global setup"} />
      {firstRun ? <Notice tone="info">Let’s set up lazydev once for this machine. You can re-run `lazydev init` any time.</Notice> : null}
      <Box flexDirection="column" marginTop={1} paddingX={1}>
        {step.name === "loading" ? <Spinner label="Reading configuration" /> : null}

        {step.name === "key-keep" ? (
          <Box flexDirection="column">
            <Text>
              Use the stored API key <Text color={theme.accent}>{maskKey(step.key)}</Text>?{" "}
            </Text>
            <ConfirmInput
              defaultChoice="confirm"
              onConfirm={() => setStep({ name: "validating", key: step.key, source: "file" })}
              onCancel={() => setStep({ name: "key-input" })}
            />
          </Box>
        ) : null}

        {step.name === "key-input" ? (
          <Box flexDirection="column">
            {step.error ? <Notice tone="error">{step.error}</Notice> : null}
            <Text>Paste your Cursor API key</Text>
            <Text color={theme.muted}>Create one at cursor.com/dashboard → Integrations. It is stored with 0600 permissions.</Text>
            <Box marginTop={1}>
              <Text color={theme.accent}>{symbols.pointer} </Text>
              <PasswordInput
                placeholder="cursor_…"
                onSubmit={(value) => {
                  if (value.trim()) setStep({ name: "validating", key: value.trim(), source: "input" });
                }}
              />
            </Box>
          </Box>
        ) : null}

        {step.name === "validating" ? (
          <Box flexDirection="column">
            {step.source === "env" ? <Text color={theme.muted}>Using CURSOR_API_KEY from the environment ({maskKey(step.key)}).</Text> : null}
            <Spinner label="Validating key and loading models" />
          </Box>
        ) : null}

        {step.name === "fatal" ? (
          <Box flexDirection="column">
            <Notice tone="error">{step.message}</Notice>
            <Text color={theme.muted}>Press enter to exit.</Text>
          </Box>
        ) : null}

        {step.name === "models" ? (
          <Box flexDirection="column">
            <Text color={theme.muted}>
              Step {slots.findIndex((entry) => entry.slot === step.slot) + 1} of {slots.length}
            </Text>
            <ModelPicker
              key={step.slot}
              label={slots.find((entry) => entry.slot === step.slot)!.label}
              hint={slots.find((entry) => entry.slot === step.slot)!.hint}
              models={step.models}
              defaultId={defaultModels(step.models, existing?.models)[step.slot]}
              onSelect={(id) => void choose(step, id)}
            />
          </Box>
        ) : null}

        {step.name === "saving" ? <Spinner label="Saving" /> : null}

        {step.name === "doctor" ? (
          step.checks ? (
            <Box flexDirection="column">
              <Text bold>Setup complete. Health check:</Text>
              <Box marginTop={1}>
                <CheckList checks={step.checks} />
              </Box>
              <Box marginTop={1}>
                <Text color={theme.muted}>
                  {firstRun ? "Press enter to continue." : "Press enter to finish, then run lazydev inside any git repo."}
                </Text>
              </Box>
            </Box>
          ) : (
            <Spinner label="Running health checks" />
          )
        ) : null}
      </Box>
      {step.name === "models" ? <KeyHints hints={[["↑↓", "move"], ["type", "filter"], ["enter", "select"], ["ctrl+c", "quit"]]} /> : null}
    </Box>
  );
}
