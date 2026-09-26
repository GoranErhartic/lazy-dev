#!/usr/bin/env bash
# Install lazy-dev globally to ~/.lazy-dev (macOS and Linux only).
#
# Usage: ./install.sh

set -euo pipefail

case "$(uname -s)" in
    Darwin|Linux) ;;
    *)
        echo "lazy-dev supports macOS and Linux only (found: $(uname -s))." >&2
        exit 1
        ;;
esac

LAZY_DEV_HOME="${LAZY_DEV_HOME:-$HOME/.lazy-dev}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LAZY_DEV_HOME="$(cd "$LAZY_DEV_HOME" 2>/dev/null && pwd -P || echo "$LAZY_DEV_HOME")"
LOCAL_BIN="${HOME}/.local/bin"
MARKER=".lazy-dev-install"
LEGACY_SKILL_LINK="${HOME}/.cursor/skills/generate-prd"

if [ "$LAZY_DEV_HOME" = "$SOURCE_DIR" ]; then
    echo "ERROR: LAZY_DEV_HOME must differ from the source checkout ($SOURCE_DIR)." >&2
    exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: Node.js 22.13+ and npm are required." >&2
    exit 1
fi

if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=13)?0:1)'; then
    echo "ERROR: Node.js 22.13+ is required (found $(node --version))." >&2
    exit 1
fi

echo "Installing lazy-dev to ${LAZY_DEV_HOME}..."

(
    cd "$SOURCE_DIR"
    npm ci
    npm run build
)

# Only wipe a directory that a previous install created. Legacy installs are
# recognised by their dist/cli.js or lazy.sh.
if [ -e "$LAZY_DEV_HOME" ]; then
    if [ -f "$LAZY_DEV_HOME/$MARKER" ] || [ -f "$LAZY_DEV_HOME/dist/cli.js" ] || [ -f "$LAZY_DEV_HOME/lazy.sh" ]; then
        rm -rf "${LAZY_DEV_HOME:?}"
    else
        echo "ERROR: $LAZY_DEV_HOME exists but is not a lazy-dev install. Refusing to delete it." >&2
        echo "       Set LAZY_DEV_HOME to another path or remove it yourself." >&2
        exit 1
    fi
fi

mkdir -p "$LAZY_DEV_HOME"
cp -R "$SOURCE_DIR/dist" "$SOURCE_DIR/skills" "$SOURCE_DIR/rules" "$SOURCE_DIR/examples" "$LAZY_DEV_HOME/"
cp "$SOURCE_DIR/prompt.md" "$SOURCE_DIR/package.json" "$SOURCE_DIR/package-lock.json" "$LAZY_DEV_HOME/"
(
    cd "$LAZY_DEV_HOME"
    npm ci --omit=dev --no-audit --no-fund
)
touch "$LAZY_DEV_HOME/$MARKER"
chmod +x "${LAZY_DEV_HOME}/dist/cli.js"

if [ ! -s "${LAZY_DEV_HOME}/skills/generate-prd/SKILL.md" ]; then
    echo "ERROR: skills/generate-prd/SKILL.md is missing or empty. Cannot install." >&2
    exit 1
fi

mkdir -p "$LOCAL_BIN"
ln -sf "${LAZY_DEV_HOME}/dist/cli.js" "${LOCAL_BIN}/lazydev"

# The PRD skill is now inlined by the CLI; remove the symlink older installs created.
if [ -L "$LEGACY_SKILL_LINK" ] && [ "$(readlink "$LEGACY_SKILL_LINK")" = "${LAZY_DEV_HOME}/skills/generate-prd" ]; then
    rm "$LEGACY_SKILL_LINK"
fi

echo ""
echo "Installed lazy-dev to ${LAZY_DEV_HOME}"
echo "  CLI: ${LOCAL_BIN}/lazydev"
echo ""

case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *)
        echo "Add ${LOCAL_BIN} to your PATH:"
        echo "  export PATH=\"${LOCAL_BIN}:\$PATH\""
        echo ""
        ;;
esac

echo "Next steps:"
echo "  1. lazydev init      # once per machine: API key, default models, health check"
echo "  2. cd your-git-repo"
echo "  3. lazydev           # first run sets up the repo, then create a PRD or implement one"
echo ""
