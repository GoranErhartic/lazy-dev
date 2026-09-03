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
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="${HOME}/.local/bin"
CURSOR_SKILL="${HOME}/.cursor/skills/generate-prd"

install_tree() {
    local name="$1"
    rm -rf "${LAZY_DEV_HOME:?}/${name}"
    cp -R "${SOURCE_DIR}/${name}" "${LAZY_DEV_HOME}/${name}"
}

echo "Installing lazy-dev to ${LAZY_DEV_HOME}..."

mkdir -p "$LAZY_DEV_HOME"

for file in lazy.sh lazydev prompt.md; do
    cp "${SOURCE_DIR}/${file}" "${LAZY_DEV_HOME}/${file}"
    chmod +x "${LAZY_DEV_HOME}/${file}"
done

for dir in skills rules examples; do
    install_tree "$dir"
done

mkdir -p "$LOCAL_BIN"
ln -sf "${LAZY_DEV_HOME}/lazydev" "${LOCAL_BIN}/lazydev"

mkdir -p "$(dirname "$CURSOR_SKILL")"
ln -sfn "${LAZY_DEV_HOME}/skills/generate-prd" "$CURSOR_SKILL"

echo ""
echo "Installed lazy-dev to ${LAZY_DEV_HOME}"
echo "  CLI: ${LOCAL_BIN}/lazydev"
echo "  Skill: ${CURSOR_SKILL}"
echo ""

case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *)
        echo "Add ${LOCAL_BIN} to your PATH if lazydev is not found:"
        echo "  export PATH=\"${LOCAL_BIN}:\$PATH\""
        echo ""
        ;;
esac

echo "Run 'lazydev' from any git project to get started."
