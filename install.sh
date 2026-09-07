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
CURSOR_SKILL="${HOME}/.cursor/skills/generate-prd"
INSTALL_IN_PLACE=0

if [ "$SOURCE_DIR" = "$LAZY_DEV_HOME" ]; then
    INSTALL_IN_PLACE=1
fi

install_tree() {
    local name="$1"
    if [ "$INSTALL_IN_PLACE" = "1" ]; then
        return 0
    fi
    rm -rf "${LAZY_DEV_HOME:?}/${name}"
    cp -R "${SOURCE_DIR}/${name}" "${LAZY_DEV_HOME}/${name}"
}

echo "Installing lazy-dev to ${LAZY_DEV_HOME}..."
if [ "$INSTALL_IN_PLACE" = "1" ]; then
    echo "  (in-place: source tree is the install target; skipping file copy)"
fi

mkdir -p "$LAZY_DEV_HOME"

if [ "$INSTALL_IN_PLACE" != "1" ]; then
    for file in lazy.sh lazydev prompt.md; do
        cp "${SOURCE_DIR}/${file}" "${LAZY_DEV_HOME}/${file}"
        chmod +x "${LAZY_DEV_HOME}/${file}"
    done

    for dir in skills rules examples; do
        install_tree "$dir"
    done
else
    chmod +x "${LAZY_DEV_HOME}/lazy.sh" "${LAZY_DEV_HOME}/lazydev" 2>/dev/null || true
fi

mkdir -p "$LOCAL_BIN"
ln -sf "${LAZY_DEV_HOME}/lazydev" "${LOCAL_BIN}/lazydev"

mkdir -p "$(dirname "$CURSOR_SKILL")"
ln -sfn "${LAZY_DEV_HOME}/skills/generate-prd" "$CURSOR_SKILL"

if [ ! -s "${LAZY_DEV_HOME}/skills/generate-prd/SKILL.md" ]; then
    echo "ERROR: skills/generate-prd/SKILL.md is missing or empty. Cannot install." >&2
    exit 1
fi

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

echo "Next steps:"
echo "  1. cd your-git-repo"
echo "  2. lazydev          # auto-inits the project if needed"
echo "  3. git add … && git commit …   # commit init changes; tree must be clean"
echo "  4. lazydev          # create a PRD or implement a feature"
echo ""
