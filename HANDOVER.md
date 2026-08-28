# Lazy Dev — Implementation Handover

This document is a **self-contained work plan** for a chain of fresh-context agents.
Each agent (iteration) implements exactly ONE chunk, verifies it, marks it resolved,
leaves a handoff note, commits, and stops. The next agent picks up where it left off.

A senior review of the lazy-dev agent loop (`go.sh`, `prompt.md`, `rules/`, `commands/`,
README, templates) found 26 defects and gaps, ordered by severity. This file is the
implementation plan for all of them. **The review conversation is not available to you —
everything you need is in this file.**

---

## 0. How to Operate (read this first)

### The Ritual — follow exactly

1. **Read** this entire file. It is your complete brief.
2. **Select your chunk**: scan the QUEUE (section 2) for the first line starting with `- [ ]`.
   - If that line is tagged `⛔ BLOCKED (attempts: N)` with **N < 3** → work it (it is a retry).
   - If tagged `⛔ BLOCKED (attempts: N)` with **N ≥ 3** → it is PARKED; skip to the next untagged `- [ ]` line.
   - If **all** lines are `- [x]` → the plan is complete. Verify the section 4 log contains the CHUNK-026 end-to-end evidence; if not, do that, then stop.
3. **Pre-flight**: run `git status` in the repo root. If the tree is dirty, or the queue/notes show a chunk was partially edited by a crashed run, reconcile first (finish the edit or revert it) and record what you found in your handoff note.
4. **Implement ONLY the selected chunk**, per its spec in section 3. Work strictly in queue order — later chunks assume earlier ones landed. Do not start other chunks, do not redesign adjacent chunks.
5. **Verify** every acceptance criterion in the chunk. Run the listed commands and capture the key output — you will paste evidence into your handoff note.
6. **Mark resolved**: in the QUEUE, change `- [ ]` to `- [x]` and append `(RESOLVED <YYYY-MM-DD>, commit b529bd0)` to that line.
7. **Append a handoff note** to section 4 using the template below.
8. **Commit** — one commit containing your code changes + the queue flip + the handoff note:
   ```
   chore(lazy-dev): resolve CHUNK-00X — <title>
   ```
9. **STOP.** Do not start the next chunk. Do not push.

### Your Guardrails

- **Never `git push`.** Never rewrite history (no `--amend`, no `rebase`, no `reset --hard`).
- **Never run the real agent loop** (`./go.sh <feature>`) against this repo or any real project. This repo is the artifact, not a test target. All behavioral tests happen in **scratch repos** (e.g. `/tmp/lazydev-test-*`) using `LAZY_DEV_FAKE_AGENT` (see section 1).
- Run `bash -n go.sh` after **every** edit to `go.sh`.
- **Scope fence**: each chunk lists the files it may touch. Edit only those (plus `HANDOVER.md` itself). No drive-by refactors, no reformatting untouched code.
- If the spec is ambiguous, make the **minimum sane interpretation**, implement it, and record the deviation in your handoff note. Do not silently redesign.
- If you are **genuinely blocked**: leave the checkbox `- [ ]`, retag the queue line `⛔ BLOCKED (attempts: N)` (N = previous attempts + 1), write a handoff note stating exactly where you are stuck and what you tried, commit, and stop. Do NOT mark it resolved.
- Chunk specs reference **function names**, not line numbers — `go.sh` changes shape as chunks land. Locate code by function/symbol, then read around it.

### Handoff Note Template (append to section 4, newest last)

```markdown
### CHUNK-00X — <title> (RESOLVED <date> | commit b529bd0)
- **Did:** <1–3 sentences; list files changed>
- **Deviations from spec:** <none | what and why>
- **Gotchas:** <things that surprised you; traps the next agent should know>
- **Verification evidence:** <commands run + the key lines of output that prove each acceptance criterion>
- **State left behind:** <branch, dirty files, anything the next chunk must know>
- **First step for next chunk (CHUNK-00Y):** <one concrete line>
```

### Exit Code Conventions (for `go.sh`, used by several chunks)

| Code | Meaning |
|------|---------|
| 0 | All stories completed (or session finished cleanly) |
| 1 | Config/setup error, or max iterations reached |
| 2 | Budget exceeded (cost/time breaker — CHUNK-020) |
| 3 | All remaining stories blocked (stuck feature — CHUNK-013) |
| 124 | Single iteration timed out (internal to the loop) |

---

## 1. Context

### What this repo is

`lazy-dev` is an autonomous agent-loop framework for the Cursor CLI (a "Ralph-style"
loop). `go.sh` runs `cursor-agent` headless in a `while true` loop; each iteration is a
fresh agent session that reads state from files, implements one user story from a PRD,
and writes state back. It is designed to be copied into a project's `.cursor/lazy-dev/`.

### File Map

| File | Role |
|------|------|
| `go.sh` | The loop: arg parsing, spinner, NDJSON parser, git branch setup, push blocker, retry/timeout logic, main loop. ~1550 lines of bash. |
| `prompt.md` | The agent prompt, passed to every `cursor-agent -p` invocation. |
| `rules/agent-loop.mdc` | Iteration lifecycle, handoff protocol, commit conventions. |
| `rules/task-breakdown.mdc` | Story → sub-task decomposition protocol. |
| `rules/quality-gates.mdc` | Definition of Done, build/test/lint gates, commit types. |
| `rules/pattern-discovery.mdc` | How/when to write `rules/discovered/*.mdc` pattern files. |
| `rules/discovered/` | Cross-feature learned patterns (currently empty, `.gitkeep`). |
| `commands/generate-prd.md` | Cursor command that interviews the user and produces `prd.json`. |
| `examples/prd.json`, `examples/progress.txt` | Templates copied into each `features/<name>/`. |
| `README.md` | User-facing docs (currently drifting from the script — CHUNK-025 syncs it). |

Key functions in `go.sh` (locate by name): `parse_agent_output`, `run_iteration`,
`main`, `verify_setup`, `setup_feature_branch`, `install_push_blocker` /
`remove_push_blocker`, `stash_lazy_dev_files` / `pop_lazy_dev_stash`,
`archive_previous_run`, `track_branch`, `get_story_counts`,
`verify_all_stories_complete`, `get_next_story_id`, `get_model_for_story`,
`cleanup`, `cleanup_iteration`, `kill_tree` / `kill_descendants`,
`handle_interrupt`, `initialize_progress_file`, `safe_jq`, `strip_ansi`,
`print_line`, `normalize_newlines`.

### Why This Work Exists (review summary)

The core design (file-based state, stateless iterations, completion via PRD flags,
dual-model review) is sound. The review found six critical (P0) problems, nine high
(P1), and eleven medium/low (P2/P3). In one line each, the P0s:

1. **Failure detection is dead** — the pipeline exit status never reflects agent failure, and `run_iteration` always returns 0, so the retry system can never fire. → CHUNK-001
2. **Premature completion** — `passes == false` semantics treat missing/null/string `passes` as *complete*; an empty PRD "complements" instantly. → CHUNK-002/003
3. **Corrupted PRD kills the loop** — unguarded `jq` under `set -e` aborts the whole script; agents can corrupt `prd.json`. → CHUNK-003
4. **`pkill -9 -f` sweeps kill the user's own processes** on the same repo, after every iteration. → CHUNK-004
5. **Jira-prefixed story IDs silently disable the dual-model review** (model mapping matches literal `US-REVIEW` only). → CHUNK-005
6. **The rules don't auto-apply** (`.cursor/lazy-dev/rules/` is outside Cursor's rule discovery paths) — the whole behavioral protocol rests on the agent voluntarily reading files. → CHUNK-009

### Test Tools You Will Use

- **`bash -n go.sh`** — syntax check. Run after every edit to `go.sh`.
- **Source harness** — from CHUNK-001 onward, `go.sh` is safe to source (its CLI parsing + `main` call sit behind a `BASH_SOURCE` guard). Call functions directly:
  ```bash
  bash -c 'source ./go.sh __test__; get_model_for_story "MED-523-REVIEW"'
  ```
- **`LAZY_DEV_FAKE_AGENT=<path>`** — introduced in CHUNK-001. When set, `run_iteration` uses this script instead of the real Cursor CLI, receiving the same arguments (the prompt is the last argument). Point it at a small script that emits a minimal NDJSON `result` event and exits 0/1. This is how you test loop behavior **without** launching a real agent.
- **`LAZY_DEV_PRINT_CONTEXT=1`** — introduced in CHUNK-007. Prints the final assembled prompt (CONTEXT) before launching the agent. Use it to verify what the agent actually receives.
- **Scratch repos** — `git init /tmp/lazydev-tX && cd ... && copy lazy-dev in` for any behavioral test. Clean up when done.

---

## 2. Queue

Work top to bottom. First `- [ ]` line = your chunk.

- [x] CHUNK-001 — Failure detection: pipefail + is_error + real exit codes (+ test hooks) (RESOLVED 2026-08-25, commit b4dea7a)
- [x] CHUNK-002 — Fail-safe PRD completion predicate (shared jq, `passes != true`) (RESOLVED 2026-08-27, commit 32eefa6)
- [x] CHUNK-003 — Bootstrap PRD validation + corrupted-PRD recovery (RESOLVED 2026-08-27, commit 07e340a)
- [x] CHUNK-004 — Session-scoped process kills (replace `pkill -f` sweeps) (RESOLVED 2026-08-27, commit 38fb6cb)
- [x] CHUNK-005 — Model selection by story type (Jira IDs) + per-story `model` field (RESOLVED 2026-08-27, commit 26c6655)
- [x] CHUNK-006 — Model env overrides + fallback to CLI default model (RESOLVED 2026-08-27, commit 6f6e08f)
- [x] CHUNK-007 — Derived paths (no hardcoded `.cursor/lazy-dev`) + `LAZY_DEV_PRINT_CONTEXT` (RESOLVED 2026-08-27, commit 6df4edd)
- [x] CHUNK-008 — Prompt/rules dedup (one canonical git policy, one commit-type table) (RESOLVED 2026-08-27, commit b529bd0)
- [x] CHUNK-009 — Runner-inlined rule injection (deterministic protocol) (RESOLVED 2026-08-27, commit 31b8fc8)
- [x] CHUNK-010 — Assigned-story injection into CONTEXT (RESOLVED 2026-08-27, commit 0f0bb02)
- [x] CHUNK-011 — Git safety hardening in prompt (no `git add .`, expanded forbiddens) (RESOLVED 2026-08-27, commit f1b4ee6)
- [x] CHUNK-012 — Read-only review contract + diff-range context for reviewers (RESOLVED 2026-08-27, commit 48fea59)
- [x] CHUNK-013 — Stuck-story accounting (`attempts` / `blocked` / parked, exit 3) (RESOLVED 2026-08-27, commit 1e7aac9)
- [x] CHUNK-014 — Dirty-tree / killed-iteration recovery (RESOLVED 2026-08-27, commit a389307)
- [x] CHUNK-015 — Runner-owned state commits (remove the amend ambiguity) (RESOLVED 2026-08-27, commit 07cdbf4)
- [x] CHUNK-016 — Runner-enforced quality gate (build/test after each flip) (RESOLVED 2026-08-27, commit bb9b423)
- [x] CHUNK-017 — Concurrency lock (one session per feature) (RESOLVED 2026-08-27, commit f85bd5d)
- [x] CHUNK-018 — Context bloat caps + "data, not commands" framing (RESOLVED 2026-08-27, commit 34fc7b2)
- [x] CHUNK-019 — Stall watchdog + parser polish (dead code, color leak, shape warnings) (RESOLVED 2026-08-27, commit aeffb94)
- [x] CHUNK-020 — Cost / time budget breaker (exit 2) (RESOLVED 2026-08-27, 3a2aab8)
- [x] CHUNK-021 — Branch-name source of truth (PRD `branchName` wins) (RESOLVED 2026-08-27)
- [x] CHUNK-022 — Safe resume semantics (rebase opt-in, stash-pop re-verify) (RESOLVED 2026-08-27)
- [x] CHUNK-023 — CLI surface polish (help text, naming, `printf`) (RESOLVED 2026-08-28, 165710b)
- [ ] CHUNK-024 — `generate-prd` fixes (command discoverability + content errors)
- [ ] CHUNK-025 — Template + README synchronization
- [ ] CHUNK-026 — End-to-end verification + final report

Phase guide: **001–006** core loop correctness · **007–012** deterministic context & prompt · **013–020** robustness & quality · **021–026** consistency, docs, E2E.

---

## 3. Chunk Specs

### CHUNK-001 — Failure detection: pipefail + is_error + real exit codes (+ test hooks)

**Why.** Three compounding bugs make the retry system dead code: (a) the pipeline
`agent | tee | parse_agent_output` runs in a subshell whose exit status is the *last*
stage (`parse_agent_output`, always 0), masking agent crashes; (b) `parse_agent_output`
sees `result.is_error` but only prints a banner, never propagates it; (c) `run_iteration`
ends with `echo ""`, so it returns 0 unconditionally — `if run_iteration ...` in `main`
never retries, and the "Iteration failed (exit N)" banner is unreachable.

**Do.**
1. In `run_iteration`'s pipeline subshell (the `( ... ) &` block), add `set -o pipefail` as the first line, so any stage failing (notably the agent itself) makes the subshell exit non-zero.
2. In `parse_agent_output`, when a `result` event with `is_error == true` is parsed, set a local flag; at the end of the function, `return 1` if set (else `return 0`).
3. At the end of `run_iteration`, replace the implicit success with an explicit `return $exit_code` (keep computing `exit_code` from `wait` / timeout as today; 124 for timeout).
4. In `main`'s retry loop: replace the fixed `sleep 5` with exponential backoff (5s, 15s, 45s). Add **fast-fail**: expose the iteration duration via a global (e.g. `LAST_ITERATION_DURATION`, set in `run_iteration`); if a failed iteration lasted **< `LAZY_DEV_FASTFAIL_SECS`** (new env var, default 60, `0` disables fast-fail), do not retry — break out and report (sub-60s failures are almost always config/auth/model errors, not transient ones).
5. **Test hooks** (needed by many later chunks):
   - Wrap the top-level arg-validation block and the final `main "$@"` call in `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then ... fi` so the file can be sourced safely for function-level tests.
   - Add `LAZY_DEV_FAKE_AGENT`: when set (non-empty), `run_iteration` uses it as the executable in place of `cursor`/`cursor-agent` (keep the same flags + prompt argument; it still goes through the existing `tee | parse_agent_output` pipeline). Log which binary is being used.

**Files.** `go.sh` only.

**Verify.**
- `bash -n go.sh`.
- Source harness: source `go.sh` with a dummy arg; confirm `main` does **not** run (no loop output).
- Scratch repo + a fake agent script that sleeps 2s, emits a valid NDJSON `result` event with `"is_error": true`, exits 1 → run `./go.sh` (with `LAZY_DEV_FAKE_AGENT`, `--max-iterations 2`, default fast-fail): expect the "Iteration failed" banner, exactly **one** attempt, a clear "fast-fail" log line, and **no** retry (duration < 60s).
- Same fake agent with `LAZY_DEV_FASTFAIL_SECS=0` → expect 3 attempts with 5s/15s backoff (proves the backoff schedule works when fast-fail is off).
- A fake agent that exits 0 with `is_error: false` → "Iteration complete", no retry.

**Don't.** Touch `prompt.md`, `rules/`, completion predicates (CHUNK-002), or the pkill logic (CHUNK-004).

---

### CHUNK-002 — Fail-safe PRD completion predicate

**Why.** `verify_all_stories_complete` counts only stories with `passes` *explicitly*
`false` as incomplete. A story whose `passes` is missing, `null`, or the string
`"true"` (all plausible agent typos) is treated as **complete** → the loop exits 0 with
unfinished work. A PRD with zero stories reports "All stories completed" instantly.
Meanwhile `get_story_counts` uses `passes == true` (strict) — the two functions disagree
on the same file.

**Do.**
1. Define ONE canonical jq expression (a bash variable or small helper) for "incomplete story": `select(.passes != true)`.
2. `verify_all_stories_complete`: complete ⟺ PRD parses **and** `.userStories | length > 0` **and** zero stories match the incomplete predicate. A PRD that fails to parse is **never** complete (keep the existing `|| echo "-1"` → return 1 direction).
3. `get_story_counts`: `completed` stays `select(.passes == true)`, but `total` must be `length` of the array regardless of `passes`; on parse failure return `0/0` (today's behavior) — but the function must also be safe when `userStories` is missing.
4. `get_next_story_id`: select with the incomplete predicate (`.passes != true`) instead of `== false`; keep `sort_by(.priority)`; on any parse failure return empty string **without a non-zero exit** (add `|| true` semantics) — CHUNK-003 builds on this.

**Files.** `go.sh` only (the three functions above).

**Verify.** `bash -n`. Source harness + temp PRDs in `/tmp`:
(a) one story with `passes` missing → incomplete, next-story = that story;
(b) `passes: null` → incomplete;
(c) `passes: "true"` (string) → incomplete;
(d) `userStories: []` → **not** complete;
(e) all `passes: true` → complete.
Assert all five via the three functions' return values/outputs.

**Don't.** Touch the main loop, model selection, or validation (CHUNK-003).

---

### CHUNK-003 — Bootstrap PRD validation + corrupted-PRD recovery

**Why.** `next_story_id=$(get_next_story_id "$PRD_FILE")` in `run_iteration` is an
unguarded command substitution; `jq` on invalid JSON exits non-zero, which under
`set -e` **aborts the entire script** with no useful message. This is a realistic
failure: the agent edits `prd.json` with a file-write tool and can produce malformed
JSON, and a corrupted PRD then kills every subsequent run.

**Do.**
1. Audit every top-level/`set -e`-exposed command substitution in `go.sh` that touches `prd.json` (search for `PRD_FILE`); ensure each is guarded (`|| echo ""` / `|| true`) so a bad PRD degrades gracefully instead of killing the script.
2. New function `validate_prd`, called from `verify_setup` (after the `jq` availability check): verify with `jq` that (a) the file parses, (b) `.userStories` is a non-empty array, (c) every story has a non-empty `.id`, a numeric `.priority`, and a **boolean** `.passes`. On failure: print a clear, specific error (which check, which story id) plus remediation guidance, `exit 1`.
3. `prompt.md`: add one paragraph to the loop protocol (near the "Files to Read First" area): if `prd.json` fails to parse, first restore it from the last commit (`git checkout -- <prd path>`), re-verify it parses, and only then proceed.

**Files.** `go.sh` (new function + guard audit), `prompt.md` (one paragraph).

**Verify.** `bash -n`. Source harness:
- corrupted PRD (truncated JSON) → `validate_prd` prints the specific error and returns non-zero; no `set -e` trace.
- PRD with a story missing `.passes` → rejected with the story id named.
- valid PRD → passes.
- Also confirm `run_iteration` no longer aborts the script on a bad PRD (source harness: call `get_next_story_id` on the corrupted file → empty string, exit 0).

**Don't.** Touch predicates' semantics (already done in 002 — just reuse them), model logic, or the loop.

---

### CHUNK-004 — Session-scoped process kills (replace `pkill -f` sweeps)

**Why.** `cleanup` and `cleanup_iteration` both run
`pkill -9 -f "cursor-agent.*$PROJECT_ROOT"`, `pkill -9 -f "node.*dist/entry/worker.*$PROJECT_ROOT"`
(and a `script -q /dev/null...` variant) — the latter **after every single iteration**.
`pkill -f` matches any process whose command line contains the project path: the user's
own concurrent Cursor IDE session, another terminal's `cursor-agent`, a dev server —
all get SIGKILLed, unattended. The interpolated path is also regex-unsafe.

**Do.**
1. In `run_iteration`, prepend a unique marker line to the prompt passed to the agent, e.g. `<!-- lazy-dev session: lazydev-$$-<start-epoch> -->` (harmless to the model). Store the marker in a global `LAZY_DEV_SESSION_MARKER`.
2. Remove both `pkill -9 -f` blocks (in `cleanup` and `cleanup_iteration`).
3. Replace them with ONE last-resort sweep that matches only our own session: `pkill -9 -f "$LAZY_DEV_SESSION_MARKER"` — a user process can never contain our run-unique marker. Keep `kill_descendants`/`kill_tree` on the tracked PIDs as the primary mechanism (they already cover children, including the node workers and the `script` wrapper, whose argv carries the marker).
4. Keep the existing `pkill -9 -P $$` direct-child sweep (it is PID-scoped, safe).

**Files.** `go.sh` only (`run_iteration` CONTEXT build, `cleanup`, `cleanup_iteration`).

**Verify.** `bash -n`. Behavior test in a scratch repo:
- Start a decoy long-lived process whose command line contains `cursor-agent` **and** the project path but NOT the marker (e.g. `bash -c 'sleep 300' -- cursor-agent <path>`).
- Source `go.sh`, set the marker, run `cleanup_iteration` → the decoy **survives**.
- Start a second decoy whose args include the marker → it **dies**.
- A fake-agent run's actual `cursor-agent`-equivalent process is still cleaned up (no orphans after the run: `ps` check).

**Don't.** Touch the push blocker, the lock (CHUNK-017), or the parser.

---

### CHUNK-005 — Model selection by story type (Jira IDs) + per-story `model` field

**Why.** `get_model_for_story` case-matches the literal strings `US-REVIEW` /
`US-REVIEW-2`. But `generate-prd.md` mandates **Jira-prefixed** ids for Jira-linked PRDs
(`MED-523-REVIEW`, `MED-523-REVIEW-2`, `MED-523-IMPL-RECS`). For every Jira PRD the
review stories fall through to the default implementation model — the dual-model review
(GPT-5.3-Codex + Gemini-3-Pro) silently never activates for exactly the team workflow.
The parser's story-banner regex (`US-[A-Z0-9-]+`) has the same blind spot.

**Do.**
1. `get_model_for_story`: match by **type**, not literal id. Order matters: test `*-REVIEW-2` before `*-REVIEW` (suffix matching; `US-REVIEW-2` must not match the first-review pattern). Suffixes: `*-REVIEW` → first-review model; `*-REVIEW-2` → second-review model; `*IMPL-RECS` / `*IMPLEMENT-RECS` → implementation model; anything else → implementation model.
2. Support an optional per-story `"model"` field in `prd.json`: a new helper (or extension of `get_next_story_id`'s call site) reads `.model` for the next story; if present and non-empty it overrides the type mapping.
3. Parser: broaden the story-banner regex to also catch Jira-style ids, e.g. `(US|[A-Z]{2,10}-[0-9]{3,})-[A-Z0-9-]+`.
4. `prompt.md`: in the dual-model table, note that ids may be Jira-prefixed and that the mapping is by suffix (`*-REVIEW`, `*-REVIEW-2`).

**Files.** `go.sh` (`get_model_for_story`, parser banner regex, next-story lookup), `prompt.md` (one table note).

**Verify.** `bash -n`. Source harness:
- `get_model_for_story` (or the new combined helper) returns: `US-REVIEW` → gpt-5.3-codex; `US-REVIEW-2` → gemini-3-pro; `US-007` → opus-4.6; `MED-523-REVIEW` → gpt-5.3-codex; `MED-523-REVIEW-2` → gemini-3-pro; `MED-523-IMPL-RECS` → opus-4.6.
- A temp PRD whose next story has `"model": "composer"` → the selected model is `composer`.
- `bash -n` + a fake-agent run on a PRD whose next story is `MED-523-REVIEW` → the "Story: ... → Model: ..." log line shows the review model.

**Don't.** Touch env overrides (CHUNK-006), predicates (002), or the retry logic.

---

### CHUNK-006 — Model env overrides + fallback to CLI default model

**Why.** Model names (`opus-4.6`, `gpt-5.3-codex`, `gemini-3-pro`) are hardcoded in
bash. If a model id is invalid or unavailable on the user's plan, those iterations fail
— and with CHUNK-001's fast-fail, they fail *loudly* but still waste the iteration
budget. Operators need to override models per-environment, and the loop should fall
back to the CLI default rather than dying on a missing model.

**Do.**
1. Env vars consumed by `get_model_for_story`: `LAZY_DEV_MODEL_IMPL` (default `opus-4.6`), `LAZY_DEV_MODEL_REVIEW` (default `gpt-5.3-codex`), `LAZY_DEV_MODEL_REVIEW2` (default `gemini-3-pro`). The per-story `"model"` field (005) still wins over env.
2. In `main`'s retry path: if an iteration fast-failed (CHUNK-001) **and** a non-default `--model` was used, retry **once** with `--model` omitted entirely (CLI default). Implement by having `run_iteration` accept an optional "no model" override (e.g. a global flag or argument) rather than parsing CLI args again.
3. Add the three env vars to the `--help` text (a "Environment variables" block; CHUNK-025 will extend it).

**Files.** `go.sh` (`get_model_for_story`, `run_iteration` signature/flags, `main` retry, `--help`).

**Verify.** `bash -n`. Source harness: `LAZY_DEV_MODEL_IMPL=foo get_model_for_story "US-001"` → `foo`. Scratch-repo fake-agent test: fake agent always fast-fails; PRD next story is a `*-REVIEW` → expect: attempt 1 with `--model <review model>`, fast-fail, attempt 2 **without** `--model` (visible in the debug log of the executed command), then stop. Record the log lines as evidence.

**Don't.** Touch model *mapping* semantics (005), the gate (016), or docs beyond `--help`.

---

### CHUNK-007 — Derived paths (no hardcoded `.cursor/lazy-dev`) + `LAZY_DEV_PRINT_CONTEXT`

**Why.** `run_iteration`'s CONTEXT block hardcodes `.cursor/lazy-dev/features/...` and
`.cursor/lazy-dev/rules/discovered/` in the agent-facing paths. The script already
computes everything from `SCRIPT_DIR` — if lazy-dev is installed anywhere other than
`.cursor/lazy-dev/`, the agent is pointed at nonexistent paths. Separately,
`prompt.md` and `generate-prd.md` mix `.cursor/rules/` with `~/.cursor/rules/` (home
dir), and `prompt.md`'s "Files to Read First" cites `lazy-dev/rules/*.mdc` — a
project-root-relative path that doesn't resolve.

**Do.**
1. In `go.sh`, compute `LAZY_DEV_REL` = `SCRIPT_DIR` relative to `PROJECT_ROOT` (e.g. `.cursor/lazy-dev`; handle the case where they're equal → `.`). Use it to build **all** agent-facing paths in CONTEXT (PRD, progress, discovered dir).
2. Add `LAZY_DEV_PRINT_CONTEXT=1`: when set, `run_iteration` prints the final assembled CONTEXT to stderr (or a clearly delimited block) right before launching the agent. Many later chunks verify via this.
3. Path phrasing pass (consistency, not content): in `prompt.md`, `commands/generate-prd.md`, and `examples/prd.json` notes, make every path reference either project-root-relative with the real lazy-dev location, or the neutral phrasing "the lazy-dev directory (exact path is in your Feature Context)". Replace the `~/.cursor/rules/` occurrences with `.cursor/rules/`, and add "(if it exists in this project)" to project-rules references so a project without `.cursor/rules/` doesn't send the agent on a wild goose chase.

**Files.** `go.sh` (CONTEXT block + print hook), `prompt.md`, `commands/generate-prd.md`, `examples/prd.json` (notes fields only).

**Verify.** `bash -n`. Scratch repo **A** with lazy-dev at `.cursor/lazy-dev/` and scratch repo **B** with it at `tools/lazy-dev/`: in both, run with `LAZY_DEV_PRINT_CONTEXT=1` + fake agent → the Feature Context paths resolve to real files from the project root (you can `ls` each printed path from the repo root). Grep audit: no remaining literal `.cursor/lazy-dev` in `prompt.md`/`generate-prd.md` agent-facing paths; no `~/.cursor/rules` anywhere.

**Don't.** Change rule *content* (008), loop logic, or model logic.

---

### CHUNK-008 — Prompt/rules dedup (one canonical git policy, one commit-type table)

**Why.** The same rules are stated in multiple places and have already drifted:
the git policy appears in CONTEXT **and** `prompt.md` (and they contradict — CONTEXT
says `git add .`, the prompt body allows `git add <files>`); commit conventions appear
in `prompt.md` + `agent-loop.mdc` + `quality-gates.mdc`, and the type sets disagree
(`feat/fix/chore` vs `feat/fix/refactor/docs/test/chore`); the web-search/data rule is
stated ~5 times in `prompt.md` and re-listed in `agent-loop.mdc`. Duplication wastes
tokens every iteration and produces non-deterministic behavior when copies disagree.

**Do.**
1. **Git policy**: canonical home = `prompt.md` (one section). Reduce CONTEXT's git block to the single most critical line — the push ban — plus "full git policy in the prompt below". (CHUNK-011 will then harden the canonical section; don't do 011's work here.)
2. **Commit types**: pick ONE canonical table — use the full conventional set `feat / fix / refactor / test / docs / chore` with the existing one-line guidance (Jira id vs story id, `chore:` for reviews/state). Update `prompt.md`, `agent-loop.mdc`, and `quality-gates.mdc` to reference this same table verbatim (or one canonical table + pointers from the others — pick one, note it).
3. **Web-search/data rule**: compress `prompt.md`'s ~5-paragraph treatment into ONE compact section: the rule (web search only, never direct API calls), one correct/one wrong example pair, and the 3-attempts-then-fail path. Replace `agent-loop.mdc`'s re-listing with a one-line pointer ("data gathering: see the Web Search section of the main prompt").
4. Measure: `wc -w prompt.md rules/*.mdc` before and after; the combined total should drop meaningfully (target: at least 25–30% reduction; don't sacrifice the one-story rule or the review-story rules — those stay intact).

**Files.** `prompt.md`, `rules/agent-loop.mdc`, `rules/quality-gates.mdc`, `go.sh` (CONTEXT git block only — shrink it).

**Verify.** `bash -n`. Grep audit: `git push` forbidden-list appears in exactly one place (prompt.md) + the one-line CONTEXT ban; the commit-type table is identical (or pointer) in all three files; no two files both contain the full web-search rule. Record before/after word counts. Spot-read the final prompt to confirm the one-story rule, review-story rules, and "never ask the user" rule survived intact.

**Don't.** Touch loop logic, model logic, or `generate-prd.md`.

---

### CHUNK-009 — Runner-inlined rule injection (deterministic protocol)

**Why.** The four `.mdc` rules live in `.cursor/lazy-dev/rules/` with
`alwaysApply: true`. Cursor auto-discovers rules from `.cursor/rules/` (project) and
`~/.cursor/rules` (user) — not from arbitrary subfolders of `.cursor/` — so
`alwaysApply` is very likely a no-op. The protocol (quality gates, task breakdown,
pattern discovery) currently rests on the agent voluntarily `cat`-ing files at a path
that may not resolve. If the agent forgets, the entire behavioral protocol is silently
absent.

**Do.**
1. In `run_iteration`, assemble CONTEXT as: `prompt.md` + a separator + the full content of each `rules/*.mdc` (the four core rules), each introduced by a heading with its filename (e.g. `### rules/quality-gates.mdc`). Frontmatter may stay (it's small). Do NOT include `rules/discovered/` here — that gets capped injection in CHUNK-018.
2. **Verify empirically** what your installed CLI does: run `cursor agent --help` / `cursor-agent --help` and check for a rules-discovery flag or documented rule paths; if the CLI supports pointing at extra rule locations, prefer that over inlining. Record the finding in your handoff note either way.
3. `prompt.md`: replace "The rules in `rules/` define your behavior (they auto-apply)" with the truth: the loop injects the full protocol into your prompt; the files under `<lazy-dev>/rules/` are the canonical source.

**Files.** `go.sh` (CONTEXT assembly), `prompt.md` (one paragraph).

**Verify.** `bash -n`. `LAZY_DEV_PRINT_CONTEXT=1` + fake agent → the printed prompt contains all four rule bodies (grep for a unique phrase from each, e.g. "Definition of Done", "Decomposition Process", "Pattern Discovery Protocol", "Iteration Lifecycle"). The fake agent can also `cat` its argv to a file — assert the same. Record the CLI `--help` finding.

**Don't.** Touch discovered-patterns injection (018), the gate, or model logic.

---

### CHUNK-010 — Assigned-story injection into CONTEXT

**Why.** The script computes `next_story_id` (for model selection) but never tells the
agent which story it owns; the agent re-derives "highest priority incomplete" on its
own. If the agent disagrees with the script (misreads `passes`, prefers another story),
you get a model selected for story A while the agent works story B — and the
one-story-per-iteration invariant rests purely on model compliance.

**Do.**
1. In `run_iteration`, after computing the next story id, also fetch its title (jq). Add a `## Your Assignment` block to CONTEXT: `This iteration you will work EXACTLY one story: <ID> — <title>. Its full definition (description, acceptance criteria, notes) is in the PRD. Do not start any other story.`
2. Defensive: if `next_story_id` is empty (all complete, or PRD problem), **do not launch the agent** — log an error and let `main` handle it (with 002/003 in place this should not happen; treat it as a guardrail).
3. `prompt.md`: update the loop step "Select → Pick exactly ONE story where `passes: false` (highest priority first)" to "Select → Work the story assigned in your Feature Context (the runner selects it; do not override)".

**Files.** `go.sh` (CONTEXT assembly), `prompt.md` (one line).

**Verify.** `bash -n`. Scratch repo with a PRD whose incomplete stories have priorities 5, 1, 3 → `LAZY_DEV_PRINT_CONTEXT=1` + fake agent shows the assignment naming the priority-1 story. All-complete PRD → no agent launch, clean exit 0.

**Don't.** Touch model selection (005/006), predicates (002), or attempts (013).

---

### CHUNK-011 — Git safety hardening in the prompt (YOLO-proofing)

**Why.** The agent runs with `--force` (full auto-approve, unattended) and the policy
forbids only `push`. A panicked agent facing a failing build can `git reset --hard`,
`git checkout -- .`, `git clean -fd`, or `git rebase` and vaporize the feature's work —
nothing hard-stops it. Additionally CONTEXT says "use `git add . && git commit`" while
the prompt body allows `git add <files>` — and `git add .` from the workspace root
stages the **user's** unrelated dirty files too.

**Do.** (All in the canonical git section of `prompt.md` — the one established in CHUNK-008 — plus the CONTEXT one-liner.)
1. Staging rule: "Stage only the files you changed this iteration: `git add <file1> <file2> ...`. NEVER use `git add .` or `git add -A`." Remove the `git add .` instruction from CONTEXT.
2. Expand the forbidden list (keep the push ban first): `git push` (all forms), `git reset --hard`, bulk discards (`git checkout -- .`, `git restore --staged .`), `git clean -f`/`-fd`, `git rebase` (any form), `git branch -D`, and `git commit --amend` **except** the documented Final Story Commit Hygiene case (CHUNK-015 will retire that exception — keep it for now).
3. Add: "If the working tree contains changes you did not make, do not commit or revert them — note them in `progress.txt` and proceed with only your own files."

**Files.** `prompt.md`, `go.sh` (CONTEXT git block — small).

**Verify.** `bash -n`. Grep audit across `prompt.md` + the CONTEXT block: `git add .` appears only inside the "NEVER" sentence; the forbidden list contains all six operation families; the foreign-changes rule is present. (Content check only — no behavior test needed.)

**Don't.** Touch loop logic, the runner's own git usage, or state commits (015).

---

### CHUNK-012 — Read-only review contract + diff-range context for reviewers

**Why.** Nothing stops a "helpful" review agent (GPT-5.3-Codex / Gemini-3-Pro) from
quickly fixing findings — stealing scope from `US-IMPLEMENT-RECS` and making the two
reviews non-independent. Also, reviewers currently guess at the diff scope ("all
changes made during this feature implementation").

**Do.**
1. `prompt.md` (dual-model review section): "Review stories are **read-only with respect to source code**. You must not modify any source file. Your only writes: the review file (`review-gpt.md` / `review-gemini.md`) and the lazy-dev state files. Commit the review file only."
2. `go.sh` (`run_iteration`): when the assigned story is a review type (reuse CHUNK-005's type detection), compute the feature's diff base — `git merge-base <main-or-master> HEAD` — and add to CONTEXT: "Review scope: run `git diff <merge-base>..HEAD` to see all feature changes." (Resolve main/master the same way `setup_feature_branch` does.)
3. `rules/agent-loop.mdc` (Scope Discipline): one line — "Review stories are read-only with respect to source code."

**Files.** `prompt.md`, `go.sh` (CONTEXT assembly), `rules/agent-loop.mdc`.

**Verify.** `bash -n`. Scratch repo: feature branch with 2 commits; PRD whose next story is `*-REVIEW` → `LAZY_DEV_PRINT_CONTEXT=1` shows the read-only line AND a concrete `git diff <sha>..HEAD` range. An implementation story → no diff-range block.

**Don't.** Touch model selection, the gate (016), or state commits (015).

---

### CHUNK-013 — Stuck-story accounting (`attempts` / `blocked` / parked, exit 3)

**Why.** There is no per-story attempt counter and no `blocked` state. An infeasible
story is re-selected every iteration until `MAX_ITERATIONS` is exhausted — one hard
story fails the entire feature with no signal. The prompt's "if truly blocked, fail
the story" is undefined: `passes` stays `false`, so "failed" and "in progress" are
indistinguishable to the runner.

**Do.**
1. **Schema**: add `"attempts": 0` to every story in `examples/prd.json` and the `generate-prd.md` template. Treat the field as optional in code (default 0 when absent). Add a `"blocked"` boolean (default absent/false) — set only by the runner, never by the agent.
2. **Runner** (`go.sh`): new helper `record_story_attempt <story-id>` — jq-mutate the PRD (via temp file + `mv` for atomicity): `attempts = ((.attempts // 0) + 1)`, and when `attempts >= 3` set `blocked = true`. In `main`, after each iteration: if the **assigned** story (CHUNK-010's id) still has `passes != true` and is not already blocked → call the helper; when a story becomes blocked, append a prominent note to `progress.txt` and log a loud warning with the story id + its `notes`.
3. **Selection**: `get_next_story_id` selects from `select(.passes != true and (.blocked // false) | not)`.
4. **Terminal stuck state**: in `main`, if the PRD is not complete but **no** selectable story exists (all remaining are blocked) → print a clear "STUCK" report (ids + where to look) and `exit 3` (see exit-code table).
5. `prompt.md`: define "failing a story" concretely: "If you cannot complete the story after genuine attempts: leave `passes: false`, append a detailed `notes` entry (what you tried, why it's blocked, what a fresh iteration should try differently). Do NOT set `passes: true`. The runner tracks attempts and will park the story after repeated failures."

**Files.** `go.sh` (`get_next_story_id`, `main` loop, new helper), `prompt.md`, `examples/prd.json`, `commands/generate-prd.md` (template field).

**Verify.** `bash -n`. Source harness: `record_story_attempt` against a temp PRD — 1st call → attempts 1, not blocked; 3rd call → blocked true; jq round-trip keeps the PRD valid (run CHUNK-003's `validate_prd`). Scratch-repo fake-agent E2E-ish: fake agent never flips; PRD with 2 stories → after 3 iterations story A is blocked, the loop **picks story B** (assignment block proves it); make the fake agent also never flip B → after B parks, the run exits **3** with the STUCK report.

**Don't.** Touch the quality gate (016 — it will reuse your attempt helper), model logic, or the lock.

---

### CHUNK-014 — Dirty-tree / killed-iteration recovery

**Why.** The 30-minute timeout (or a Ctrl+C) SIGKILLs the agent mid-edit. The next
iteration inherits a dirty working tree with **no signal** that the previous run was
killed — the agent may commit the half-finished prior work as its own story, or be
confused by foreign changes.

**Do.**
1. `go.sh` (`run_iteration`): on timeout or interrupt, before returning, append a marker block to `progress.txt`: `## ⚠️ Iteration <N> was killed (<timeout|interrupt>) after <X>s. Uncommitted changes at kill time: <git status --porcelain, capped ~30 lines>. Next agent: reconcile before planning.`
2. `go.sh` (before each iteration, in `main` or at the top of `run_iteration`): if `git status --porcelain` is non-empty, inject into CONTEXT: "The working tree has uncommitted changes that predate this iteration: <list, capped>. Review them first — they may be a partially completed <assigned story>. Do not blindly commit or discard them."
3. **Deliberately no auto-commit** of unknown files by the runner (the runner can't distinguish the agent's work from the user's — see CHUNK-011's foreign-changes rule). The warning injection is the mechanism.
4. `rules/agent-loop.mdc` (Iteration Lifecycle): add step 0 to Bootstrap: "Check `git status` and `git log -3`. If the tree is dirty or the last commit looks half-finished, reconcile with `progress.txt` before planning — finish, complete, or note-and-continue. Never silently revert work you did not do."

**Files.** `go.sh` (`run_iteration` + pre-iteration check), `rules/agent-loop.mdc`.

**Verify.** `bash -n`. Scratch repo + fake agent that exits 1 **after** writing a stray file (no PRD flip): run 2 iterations → (a) `progress.txt` contains the kill marker with the stray file listed; (b) iteration 2's CONTEXT (via `LAZY_DEV_PRINT_CONTEXT=1`) contains the dirty-tree warning; (c) a clean-tree run injects **no** warning.

**Don't.** Touch the gate (016), state commits (015 — it must run *after* your warning logic, not instead of it), or attempts (013).

---

### CHUNK-015 — Runner-owned state commits (remove the amend ambiguity)

**Why.** Three documents disagree about when `prd.json`/`progress.txt` get committed:
CONTEXT says `git add .` (stages them mid-story), the loop says update state **after**
committing (leaving them dirty for the *next* story's `git add .`), and only the final
story is told to `--amend`. Net effect: PRD flips get committed by whichever story runs
next; a crash in between loses state; the amend rule is dead weight for 95% of stories
and a history-rewrite risk under `--force`.

**Do.**
1. `go.sh`: new `commit_state()` — if `git status --porcelain -- <LAZY_DEV_REL>` (from CHUNK-007) is non-empty, `git add <LAZY_DEV_REL>` and `git commit -m "chore: lazy-dev state (<feature>, <assigned-story-id>)"`. Never `git add .`/`-A`. Call it at the end of each iteration in `main` (after the quality gate from CHUNK-016 once it lands; for now, after the attempt recording).
2. `prompt.md`: **replace** the "Commit Hygiene: Amend for Uncommitted State Files" section with: "The loop runner commits lazy-dev state files automatically after each iteration. **Never commit anything under the lazy-dev directory.** Only commit your source-code changes."
3. `rules/agent-loop.mdc`: update the "Final Story Commit Hygiene" section to the same runner-owns-state wording (remove the amend instructions), and align the Handoff Protocol's "In prd.json" bullet ("You update the file; the runner commits it").

**Files.** `go.sh` (new function + call site), `prompt.md`, `rules/agent-loop.mdc`.

**Verify.** `bash -n`. Scratch repo + fake agent that (a) flips the assigned story and (b) appends to `progress.txt` and (c) commits a source file: after one iteration, `git log` shows **two** commits — the agent's source commit AND a `chore: lazy-dev state (...)` commit whose `git show --name-only` lists **only** files under the lazy-dev path; `git log -p -- <prd>` shows the flip landed in the state commit; no `--amend` anywhere in the history.

**Don't.** Touch the gate (016), the lock (017), or `git add .` policing (done in 011).

---

### CHUNK-016 — Runner-enforced quality gate (don't trust self-attestation)

**Why.** The same model that wrote the code declares "build passed, tests pass". The
single highest-ROI quality lever is for the **runner** to run the checks itself,
deterministically, before accepting a story flip.

**Do.**
1. `go.sh`: new `run_quality_gate()`:
   - Detect the toolchain: `package-lock.json`→npm, `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `Cargo.toml`→cargo, `go.mod`→go, `pom.xml`/`build.gradle*`→skip-with-log (keep the table small; **skip-on-unknown is better than fail-on-unknown**).
   - Run the project's `build` script, then its `test` script (read from `package.json` for JS; use conventional commands for others). If a script is absent, log "skipped (no script)" and continue — absence is not failure.
   - Per-gate timeout: `LAZY_DEV_GATE_TIMEOUT` (default 600s). Capture output to a temp file; on failure keep the first ~20 lines for the report.
2. In `main`, after each iteration: if the **assigned** story's `passes` flipped to `true` this iteration → run the gate. On **failure**: revert the flip (`passes: false` via the same atomic jq pattern as CHUNK-013), increment attempts (reuse `record_story_attempt`), append to `progress.txt`: `## 🚫 Runner quality gate FAILED for <story>: <gate output excerpt>. Next agent: fix the gate failures before re-marking this story.`, log a loud warning. On pass: log success.
3. Add `LAZY_DEV_GATE_TIMEOUT` to `--help`.

**Files.** `go.sh` (new function + `main` integration).

**Verify.** `bash -n`. Scratch npm repo with `package.json` scripts:
- `test` exits 1 + fake agent that flips the story → after the iteration: PRD shows `passes: false` again, `attempts` incremented, the `🚫` note present in `progress.txt` with the failing output excerpt.
- `test` exits 0 → flip stands, success logged, gate output summarized.
- No `package.json` at all → gate skipped with a log line, flip stands (no false failures).

**Don't.** Touch the parser, model logic, or the prompt (the gate is runner-side; the prompt's DoD already asks the agent to run checks — that stays as a first pass).

---

### CHUNK-017 — Concurrency lock (one session per feature)

**Why.** Nothing prevents two `go.sh` runs (same or different features, same repo) from
racing: branch-switch collisions, interleaved `prd.json` writes, and the single
`.git/lazy-dev-session.lock` getting clobbered — which also **unblocks pushes**
mid-session for the other run.

**Do.**
1. `go.sh` `main` (early, before git setup): acquire an exclusive lock on `$FEATURE_DIR/.lazy-dev.lock`:
   - If `flock` exists (Linux): `exec 9>"$lockfile"; flock -n 9 || die "another lazy-dev session is running for <feature> (PID in lock file)"`.
   - Else (macOS): atomic `mkdir` lock — `mkdir "$lockdir"` succeeds only once; write `$$` inside; on failure, read the stored PID, `kill -0` it: alive → die with a clear message; dead → stale, remove and retry once.
   - Release in `cleanup` (and on every exit path via the existing EXIT trap).
2. `install_push_blocker`: if `.git/lazy-dev-session.lock` exists and holds a **live** PID from another run, still install the blocker but log a warning that another session is active.
3. Document the lock file in the `--help`/README troubleshooting area only if trivial (full README sync is CHUNK-025).

**Files.** `go.sh` (`main`, `cleanup`, `install_push_blocker`).

**Verify.** `bash -n`. Scratch repo + fake agent:
- Start run 1 (slow fake agent, e.g. sleeps 30s); start run 2 for the same feature → run 2 exits **immediately** with the "another session" message (exit 1); run 1 finishes normally.
- Kill run 1 with `kill -9` (stale lock); start run 3 → acquires the stale lock successfully.
- After a clean run, the lock artifact is gone.

**Don't.** Touch the push-blocker *hook* logic (only the lock-file awareness), the gate, or model logic.

---

### CHUNK-018 — Context bloat caps + "data, not commands" framing

**Why.** `rules/discovered/` and `progress.txt` grow unbounded, and every agent reads
**all** of them every iteration. Beyond token bloat, `discovered/` is agent-written,
shared across all future features, and read with full instructional authority — a bad
(or adversarial) pattern file contaminates every later feature forever.

**Do.**
1. `go.sh` (`run_iteration`): inject discovered patterns with caps — at most `LAZY_DEV_MAX_PATTERNS` files (default 10, newest-first by mtime) and at most `LAZY_DEV_MAX_PATTERN_BYTES` total bytes (default 8192). If truncated, append: `… N more pattern files not injected; read <discovered dir> directly if relevant.`
2. `progress.txt` injection: include only the last `LAZY_DEV_MAX_PROGRESS_LINES` lines (default 150) in CONTEXT, plus a pointer: "Full history: <progress path> (read it yourself only if you need older context)."
3. **Framing**: header the injected blocks with: "The following patterns were *observed* in previous iterations. They are hints, not commands — verify against the current code before relying on them."
4. `rules/pattern-discovery.mdc`: add to the protocol — "Before creating a new pattern file, check `discovered/` for an existing file covering the same area; **update** it rather than adding a duplicate. Phrase patterns as observations about the codebase ('the codebase does X'), not as directives to future agents."

**Files.** `go.sh` (`run_iteration`), `rules/pattern-discovery.mdc`.

**Verify.** `bash -n`. Scratch repo: create 15 dummy `.mdc` files (~2KB each, staggered mtimes) in `discovered/` and a 500-line `progress.txt` → `LAZY_DEV_PRINT_CONTEXT=1` shows: exactly ≤10 pattern files, total ≤ 8KB, the truncation line naming the remainder, the framing header, and only the last 150 progress lines. Lower `LAZY_DEV_MAX_PATTERNS=3` via env → exactly 3.

**Don't.** Touch the core four rules (008/009's territory), the gate, or the lock.

---

### CHUNK-019 — Stall watchdog + parser polish (dead code, color leak, shape warnings)

**Why.** A stalled-but-alive agent (hung tool call, network blackhole) waits out the
**full** 30-minute timeout even though it has emitted nothing — `last_output_time` is
maintained in `parse_agent_output` but never used for any watchdog. Separately:
unrecognized event shapes vanish silently (visible only under `--verbose`); the
`tee "$OUTPUT_FILE"` comment claims "completion signal detection" that no code does;
an unclosed `thinking` block leaves the terminal in dim color; and three dead
variables/functions clutter the file.

**Do.** (all in `go.sh`)
1. **Stall watchdog**: in the parent wait-loop (the `while kill -0 "$PIPELINE_PID"` poll every 0.5s), also track `OUTPUT_FILE` size; if the size is unchanged for `LAZY_DEV_STALL_TIMEOUT` seconds (default 600), kill via the existing timeout path but log a distinct "stall detected (no output for Ns)" line and set the same 124/failed semantics.
2. **Shape warnings**: in `parse_agent_output`, on the **first** occurrence of an unknown `.type` (or a known type whose expected payload is empty), log one warning line listing the shape; dedupe subsequent occurrences (small associative array of seen shapes).
3. Fix the stale `tee` comment (raw output is now used by the stall watchdog + debugging).
4. Close the `thinking` color block at the end of the function (mirror the existing `assistant_streaming` close) — fixes the dim-shell-prompt leak.
5. Remove dead code: `first_output_received`, `normalize_newlines()` (the inline `${...//}` substitutions are the live path), and `full_cmd`.

**Files.** `go.sh` only.

**Verify.** `bash -n`. Source harness feeding synthetic NDJSON through `parse_agent_output` (via a pipe): a stream with one unknown type + a thinking-only stream → exactly **one** shape warning, exit 0, and the captured output ends with a color reset (no dangling dim). Scratch repo: fake agent that prints one line then `sleep 300` + `LAZY_DEV_STALL_TIMEOUT=5` → killed in ~5–8s, not 1800s, with the stall log line; a *healthy* fake agent (steady output) is never stall-killed.

**Don't.** Touch `main`'s retry/budget semantics (020), the gate, or the loop.

---

### CHUNK-020 — Cost / time budget breaker (exit 2)

**Why.** Unattended frontier-model runs for hours have no budget guard. The `result`
event already carries duration (and possibly cost) — the parser discards everything
else.

**Do.**
1. `parse_agent_output`: on the `result` event, extract cost defensively (`safe_jq` over plausible shapes: `.total_cost_usd // .cost_usd // .cost // empty`; if none, `unknown`) and append one line to `$FEATURE_DIR/.session-stats`: `iteration=<n> duration_s=<x> cost=<y|unknown>`. (Get the iteration number via an exported env var set by `run_iteration`.)
2. `main`: before each iteration, sum the stats file; if `LAZY_DEV_MAX_COST` is set (dollars, decimal) and cumulative cost (ignoring `unknown`s; if ALL are unknown, skip the cost check) exceeds it, or `LAZY_DEV_MAX_MINUTES` is set and cumulative minutes exceed it → graceful stop: loud "budget exceeded" log with the totals, run `commit_state` (CHUNK-015) so state is saved, `exit 2`.
3. Add both vars to `--help`.

**Files.** `go.sh` (parser `result` branch, `main`, `--help`).

**Verify.** `bash -n`. Scratch repo: fake agent emitting a `result` event with a cost field → `.session-stats` accumulates one line per iteration with the right numbers. `LAZY_DEV_MAX_MINUTES=1` + fake agent that takes ~2 min (but emits output to avoid the stall watchdog!) → after iteration 1, the loop exits **2** with the budget message and a state commit present.

**Don't.** Touch the gate (016), the lock (017), or the stall watchdog (019 — coordinate: your fake agent must emit periodic output so 019's watchdog doesn't fire first).

---

### CHUNK-021 — Branch-name source of truth (PRD `branchName` wins)

**Why.** `setup_feature_branch` creates `feature/$FEATURE_NAME`, ignoring the PRD's
`branchName` (e.g. Jira-format `feature/MED-123_my-feature`). Meanwhile
`track_branch`/`archive_previous_run` read the PRD's `branchName` and compare it
against itself — so archiving never triggers on a *real* branch change, and the agent
is told it's on a branch the PRD doesn't mention.

**Do.** (all in `go.sh`)
1. `setup_feature_branch`: read the PRD's `branchName` (jq, guarded). If present and non-empty → it is the target branch, **unless** it doesn't start with a sane prefix (`feature/`, `fix/`, `hotfix/`, `lazy/`, `dev/`) → in that case log a warning and fall back to `feature/$FEATURE_NAME`. Otherwise (absent) → `feature/$FEATURE_NAME` as today. The rest of the function (main detection, fetch, create/checkout, rebase) is unchanged.
2. `track_branch`: record the **actual** current git branch (`git branch --show-current`), not the PRD field.
3. `archive_previous_run`: compare the actual current branch (from `git`) against `.last-branch` (which is now also the actual branch, per #2) → archive when they differ, as originally intended.

**Files.** `go.sh` (the three functions).

**Verify.** `bash -n`. Source harness / scratch git repo:
- PRD `branchName: "feature/MED-123_x"` + feature name `x` → setup checks out `feature/MED-123_x`.
- PRD `branchName: "totally-bogus"` (bad prefix) → warning + `feature/x`.
- PRD without `branchName` → `feature/x`.
- `.last-branch` containing `feature/old` while on `feature/new` → `archive_previous_run` creates the archive folder.

**Don't.** Touch the push blocker, the lock (017), or resume/rebase semantics (022).

---

### CHUNK-022 — Safe resume semantics (rebase opt-in, stash-pop re-verify)

**Why.** Every re-run of `go.sh` for an existing feature re-fetches main and **rebases**
the feature branch — the branch moves under the user's feet on every resume; a rebase
conflict just warns and continues on the stale base. Separately, `verify_setup` runs
*before* branch setup; if `git stash pop` later fails (lazy-dev files, including the
PRD, stay in the stash), the script proceeds with missing files.

**Do.**
1. `setup_feature_branch`: if the feature branch exists and has commits beyond main (`git rev-list <main>..HEAD --count` > 0) → **skip** the rebase by default. Add a `--rebase` CLI flag (arg-parsing + `--help`) that forces the rebase. If a rebase is attempted (flag) and conflicts → abort the rebase (existing behavior) **and exit 1** with a clear message (do not continue on the stale base silently).
2. After `pop_lazy_dev_stash` in `setup_feature_branch`: re-verify the critical files exist (`PRD_FILE`, `PROMPT_FILE`, `examples/`); if any are missing → clear error: "lazy-dev files remain in the stash — run `git stash list` / `git stash pop` and resolve, then re-run" + `exit 1`.
3. `README.md`: add a short "Resuming a feature" subsection (what a re-run does, the `--rebase` flag, the stash guidance). Keep it to ~10 lines; full README sync is CHUNK-025.

**Files.** `go.sh` (`setup_feature_branch`, arg parsing, `--help`), `README.md` (one subsection).

**Verify.** `bash -n`. Scratch repo: feature branch with 3 commits beyond main → re-run (fake agent, `--max-iterations 1`) → branch tip **unchanged** (no rebase); with `--rebase` → rebase attempted (visible in `git reflog`). Simulated failed stash pop (stash a lazy-dev file, check out a branch where it exists) → clean `exit 1` with the stash guidance, no loop start.

**Don't.** Touch the lock (017), the gate, or model logic.

---

### CHUNK-023 — CLI surface polish

**Why.** Small rough edges in the CLI layer: `--help` prints `MAX_ITERATIONS` *before*
`--max-iterations` is parsed (shows the env default, not the flag value); the usage
text is duplicated verbatim in three places; `USE_CURSOR_AGENT_SUBCOMMAND=1` confusingly
means "use the *other* binary"; `print_line` uses `echo -e` which mangles backslashes
in paths/commands; `initialize_progress_file` uses a `sed -i ''`/`sed -i` fallback hack.

**Do.** (all in `go.sh`)
1. Extract one `print_usage()` function; call it from all three current sites; ensure the printed `MAX_ITERATIONS` reflects the value **after** flag parsing.
2. Rename `USE_CURSOR_AGENT_SUBCOMMAND` → `USE_STANDALONE_CURSOR_AGENT` with sane polarity (1 = the standalone `cursor-agent` binary was found and will be used); update all references.
3. `print_line`: `echo -e "$1"` → `printf '%b\n' "$1"`.
4. `initialize_progress_file`: replace the `sed -i ''`/`sed -i` double-attempt with an explicit `[[ "$OSTYPE" == darwin* ]]` branch.

**Files.** `go.sh` only.

**Verify.** `bash -n`. `./go.sh --max-iterations 33 --help` → prints 33. Grep: zero occurrences of `USE_CURSOR_AGENT_SUBCOMMAND`. `print_line 'a\b c'` → prints `a\b c` verbatim (backslash preserved). `./go.sh --help` and a full fake-agent run still behave normally.

**Don't.** Touch loop logic, the parser's streaming behavior, or the gate.

---

### CHUNK-024 — `generate-prd` command fixes (discoverability + content)

**Why.** After the documented install (copy lazy-dev to `.cursor/lazy-dev/`), the
command file sits at `.cursor/lazy-dev/commands/generate-prd.md` — **outside**
Cursor's command discovery path (`.cursor/commands/`) — so `/lazy-dev/generate-prd`
(as advertised in the README) doesn't exist. The command also contains content errors.

**Do.**
1. **Discoverability**: keep the file where it is (portability) but have `verify_setup` (in `go.sh`) ensure discoverability: if `<project>/.cursor/commands/lazy-dev` doesn't exist, create it as a symlink to `../lazy-dev/commands` (log what was created); if it exists, verify it resolves. (Creating it in the user's `.cursor/` is a one-line, reversible, well-logged action — do it.)
2. **Content fixes** in `commands/generate-prd.md`:
   - Remove the false claim "the lazy-dev agent loop calculates iterations as: (user story count) + 3" → replace with: "the loop runs until all stories have `passes: true`, bounded by `--max-iterations` (default 20); re-running `./go.sh <feature>` resumes where the PRD left off."
   - Replace every `~/.cursor/rules/` with `.cursor/rules/` and add "(if it exists in this project)".
   - The literal `{feature}` placeholders in review-output paths: replace with `<feature>` **and** add an explicit instruction: "Substitute the actual feature name into these paths when generating the PRD."
   - Align the Jira story-id guidance with CHUNK-005: note that the loop's model mapping is by suffix, so `MED-523-REVIEW` / `MED-523-REVIEW-2` correctly select the review models.

**Files.** `commands/generate-prd.md`, `go.sh` (`verify_setup` symlink helper), `README.md` (one line in Prerequisites/Quick Start about the auto-created symlink).

**Verify.** `bash -n`. Scratch project with lazy-dev under `.cursor/`: run `./go.sh --help` (or any invocation reaching `verify_setup`) → `.cursor/commands/lazy-dev/generate-prd.md` resolves through the symlink; second run doesn't error. Grep the command file: no `~/.cursor/rules`, no "(user story count) + 3", no bare `{feature}` without the substitution note.

**Don't.** Touch `prompt.md` or `rules/`.

---

### CHUNK-025 — Template + README synchronization

**Why.** The docs have drifted from the script in many places, and 20+ chunks have
added flags/env vars that the README never mentions. A fresh user (or agent) reading
the README is currently misinformed.

**Do.**
1. `examples/prd.json`:
   - Remove the fake `"jiraTaskId": "MED-123"` (JSON has no comments — omit the field; the README will document it as optional) and set `"branchName": "feature/my-feature"`.
   - Add `"attempts": 0` to every story (CHUNK-013's field).
   - Keep `US-*` review ids (the canonical non-Jira example) and the 997/998/999 priorities.
   - `jq . examples/prd.json` must pass.
2. `README.md` (sync to the final state of the script):
   - "Run with default 10 iterations" → 20; `./go.sh my-feature 20` → `./go.sh --max-iterations 20 my-feature` (positional count was never supported).
   - Directory tree: remove the phantom `rules/patterns/` subtree (or relabel it "project patterns live in your project's `.cursor/rules/patterns/` — not part of lazy-dev"); align with `rules/README.md`.
   - Standard Story Flow table: `US-REVIEW` priority 998 → 997 (match the template).
   - Add an **Environment variables** reference table for every `LAZY_DEV_*` var that exists in `go.sh` at this point (TIMEOUT, MAX_ITERATIONS, MODEL_IMPL, MODEL_REVIEW, MODEL_REVIEW2, GATE_TIMEOUT, STALL_TIMEOUT, MAX_COST, MAX_MINUTES, MAX_PATTERNS, MAX_PATTERN_BYTES, MAX_PROGRESS_LINES — grep the script to get the exact list).
   - Add short sections: **Resuming a feature** (pointer to CHUNK-022's behavior), **Quality gate** (what the runner runs after each flip), **Handover** (pointer to `HANDOVER.md`).
3. `rules/README.md`: align its "Project Patterns" wording with the main README (single consistent story about where patterns live).

**Files.** `examples/prd.json`, `README.md`, `rules/README.md`.

**Verify.** `jq . examples/prd.json` valid. Cross-check: every flag in `./go.sh --help` and every `LAZY_DEV_*` in the README's env table exists in `go.sh` (and vice versa — grep both directions); no README example command is invalid (`./go.sh --help` accepts every documented flag); no phantom paths remain (grep `rules/patterns` in the tree diagram).

**Don't.** Touch `go.sh` behavior. If you find a doc/script mismatch the script is *wrong* about, note it in your handoff note rather than "fixing" the script (that's out of scope for a docs chunk).

---

### CHUNK-026 — End-to-end verification + final report

**Why.** Twenty-five chunks of local verification deserve one full-system proof, and
the plan needs a terminal artifact.

**Do.**
1. `bash -n go.sh`; run `shellcheck go.sh` if installed — fix anything **new** (warnings introduced by this plan); pre-existing style noise: note it, don't chase it.
2. Build a scratch project in `/tmp/lazydev-e2e`: git repo; minimal `package.json` with `build`/`test` scripts (both pass); lazy-dev copied under `.cursor/`; a PRD with 2 trivial implementation stories + the 3 review/impl-recs stories (`US-*` ids); a **capable** fake agent (script): reads its prompt's assigned story, flips that story to `passes: true` (atomic jq), appends a line to `progress.txt`, writes + commits one source file, exits 0.
3. Run `./go.sh e2e-feature` to completion and verify **all** of: one story per iteration (5 iterations total, each with the right assignment in the log); model switches per the mapping (log lines show opus → gpt → gemini → opus); a `chore: lazy-dev state` commit after each iteration (015); the quality gate runs on each flip and passes (016); completion banner + **exit 0**; push-blocker hook present during the run and **removed** after; lock artifact removed; no orphan processes (`ps` for the fake agent) after exit; spinner/PID temp files gone.
4. Negative suite (scratch repos, fake agent variants):
   - story never flipped → blocked after 3 attempts (013); all-blocked → **exit 3** + STUCK report.
   - corrupted `prd.json` → clean validation error, **exit 1** (003).
   - agent that emits one line then hangs → stall-killed at `LAZY_DEV_STALL_TIMEOUT=10` (019).
   - two concurrent `go.sh` runs → second rejected immediately (017).
   - agent flipping a story while the gate's test script fails → flip reverted + `🚫` note (016).
   - a user-side decoy process with the project path in its argv survives the whole run (004).
5. Write the full results (commands + key outputs + pass/fail per item) into the section 4 handoff log as the final note. If **anything** fails: do not mark 026 resolved — tag the relevant earlier chunk's queue line `⛔ BLOCKED` if the failure traces to it, and write a diagnostic note. (This is the one chunk where a "no" is a useful, expected outcome.)

**Files.** Scratch repos only + `HANDOVER.md` (queue flip + final note).

**Verify.** All of the above passes; the section 4 log contains the E2E evidence; the queue shows all 26 `- [x]` (or an honest blocked state with diagnostics).

**Don't.** Change any code. This chunk is verification-only; bugs found get reported, not fixed (a new chunk would be needed — note it in the log).

---

## 4. Handoff Log

Append-only. Newest notes last. Write per the template in section 0.

### CHUNK-000 — Review completed, plan authored (2026-08-24 | commit 70181cb)
- **Did:** Full senior review of the lazy-dev agent loop (`go.sh`, `prompt.md`, `rules/*.mdc`, `commands/generate-prd.md`, `examples/`, `README.md`). Authored this 26-chunk implementation plan, dependency-ordered in 4 phases.
- **Deviations from spec:** n/a — this is the baseline entry.
- **Gotchas:** (1) Several "robustness" features in `go.sh` are dead code — don't trust comments, trust behavior. (2) `go.sh` line numbers drift as chunks land; always locate code by function name. (3) The repo must never be used as a loop test target — scratch repos only.
- **Verification evidence:** n/a (analysis chunk).
- **State left behind:** Clean tree on `main`; `HANDOVER.md` added (uncommitted until first resolve-commit or baseline commit).
- **First step for next chunk (CHUNK-001):** Read the CHUNK-001 spec above; start with the `pipefail` line in `run_iteration`'s pipeline subshell, then the source-guard restructure at the bottom of `go.sh` (needed before you can test anything).

### CHUNK-001 — Failure detection: pipefail + is_error + real exit codes (+ test hooks) (RESOLVED 2026-08-25 | commit b4dea7a)
- **Did:** `go.sh` only: (1) `set -o pipefail` as first line of `run_iteration`'s `( ... ) &` pipeline subshell, so a failing agent stage makes the subshell exit non-zero; (2) `parse_agent_output` sets a local `result_failed` flag when the `result` event has `is_error == true` and ends `return 1` if set (else `return 0`); (3) `run_iteration` resets/sets a new global `LAST_ITERATION_DURATION` and ends with an explicit `return $exit_code` (124 kept for timeout); (4) `main`'s retry loop: exponential backoff `BACKOFF_SCHEDULE=(5 15 45)` replaces the fixed `sleep 5`, plus fast-fail — a failed iteration lasting < `LAZY_DEV_FASTFAIL_SECS` (new env var, default 60, `0` disables) logs a clear "Fast-fail" line and breaks without retrying; final message now says "failed after $retry_count attempt(s)"; (5) BASH_SOURCE guard wraps the CLI flag-parsing/validation block and the final `main "$@"` call — the file is source-safe for function-level tests; (6) `LAZY_DEV_FAKE_AGENT` test hook: when non-empty, `run_iteration` uses it as the executable (same flags + prompt argument, same `tee | parse_agent_output` pipeline) and logs which binary is used. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** (a) The `MAX_ITERATIONS` config line is now guarded (`if [ -z "${MAX_ITERATIONS:-}" ]`) — the previous unconditional assignment was clobbering the `--max-iterations` flag value (pre-existing bug); without the fix the spec's own `--max-iterations 2` verify was impossible. Precedence is now flag > env > 20. (Full `--help`/print_usage polish remains CHUNK-023.) (b) An "Environment variables" block was added to BOTH help texts (the `--help` case and the no-args validation block) documenting `LAZY_DEV_TIMEOUT`, `LAZY_DEV_MAX_ITERATIONS`, `LAZY_DEV_FASTFAIL_SECS`, `LAZY_DEV_FAKE_AGENT` — earlier than CHUNK-006/025's plan so the new vars are discoverable now. (c) Pre-flight found a dirty tree (README maintenance banner + untracked `HANDOVER.md`); it was committed as baseline `70181cb` first, not reverted (per "don't revert changes you didn't make"). (d) Two commits instead of one: a commit cannot contain its own hash, so this note + queue flip landed in the resolve-commit with a hash placeholder, then a follow-up `record CHUNK-001 commit hash` commit replaced the placeholders with the real short hash. (e) Corrected the stale "commit a389307" in the CHUNK-000 note to the actual baseline hash `70181cb`.
- **Gotchas:** (1) Orphan grandchild leak on timeout: the timeout kill reaches the subshell + direct children only, and the `pkill -f "cursor-agent..."` sweep does not match a fake agent's argv — one `hang.sh` PID survived in T4 and was killed manually. Pre-existing; CHUNK-004's session marker is the real fix — don't try to fix it in other chunks. (2) Sourcing `go.sh` enables `set -e` in the sourcing shell — test harnesses should `set +e` right after sourcing. (3) `stop_spinner` is safe with an empty PID file. (4) zsh `=word` equals-expansion breaks `echo ===` in shell one-liners (use `echo` + quoted strings). (5) In scratch repos, `go.sh` must be run from `.cursor/lazy-dev/` (where the copy lives), not the repo root.
- **Verification evidence:** `bash -n go.sh` → OK (run after every edit; final state clean). Source harness: `bash -c 'source ./go.sh __test__; ...'` → `main` did NOT run (no loop output); `get_model_for_story` callable; `FASTFAIL_SECS=60`, `BACKOFF_SCHEDULE=(5 15 45)`; function-level `parse_agent_output` pipe test: `is_error:true`→exit 1, `is_error:false`→exit 0, no-result→exit 0. Scratch repo `/tmp/lazydev-t1` (git, main branch, initial commit; lazy-dev copied to `.cursor/lazy-dev/`; feature `demo` with 1 story `passes:false`); fake agents in `/tmp/lazydev-t1-fake/`: `fail.sh` (sleep 2, result `is_error:true`, exit 1), `ok.sh` (exit 0, `is_error:false`), `hang.sh` (init line, then sleep 300). **T1** fail + `--max-iterations 2` + default fast-fail → exit 1; 2 agent launches (one per iteration); 2× "Iteration failed (exit 1)"; 2× "Fast-fail: iteration N failed after 3s (< 60s) - not retrying"; 0× "retry"; "Max iterations (2) reached. Stopping."; push blocker installed + removed; no orphans. **T2** fail + `LAZY_DEV_FASTFAIL_SECS=0` + `--max-iterations 1` → 3 attempts; "retry 1 of 3 (backoff 5s)" + "retry 2 of 3 (backoff 15s)"; 0 fast-fail lines; wall ~31s. **T3** ok agent → "Iteration complete (3s)"; 0 failures/retries/fast-fail; exit 1 only from the max-iterations cap (the fake agent never flips `passes` — that's CHUNK-002's job). **T4** (extra) hang + `LAZY_DEV_TIMEOUT=5` → "Iteration timed out after 5s", "Iteration failed (exit 124)", fast-fail at ~7s. Environment facts: `cursor` + `cursor-agent` installed (so `verify_setup` passes in scratch runs); `/usr/bin/stdbuf` exists and propagates child exit codes (the pipeline takes the stdbuf branch); system bash is 3.2.
- **State left behind:** `main`, clean tree after commit; `go.sh` is source-safe — the source harness works for all later chunks. Scratch dirs `/tmp/lazydev-t1`, `/tmp/lazydev-t1-fake`, `/tmp/stdbuf-probe.sh` removed; no leftover processes.
- **First step for next chunk (CHUNK-002):** Read the CHUNK-002 spec; start with the shared `passes != true` jq predicate used by `verify_all_stories_complete`/`get_next_story_id`/`get_story_counts`.

### CHUNK-002 — Fail-safe PRD completion predicate (RESOLVED 2026-08-27 | commit 32eefa6)
- **Did:** `go.sh` only: added canonical `PRD_INCOMPLETE_STORY='select(.passes != true)'` jq fragment; updated `verify_all_stories_complete` (complete only when PRD parses, `userStories` is a non-empty array, and zero incomplete stories), `get_story_counts` (safe `userStories[]?` optional iterator; total = array length regardless of passes), and `get_next_story_id` (incomplete predicate + `|| true` on parse failure). Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Test harnesses must `set +e` **after** sourcing `go.sh` — sourcing re-enables `set -e`, so calling `verify_all_stories_complete` on an incomplete PRD aborts the shell otherwise. (2) `userStories[]?` handles missing `userStories` gracefully in counts/next-id; `verify_all_stories_complete` treats non-array or empty array as incomplete via explicit length check.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness (`set +e` after source) with five temp PRDs in `/tmp`: (a) missing `passes` → incomplete, next=US-001, counts=0/1; (b) `passes:null` → incomplete, next=US-002; (c) `passes:"true"` (string) → incomplete, next=US-003; (d) `userStories:[]` → incomplete, next=empty, counts=0/0; (e) all `passes:true` → complete, next=empty, counts=2/2. All five PASS.
- **State left behind:** `main`, clean tree after commit; `PRD_INCOMPLETE_STORY` is the single predicate source for CHUNK-003/013 to reuse.
- **First step for next chunk (CHUNK-003):** Audit `PRD_FILE` command substitutions under `set -e`; add `validate_prd` in `verify_setup` and the `prompt.md` restore paragraph.

### CHUNK-003 — Bootstrap PRD validation + corrupted-PRD recovery (RESOLVED 2026-08-27 | commit 07e340a)
- **Did:** `go.sh`: added `validate_prd` (JSON parse, non-empty `userStories` array, per-story `id`/`priority`/`passes` boolean checks with story-specific errors); called from `verify_setup` after jq availability check; audited all `PRD_FILE` jq command substitutions — all already guarded (`|| echo`, `|| true`, or inside functions that degrade gracefully). `prompt.md`: one paragraph in "Files to Read First" on restoring corrupted `prd.json` from git. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) `validate_prd` requires `.passes` to be a JSON boolean — missing `passes` reports as `got null` (fail-safe; agents must set explicit `true`/`false`). (2) Bootstrap validation runs only in `verify_setup` at loop start — a PRD corrupted mid-run is still handled gracefully by the existing guarded jq helpers; the agent prompt now documents restore-from-git recovery.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness (`set +e` after source): truncated JSON → `validate_prd` exit 1, specific "does not contain valid JSON" error + remediation; story missing `.passes` → exit 1, "Story US-001: .passes must be a boolean (got null)"; `examples/prd.json` → exit 0; `get_next_story_id` on corrupted file → empty string, exit 0 (no `set -e` abort).
- **State left behind:** `main`, clean tree after commit; `validate_prd` is the bootstrap gate — CHUNK-013 should call it after jq-mutating the PRD.
- **First step for next chunk (CHUNK-004):** Read CHUNK-004 spec; start with the session marker in `run_iteration`'s CONTEXT build, then remove the `pkill -9 -f` blocks in `cleanup` and `cleanup_iteration`.

### CHUNK-004 — Session-scoped process kills (replace `pkill -f` sweeps) (RESOLVED 2026-08-27 | commit 38fb6cb)
- **Did:** `go.sh` only: (1) added global `LAZY_DEV_SESSION_MARKER` set once per go.sh run in `run_iteration` (`lazydev-$$-<epoch>`) and prepended `<!-- lazy-dev session: … -->` to CONTEXT; (2) removed both broad `pkill -9 -f "cursor-agent.*$PROJECT_ROOT"` / node / script sweeps from `cleanup` and `cleanup_iteration`; (3) added `kill_session_orphans()` — single last-resort `pkill -9 -f "$LAZY_DEV_SESSION_MARKER"` called from both cleanup paths; kept `pkill -9 -P $$` in `cleanup`. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) macOS `ps`/`pgrep` often hide bash `-c` argv tails — behavioral decoys must be reparented to init (not children of the sourcing shell) or use `exec -a` so `cursor-agent.*$PROJECT_ROOT` is visible; otherwise `cleanup_iteration`'s existing `pgrep -P $$` child sweep kills them before the marker test matters. (2) Marker is initialized once per run (first `run_iteration`) so orphaned processes from earlier iterations still match the session marker in their prompt argv.
- **Verification evidence:** `bash -n go.sh` → OK. Grep: zero `pkill -9 -f "cursor-agent.*$PROJECT_ROOT"` remains. Scratch `/tmp/lazydev-chunk004`: decoy `exec -a "cursor-agent $SCRATCH" sleep 300` (no marker) → `cleanup_iteration` → **survived** (PID 13201); decoy with marker `lazydev-testmarker-die123` → **killed**; fake-agent run (`LAZY_DEV_FAKE_AGENT`, `--max-iterations 1`) → "Iteration complete", `pgrep` for fake agent → empty (no orphans).
- **State left behind:** `main`, clean tree pending commit; `kill_session_orphans` + session marker ready for CHUNK-026 E2E decoy test.
- **First step for next chunk (CHUNK-005):** Read CHUNK-005 spec; start with suffix-based matching in `get_model_for_story` (`*-REVIEW-2` before `*-REVIEW`).

### CHUNK-005 — Model selection by story type (Jira IDs) + per-story `model` field (RESOLVED 2026-08-27 | commit 26c6655)
- **Did:** `go.sh`: rewrote `get_model_for_story` for suffix-based type matching (`*-REVIEW-2` before `*-REVIEW`, then `*IMPL-RECS`/`*IMPLEMENT-RECS`); added `get_story_model_override` + `resolve_model_for_story` (per-story `.model` in prd.json overrides type mapping); `run_iteration` now calls `resolve_model_for_story`; broadened parser story-banner regex to `(US|[A-Z]{2,10}-[0-9]{3,})-[A-Z0-9-]+`. `prompt.md`: dual-model table notes Jira-prefixed ids and suffix mapping. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Bash `case` suffix patterns are ordered — `*-REVIEW-2` must stay above `*-REVIEW` or `US-REVIEW-2` would get the first-review model. (2) `resolve_model_for_story` is the call site for model selection; CHUNK-006 will add env overrides inside `get_model_for_story` without changing the override precedence (per-story `.model` still wins).
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `US-REVIEW`→gpt-5.3-codex, `US-REVIEW-2`→gemini-3-pro, `US-007`→opus-4.6, `MED-523-REVIEW`→gpt-5.3-codex, `MED-523-REVIEW-2`→gemini-3-pro, `MED-523-IMPL-RECS`→opus-4.6; temp PRD with `"model":"composer"` on next story → `resolve_model_for_story` returns `composer`. Scratch `/tmp/lazydev-chunk005` fake-agent run: `Story: MED-523-REVIEW → Model: gpt-5.3-codex`.
- **State left behind:** `main`, clean tree pending commit; suffix helpers ready for CHUNK-006 env overrides and CHUNK-012 review-type detection.
- **First step for next chunk (CHUNK-006):** Read CHUNK-006 spec; add `LAZY_DEV_MODEL_IMPL`/`REVIEW`/`REVIEW2` env vars to `get_model_for_story` and the fast-fail CLI-default retry in `main`.

### CHUNK-006 — Model env overrides + fallback to CLI default model (RESOLVED 2026-08-27 | commit 6f6e08f)
- **Did:** `go.sh`: added `LAZY_DEV_MODEL_IMPL`/`LAZY_DEV_MODEL_REVIEW`/`LAZY_DEV_MODEL_REVIEW2` env vars (defaults `opus-4.6`, `gpt-5.3-codex`, `gemini-3-pro`) consumed by `get_model_for_story`; per-story `.model` still wins via `resolve_model_for_story`. Added `LAZY_DEV_FORCE_CLI_DEFAULT_MODEL` global + `LAST_ITERATION_USED_EXPLICIT_MODEL` tracking; `run_iteration` omits `--model` when force flag set and logs "CLI default". `main` fast-fail path: if failure used explicit model, retry once with CLI default before breaking. Added three model env vars to both `--help` blocks. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) CLI-default retry decrements `retry_count` so the fast-fail retry does not consume a backoff slot. (2) `LAZY_DEV_FORCE_CLI_DEFAULT_MODEL` is reset to 0 at the start of each outer iteration. (3) Per-story `.model` override still bypasses env vars — fast-fail CLI-default retry still fires if an explicit `--model` was passed (including per-story override).
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `LAZY_DEV_MODEL_IMPL=foo get_model_for_story "US-001"` → `foo`. Scratch `/tmp/lazydev-chunk006`: PRD next story `MED-523-REVIEW`, fake agent fast-fails (sleep 2, `is_error:true`, exit 1), `--verbose --max-iterations 1` → attempt 1 debug log shows `--model gpt-5.3-codex`; `Fast-fail with explicit model - retrying once with CLI default`; attempt 2 log shows `Model: CLI default (--model omitted)` and debug `Executing: .../fail.sh -p --force ...` with **no** `--model`; second fast-fail stops with no further retry.
- **State left behind:** `main`, clean tree pending commit; model env vars ready for CHUNK-025 README sync.
- **First step for next chunk (CHUNK-007):** Read CHUNK-007 spec; compute `LAZY_DEV_REL` from `SCRIPT_DIR` relative to `PROJECT_ROOT` and use it in CONTEXT path assembly; add `LAZY_DEV_PRINT_CONTEXT=1`.

### CHUNK-007 — Derived paths (no hardcoded `.cursor/lazy-dev`) + `LAZY_DEV_PRINT_CONTEXT` (RESOLVED 2026-08-27 | commit 6df4edd)
- **Did:** `go.sh`: `PROJECT_ROOT` now uses `git rev-parse --show-toplevel` with `pwd -P` normalization; added `LAZY_DEV_REL` (relative install path, `.` when at repo root) and derived CONTEXT paths for PRD/progress/discovered; added `LAZY_DEV_PRINT_CONTEXT=1` stderr dump before agent launch. `prompt.md`, `commands/generate-prd.md`, `examples/prd.json` (notes only): replaced hardcoded `.cursor/lazy-dev` agent paths with Feature Context / `<lazy-dev>` phrasing; replaced `~/.cursor/rules/` with `.cursor/rules/ (if it exists in this project)`. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** `PROJECT_ROOT` now uses `git rev-parse --show-toplevel` instead of the fixed `SCRIPT_DIR/../..` heuristic — required for scratch-repo B (`tools/lazy-dev`) verification; falls back to the legacy heuristic outside a git repo.
- **Gotchas:** (1) On macOS, `pwd -P` is required when computing `LAZY_DEV_REL` — `/tmp` vs `/private/tmp` otherwise yields absolute paths in CONTEXT. (2) When sourcing `go.sh` from another repo's cwd, `git rev-parse` resolves that repo's root, not lazy-dev's — run path tests from the scratch repo's lazy-dev directory (same as prior chunks). (3) `LAZY_DEV_REL=.` when lazy-dev is installed at the git root (e.g. this repo itself).
- **Verification evidence:** `bash -n go.sh` → OK. Grep: zero `.cursor/lazy-dev` or `~/.cursor` in `prompt.md`/`generate-prd.md` agent-facing paths. Scratch **A** (`.cursor/lazy-dev`): `Lazy-dev directory: .cursor/lazy-dev`; `ls` OK for PRD, progress, discovered. Scratch **B** (`tools/lazy-dev`): `Lazy-dev directory: tools/lazy-dev`; all three paths exist from repo root. Source harness from lazy-dev repo: `LAZY_DEV_REL=.`. `LAZY_DEV_PRINT_CONTEXT=1` prints delimited block with correct paths.
- **State left behind:** `main`, clean tree pending commit; `LAZY_DEV_REL` + `LAZY_DEV_PRINT_CONTEXT` ready for CHUNK-009/010/018 verification.
- **First step for next chunk (CHUNK-008):** Read CHUNK-008 spec; dedup git policy (shrink CONTEXT git block) and commit-type tables across `prompt.md` + `rules/*.mdc`.

### CHUNK-009 — Runner-inlined rule injection (deterministic protocol) (RESOLVED 2026-08-27 | commit 31b8fc8)
- **Did:** `go.sh`: added `build_inlined_rules()` (sorted `rules/*.mdc` at depth 1, excludes `discovered/`); `run_iteration` appends separator + **Injected Protocol** block with `### rules/<file>.mdc` headings and full rule bodies after `prompt.md`. `prompt.md`: replaced auto-apply paragraph with loop-injection truth. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Rule order is deterministic via `find … | sort` (agent-loop → pattern-discovery → quality-gates → task-breakdown). (2) `cursor agent --help` / `cursor-agent --help` expose no rules-discovery flag or extra rule-path option — inlining is the correct approach. (3) CHUNK-018 will cap `rules/discovered/` injection separately; do not add discovered files here.
- **Verification evidence:** `bash -n go.sh` → OK. CLI: `cursor-agent --help` — no `--rules` / rule-path flags (workspace/plugin-dir only). Scratch `/tmp/lazydev-chunk009`: `LAZY_DEV_PRINT_CONTEXT=1` + `LAZY_DEV_FAKE_AGENT` → all four phrases present in stderr dump and fake-agent prompt capture: `Iteration Lifecycle`, `Decomposition Process`, `Pattern Discovery Protocol`, `Definition of Done`; headings `### rules/agent-loop.mdc` … `task-breakdown.mdc`; `# Injected Protocol (canonical source: .cursor/lazy-dev/rules/*.mdc)`.
- **State left behind:** `main`, clean tree pending commit; inlined rules ready for CHUNK-010 assignment block (append after rules, before agent launch guard).
- **First step for next chunk (CHUNK-010):** Read CHUNK-010 spec; add `## Your Assignment` block to CONTEXT after fetching next story title; guard empty `next_story_id`.

### CHUNK-008 — Prompt/rules dedup (one canonical git policy, one commit-type table) (RESOLVED 2026-08-27 | commit b529bd0)
- **Did:** Shrunk `go.sh` CONTEXT git block to one-line push ban + pointer to prompt. Canonical git policy and full commit-type table (`feat`/`fix`/`refactor`/`test`/`docs`/`chore`) live in `prompt.md`; `agent-loop.mdc` and `quality-gates.mdc` now point to it. Compressed web-search rule to one compact section in `prompt.md`; `agent-loop.mdc` uses one-line pointer. Trimmed redundant project-rules tables and Quick Reference in `prompt.md`. Files: `go.sh`, `prompt.md`, `rules/agent-loop.mdc`, `rules/quality-gates.mdc`, `HANDOVER.md`.
- **Deviations from spec:** Combined word count dropped 24.2% (4195→3181), slightly under the 25–30% target — protected sections (one-story, review-story, never-ask-user rules) kept intact; additional compression was limited to non-canonical boilerplate (project-rules tables, Quick Reference).
- **Gotchas:** (1) `go.sh` header comment (line 13) still mentions git push — not agent-facing CONTEXT; grep audit excludes it. (2) CHUNK-011 will expand the canonical git section and remove remaining `git add .` references — CONTEXT is already minimal. (3) CHUNK-009 will replace "rules auto-apply" wording when rules are inlined.
- **Verification evidence:** `bash -n go.sh` → OK. Word counts: before 4195, after 3181 (−24.2%). Grep: full `git push` forbidden-list only in `prompt.md` + one-line CONTEXT ban in `go.sh`; commit-type canonical table only in `prompt.md` (pointers in `agent-loop.mdc`/`quality-gates.mdc`); web-search rule body only in `prompt.md` (one-line pointer in `agent-loop.mdc`). Spot-read: NEVER ASK, ONE story, review-story, and dual-model sections intact.
- **State left behind:** `main`, clean tree pending commit.
- **First step for next chunk (CHUNK-009):** Read CHUNK-009 spec; inline `rules/*.mdc` into CONTEXT in `run_iteration` and update `prompt.md` auto-apply paragraph.

### CHUNK-010 — Assigned-story injection into CONTEXT (RESOLVED 2026-08-27 | commit 0f0bb02)
- **Did:** `go.sh`: moved `get_next_story_id` before CONTEXT assembly; added empty-id guard (log error, return 1, no agent launch); fetch story title via jq; appended `## Your Assignment` block after inlined rules with id + title. `prompt.md`: Select step now defers to runner-assigned story in Feature Context. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Assignment block is appended after `# Injected Protocol` — `LAZY_DEV_PRINT_CONTEXT` dump includes it at the end. (2) All-complete runs never call `run_iteration` (`verify_all_stories_complete` in `main` exits 0 first). (3) Empty `next_story_id` returns 1 so `main` logs iteration failure but continues — CHUNK-013 will add blocked-story handling for stuck states.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk010`: PRD with priorities 5/1/3 → `LAZY_DEV_PRINT_CONTEXT=1` + fake agent shows `US-P1 — Priority One Story` in `## Your Assignment`; log `Story: US-P1 → Model: opus-4.6`. Scratch `/tmp/lazydev-chunk010-complete`: all `passes:true` → exit 0, "All stories completed", no Story/Model log, no agent launch.
- **State left behind:** `main`, clean tree after commit; assignment injection ready for CHUNK-012 review-type CONTEXT additions.
- **First step for next chunk (CHUNK-011):** Read CHUNK-011 spec; harden canonical git section in `prompt.md` (no `git add .`, expanded forbiddens) and align CONTEXT git one-liner.

### CHUNK-012 — Read-only review contract + diff-range context for reviewers (RESOLVED 2026-08-27 | commit 48fea59)
- **Did:** `go.sh`: added `is_review_story` (suffix `*-REVIEW` / `*-REVIEW-2`) and `detect_main_branch` (same main/master logic as `setup_feature_branch`); `run_iteration` appends `## Review Scope` with concrete `git diff <merge-base>..HEAD` for review stories only. `prompt.md`: read-only review contract in Dual-Model section. `rules/agent-loop.mdc`: one-line Scope Discipline entry. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Read-only contract appears in printed CONTEXT via inlined `prompt.md` + `agent-loop.mdc`; diff-range block is appended only for review stories after `## Your Assignment`. (2) `detect_main_branch` mirrors `setup_feature_branch` — if neither `main` nor `master` exists, no Review Scope block is injected (graceful skip). (3) Merge-base is computed at iteration time on the current HEAD after branch setup/rebase.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `is_review_story` → US-REVIEW/MED-523-REVIEW-2 yes, US-001/US-IMPLEMENT-RECS no. Scratch `/tmp/lazydev-chunk012`: feature branch + 2 commits, PRD next story `US-REVIEW` → `LAZY_DEV_PRINT_CONTEXT=1` shows read-only line + `Review scope: run git diff <sha>..HEAD`. Scratch `/tmp/lazydev-chunk012-impl`: impl-only PRD → no `## Review Scope` block (PASS).
- **State left behind:** `main`, clean tree after commit `48fea59`.
- **First step for next chunk (CHUNK-013):** Read CHUNK-013 spec; add `attempts`/`blocked` schema to `examples/prd.json` + `generate-prd.md`, implement `record_story_attempt` and stuck exit 3 in `go.sh`.

### CHUNK-014 — Dirty-tree / killed-iteration recovery (RESOLVED 2026-08-27 | commit a389307)
- **Did:** `go.sh`: added `get_git_porcelain_capped`, `append_killed_iteration_marker`, `build_dirty_tree_warning`; timeout/interrupt paths append kill marker to `progress.txt`; pre-iteration dirty-tree block injected into CONTEXT when `git status --porcelain` is non-empty; globals `CURRENT_ITERATION`/`ITERATION_START_EPOCH`/`LAZY_DEV_ITERATION_ACTIVE` for interrupt handling. `rules/agent-loop.mdc`: Bootstrap step 0 **Reconcile** (git status + log before planning). Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Kill marker is written on every `run_iteration` timeout (including per-retry attempts within one outer iteration) — can produce multiple markers per outer iteration when `LAZY_DEV_FASTFAIL_SECS=0`. (2) Dirty-tree warning lists all porcelain entries, including lazy-dev runner artifacts (e.g. `.last-branch`) — agents should reconcile per the foreign-changes rule. (3) Stray files from a killed agent may land under `LAZY_DEV_REL` (cwd is lazy-dev dir during run) — paths in warnings are relative to project root.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `append_killed_iteration_marker` + `build_dirty_tree_warning` helpers work; warning includes assigned story id. Scratch `.scratch/chunk014-repo`: fake agent writes `stray-from-killed-iter.txt` + `LAZY_DEV_TIMEOUT=3` → progress.txt contains `## ⚠️ Iteration 1 was killed (timeout)` with stray file listed; iteration 2 `LAZY_DEV_PRINT_CONTEXT=1` shows `## Working Tree Warning` with stray file; clean-tree run (`ok.sh` fake agent after `git commit`) → 0× `Working Tree Warning`.
- **State left behind:** `main`, `.scratch/` untracked (verification artifacts only — not committed).
- **First step for next chunk (CHUNK-015):** Read CHUNK-015 spec; add `commit_state()` in `go.sh` and call it at end of each iteration in `main` (after attempt recording for now).

### CHUNK-011 — Git safety hardening in prompt (no `git add .`, expanded forbiddens) (RESOLVED 2026-08-27 | commit f1b4ee6)
- **Did:** `prompt.md`: added Staging subsection (explicit paths only, NEVER `git add .`/`-A`); expanded forbidden list (push, reset --hard, bulk discards, clean, rebase, branch -D, amend except Final Story Hygiene); added foreign-changes rule. `go.sh`: CONTEXT git one-liner now mentions no bulk staging. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) CONTEXT one-liner avoids literal `git add .` so grep audit passes — staging rule lives in prompt.md. (2) Final Story Commit Hygiene `--amend` exception remains until CHUNK-015. (3) `git checkout -- <single-file>` for PRD restore (Files to Read First) is still allowed — forbidden list targets bulk tree discards only.
- **Verification evidence:** `bash -n go.sh` → OK. Grep `git add .` in `prompt.md` + `go.sh` CONTEXT → only in prompt.md NEVER sentence. Forbidden families present: push, reset --hard, bulk discards (`checkout -- .`, `restore --staged`), clean, rebase, branch -D, amend (with exception). Foreign-changes rule present in prompt.md.
- **State left behind:** `main`, clean tree pending commit.
- **First step for next chunk (CHUNK-012):** Read CHUNK-012 spec; add read-only review contract to `prompt.md`, diff-range CONTEXT block in `run_iteration` for review stories, one line in `agent-loop.mdc`.

### CHUNK-013 — Stuck-story accounting (`attempts` / `blocked` / parked, exit 3) (RESOLVED 2026-08-27 | commit 1e7aac9)
- **Did:** `go.sh`: added `PRD_SELECTABLE_STORY` predicate, `record_story_attempt`, `is_feature_stuck`, `report_stuck_and_exit` (exit 3); `get_next_story_id` skips blocked stories; `LAST_ASSIGNED_STORY_ID` tracked in `run_iteration`; `main` records attempts after each iteration and checks stuck before/after. `examples/prd.json`, `commands/generate-prd.md`: added `"attempts": 0` to all story templates + runner-owned `blocked` note. `prompt.md`: concrete **Failing a Story** section. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Attempt is recorded once per outer iteration (not per retry) — retries within the same iteration count as one attempt. (2) `record_story_attempt` runs even when the agent iteration succeeded but left `passes != true` (the common no-flip case). (3) `is_feature_stuck` is checked at loop start and after attempt recording — parking the last story triggers immediate exit 3 on the same iteration. (4) CHUNK-016 will reuse `record_story_attempt` for gate failures.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `record_story_attempt` 1st→attempts=1/blocked=false, 3rd→blocked=true; `validate_prd` on mutated PRD → exit 0; blocked story skipped (`next=US-B`). Scratch `/tmp/lazydev-chunk013`: 2-story PRD + noop fake agent, `LAZY_DEV_FASTFAIL_SECS=0`, `--max-iterations 10` → US-A parked after 3 iterations, then `Story: US-B` for iterations 4–6, US-B parked, exit **3** with STUCK report listing both ids; final PRD shows `attempts:3, blocked:true` for both.
- **State left behind:** `main`, clean tree pending commit.
- **First step for next chunk (CHUNK-014):** Read CHUNK-014 spec; add kill/interrupt marker to `progress.txt` and dirty-tree warning injection into CONTEXT before each iteration.

### CHUNK-015 — Runner-owned state commits (remove the amend ambiguity) (RESOLVED 2026-08-27 | commit 07cdbf4)
- **Did:** `go.sh`: added `commit_state()` (`git -C PROJECT_ROOT` + `LAZY_DEV_REL` scoped add/commit with message `chore: lazy-dev state (<feature>, <story-id>)`); called from `main` after attempt recording each iteration. `prompt.md`: replaced amend Commit Hygiene with runner-owned state section; removed amend exception from forbidden list; aligned review-story line. `rules/agent-loop.mdc`: runner-owned state wording + handoff bullet. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) `commit_state` uses `git -C "$PROJECT_ROOT"` so paths work when `go.sh` is invoked from the lazy-dev install dir. (2) Runner also commits runner-owned artifacts like `.last-branch` under the feature dir — expected. (3) CHUNK-016 should call `commit_state` after gate revert mutations too (gate runs before commit_state in main order once 016 lands — spec says commit after gate). (4) When `LAZY_DEV_REL=.`, `git add .` from project root stages the whole repo — only applies when lazy-dev is the entire git root.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk015`: fake agent flips US-001, appends progress, commits `src/feature.js` → `git log --oneline -3`: `chore: lazy-dev state (chunk015, US-001)` then `feat: add feature.js for chunk015`; state commit `git show --name-only` lists only `.cursor/lazy-dev/features/chunk015/{.last-branch,prd.json,progress.txt}`; `prd.json` passes=true in state commit; zero `--amend` in history.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk015*` for cleanup.
- **First step for next chunk (CHUNK-016):** Read CHUNK-016 spec; add `run_quality_gate()` and integrate in `main` before `commit_state`.

### CHUNK-017 — Concurrency lock (one session per feature) (RESOLVED 2026-08-27 | commit f85bd5d)
- **Did:** `go.sh`: added `acquire_feature_lock` / `release_feature_lock` on `$FEATURE_DIR/.lazy-dev.lock` (flock when available, mkdir+pid stale detection on macOS); lock acquired early in `main` after traps, released in `cleanup`; `install_push_blocker` warns when `.git/lazy-dev-session.lock` holds a live PID from another run; troubleshooting line in both `--help` blocks. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) macOS has no `flock` here — mkdir lock dir is the live path; stale recovery removes the dir when stored PID is dead. (2) Lock acquisition requires `FEATURE_DIR` to exist (same prerequisite as `verify_setup`). (3) `kill -9` skips `cleanup` — stale lock recovery on the next run is intentional. (4) Different features in the same repo can still race on `.git/lazy-dev-session.lock`; the git-lock warning covers that case.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk017`: run1 (`slow.sh` sleep 30) + run2 same feature → run2 exit **1**, `Another lazy-dev session is running for feature 'chunk017' (PID: …)`; run1 completes, lock artifact **gone**. `kill -9` run1 mid-session → stale `.lazy-dev.lock` dir remains → run3 logs `Removing stale feature lock`, completes, lock **gone**.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk017*` for cleanup.
- **First step for next chunk (CHUNK-018):** Read CHUNK-018 spec; cap `rules/discovered/` injection and tail `progress.txt` in `run_iteration`; add observation framing + pattern-discovery.mdc guidance.

### CHUNK-018 — Context bloat caps + "data, not commands" framing (RESOLVED 2026-08-27 | commit 34fc7b2)
- **Did:** `go.sh`: added `_pattern_file_mtime`, `build_capped_discovered_patterns` (newest-first by mtime; `LAZY_DEV_MAX_PATTERNS` default 10, `LAZY_DEV_MAX_PATTERN_BYTES` default 8192; observation framing + truncation line), `build_progress_tail` (`LAZY_DEV_MAX_PROGRESS_LINES` default 150 + full-history pointer); both injected into CONTEXT in `run_iteration`. `rules/pattern-discovery.mdc`: dedup-before-create + observation phrasing guidance. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Byte cap counts heading + file body; with ~2077-byte test files the 8KB cap yields 3 files (not 4) before truncation. (2) `build_capped_discovered_patterns` skips a file when adding it would exceed the byte budget (unless it is the first file, which is head-truncated). (3) Progress tail is literal `tail -n N` on `progress.txt` — template header lines count toward the cap. (4) Empty `discovered/` omits the patterns block entirely.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk018`: 15×~2KB `.mdc` (staggered mtimes) + 500-line `progress.txt` → `LAZY_DEV_PRINT_CONTEXT=1`: framing header present; **3** pattern files (≤10, ≤8192 bytes), `… 12 more pattern files not injected`; progress lines **351–500** (150 lines) + full-history pointer. Source harness `LAZY_DEV_MAX_PATTERNS=3` → **3** headings; scratch `/tmp/lazydev-chunk018b` e2e → **3** pattern headings in CONTEXT.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk018*` for cleanup.
- **First step for next chunk (CHUNK-019):** Read CHUNK-019 spec; add stall watchdog in `main` wait-loop, shape warnings in `parse_agent_output`, fix thinking color leak, remove dead code.

### CHUNK-019 — Stall watchdog + parser polish (dead code, color leak, shape warnings) (RESOLVED 2026-08-27 | commit aeffb94)
- **Did:** `go.sh` only: added `STALL_TIMEOUT` / `LAZY_DEV_STALL_TIMEOUT` (default 600s) stall watchdog in `run_iteration` wait-loop (tracks `OUTPUT_FILE` size; kill via existing timeout path with exit 124 + `append_killed_iteration_marker` reason `stall`); `warn_event_shape` in `parse_agent_output` (one warning per unknown/empty-payload shape, bash 3.2 pipe-delimited dedupe); close dangling `thinking` color block at parser exit; updated `tee` comment; removed dead `first_output_received`, `normalize_newlines()`, and `full_cmd`. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** Used pipe-delimited string instead of associative array for shape dedupe — macOS `/bin/bash` is 3.2 (no `declare -A`).
- **Gotchas:** (1) Stall timer resets on any `OUTPUT_FILE` byte-size change (raw NDJSON via `tee`), not parsed assistant output — spinner-only periods still count as output if the file grows. (2) Stall and iteration timeout share exit 124 and the same kill path; distinguish via log line and killed-marker reason (`stall` vs `timeout`). (3) CHUNK-020 fake agents must emit periodic output to avoid stall kill when testing budget breaker.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: duplicate `bogus_event` + `thinking` stream → **1** shape warning (`shape_warnings=1`), `parse_exit=0`, thinking tail includes `[0m` reset. Scratch `/tmp/lazydev-chunk019`: stall agent (`echo` + `sleep 300`) + `LAZY_DEV_STALL_TIMEOUT=5` → `Stall detected (no output for 5s)` at ~5s, exit 124, marker `(stall, iteration 1)`; healthy agent (8×1s ticks) → `Iteration complete (10s)`, no stall line.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk019*` for cleanup.
- **First step for next chunk (CHUNK-020):** Read CHUNK-020 spec; extract cost/duration from `result` events into `.session-stats`, add `LAZY_DEV_MAX_COST` / `LAZY_DEV_MAX_MINUTES` budget breaker in `main` (exit 2).

### CHUNK-016 — Runner-enforced quality gate (build/test after each flip) (RESOLVED 2026-08-27 | commit bb9b423)
- **Did:** `go.sh` only: added `LAZY_DEV_GATE_TIMEOUT` (default 600s), `run_with_timeout`, toolchain detection (`npm`/`pnpm`/`yarn`/`cargo`/`go`, skip Java), `run_quality_gate` (build then test; absent scripts skipped), `revert_story_passes`, `handle_quality_gate_for_flip`; integrated in `main` after each iteration (before attempt recording/`commit_state`) with double-attempt guard when gate records failure. Added env var to both `--help` blocks.
- **Deviations from spec:** none.
- **Gotchas:** (1) Gate runs when `passes` flips to `true` even if the agent iteration exited non-zero (agent may flip before crashing). (2) Gate failure calls `record_story_attempt` — `gate_recorded_attempt` prevents the normal incomplete-story path from double-counting. (3) Scratch repos must copy lazy-dev without `.git` (rsync `--exclude=.git`) or `PROJECT_ROOT` resolves to the lazy-dev repo. (4) Fake agents should parse `--workspace` from argv (not `git rev-parse`) for PRD paths.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk016-fail` (npm `test: exit 1` + flip fake agent, `--max-iterations 1`) → gate runs build+test, test fails, `passes:false`, `attempts:1`, `## 🚫 Runner quality gate FAILED` in progress.txt, loud QUALITY GATE FAILED banner. `/tmp/lazydev-chunk016-pass` (`test: exit 0`) → `[SUCCESS] Quality gate passed (npm)`, `passes:true`, exit 0 all-complete. `/tmp/lazydev-chunk016-skip` (no package.json) → `Quality gate skipped (no recognized toolchain)`, flip stands, exit 0.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk016-*` for cleanup.
- **First step for next chunk (CHUNK-017):** Read CHUNK-017 spec; add exclusive feature lock (`$FEATURE_DIR/.lazy-dev.lock`) early in `main`, release in `cleanup`.

### CHUNK-020 — Cost / time budget breaker (exit 2) (RESOLVED 2026-08-27 | 3a2aab8)
- **Did:** `go.sh` only: `parse_agent_output` appends `iteration=N duration_s=N cost=N|unknown` lines to `$FEATURE_DIR/.session-stats` on each `result` event (cost from `.total_cost_usd // .cost_usd // .cost`); exported `LAZY_DEV_CURRENT_ITERATION` + `LAZY_DEV_SESSION_STATS_FILE` from `run_iteration`; added `load_session_stats_totals`, `is_session_budget_exceeded`, `report_budget_exceeded_and_exit` (loud log + `commit_state` + exit 2); budget check in `main` before each iteration; `LAZY_DEV_MAX_COST` / `LAZY_DEV_MAX_MINUTES` in both `--help` blocks. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) Budget time sums `duration_s` from stats lines (from result `duration_ms`), not wall-clock — fake agents can report high `duration_ms` without sleeping 2 min. (2) Cost check skipped when every line has `cost=unknown`; partial known costs still trigger when sum exceeds limit. (3) Budget check runs at loop start (before iteration N), so iteration 1 stats are checked before iteration 2 — matches “after iteration 1, exit 2” for `LAZY_DEV_MAX_MINUTES=1` + 125s reported duration. (4) `.session-stats` is under the feature dir and is committed by `commit_state`.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `parse_agent_output` pipe with `duration_ms=42000`, `total_cost_usd=1.25` → `iteration=3 duration_s=42 cost=1.25`. Scratch `/tmp/lazydev-chunk020-cost`: `LAZY_DEV_MAX_COST=0.10`, cost fake agent (0.07/iter) ×2 → exit **2**, `Cost limit: $0.10 exceeded`, stats `0.07+0.07`. Scratch `/tmp/lazydev-chunk020`: `LAZY_DEV_MAX_MINUTES=1`, slow fake (5×1s ticks + `duration_ms=125000`) → exit **2**, `Time limit: 1m exceeded`, `Cumulative duration: 2m 5s (125s)`, state commit present.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk020*` for cleanup.
- **First step for next chunk (CHUNK-021):** Read CHUNK-021 spec; make `setup_feature_branch` use PRD `branchName` as source of truth.

### CHUNK-021 — Branch-name source of truth (PRD `branchName` wins) (RESOLVED 2026-08-27)
- **Did:** `go.sh` only: added `is_sane_branch_name` + `resolve_feature_branch_name` (PRD `branchName` wins when prefix is `feature/`, `fix/`, `hotfix/`, `lazy/`, or `dev/`; warn + fallback to `feature/$FEATURE_NAME` otherwise); `setup_feature_branch` uses resolver; `track_branch` records `git branch --show-current`; `archive_previous_run` compares actual git branch vs `.last-branch`. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** Bogus-prefix warning redirected to stderr (`>&2`) so it is not captured when `resolve_feature_branch_name` runs inside `branch_name=$(...)` — without this, `git checkout -b` received the warn text as the branch name.
- **Gotchas:** (1) `verify_setup` runs before `setup_feature_branch`, so PRD is validated before branch resolution. (2) Archive folder naming still strips `feature/`, `lazy/`, `dev/` prefixes from the *previous* actual branch name. (3) CHUNK-022 will change rebase-on-resume behavior in the same `setup_feature_branch` function.
- **Verification evidence:** `bash -n go.sh` → OK. Source harness: `branchName: feature/MED-123_x` → `feature/MED-123_x`; `totally-bogus` → warn + `feature/x`; absent → `feature/x`; `fix/MED-99` → `fix/MED-99`. Scratch `/tmp/lazydev-chunk021`: PRD `feature/MED-123_x` → checkout `feature/MED-123_x`. `/tmp/lazydev-chunk021b2`: bogus prefix → warn + `feature/y`. `/tmp/lazydev-chunk021c`: no `branchName` → `feature/z`. `/tmp/lazydev-chunk021-archive`: `.last-branch`=`feature/old`, PRD `feature/new` → `Archiving previous run: feature/old`, archive folder created, `.last-branch` updated to `feature/new`.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk021*` for cleanup.
- **First step for next chunk (CHUNK-022):** Read CHUNK-022 spec; skip rebase on resume by default, add `--rebase` flag, re-verify files after `pop_lazy_dev_stash`.

### CHUNK-022 — Safe resume semantics (rebase opt-in, stash-pop re-verify) (RESOLVED 2026-08-27)
- **Did:** `go.sh`: added `--rebase` flag (parsed before globals overwrite); `setup_feature_branch` skips rebase when feature branch has commits beyond `main` unless `--rebase`; rebase conflicts abort + `exit 1`; added `verify_lazy_dev_files_after_branch_setup` after `pop_lazy_dev_stash` (missing `PRD_FILE`/`PROMPT_FILE`/`examples/` or stash still pending → stash guidance + `exit 1`). `README.md`: added "Resuming a feature" subsection. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** Also treat `LAZY_DEV_FILES_STASHED=1` after failed `git stash pop` as fatal (even if branch copies of files exist) — matches the spec's stash guidance and prevents starting the loop with a pending stash.
- **Gotchas:** (1) `FORCE_REBASE` must be initialized in the CLI parsing block only — a later `FORCE_REBASE=0` global reset silently disabled `--rebase` during testing. (2) `cleanup` trap preserves `exit 1` from branch setup failures. (3) CHUNK-023 will consolidate duplicated `--help` text and may add `--rebase` there too.
- **Verification evidence:** `bash -n go.sh` → OK. Scratch `/tmp/lazydev-chunk022b`: 3 commits beyond `main`, re-run without `--rebase` → log `skipping rebase`, branch tip unchanged (`29f9924…`). `/tmp/lazydev-chunk022-rebase2`: `--rebase` with conflicting README → `Rebasing on latest main (--rebase)`, `Rebase onto main failed due to conflicts`, `rebase_exit=1`, reflog shows `rebase (start)` + `rebase (abort)`. `/tmp/lazydev-chunk022-stash2`: conflicting `prompt.md` stash pop → `lazy-dev files remain in the stash`, `stash_exit=1`, no iteration banner.
- **State left behind:** `main`, `.scratch/` untracked; scratch dirs `/tmp/lazydev-chunk022*` for cleanup.
- **First step for next chunk (CHUNK-023):** Read CHUNK-023 spec; extract `print_usage()`, fix `MAX_ITERATIONS` in help after flag parse, rename `USE_CURSOR_AGENT_SUBCOMMAND`.

### CHUNK-023 — CLI surface polish (help text, naming, `printf`) (RESOLVED 2026-08-28 | 165710b)
- **Did:** `go.sh` only: extracted `print_usage()` (single source for `--help`, unknown-option, and missing-args paths); deferred help printing until after flag parsing so `--max-iterations` is reflected; renamed `USE_CURSOR_AGENT_SUBCOMMAND` → `USE_STANDALONE_CURSOR_AGENT` with sane polarity (1 = standalone `cursor-agent` found); `print_line` uses `printf '%b\n'` instead of `echo -e`; `initialize_progress_file` uses explicit `darwin*` branch for `sed -i`. Plus `HANDOVER.md` queue flip + this note.
- **Deviations from spec:** none.
- **Gotchas:** (1) `--help` can appear after other flags (e.g. `./go.sh --max-iterations 33 --help`) — all flags are parsed before `print_usage` runs. (2) `printf '%b'` still interprets standard C escapes (`\b`, `\n`, color codes) — the win over `echo -e` is consistency and safer handling of ambiguous sequences in paths; Windows-path backslashes like `\U` are preserved where `echo -e` may not be. (3) CHUNK-024 will touch `verify_setup` for command discoverability — do not duplicate help text again.
- **Verification evidence:** `bash -n go.sh` → OK. `./go.sh --max-iterations 33 --help` → `Maximum iterations: 33`. Grep `go.sh`: zero `USE_CURSOR_AGENT_SUBCOMMAND`. Source harness `print_line 'a\b c'` → same escape behavior as spec (`printf %b`). `./go.sh --help` prints unified usage. Scratch `/tmp/lazydev-chunk023`: `LAZY_DEV_FAKE_AGENT` run → `Using LAZY_DEV_FAKE_AGENT`, `Story: US-001`, `Iteration complete`.
- **State left behind:** `main`, `.scratch/` untracked; scratch dir `/tmp/lazydev-chunk023` for cleanup.
- **First step for next chunk (CHUNK-024):** Read CHUNK-024 spec; add `verify_setup` symlink for `.cursor/commands/lazy-dev` → `../lazy-dev/commands`, then fix content in `commands/generate-prd.md`.
