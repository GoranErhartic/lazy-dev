# Lazy Dev Rules

Shared rules that apply to all features in the agent loop.

## Structure

```
rules/
├── agent-loop.mdc         # Core iteration behavior (alwaysApply)
├── task-breakdown.mdc     # Story decomposition (alwaysApply)
├── quality-gates.mdc      # Verification checklists (alwaysApply)
├── pattern-discovery.mdc  # Capturing reusable patterns (alwaysApply)
└── discovered/            # Cross-feature discovered patterns
    └── .gitkeep
```

## Rule Types

### Always Applied (`alwaysApply: true`)

Core rules active for every agent invocation:
- `agent-loop.mdc` - How to operate in the iteration loop
- `task-breakdown.mdc` - How to decompose stories
- `quality-gates.mdc` - What checks must pass
- `pattern-discovery.mdc` - How to capture reusable patterns

### Project Patterns

Project-specific patterns (architecture, testing, security, etc.) live in **your project's** `.cursor/rules/patterns/` — not inside lazy-dev's `rules/` tree. Maintain them separately from lazy-dev; agents consult them during implementation (see `prompt.md` and the main [README](../README.md#rules-system) for the full loading order).

### Discovered Patterns

All discovered patterns are stored centrally in `discovered/` for cross-feature learning.

## Creating New Shared Rules

1. Create file: `discovered/{category}-{area}.mdc`
2. Add frontmatter:
   ```yaml
   ---
   description: "Brief description"
   globs: ["**/src/**"]
   ---
   ```
3. Write concise, actionable rules

## Pattern Loading

At iteration start, agents should:
1. Read `rules/discovered/*.mdc` for cross-feature patterns
2. Consult your project's `.cursor/rules/patterns/*.mdc` for project-specific patterns (see `prompt.md` for details)

## Examples

### Discovered Pattern

```yaml
# rules/discovered/database-conventions.mdc
---
description: "Database conventions for all features"
globs: ["**/migrations/**", "**/db/**"]
discoveredFrom: "user-auth"
---

# Database Conventions
- Use IF NOT EXISTS for table creation
- Include both up() and down() migrations
- Use snake_case for column names
```
