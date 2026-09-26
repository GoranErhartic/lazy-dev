import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  credentialsFile,
  maskKey,
  readGlobalConfig,
  resolveApiKey,
  saveApiKey,
  writeGlobalConfig,
} from "../src/config/global.js";
import { bootstrapRepo, readRepoConfig, resolveModels } from "../src/config/repo.js";
import { isDirty } from "../src/engine/git.js";
import { makeRepo, sh } from "./helpers.js";

const models = { impl: "impl", review: "rev", review2: "rev2" };

describe("global config", () => {
  const saved = { dir: process.env.LAZY_DEV_CONFIG_DIR, key: process.env.CURSOR_API_KEY };

  beforeEach(() => {
    process.env.LAZY_DEV_CONFIG_DIR = mkdtempSync(join(tmpdir(), "lazydev-config-"));
    delete process.env.CURSOR_API_KEY;
  });

  afterEach(() => {
    process.env.LAZY_DEV_CONFIG_DIR = saved.dir;
    if (saved.key === undefined) delete process.env.CURSOR_API_KEY;
    else process.env.CURSOR_API_KEY = saved.key;
  });

  it("stores the API key with 0600 permissions and lets the environment win", async () => {
    await saveApiKey("  stored-key-1234 ");
    expect(statSync(credentialsFile()).mode & 0o777).toBe(0o600);
    expect(await resolveApiKey()).toEqual({ key: "stored-key-1234", source: "file" });

    process.env.CURSOR_API_KEY = "env-key-9999";
    expect(await resolveApiKey()).toEqual({ key: "env-key-9999", source: "env" });
    expect(maskKey("env-key-9999")).toBe("••••9999");
  });

  it("round-trips models and rejects incomplete configs", async () => {
    expect(await readGlobalConfig()).toBeUndefined();
    await writeGlobalConfig({ version: 1, models, maxIterations: 5 });
    expect(await readGlobalConfig()).toEqual({ version: 1, models, maxIterations: 5 });
  });

  it("merges per-repo model overrides over global defaults", async () => {
    await writeGlobalConfig({ version: 1, models });
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });
    expect(await resolveModels(root)).toEqual(models);
  });
});

describe("repo bootstrap", () => {
  it("keeps local-only state out of the tree via .git/info/exclude", async () => {
    const root = makeRepo();
    await bootstrapRepo(root, { tracked: false });

    expect(await readRepoConfig(root)).toEqual({ tracked: false, models: undefined });
    expect(readFileSync(join(root, ".git", "info", "exclude"), "utf8")).toContain("/.lazy-dev/");
    expect(isDirty(root)).toBe(false);
  });

  it("commits tracked state when asked, leaving a clean tree", async () => {
    const root = makeRepo();
    const result = await bootstrapRepo(root, { tracked: true, commit: true });

    expect(result.commit).toMatch(/^[0-9a-f]+$/);
    expect(sh(root, ["log", "-1", "--format=%s"])).toBe("chore: initialize lazy-dev");
    expect(isDirty(root)).toBe(false);
  });
});
