# Lazy Dev

An autonomous agent loop framework for Cursor. Runs multiple agent iterations to complete user stories from a PRD, with automatic task breakdown, quality gates, and knowledge persistence.

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

## CLI Wrapper

Run `lazydev` from the terminal for an interactive menu that stays open until you quit:

```
Lazy Dev
────────
1) Create new feature PRD
2) Implement a feature
q) Quit
```

1. **Create new feature PRD** — launches an interactive `cursor-agent` session with the `generate-prd` skill. You clarify requirements in chat; the agent writes `features/<name>/prd.json`.
2. **Implement a feature** — pick a prepared feature and run the `lazy.sh` agent loop until all stories pass (or the loop stops on budget/stuck/max-iterations).

### Install

```bash
chmod +x lazydev
# Optional: add to PATH
ln -s "$(pwd)/lazydev" ~/.local/bin/lazydev
```

Then run from your project root (or any directory inside the git repo):

```bash
lazydev
```

You can still run `./lazy.sh <feature-name>` directly if you prefer.

## Directory Structure

```
lazy-dev/
├── lazydev                    # CLI wrapper script
├── lazy.sh                    # Main loop script
├── prompt.md                  # Agent instructions
├── README.md                  # This file
├── skills/                    # Cursor skills for different tasks
│   └── generate-prd/          # PRD generation skill
├── features/                  # Feature directories with PRDs and progress tracking
└── rules/                     # Project development rules
```

## Commands

### Create a New Feature PRD

Choose option **1** in the `lazydev` menu. An interactive agent session starts with the `generate-prd` skill. Describe your feature, answer clarification questions, and confirm the requirements summary. The agent creates:

- `features/<feature-name>/prd.json`
- `features/<feature-name>/progress.txt`
- A feature branch (`feature/<name>` or `feature/<JIRA-ID>_<name>`)

### Implement an Existing Feature

Choose option **2** in the `lazydev` menu. Pick from features that have a `prd.json`, then the agent loop runs until all stories have `passes: true`.

You can also run the loop directly:

```bash
./lazy.sh <feature-name>
```

## Directory Structure

Each feature gets its own subfolder with isolated state.
- `features/<name>/prd.json` - Feature requirements and user stories
- `features/<name>/progress.txt` - Implementation progress tracking

## Git Safety Policy

```
╔═══════════════════════════════════════════════════════════════════════════╗
║                        ⚠️  GIT SAFETY POLICY  ⚠️                           ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  ✅ ALLOWED: git commit                                                   ║
║  ❌ FORBIDDEN: git push (NEVER - this is STRICTLY BLOCKED)               ║
║                                                                           ║
║  This script will:                                                        ║
║  1. Ensure you're on the latest main branch                              ║
║  2. Create a feature branch: feature/<feature-name>                      ║
║  3. Block ALL push operations                                            ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

## How It Works

The agent loop runs continuously until all user stories in the PRD have `passes: true`. The implementation uses:
- Headless mode with `--auto-review` (Smart Auto approval)
- Automatic task breakdown and verification
- Progress tracking through state files