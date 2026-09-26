import { Box, Text, useInput } from "ink";
import { useMemo, useState } from "react";
import { fuzzyFilter, type ModelChoice } from "../config/models.js";
import { symbols, theme } from "./theme.js";

export interface ModelPickerProps {
  label: string;
  hint?: string;
  models: ModelChoice[];
  defaultId?: string;
  visible?: number;
  onSelect: (id: string) => void;
}

export function ModelPicker({ label, hint, models, defaultId, visible = 8, onSelect }: ModelPickerProps) {
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(() => Math.max(0, models.findIndex((model) => model.id === defaultId)));
  const matches = useMemo(() => fuzzyFilter(models, query), [models, query]);
  const index = Math.min(cursor, Math.max(0, matches.length - 1));

  useInput((input, key) => {
    if (key.upArrow) setCursor(Math.max(0, index - 1));
    else if (key.downArrow) setCursor(Math.min(matches.length - 1, index + 1));
    else if (key.return) {
      const chosen = matches[index];
      if (chosen) onSelect(chosen.id);
    } else if (key.backspace || key.delete) {
      setQuery((value) => value.slice(0, -1));
      setCursor(0);
    } else if (input && !key.ctrl && !key.meta && !key.tab && !key.escape) {
      setQuery((value) => value + input);
      setCursor(0);
    }
  });

  const start = Math.max(0, Math.min(index - Math.floor(visible / 2), matches.length - visible));
  const window = matches.slice(start, start + visible);

  return (
    <Box flexDirection="column">
      <Box>
        <Text bold>{label}</Text>
        {hint ? <Text color={theme.muted}> {hint}</Text> : null}
      </Box>
      <Box>
        <Text color={theme.accent}>{symbols.pointer} </Text>
        {query ? <Text>{query}</Text> : <Text color={theme.muted}>type to filter {models.length} models</Text>}
      </Box>
      <Box flexDirection="column" marginTop={1}>
        {window.length === 0 ? <Text color={theme.warn}>No models match “{query}”.</Text> : null}
        {window.map((model) => {
          const active = model === matches[index];
          const isDefault = model.id === defaultId;
          return (
            <Text key={model.id} color={active ? theme.accent : undefined}>
              {active ? `${symbols.pointer} ` : "  "}
              {model.label}
              {isDefault ? <Text color={theme.muted}> (current)</Text> : null}
            </Text>
          );
        })}
        {matches.length > visible ? (
          <Text color={theme.muted}>
            {"  "}
            {index + 1}/{matches.length}
          </Text>
        ) : null}
      </Box>
    </Box>
  );
}
