import { Box, Text } from "ink";
import type { ReactNode } from "react";
import { statusStyle, symbols, theme } from "./theme.js";
import type { FeatureStatus } from "../workflow.js";

export function Header({ context, right }: { context?: string; right?: ReactNode }) {
  return (
    <Box justifyContent="space-between" paddingX={1} marginBottom={1}>
      <Box>
        <Text bold color={theme.brand}>
          lazydev
        </Text>
        {context ? <Text color={theme.muted}> {symbols.dot} {context}</Text> : null}
      </Box>
      {right ? <Box>{right}</Box> : null}
    </Box>
  );
}

export type Hint = [key: string, label: string];

export function KeyHints({ hints }: { hints: Hint[] }) {
  return (
    <Box paddingX={1} marginTop={1} flexWrap="wrap">
      {hints.map(([key, label]) => (
        <Box key={key} marginRight={2}>
          <Text color={theme.accent} bold>
            {key}
          </Text>
          <Text color={theme.muted}> {label}</Text>
        </Box>
      ))}
    </Box>
  );
}

export function ProgressBar({ done, total, width = 12 }: { done: number; total: number; width?: number }) {
  const filled = total === 0 ? 0 : Math.round((done / total) * width);
  const color = total > 0 && done === total ? theme.success : theme.accent;
  return (
    <Text>
      <Text color={color}>{"━".repeat(filled)}</Text>
      <Text color={theme.muted}>{"━".repeat(width - filled)}</Text>
      <Text color={theme.muted}>
        {" "}
        {done}/{total}
      </Text>
    </Text>
  );
}

export function StatusBadge({ status }: { status: FeatureStatus }) {
  const style = statusStyle[status];
  return <Text color={style.color}>● {style.label}</Text>;
}

export function Panel({ title, children, width, flexGrow, height }: { title: string; children: ReactNode; width?: number | string; flexGrow?: number; height?: number }) {
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.muted} paddingX={1} width={width} flexGrow={flexGrow} height={height} overflow="hidden">
      <Text color={theme.muted} bold>
        {title}
      </Text>
      {children}
    </Box>
  );
}

export function StatusBar({ items }: { items: Array<{ label: string; value: ReactNode }> }) {
  return (
    <Box paddingX={1} flexWrap="wrap">
      {items.map((item) => (
        <Box key={item.label} marginRight={3}>
          <Text color={theme.muted}>{item.label} </Text>
          <Text>{item.value}</Text>
        </Box>
      ))}
    </Box>
  );
}

export function Notice({ tone, children }: { tone: "info" | "success" | "warn" | "error"; children: ReactNode }) {
  const map = {
    info: { color: theme.accent, icon: "ℹ" },
    success: { color: theme.success, icon: symbols.done },
    warn: { color: theme.warn, icon: "⚠" },
    error: { color: theme.danger, icon: symbols.failed },
  } as const;
  return (
    <Box paddingX={1}>
      <Text color={map[tone].color}>{map[tone].icon} </Text>
      <Text>{children}</Text>
    </Box>
  );
}
