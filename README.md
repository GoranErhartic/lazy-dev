# Lazy Dev

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20Me-F16061?logo=ko-fi&logoColor=white)](https://ko-fi.com/goranlegenda)

An autonomous agent loop for Cursor. `lazydev` uses the Cursor TypeScript Agent SDK to turn a feature idea into a PRD through an interactive Q&A, then implements it story by story with local coding agents, quality gates, and one commit per story.

**Requirements:** macOS or Linux, Node.js 22.13+, npm, git, and a Cursor API key.

## Quick start

```bash
./install.sh          # 1. install once per machine
lazydev init          # 2. global setup: API key, default models, health check
cd your-repo
lazydev               # 3. first run sets up the repo, then opens the home screen
```

### 1. Install

`./install.sh` builds the CLI into `~/.lazy-dev/` and links `lazydev` into `~/.local/bin/`. Re-run it to update. It only replaces a directory that a previous install created.

### 2. Global setup: `lazydev init`

A one-time wizard:

1. **API key**: paste a key from [Cursor Dashboard → Integrations](https://cursor.com/dashboard/integrations). It is validated and stored in `~/.config/lazy-dev/credentials` with `0600` permissions. `CURSOR_API_KEY` in the environment always takes precedence.
2. **Default models**: pick the implementation, first-review, and second-review models from a searchable list (type to filter, arrow keys to move).
3. **Health check**: Node, git, PATH, toolkit assets, and credentials.

Re-run `lazydev init` any time to change the key or models. `lazydev doctor` re-runs the health check, and `lazydev config` shows the resolved settings.

### 3. Per repo: just run `lazydev`

The first time you run `lazydev` in a repo it asks one question: where should PRDs and progress live?

- **Local only (default):** `.lazy-dev/` is ignored through `.git/info/exclude`, so nothing is added to your tree and there is nothing to commit.
- **Tracked in git:** `.lazy-dev/` is committed so your team shares PRDs. lazydev offers to make that commit for you.

After that, `lazydev` opens the home screen:

```
 lazydev · my-app                                   ⎇ main ● clean

 ❯ + New feature PRD

   Features
   task-priority   ━━━━━━━━━━ 7/7   ● done         Priority levels for tasks
   bulk-export     ━━━━━━──── 3/5   ● in progress  CSV export for reports

 ↑↓ move  enter implement  n new PRD  o open PRD  u unblock  r refresh  q quit
```

| Key | Action |
|---|---|
| `enter` | Implement the selected feature (or create a PRD on the first row) |
| `n` | New feature PRD |
| `o` | Open the PRD in `$VISUAL` / `$EDITOR` |
| `u` | Reset attempts on blocked stories so they are retried |
| `q` / `esc` | Quit |

#### Creating a PRD

Name the feature (kebab-case), optionally describe it, and the PRD agent starts. Its clarifying questions appear as selectable options (with an "Other" free-text choice). When the agent has written a valid `prd.json`, lazydev shows the stories and offers **Implement now**, **Keep refining**, or **Back to home**. You can also reply in free text, `/done` asks the agent to finalize, and `/cancel` leaves.

#### Implementing a feature

The run dashboard shows overall progress, the current story and model, a story checklist, the live agent stream (text and tool calls), and quality-gate results. Press `c` to cancel (with confirmation). Ctrl+C cancels immediately, and pressing it twice quits.

## Commands

| Command | Description |
|---|---|
| `lazydev` | Home screen for the current repo (sets the repo up on first run) |
| `lazydev init` | Global setup wizard |
| `lazydev run <feature>` | Implement a feature. Uses the dashboard in a terminal, plain logs with `--no-tui` or in CI |
| `lazydev create <feature>` | Scaffold a PRD from the template for manual editing |
| `lazydev doctor [--offline]` | Health check (`--offline` skips the API call) |
| `lazydev config` | Show config paths, masked key, and resolved models |

`lazydev run` exit codes: `0` complete, `3` blocked, `4` iteration limit reached, `130` cancelled, `1` error.

## How the loop works

Each iteration:

1. Re-reads `prd.json` and picks the highest-priority story that is neither passing nor blocked.
2. Runs a local Cursor agent on it, using the model for that story type (a story's own `model` field overrides it).
3. Reads back the PRD the agent wrote. The agent may only complete its assigned story. `attempts` and `blocked` are owned by the runner.
4. If the story passes, runs the repo's `build`, `typecheck`, `lint`, and `test` scripts with the detected package manager (npm, pnpm, yarn, or bun). A failing gate reverts `passes`.
5. Commits all changes as one commit (`feat: (JIRA-1) Title` or `feat: US-001 - Title`).

A story that fails three times is parked as blocked. The run ends as **complete**, **blocked**, **iteration limit**, or **cancelled**. Each session writes a transcript to `.lazy-dev/features/<feature>/logs/`.

Every PRD ends with two independent review stories (`*-REVIEW` writes `review-1.md`, `*-REVIEW-2` writes `review-2.md`) and `*-IMPL-RECS`, which implements their findings.

### Git safety

- The run refuses to start on a dirty working tree.
- On `main`/`master`, it creates or checks out the PRD's `branchName` (default `feature/<feature>`).
- `git push` is blocked with a temporary `pre-push` hook during a run. Worktrees and `core.hooksPath` (husky) are supported, and the hook is restored on exit, cancel, or the next run after a crash.
- Agents never run git. The runner makes every commit.

## Directory layout

```
~/.lazy-dev/                 # toolkit (replaced by install.sh)
├── dist/  node_modules/
├── prompt.md  rules/  skills/  examples/

~/.config/lazy-dev/          # your settings (survives reinstalls)
├── config.json              # default models, optional maxIterations / timeoutMinutes
└── credentials              # API key, mode 0600

<repo>/.lazy-dev/            # per-repo state
├── config                   # { "tracked": bool, "models": { optional overrides } }
├── features/<feature>/
│   ├── prd.json  progress.txt  review-1.md  review-2.md
│   └── logs/                # session transcripts (always git-ignored)
└── rules/discovered/        # patterns shared across features
```

`LAZY_DEV_CONFIG_DIR` overrides the settings directory (and `XDG_CONFIG_HOME` is honoured).

## Development

```bash
npm run dev            # run the CLI from source
npm run typecheck
npm run lint
npm test
npm run build
```

## Support

If you find this project useful, consider supporting its development:

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/goranlegenda)

Or buy me a coffee at [ko-fi.com/goranlegenda](https://ko-fi.com/goranlegenda).

## License

MIT
