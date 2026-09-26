import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface ModelConfig {
  impl: string;
  review: string;
  review2: string;
}

export interface GlobalConfig {
  version: 1;
  models: ModelConfig;
  maxIterations?: number;
  timeoutMinutes?: number;
}

export type ApiKeySource = "env" | "file";

export function configDir(): string {
  if (process.env.LAZY_DEV_CONFIG_DIR) return process.env.LAZY_DEV_CONFIG_DIR;
  return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "lazy-dev");
}

const configPath = (): string => join(configDir(), "config.json");
const credentialsPath = (): string => join(configDir(), "credentials");

async function writePrivate(path: string, contents: string, mode: number): Promise<void> {
  await mkdir(configDir(), { recursive: true, mode: 0o700 });
  const tmp = `${path}.tmp`;
  await writeFile(tmp, contents, { mode });
  await chmod(tmp, mode);
  await rename(tmp, path);
}

export function isModelConfig(value: unknown): value is ModelConfig {
  if (typeof value !== "object" || value === null) return false;
  const models = value as Record<string, unknown>;
  return ["impl", "review", "review2"].every((key) => typeof models[key] === "string" && models[key] !== "");
}

export async function readGlobalConfig(): Promise<GlobalConfig | undefined> {
  try {
    const parsed = JSON.parse(await readFile(configPath(), "utf8")) as Partial<GlobalConfig>;
    if (!isModelConfig(parsed.models)) return undefined;
    return { ...parsed, version: 1, models: parsed.models };
  } catch {
    return undefined;
  }
}

export async function writeGlobalConfig(config: GlobalConfig): Promise<void> {
  await writePrivate(configPath(), `${JSON.stringify(config, null, 2)}\n`, 0o644);
}

export async function readStoredApiKey(): Promise<string | undefined> {
  try {
    const parsed = JSON.parse(await readFile(credentialsPath(), "utf8")) as { apiKey?: unknown };
    return typeof parsed.apiKey === "string" && parsed.apiKey.trim() ? parsed.apiKey.trim() : undefined;
  } catch {
    return undefined;
  }
}

export async function saveApiKey(apiKey: string): Promise<void> {
  await writePrivate(credentialsPath(), `${JSON.stringify({ apiKey: apiKey.trim() })}\n`, 0o600);
}

export async function resolveApiKey(): Promise<{ key: string; source: ApiKeySource } | undefined> {
  const fromEnv = process.env.CURSOR_API_KEY?.trim();
  if (fromEnv) return { key: fromEnv, source: "env" };
  const stored = await readStoredApiKey();
  return stored ? { key: stored, source: "file" } : undefined;
}

export async function requireApiKey(): Promise<string> {
  const resolved = await resolveApiKey();
  if (!resolved) throw new Error("No Cursor API key found. Run `lazydev init` or export CURSOR_API_KEY.");
  return resolved.key;
}

/** Shows only the last four characters of a secret. */
export function maskKey(key: string): string {
  return `••••${key.slice(-4)}`;
}

export function credentialsFile(): string {
  return credentialsPath();
}

export function globalConfigFile(): string {
  return configPath();
}
