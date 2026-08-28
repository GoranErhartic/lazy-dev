# Lazy Dev

An autonomous agent loop framework for Cursor. Runs multiple agent iterations to complete user stories from a PRD, with automatic task breakdown, quality gates, and knowledge persistence.

> **🚧 Maintenance in progress:** a 26-chunk hardening plan for the loop lives in [HANDOVER.md](HANDOVER.md) — read it before making changes to `go.sh`.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     Agent Loop                              │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Iteration│───▶│ Iteration│───▶│ Iteration│───▶ Complete │
│  │    1     │    │    2     │    │    N     │              │
│  └──────────┘    └──────────┘    └──────────┘              │
│       │              │              │                       │
│       ▼              ▼              ▼                       │
│  ┌─────────────────────────────────────────┐               │
│  │      Feature State                      │               │
│  │  • features/<name>/prd.json             │               │
│  │  • features/<name>/progress.txt         │               │
│  └─────────────────────────────────────────┘               │
│       │              │              │                       │
│       ▼              ▼              ▼                       │
│  ┌─────────────────────────────────────────┐               │
│  │      Shared Knowledge (Cross-Feature)   │               │
│  │  • rules/discovered/*.mdc               │               │
│  └─────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

Each iteration:
1. Reads the feature's PRD and picks the highest priority incomplete story
2. Breaks the story into atomic sub-tasks
3. Implements each sub-task with verification
4. Commits changes and updates state
5. Continues until all stories are complete

The loop automatically stops when all stories in the PRD have `passes: true`.

## Directory Structure

```
lazy-dev/
├── go.sh                      # Main loop script
├── prompt.md                  # Agent instructions
├── README.md                  # This file
├── commands/                  # Cursor commands
│   └── generate-prd.md        # Generate PRD from requirements
├── examples/                  # Templates for new features
│   ├── prd.json               # PRD template with US-REVIEW, US-IMPLEMENT-RECS
│   └── progress.txt
├── rules/                     # Shared rules (all features)
│   ├── agent-loop.mdc
│   ├── task-breakdown.mdc
│   ├── quality-gates.mdc
│   ├── pattern-discovery.mdc
│   ├── discovered/            # ALL discovered patterns (cross-feature learning)
│   │   └── {feature}-{area}.mdc
│   └── README.md
└── features/                  # Each feature gets isolated state
    └── my-feature/
        ├── prd.json           # This feature's stories
        ├── progress.txt       # This feature's log
        └── archive/           # Previous runs
```

## Prerequisites

- [Cursor](https://cursor.sh) with CLI enabled
- `jq` for JSON parsing (install via `brew install jq` on macOS)
- Git repository initialized
- On first `./go.sh` run, lazy-dev auto-creates `.cursor/commands/lazy-dev` as a symlink to `commands/` so `/lazy-dev/generate-prd` is discoverable in Cursor

## Agent Capabilities

The agent has access to powerful tools for autonomous work:

| Tool | Purpose |
|------|---------|
| `mcp_open-websearch_search` | Search the web for current data, prices, market info, news |
| `mcp_context7_resolve-library-id` | Resolve package name to Context7 library ID (call first) |
| `mcp_context7_query-docs` | Query library documentation and code examples |
| `codebase_search` | Find patterns and implementations in the codebase |
| `grep` | Search for specific strings in files |

**Important:** The agent should NEVER ask the user for data. If a story requires external information (market data, prices, etc.), the agent should use `mcp_open-websearch_search` to find information autonomously.

## Commands

### Generate PRD

Use the `/lazy-dev/generate-prd` command to create a PRD from human-readable feature requirements:

1. Run the command in Cursor
2. Describe your feature in plain English
3. Answer clarifying questions
4. Get a structured `prd.json` ready for the agent loop

This is the recommended way to create new features—it ensures your PRD is properly structured and breaks work into appropriately-sized user stories.

## Quick Start

### 1. Copy to Your Project

Copy the `lazy-dev/` directory to your project's `.cursor/` folder:

```bash
cp -r cursor-rules/.cursor/lazy-dev/ /path/to/your/project/.cursor/lazy-dev/
```

### 2. Create a Feature

```bash
cd .cursor/lazy-dev
mkdir -p features/my-feature
cp examples/prd.json features/my-feature/
cp examples/progress.txt features/my-feature/
```

### 3. Configure the PRD

Edit `features/my-feature/prd.json` with your user stories:

```json
{
  "project": "MyApp",
  "branchName": "feature/my-feature",
  "description": "What this feature accomplishes",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add user authentication",
      "description": "As a user, I want to log in securely.",
      "acceptanceCriteria": [
        "Login form with email/password",
        "JWT token stored securely",
        "Build passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

### 4. Run the Loop

```bash
chmod +x go.sh
./go.sh my-feature                      # Run with default 20 iterations
./go.sh --max-iterations 30 my-feature  # Custom max iterations
./go.sh --rebase my-feature             # Resume and rebase onto latest main
./go.sh -v my-feature                   # Verbose output
```

### CLI options

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Enable verbose/debug output |
| `--max-iterations N` | Stop after N iterations (default: 20) |
| `--rebase` | Rebase an existing feature branch onto latest `main` (default: skip when branch has commits) |
| `--help`, `-h` | Show usage |

Run `./go.sh --help` for the full list.

## Working with Multiple Features

Each feature has isolated state:

```bash
# Create features
mkdir -p features/user-auth features/payment-flow features/notifications

# Copy templates
for f in user-auth payment-flow notifications; do
  cp examples/prd.json features/$f/
  cp examples/progress.txt features/$f/
done

# Run specific feature
./go.sh user-auth
./go.sh payment-flow
```

## Rules System

### Shared Rules (`rules/`)

Apply to ALL features:
- `agent-loop.mdc` - Iteration lifecycle
- `task-breakdown.mdc` - Story decomposition
- `quality-gates.mdc` - Verification checklists
- `pattern-discovery.mdc` - How to capture and store patterns

Project-specific patterns (architecture, testing, security, etc.) live in **your project's** `.cursor/rules/patterns/` — not inside lazy-dev. See `rules/README.md` and `prompt.md` for how agents load them.

### Discovered Patterns (`rules/discovered/`)

**ALL discovered patterns are stored centrally** in `rules/discovered/` for cross-feature learning.

When an agent discovers a reusable pattern, it creates a file using the naming convention `{feature}-{area}.mdc`:

```
rules/discovered/
├── user-auth-jwt-patterns.mdc      # Discovered during user-auth feature
├── dashboard-dnd-patterns.mdc      # Discovered during dashboard feature
└── shared-api-conventions.mdc      # General patterns
```

Each pattern file includes a `discoveredFrom` field in frontmatter for traceability.

**Every iteration reads `rules/discovered/`** at bootstrap, enabling agents to benefit from patterns discovered by any previous feature.

## PRD Format

```json
{
  "project": "ProjectName",
  "branchName": "feature/branch-name",
  "description": "Feature description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "Full description",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "priority": 1,
      "passes": false,
      "attempts": 0,
      "notes": ""
    }
  ]
}
```

Optional top-level fields:

| Field | Purpose |
|-------|---------|
| `jiraTaskId` | Jira ticket id (e.g. `"MED-123"`) — used for branch naming and model mapping when story ids use Jira suffixes (`MED-123-REVIEW`) |

Optional per-story fields:

| Field | Purpose |
|-------|---------|
| `attempts` | Failed iteration count (runner-managed; start at `0`) |
| `model` | Override the default model for this story |
| `blocked` | Set by the runner when a story is parked after repeated failures |

## Standard Story Flow

Every PRD should include these final stories (in priority order):

| Story | Priority | Purpose |
|-------|----------|---------|
| `US-REVIEW` | 997 | First code review (GPT model) |
| `US-REVIEW-2` | 998 | Second independent code review (Gemini model) |
| `US-IMPLEMENT-RECS` | 999 | Fix issues found in both reviews |

Copy `examples/prd.json` for the canonical template including these stories.

## Completion Detection

The loop runner monitors the PRD state automatically and stops when all stories have `passes: true`. No special signal is required from the agent.

## Resuming a feature

Re-running `./go.sh <feature>` for an existing feature checks out the feature branch again but **does not rebase** onto `main` when the branch already has commits beyond `main` — your branch tip stays put so resume is predictable.

To pull in latest `main` anyway, pass **`--rebase`**. If the rebase hits conflicts, the runner aborts the rebase and exits with an error (it does not continue on a stale base).

Before switching branches, `go.sh` may stash uncommitted changes under the lazy-dev install directory. If `git stash pop` fails or critical files (`prd.json`, `prompt.md`, `examples/`) are missing after branch setup, the runner exits with guidance to run `git stash list` / `git stash pop` and resolve conflicts, then re-run.

## Quality gate

After each iteration, if the assigned story was flipped to `passes: true`, the runner runs an automated **quality gate** before accepting the flip:

- **Node** (`npm`, `pnpm`, or `yarn`): runs `build` and `test` scripts when present in `package.json` (missing scripts are skipped)
- **Rust** (`cargo`): `cargo build` and `cargo test`
- **Go**: `go build ./...` and `go test ./...`
- **Java/Gradle** and unrecognized toolchains: gate skipped (no built-in commands)

If the gate fails, the runner **reverts** the story flip, increments `attempts`, and appends a `🚫` note to `progress.txt` with the failure excerpt. The next iteration must fix the gate before the story can complete.

Override per-step timeout with `LAZY_DEV_GATE_TIMEOUT` (default 600 seconds).

## Environment variables

All `LAZY_DEV_*` settings override CLI defaults or tune runner behavior:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LAZY_DEV_TIMEOUT` | `1800` | Per-iteration timeout (seconds) |
| `LAZY_DEV_MAX_ITERATIONS` | `20` | Maximum iterations (overridden by `--max-iterations`) |
| `LAZY_DEV_FASTFAIL_SECS` | `60` | Failed iterations shorter than this are not retried (`0` disables) |
| `LAZY_DEV_STALL_TIMEOUT` | `600` | Kill an iteration that produces no output for this many seconds |
| `LAZY_DEV_MODEL_IMPL` | `opus-4.6` | Model for implementation stories |
| `LAZY_DEV_MODEL_REVIEW` | `gpt-5.3-codex` | Model for first review story (`*-REVIEW`, not `*-REVIEW-2`) |
| `LAZY_DEV_MODEL_REVIEW2` | `gemini-3-pro` | Model for second review story (`*-REVIEW-2`) |
| `LAZY_DEV_GATE_TIMEOUT` | `600` | Per-step build/test timeout in the quality gate (seconds) |
| `LAZY_DEV_MAX_COST` | *(unset)* | Stop when cumulative session cost exceeds this (USD) |
| `LAZY_DEV_MAX_MINUTES` | *(unset)* | Stop when cumulative session duration exceeds this (minutes) |
| `LAZY_DEV_MAX_PATTERNS` | `10` | Max discovered-pattern files injected into agent context |
| `LAZY_DEV_MAX_PATTERN_BYTES` | `8192` | Max bytes per injected pattern file |
| `LAZY_DEV_MAX_PROGRESS_LINES` | `150` | Max lines of `progress.txt` tail injected into context |
| `LAZY_DEV_PRINT_CONTEXT` | *(unset)* | Set to `1` to print the assembled agent prompt before launch (debug) |
| `LAZY_DEV_FAKE_AGENT` | *(unset)* | Test hook: executable used instead of the Cursor CLI |

## Handover

The lazy-dev repo itself is maintained via a chunked implementation plan in [HANDOVER.md](HANDOVER.md). If you are modifying `go.sh`, the loop protocol, or runner behavior, read that file first — it is the authoritative work plan and handoff log for framework changes.

## Archiving

When a feature's branch changes, previous state is archived:

```
features/my-feature/archive/
└── 2024-01-15-old-branch/
    ├── prd.json
    └── progress.txt
```

Note: Discovered patterns in `rules/discovered/` are NOT archived—they persist across all features as shared knowledge.

## Customization

### Adjusting Quality Gates

Edit `rules/quality-gates.mdc` to match your project's checks.

### Adding Discovered Patterns

Create `.mdc` files in `rules/discovered/` using the `{feature}-{area}.mdc` naming convention:

```yaml
---
description: "My project conventions discovered during user-auth feature"
globs: ["**/src/**"]
discoveredFrom: "user-auth"
---

# API Conventions
- Always return `{ data, error, meta }` shape
- Use 4xx for client errors, 5xx for server errors
```

### Modifying Agent Behavior

Edit `prompt.md` to change how agents approach tasks.

## Troubleshooting

### Feature Not Found

```bash
# Make sure the feature directory exists
mkdir -p features/<feature-name>
cp examples/prd.json features/<feature-name>/
```

### Agent Not Finding Stories

- Check `prd.json` is valid JSON
- Ensure at least one story has `passes: false`
- Verify `priority` values are set

### Quality Checks Failing

- Check if project has expected scripts (`npm run build`, etc.)
- Verify dependencies are installed
- Review `rules/quality-gates.mdc`

## License

MIT
