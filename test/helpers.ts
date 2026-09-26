import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function sh(cwd: string, args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

export function makeRepo(): string {
  const root = mkdtempSync(join(tmpdir(), "lazydev-test-"));
  sh(root, ["init", "-q", "-b", "main"]);
  sh(root, ["config", "user.email", "test@example.com"]);
  sh(root, ["config", "user.name", "Test"]);
  sh(root, ["config", "commit.gpgsign", "false"]);
  writeFileSync(join(root, "README.md"), "# test\n");
  sh(root, ["add", "-A"]);
  sh(root, ["commit", "-q", "-m", "init"]);
  return root;
}
