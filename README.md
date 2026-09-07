# Lazy Dev

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20Me-F16061?logo=ko-fi&logoColor=white)](https://ko-fi.com/goranlegenda)

An autonomous agent loop framework for Cursor. Runs multiple agent iterations to complete user stories from a PRD, with automatic task breakdown, quality gates, and knowledge persistence.

**Platform:** macOS and Linux only.

## Quick start

### 1. Install (once per machine)

```bash
./install.sh
```

This installs the toolkit to `~/.lazy-dev/`, adds `lazydev` to `~/.local/bin/`, and links the `generate-prd` skill into `~/.cursor/skills/`.

### 2. Initialize your project

```bash
cd your-repo
lazydev
```

If the project is not set up yet, `lazydev` automatically runs init: it creates `.lazy-dev/`, prompts for git tracking and model preferences, then exits.

**Commit all init changes before continuing.** Init leaves the working tree dirty (`.lazy-dev/config` and possibly `.gitignore`). Review with `git status`, then commit so your working tree is clean.

You can also run init explicitly:

```bash
lazydev init
```

### 3. Day-to-day use

Once init is committed and `git status` is clean:

```bash
lazydev
```

```
Lazy Dev
────────
1) Create new feature PRD
2) Implement a feature
q) Quit
```

1. **Create new feature PRD** — interactive `cursor-agent` session with the `generate-prd` skill. Clarifies requirements, then writes `.lazy-dev/features/<name>/prd.json`.
2. **Implement a feature** — runs the agent loop until all stories pass (auto-resumes across sessions).

## Responsibility matrix

| Component | Responsibility |
|---|---|
| `install.sh` | One-time global install to `~/.lazy-dev/` |
| `lazydev init` | Per-repo setup: git tracking + model selection |
| `lazydev` | Sole user entry point: create PRD or implement a feature |
| `generate-prd` skill | Clarify requirements, write PRD files at project level |
| `lazy.sh` | Internal agent-loop engine (not invoked directly) |

## Directory layout

**Global (`~/.lazy-dev/`)** — toolkit only:

```
~/.lazy-dev/
├── lazy.sh
├── lazydev
├── prompt.md
├── skills/
└── rules/
```

**Per project (`<repo>/.lazy-dev/`)** — state and configuration:

```
.lazy-dev/
├── config                  # tracked preference + model mapping (from lazydev init)
├── features/
│   └── <feature-name>/
│       ├── prd.json
│       └── progress.txt
└── rules/
    └── discovered/
```

By default, `lazydev init` adds `.lazy-dev/` to `.gitignore` so PRD/progress stay local. Choose to track it in git during the init prompts if you want team-shared PRDs.

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
│  │  Feature State (.lazy-dev/features/)    │               │
│  │  • <name>/prd.json                      │               │
│  │  • <name>/progress.txt                  │               │
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
4. Commits **source code changes** in the consumer repo (and `.lazy-dev/` when tracked)
5. Continues until all stories are complete

## Git Safety Policy

```
╔═══════════════════════════════════════════════════════════════════════════╗
║                        GIT SAFETY POLICY                                    ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  ✅ ALLOWED: git commit (implementation changes in consumer repo)         ║
║  ❌ FORBIDDEN: git push (blocked during agent sessions)                   ║
║                                                                           ║
║  PRD/progress state: .lazy-dev/ (gitignored by default at init)          ║
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
