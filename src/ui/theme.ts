import type { FeatureStatus } from "../workflow.js";

export const theme = {
  accent: "cyan",
  brand: "magentaBright",
  muted: "gray",
  success: "green",
  warn: "yellow",
  danger: "red",
} as const;

export const symbols = {
  pointer: "❯",
  done: "✔",
  failed: "✖",
  pending: "○",
  active: "▶",
  blocked: "⊘",
  dot: "·",
  tool: "⚙",
} as const;

export const statusStyle: Record<FeatureStatus, { label: string; color: string }> = {
  ready: { label: "ready", color: theme.accent },
  "in-progress": { label: "in progress", color: theme.warn },
  blocked: { label: "blocked", color: theme.danger },
  done: { label: "done", color: theme.success },
};

export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (value: number): string => String(value).padStart(2, "0");
  return hours ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`;
}

export function truncate(text: string, width: number): string {
  if (width <= 1) return "";
  return text.length > width ? `${text.slice(0, width - 1)}…` : text;
}
