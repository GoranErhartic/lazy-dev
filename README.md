# Lazy Dev

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20Me-F16061?logo=ko-fi&logoColor=white)](https://ko-fi.com/goranlegenda)

An autonomous agent loop framework for Cursor. Runs multiple agent iterations to complete user stories from a PRD, with automatic task breakdown, quality gates, and knowledge persistence.

**Platform:** macOS and Linux only.

## Install (once per machine)

```bash
./install.sh
```

This installs the toolkit to `~/.lazy-dev/`, adds `lazydev` to `~/.local/bin/`, and links the `generate-prd` skill into `~/.cursor/skills/`.

Model preferences are stored in `~/.lazy-dev/config.env` (created on first implement run).

## Usage (per project)

From any git repository:

```bash
lazydev
```

On first run, lazy-dev creates project state under `~/.lazy-dev/<repo-name>/`. **Nothing is written or committed inside your repository** for bootstrap — your `main` branch stays untouched.

```
Lazy Dev
────────
1) Create new feature PRD
2) Implement a feature
q) Quit
```

1. **Create new feature PRD** — interactive `cursor-agent` session with the `generate-prd` skill. Writes `~/.lazy-dev/<repo-name>/features/<name>/prd.json`.
2. **Implement a feature** — runs the agent loop until all stories pass (or the loop stops on budget/stuck/max-iterations).

You can also run the loop directly:

```bash
lazy.sh <feature-name>
```

## Directory layout

**Global (`~/.lazy-dev/`)** — toolkit + per-project state:

```
~/.lazy-dev/
├── lazy.sh
├── lazydev
├── prompt.md
├── config.env              # model preferences (first implement run)
├── skills/
├── rules/
└── <repo-name>/            # per-project state (not in your git repo)
    ├── .project-root       # absolute path to the git repo root
    ├── features/
    │   └── <feature-name>/
    │       ├── prd.json
    │       └── progress.txt
    └── rules/
        └── discovered/
```

If two repos share the same folder name, lazy-dev appends a short hash suffix (e.g. `my-app-a1b2c3d4`).

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
│  │  Feature State (~/.lazy-dev/<repo>/)    │               │
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
4. Commits **source code changes** in the consumer repo and updates state under `~/.lazy-dev/`
5. Continues until all stories are complete

## Git Safety Policy

```
╔═══════════════════════════════════════════════════════════════════════════╗
║                        GIT SAFETY POLICY                                    ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  ✅ ALLOWED: git commit (implementation changes in consumer repo)         ║
║  ❌ FORBIDDEN: git push (blocked during agent sessions)                   ║
║                                                                           ║
║  PRD/progress state: ~/.lazy-dev/<repo>/ (outside consumer git repo)      ║
║  Agent loop: requires clean tree between iterations (repo only)           ║
║  Runner commits story source changes with git add -A                      ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

## Development

After changing this repository, reinstall to `~/.lazy-dev/`:

```bash
./install.sh
```

## Support

If you find this project useful, consider supporting its development:

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/goranlegenda)

Or buy me a coffee at [ko-fi.com/goranlegenda](https://ko-fi.com/goranlegenda).

## License

MIT
