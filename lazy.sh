#!/bin/bash
# Lazy Dev - Cursor CLI Agent Loop
# Usage: ./lazy.sh <feature-name>
#
# Each feature gets its own subfolder with isolated state.
# Runs continuously until ALL user stories in PRD have passes: true.
# Always runs in headless mode with --auto-review (Smart Auto approval).
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        GIT POLICY (runner-owned)                          ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  1. Fail fast if working tree is not clean at session/iteration start    ║
# ║  2. On main: prompt for branch name; otherwise stay on current branch    ║
# ║  3. Runner commits all changes (git add -A) after each story              ║
# ║  4. Git push is BLOCKED during the session                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Print CLI usage (--help and missing-args). Caller must resolve MAX_ITERATIONS first.
print_usage() {
    echo "Usage: ./lazy.sh [OPTIONS] <feature-name>"
    echo ""
    echo "Options:"
    echo "  --verbose, -v          Enable verbose/debug output"
    echo "  --max-iterations N     Set maximum iterations (default: 20)"
    echo "  --bootstrap-project    Initialize ~/.lazy-dev/<project>/ state and exit"
    echo "  --print-state-dir      With --bootstrap-project, print the state directory path"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Runs continuously until ALL user stories in PRD have passes: true."
    echo "Agent runs in headless mode with auto-approve enabled."
    echo "Maximum iterations: $MAX_ITERATIONS (override with --max-iterations or LAZY_DEV_MAX_ITERATIONS)"
    echo ""
    echo "Examples:"
    echo "  ./lazy.sh my-feature              # Run agent for feature"
    echo "  ./lazy.sh features/user-auth      # Also accepts features/ prefix"
    echo "  ./lazy.sh -v my-feature           # With verbose output"
    echo "  ./lazy.sh --max-iterations 30 my-feature  # Custom max iterations"
    echo ""
    echo "Environment variables:"
    echo "  LAZY_DEV_TIMEOUT=<s>         Per-iteration timeout in seconds (default: 1800)"
    echo "  LAZY_DEV_MAX_ITERATIONS=<n>  Maximum iterations (default: 20)"
    echo "  LAZY_DEV_FASTFAIL_SECS=<s>   Failed iterations shorter than this are not retried (default: 60; 0 disables)"
    echo "  LAZY_DEV_FAKE_AGENT=<path>   Test hook: run this executable instead of the Cursor CLI"
    echo "  LAZY_DEV_MODEL_IMPL=<id>     Implementation story model (default: opus-4.6)"
    echo "  LAZY_DEV_MODEL_REVIEW=<id>   First review story model (default: gpt-5.3-codex)"
    echo "  LAZY_DEV_MODEL_REVIEW2=<id>  Second review story model (default: gemini-3-pro)"
    echo "  LAZY_DEV_GATE_TIMEOUT=<s>    Per-gate build/test timeout in seconds (default: 600)"
    echo "  LAZY_DEV_STALL_TIMEOUT=<s>   Kill if agent output is idle this long (default: 600)"
    echo "  LAZY_DEV_RESULT_TAIL_HANG_TIMEOUT=<s> Kill if result received but pipeline alive (default: 10)"
    echo "  LAZY_DEV_MAX_COST=<usd>      Stop when cumulative session cost exceeds this (decimal USD)"
    echo "  LAZY_DEV_MAX_MINUTES=<n>     Stop when cumulative session duration exceeds this (minutes)"
    echo ""
    echo "Install lazy-dev globally (once per machine):"
    echo "  ./install.sh"
    echo ""
    echo "To create a new feature:"
    echo "  lazydev   # option 1: Create new feature PRD"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI ENTRY POINT — direct execution only, NOT when sourced
#
# Sourcing this file (e.g. `source ./lazy.sh __test__`) only defines the
# functions and globals above, for function-level tests. Flag parsing,
# argument validation, and main() are skipped.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

# Parse flags
VERBOSE=""
SHOW_HELP=0
LAZY_DEV_BOOTSTRAP_ONLY=0
LAZY_DEV_PRINT_STATE_DIR=0
while [[ "$1" == -* ]]; do
        case "$1" in
        --verbose|-v)
            VERBOSE="1"
            shift
            ;;
        --max-iterations)
            shift
            MAX_ITERATIONS="$1"
            shift
            ;;
        --bootstrap-project)
            LAZY_DEV_BOOTSTRAP_ONLY=1
            shift
            ;;
        --print-state-dir)
            LAZY_DEV_PRINT_STATE_DIR=1
            shift
            ;;
        --help|-h)
            SHOW_HELP=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Resolve MAX_ITERATIONS before printing usage (flag > env > default)
if [ -z "${MAX_ITERATIONS:-}" ]; then
    MAX_ITERATIONS="${LAZY_DEV_MAX_ITERATIONS:-20}"
fi

if [ "$SHOW_HELP" = "1" ]; then
    print_usage
    exit 0
fi

# Validate arguments
if [ "${LAZY_DEV_BOOTSTRAP_ONLY:-0}" != "1" ] && [ -z "$1" ]; then
    print_usage
    exit 1
fi

fi  # ── end CLI entry point (direct execution only) ──

# Configuration
LAZY_DEV_HOME="${LAZY_DEV_HOME:-$HOME/.lazy-dev}"
SCRIPT_DIR="$LAZY_DEV_HOME"
CONFIG_FILE="$LAZY_DEV_HOME/config.env"
PROJECT_SLUG=""
STATE_DIR=""

FEATURE_NAME=""
if [[ "${LAZY_DEV_BOOTSTRAP_ONLY:-0}" != "1" ]] && [ -n "${1:-}" ]; then
    FEATURE_NAME="${1#features/}"
fi

# PROJECT_ROOT is the git workspace root
if _git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    PROJECT_ROOT="$(cd "$_git_root" && pwd -P)"
else
    PROJECT_ROOT="$(pwd -P)"
fi
unset _git_root

FEATURE_DIR=""
PRD_FILE=""
PROGRESS_FILE=""
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
ARCHIVE_DIR=""
LAST_BRANCH_FILE=""
SESSION_STATS_FILE=""
DISCOVERED_DIR=""

# Will be set by verify_setup: 1 when standalone cursor-agent binary is available
USE_STANDALONE_CURSOR_AGENT=0

# Global temp file for output capture (set in main, cleaned up by trap)
OUTPUT_FILE=""

# File to track spinner PID across subshells (fixes orphaned spinner bug)
SPINNER_PID_FILE=""

# Track child processes for cleanup
AGENT_PID=""
PIPELINE_PID=""
CAFFEINATE_PID=""

# Duration of the last run_iteration call, in seconds (set by run_iteration;
# consumed by main's retry loop for the fast-fail decision)
LAST_ITERATION_DURATION=0

# Story id assigned at the start of the current run_iteration (consumed by main
# for attempt accounting after each iteration)
LAST_ASSIGNED_STORY_ID=""

# Active-iteration tracking for killed-iteration markers (timeout / interrupt)
CURRENT_ITERATION=0
ITERATION_START_EPOCH=0
LAZY_DEV_ITERATION_ACTIVE=0

# Timeout for each iteration in seconds (30 minutes default)
# Override with LAZY_DEV_TIMEOUT environment variable
ITERATION_TIMEOUT="${LAZY_DEV_TIMEOUT:-1800}"

# Stall watchdog: kill if OUTPUT_FILE size is unchanged for this many seconds
# (default 600). Override with LAZY_DEV_STALL_TIMEOUT.
STALL_TIMEOUT="${LAZY_DEV_STALL_TIMEOUT:-600}"

# Kill pipeline if result NDJSON arrived but process is still alive (default 10s).
# Override with LAZY_DEV_RESULT_TAIL_HANG_TIMEOUT.
RESULT_TAIL_HANG_TIMEOUT="${LAZY_DEV_RESULT_TAIL_HANG_TIMEOUT:-10}"

# Maximum iterations to prevent infinite loops (default 20)
# Precedence: --max-iterations flag (parsed above) > LAZY_DEV_MAX_ITERATIONS
# env var > 20. Guarded so the flag value is not clobbered by this line.
if [ -z "${MAX_ITERATIONS:-}" ]; then
    MAX_ITERATIONS="${LAZY_DEV_MAX_ITERATIONS:-20}"
fi

# Maximum retries per iteration on failure
MAX_RETRIES=3

# Exponential backoff schedule (seconds) between retries: 5s, 15s, 45s
BACKOFF_SCHEDULE=(5 15 45)

# Fast-fail threshold (seconds): a FAILED iteration that ended in less than
# this time is NOT retried - sub-60s failures are almost always config/auth/
# model errors, not transient ones. 0 disables fast-fail.
# Override with LAZY_DEV_FASTFAIL_SECS
FASTFAIL_SECS="${LAZY_DEV_FASTFAIL_SECS:-60}"

# Test hook: when set (non-empty), run_iteration uses this executable in
# place of cursor/cursor-agent (same flags + prompt argument, same
# tee | parse_agent_output pipeline). Lets you test loop behavior without
# launching a real agent. Example:
#   LAZY_DEV_FAKE_AGENT=/path/to/fake-agent.sh ./lazy.sh my-feature
LAZY_DEV_FAKE_AGENT="${LAZY_DEV_FAKE_AGENT:-}"

# Per-type model overrides (consumed by get_model_for_story; per-story .model
# field in prd.json still wins via resolve_model_for_story)
LAZY_DEV_MODELS_CONFIGURED=0
LAZY_DEV_MODEL_IMPL="${LAZY_DEV_MODEL_IMPL:-opus-4.6}"
LAZY_DEV_MODEL_REVIEW="${LAZY_DEV_MODEL_REVIEW:-gpt-5.3-codex}"
LAZY_DEV_MODEL_REVIEW2="${LAZY_DEV_MODEL_REVIEW2:-gemini-3-pro}"

# Load persisted model config from ~/.lazy-dev/config.env
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Per-gate build/test timeout (seconds); consumed by run_quality_gate
LAZY_DEV_GATE_TIMEOUT="${LAZY_DEV_GATE_TIMEOUT:-600}"

# First ~20 lines of the last failed quality gate run (for progress.txt notes)
LAST_GATE_OUTPUT=""

# Set to 1 by main's fast-fail retry path to omit --model (CLI default)
LAZY_DEV_FORCE_CLI_DEFAULT_MODEL=0

# Whether the last run_iteration passed an explicit --model flag (for fast-fail
# CLI-default retry in main)
LAST_ITERATION_USED_EXPLICIT_MODEL=0

# Unique session marker injected into each agent prompt; used for scoped
# orphan cleanup (pkill -f on this marker only — never on PROJECT_ROOT).
LAZY_DEV_SESSION_MARKER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$VERBOSE" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Filesystem-safe project name from repo root (basename, lowercased).
project_slug_from_root() {
    local root="$1"
    basename "$root" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

# Per-project state lives under ~/.lazy-dev/<project>/ (never in the consumer repo).
resolve_project_state_dir() {
    local slug existing_root marker

    slug=$(project_slug_from_root "$PROJECT_ROOT")
    [ -n "$slug" ] || slug="project"

    marker="$LAZY_DEV_HOME/$slug/.project-root"
    if [ -f "$marker" ]; then
        existing_root=$(tr -d '\n' < "$marker")
        if [ "$existing_root" != "$PROJECT_ROOT" ]; then
            slug="${slug}-$(printf '%s' "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-8)"
        fi
    fi

    PROJECT_SLUG="$slug"
    STATE_DIR="$LAZY_DEV_HOME/$PROJECT_SLUG"
}

# Bind feature-scoped paths after STATE_DIR and FEATURE_NAME are known.
set_feature_paths() {
    FEATURE_DIR="$STATE_DIR/features/$FEATURE_NAME"
    PRD_FILE="$FEATURE_DIR/prd.json"
    PROGRESS_FILE="$FEATURE_DIR/progress.txt"
    ARCHIVE_DIR="$FEATURE_DIR/archive"
    LAST_BRANCH_FILE="$FEATURE_DIR/.last-branch"
    SESSION_STATS_FILE="$FEATURE_DIR/.session-stats"
    DISCOVERED_DIR="$STATE_DIR/rules/discovered"
}

# Additional colors for agent output
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'

# Spinner animation frames
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_PID=""

# Start spinner animation in background
# SAFETY: Always kills any existing spinner first to prevent orphaned processes
# NOTE: Writes PID to file so parent shell can kill spinners started in subshells
start_spinner() {
    # Kill any existing spinner first (defensive - prevents orphaned spinners)
    stop_spinner
    
    local message="${1:-Processing...}"
    (
        local i=0
        while true; do
            # Use echo -ne: -n prevents newline, -e interprets color escape sequences
            # \r returns cursor to start of line for animation effect
            echo -ne "\r${CYAN}${SPINNER_FRAMES[$i]}${NC} ${DIM}${message}${NC} "
            i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    
    # Write PID to file so parent shell can kill spinners started in subshells
    if [ -n "$SPINNER_PID_FILE" ]; then
        echo "$SPINNER_PID" >> "$SPINNER_PID_FILE"
    fi
}

# Stop spinner animation
# Kills both in-shell spinner (SPINNER_PID) and any spinners from subshells (via PID file)
stop_spinner() {
    # Kill spinner tracked in current shell
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    SPINNER_PID=""
    
    # Kill any spinners tracked in PID file (from subshells)
    if [ -n "$SPINNER_PID_FILE" ] && [ -f "$SPINNER_PID_FILE" ]; then
        while IFS= read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done < "$SPINNER_PID_FILE"
        > "$SPINNER_PID_FILE"  # Clear the file
    fi
    
    printf '\r\033[K'  # Clear the spinner line
}

# ═══════════════════════════════════════════════════════════════════════════
# NDJSON PARSER: Format streaming agent output for terminal display
# ═══════════════════════════════════════════════════════════════════════════

# Safe jq wrapper that handles malformed JSON gracefully
# Usage: result=$(safe_jq '.field // ""' "$json_string")
# Returns empty string on parse errors instead of failing
safe_jq() {
    local filter="$1"
    local input="$2"
    
    # Use try-catch pattern for error handling
    # If input is not valid JSON, return empty string
    echo "$input" | jq -r "try ($filter) catch \"\"" 2>/dev/null || echo ""
}

# Strip ALL ANSI escape sequences and control characters from text (portable across macOS/Linux)
# NOTE: The macOS `script` command outputs literal "^D" followed by backspace chars (0x08) at the start
# This corrupts JSON parsing and must be removed
strip_ansi() {
    # Use perl for reliable ANSI stripping (available on macOS and Linux)
    # Also remove:
    # - Control characters 0x00-0x1F except newline (0x0A) and tab (0x09)
    # - Literal "^D" prefix from macOS script command
    if command -v perl &> /dev/null; then
        perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r//g; s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g; s/^\^D//'
    else
        # Fallback: use sed with literal escape char via $'' and tr to remove control chars
        sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/^\^D//' | tr -d '\r\x00-\x08\x0B\x0C\x0E-\x1F'
    fi
}

# Print a line with proper newline and carriage return to reset cursor position
# This ensures each line starts at column 0
print_line() {
    # First output \r\n to start on a fresh line at column 0
    # printf %b interprets color escape sequences without mangling backslashes
    printf '\r\n'
    printf '%b\n' "$1"
}

# Parse and format NDJSON events from cursor-agent stream-json output
# Uses jq for JSON parsing and formats output with colors
# NOTE: Uses separate jq calls per field for reliability (reverted from optimization)
parse_agent_output() {
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found - falling back to raw output"
        cat
        return
    fi
    
    # Track currently displayed user story to avoid repeating banners
    local current_story=""
    # Track if we're in a thinking block (for streaming output)
    local thinking_started=0
    # Track if we're in an assistant streaming block
    local assistant_streaming=0
    # Set to 1 when the final result event reports is_error=true; the function
    # returns 1 in that case so the pipeline (pipefail) sees the agent failure
    local result_failed=0
    # Dedupe shape warnings (bash 3.2-safe pipe-delimited keys)
    local seen_event_shapes="|"
    
    # Log one warning per unique NDJSON shape (unknown type or empty payload)
    warn_event_shape() {
        local shape_key="$1"
        local line="$2"
        case "$seen_event_shapes" in
            *"|${shape_key}|"*) return 0 ;;
        esac
        seen_event_shapes="${seen_event_shapes}${shape_key}|"
        local truncated_line="${line:0:200}"
        log_warn "Unrecognized NDJSON event shape (${shape_key}): ${truncated_line}"
    }
    
    # Process each line of NDJSON
    while IFS= read -r line; do
        # Strip ANSI sequences and carriage returns from input
        line=$(printf '%s' "$line" | strip_ansi)
        
        # Skip empty lines
        [ -z "$line" ] && continue
        
        # Extract event type first using safe jq wrapper
        local event_type
        event_type=$(safe_jq '.type // ""' "$line")
        
        if [ -z "$event_type" ]; then
            # Not valid JSON - skip silently
            continue
        fi
        
        case "$event_type" in
            "system")
                # System messages - init always shown, others only in verbose mode
                local subtype
                subtype=$(safe_jq '.subtype // ""' "$line")
                if [ "$subtype" = "init" ]; then
                    local model session_id
                    model=$(safe_jq '.model // ""' "$line")
                    session_id=$(safe_jq '.session_id // ""' "$line")
                    session_id="${session_id:0:8}"
                    stop_spinner
                    print_line "${CYAN}[INIT]${NC} Session ${DIM}${session_id}${NC} - Model: ${BOLD}${model}${NC}"
                    start_spinner "Agent initializing"
                elif [ "$VERBOSE" = "1" ]; then
                    # Show other system messages in verbose mode
                    stop_spinner
                    print_line "${DIM}[SYSTEM]${NC} subtype=$subtype"
                    start_spinner "Agent working"
                fi
                ;;
            "user")
                # User message (the prompt we sent) - skip silently
                :
                ;;
            "thinking")
                # Thinking events - stream text chunks; lifecycle subtypes (started/completed) have no text
                local thinking_subtype thinking_text
                thinking_subtype=$(safe_jq '.subtype // ""' "$line")
                thinking_text=$(safe_jq '.text // .delta.text // ""' "$line")

                if [ -n "$thinking_text" ]; then
                    # Show thinking header on first thinking chunk (only stop spinner once)
                    if [ "$thinking_started" != "1" ]; then
                        stop_spinner  # Only stop spinner at the START of thinking
                        thinking_started=1
                        printf '\r\n'
                        printf "${MAGENTA}💭 Thinking...${NC}\r\n"
                        printf "${DIM}"
                    fi

                    # Normalize newlines: ensure \n is preceded by \r to reset cursor to column 0
                    thinking_text="${thinking_text//$'\n'/$'\r\n'}"
                    printf '%s' "$thinking_text"
                elif [ "$thinking_subtype" = "completed" ]; then
                    if [ "$thinking_started" = "1" ]; then
                        printf "${NC}\r\n\r\n"
                        thinking_started=0
                    fi
                elif [ "$thinking_subtype" = "started" ]; then
                    :
                else
                    warn_event_shape "thinking:empty" "$line"
                fi
                ;;
            "assistant")
                # Assistant message - extract content from various possible locations
                # Streaming: content comes in chunks via delta.content or content fields
                local content
                content=$(safe_jq '.delta.content // .message.content[0].text // .content // .text // ""' "$line")
                
                # Skip if content is empty, whitespace-only, or literal boolean strings
                if [ -n "$content" ] && [ "$content" != "false" ] && [ "$content" != "true" ] && [ "$content" != "null" ]; then
                    # Strip ANSI escape sequences from content
                    content=$(printf '%s' "$content" | strip_ansi)
                    # Skip if after stripping it's empty or just whitespace
                    local trimmed="${content//[$'\t\r\n ']}"
                    if [ -n "$trimmed" ]; then
                        # Close thinking block if we were thinking
                        if [ "$thinking_started" = "1" ]; then
                            printf "${NC}\r\n\r\n"  # Reset color and add spacing
                            thinking_started=0
                        fi
                        
                        # Check for user story pattern (US-XXX) and display banner if new story
                        local story_match
                        story_match=$(echo "$content" | grep -oE '(US|[A-Z]{2,10}-[0-9]{3,})-[A-Z0-9-]+' | head -1)
                        if [ -n "$story_match" ] && [ "$story_match" != "$current_story" ]; then
                            current_story="$story_match"
                            # End any previous streaming block before banner
                            if [ "$assistant_streaming" = "1" ]; then
                                printf "${NC}\r\n"
                                assistant_streaming=0
                            fi
                            stop_spinner
                            echo ""
                            echo "══════════════════════════════════════════════════════"
                            echo "  WORKING ON: $current_story"
                            echo "══════════════════════════════════════════════════════"
                            echo ""
                        fi
                        
                        # Stream assistant output like thinking (real-time character display)
                        if [ "$assistant_streaming" != "1" ]; then
                            stop_spinner  # Only stop spinner at START of streaming
                            assistant_streaming=1
                            printf '\r\n'
                            printf "${GREEN}▶${NC} "
                        fi
                        
                        # Normalize newlines: ensure \n is preceded by \r to reset cursor to column 0
                        content="${content//$'\n'/$'\r\n'}"
                        printf '%s' "$content"
                    else
                        warn_event_shape "assistant:empty" "$line"
                    fi
                else
                    warn_event_shape "assistant:empty" "$line"
                fi
                ;;
            "tool_call")
                # Tool calls (read, write, terminal, MCP, hooks, etc.) add noise
                # without user value — skip all display (started and completed).
                continue
                ;;
            "result")
                # Close assistant streaming block if active
                if [ "$assistant_streaming" = "1" ]; then
                    printf "${NC}\r\n"
                    assistant_streaming=0
                fi
                
                # Stop spinner before showing result
                stop_spinner
                
                # Final result
                local duration_ms is_error duration_s
                duration_ms=$(safe_jq '.duration_ms // 0' "$line")
                is_error=$(safe_jq '.is_error // false' "$line")
                # Handle non-numeric duration_ms
                if ! [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
                    duration_ms=0
                fi
                duration_s=$((duration_ms / 1000))
                
                local cost_raw cost_val iter_num stats_file
                cost_raw=$(safe_jq '.total_cost_usd // .cost_usd // .cost // empty' "$line")
                cost_val="unknown"
                if [ -n "$cost_raw" ] && [ "$cost_raw" != "null" ]; then
                    cost_val="$cost_raw"
                fi
                iter_num="${LAZY_DEV_CURRENT_ITERATION:-0}"
                stats_file="${LAZY_DEV_SESSION_STATS_FILE:-}"
                if [ -n "$stats_file" ]; then
                    printf 'iteration=%s duration_s=%s cost=%s\n' \
                        "$iter_num" "$duration_s" "$cost_val" >> "$stats_file"
                fi

                if [ "$is_error" = "true" ]; then
                    result_failed=1
                    print_line "${RED}[RESULT]${NC} ${RED}Failed${NC} in ${duration_s}s"
                else
                    print_line "${GREEN}[RESULT]${NC} ${GREEN}Success${NC} in ${duration_s}s"
                fi
                ;;
            *)
                # Unknown event type — warn once per shape (verbose still shows raw debug)
                warn_event_shape "unknown:${event_type}" "$line"
                if [ "$VERBOSE" = "1" ]; then
                    stop_spinner
                    # Show the raw event type and first 200 chars of the line
                    local truncated_line="${line:0:200}"
                    print_line "${DIM}[DEBUG]${NC} type='$event_type' raw: $truncated_line"
                    start_spinner "Agent working"
                fi
                ;;
        esac
    done
    
    # Close thinking block if still active (fixes dim-shell-prompt leak)
    if [ "$thinking_started" = "1" ]; then
        printf "${NC}\r\n"
        thinking_started=0
    fi
    
    # Close assistant streaming block if still active
    if [ "$assistant_streaming" = "1" ]; then
        printf "${NC}\r\n"
    fi
    
    # Stop spinner at the end
    stop_spinner
    
    # Final newline to ensure clean ending
    printf '\r\n'
    
    # Propagate agent failure to the caller: is_error=true in the final result
    # event means the agent reported failure (return 1 so pipefail +
    # run_iteration can act on it)
    if [ "$result_failed" = "1" ]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP: Proper resource management to prevent zombie processes
# ═══════════════════════════════════════════════════════════════════════════

# Recursively kill a process and ALL its descendants (children, grandchildren, etc.)
# Usage: kill_tree PID [SIGNAL]
# This ensures no orphaned grandchildren survive
kill_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    
    # Validate PID
    if [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    
    # Don't kill ourselves
    if [ "$pid" = "$$" ]; then
        return 0
    fi
    
    # Check if process exists
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    
    # Get all child PIDs recursively
    local children
    children=$(pgrep -P "$pid" 2>/dev/null)
    
    # Kill children first (depth-first)
    for child in $children; do
        kill_tree "$child" "$signal"
    done
    
    # Now kill the parent
    kill -"$signal" "$pid" 2>/dev/null || true
}

# Kill all descendants of a PID with both TERM and KILL.
# Uses tree traversal only — never negative-PID group kills, which can SIGKILL
# lazy.sh on macOS when job control is disabled.
# Usage: kill_descendants PID
kill_descendants() {
    local pid="$1"

    if [ -z "$pid" ]; then
        return 0
    fi

    kill_tree "$pid" "TERM"
    sleep 0.3
    kill_tree "$pid" "9"
}

# Safely terminate the agent pipeline subshell and its children.
# Usage: kill_pipeline_safely <pid> [reason]
kill_pipeline_safely() {
    local pid="$1"
    local reason="${2:-unknown}"

    if [ -z "$pid" ]; then
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log_debug "Safely killing pipeline PID $pid (reason: $reason)"
    kill_descendants "$pid"

    local i=0
    while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.5
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        kill_descendants "$pid"
    fi

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Pipeline PID $pid still alive after safe kill (reason: $reason)"
        return 1
    fi

    return 0
}

# Last-resort sweep: kill only processes whose argv contains our session marker.
# Safe because user processes cannot contain our run-unique marker string.
kill_session_orphans() {
    if [ -n "${LAZY_DEV_SESSION_MARKER:-}" ]; then
        log_debug "Killing session-specific orphaned processes (marker: $LAZY_DEV_SESSION_MARKER)..."
        pkill -9 -f "$LAZY_DEV_SESSION_MARKER" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code=$?
    log_debug "Cleanup triggered (exit code: $exit_code)"
    
    # Stop spinner if running
    stop_spinner
    
    # Stop caffeinate (allow system to sleep again)
    # Use robust termination: SIGTERM → wait → SIGKILL fallback → wait
    if [ -n "$CAFFEINATE_PID" ]; then
        if kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
            log_debug "Stopping caffeinate (PID: $CAFFEINATE_PID)..."
            kill "$CAFFEINATE_PID" 2>/dev/null || true
            # Wait briefly for graceful termination
            sleep 0.3
            # Force kill if still running
            if kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
                log_debug "Force killing caffeinate..."
                kill -9 "$CAFFEINATE_PID" 2>/dev/null || true
            fi
            # Wait for process to fully terminate before continuing
            wait "$CAFFEINATE_PID" 2>/dev/null || true
        fi
    fi
    CAFFEINATE_PID=""
    
    # Kill any cursor-agent child processes we spawned (with all descendants)
    if [ -n "$AGENT_PID" ]; then
        log_debug "Killing cursor-agent process tree (PID: $AGENT_PID)..."
        kill_descendants "$AGENT_PID"
    fi
    AGENT_PID=""
    
    # Kill the pipeline subshell and ALL its descendants (children, grandchildren, etc.)
    if [ -n "$PIPELINE_PID" ]; then
        log_debug "Killing pipeline process tree (PID: $PIPELINE_PID)..."
        kill_descendants "$PIPELINE_PID"
    fi
    PIPELINE_PID=""
    
    # Kill ALL descendants of this script (recursive - catches grandchildren)
    log_debug "Killing all descendant processes..."
    for child in $(pgrep -P $$ 2>/dev/null); do
        kill_descendants "$child"
    done
    
    # Final sweep: kill any remaining direct children
    pkill -9 -P $$ 2>/dev/null || true
    
    # Last-resort: kill only processes carrying our session marker (not PROJECT_ROOT)
    kill_session_orphans
    
    # Clean temp files
    if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE" 2>/dev/null
    fi
    OUTPUT_FILE=""
    
    if [ -n "$SPINNER_PID_FILE" ] && [ -f "$SPINNER_PID_FILE" ]; then
        rm -f "$SPINNER_PID_FILE" 2>/dev/null
    fi
    SPINNER_PID_FILE=""

    # Remove push blocker hook and session lock file
    remove_push_blocker
    
    log_debug "Cleanup completed"
    exit $exit_code
}

# ═══════════════════════════════════════════════════════════════════════════
# INTER-ITERATION CLEANUP: Clean up processes between iterations
# ═══════════════════════════════════════════════════════════════════════════

cleanup_iteration() {
    log_debug "Running inter-iteration cleanup..."
    
    # Stop any running spinner
    stop_spinner
    
    # Kill the pipeline subshell and ALL its descendants (recursive)
    if [ -n "$PIPELINE_PID" ]; then
        log_debug "Killing pipeline process tree (PID: $PIPELINE_PID)..."
        kill_pipeline_safely "$PIPELINE_PID" "cleanup_iteration"
    fi
    PIPELINE_PID=""
    
    # Kill all child process trees EXCEPT caffeinate
    for child_pid in $(pgrep -P $$ 2>/dev/null); do
        if [ -n "$CAFFEINATE_PID" ] && [ "$child_pid" = "$CAFFEINATE_PID" ]; then
            continue  # Don't kill caffeinate
        fi
        kill_descendants "$child_pid"
    done
    
    # Final sweep for any remaining direct children (except caffeinate)
    for child_pid in $(pgrep -P $$ 2>/dev/null); do
        if [ -n "$CAFFEINATE_PID" ] && [ "$child_pid" = "$CAFFEINATE_PID" ]; then
            continue
        fi
        kill -9 "$child_pid" 2>/dev/null || true
    done
    
    # Last-resort: kill only processes carrying our session marker (not PROJECT_ROOT)
    kill_session_orphans
    
    # Verify caffeinate is still running (warn if it died)
    if [ -n "$CAFFEINATE_PID" ]; then
        if kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
            log_debug "caffeinate still running (PID: $CAFFEINATE_PID)"
        else
            log_warn "caffeinate died unexpectedly - restarting..."
            caffeinate -di &
            CAFFEINATE_PID=$!
            log_info "Restarted caffeinate (PID: $CAFFEINATE_PID)"
        fi
    fi
    
    log_debug "Inter-iteration cleanup complete"
}

# Log memory usage (useful for debugging memory issues)
log_memory_usage() {
    if command -v vm_stat &> /dev/null; then
        # macOS memory stats
        local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
        local free_mb=$((free_pages * 4096 / 1024 / 1024))
        local inactive_mb=$((inactive_pages * 4096 / 1024 / 1024))
        local available_mb=$((free_mb + inactive_mb))
        log_info "Memory: ~${free_mb}MB free, ~${inactive_mb}MB inactive (~${available_mb}MB available)"
    elif [ -f /proc/meminfo ]; then
        # Linux memory stats
        local available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        local available_mb=$((available_kb / 1024))
        log_info "Available memory: ~${available_mb}MB"
    fi
}

# Count child processes of this script (for monitoring process accumulation)
log_process_count() {
    local child_count
    child_count=$(pgrep -P $$ 2>/dev/null | wc -l | tr -d ' ')
    log_debug "Active child processes: $child_count"
    
    # Warn if we have too many child processes (potential leak)
    if [ "$child_count" -gt 10 ]; then
        log_warn "High child process count ($child_count) - potential process leak"
    fi
}

# Canonical jq filter fragment: story is incomplete when passes is not strictly true
# (missing, null, false, string "true", etc.)
PRD_INCOMPLETE_STORY='select(.passes != true)'
# Selectable = incomplete and not runner-parked (blocked)
PRD_SELECTABLE_STORY='select(.passes != true and ((.blocked // false) | not))'

# Get story counts from PRD: returns "completed/total" format
# Usage: counts=$(get_story_counts "$PRD_FILE")
get_story_counts() {
    local prd_file="$1"
    
    if [ ! -f "$prd_file" ]; then
        echo "0/0"
        return
    fi
    
    local total completed
    total=$(jq '[.userStories[]?] | length' "$prd_file" 2>/dev/null || echo "0")
    completed=$(jq '[.userStories[]? | select(.passes == true)] | length' "$prd_file" 2>/dev/null || echo "0")
    
    echo "${completed}/${total}"
}

# Verify all stories in PRD have passes: true
verify_all_stories_complete() {
    local prd_file="$1"
    
    if [ ! -f "$prd_file" ]; then
        return 1
    fi
    
    local total incomplete_count
    total=$(jq '(.userStories | if type == "array" then length else 0 end)' "$prd_file" 2>/dev/null || echo "-1")
    incomplete_count=$(jq "[.userStories[]? | $PRD_INCOMPLETE_STORY] | length" "$prd_file" 2>/dev/null || echo "-1")
    
    if [ "$total" = "-1" ] || [ "$incomplete_count" = "-1" ]; then
        return 1
    fi
    
    if [ "$total" -eq 0 ]; then
        return 1  # Empty PRD is never complete
    fi
    
    if [ "$incomplete_count" -gt 0 ]; then
        return 1  # Not complete - continue iterations
    fi
    
    return 0  # All stories complete
}

# Get the next story ID (highest priority incomplete story)
# Usage: next_story=$(get_next_story_id "$PRD_FILE")
get_next_story_id() {
    local prd_file="$1"
    
    if [ ! -f "$prd_file" ]; then
        echo ""
        return
    fi
    
    jq -r "[.userStories[]? | $PRD_SELECTABLE_STORY] | sort_by(.priority) | .[0].id // \"\"" "$prd_file" 2>/dev/null || true
}

# True when PRD is incomplete but no selectable (non-blocked) story remains
is_feature_stuck() {
    local prd_file="$1"

    if verify_all_stories_complete "$prd_file"; then
        return 1
    fi

    local next_id
    next_id=$(get_next_story_id "$prd_file")
    [ -z "$next_id" ]
}

# Print STUCK report and exit 3 (all remaining stories are blocked)
report_stuck_and_exit() {
    local prd_file="$1"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  STUCK: Feature cannot progress — all remaining stories blocked"
    echo "  Feature: $FEATURE_NAME"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Blocked stories:"
    jq -r --arg progress "$PROGRESS_FILE" --arg prd "$prd_file" \
        '.userStories[]? | select(.passes != true and (.blocked // false) == true) |
        "  - \(.id): \(.title)\n    Notes: \(.notes // "(none)")\n    See: \($progress) and \($prd)"' \
        "$prd_file" 2>/dev/null || true
    echo ""
    echo "Remediation: review notes above, fix blockers, set blocked=false in prd.json, re-run."
    exit 3
}

# Record a failed iteration attempt for a story (runner-owned, not agent).
# Increments attempts; sets blocked=true when attempts reach 3.
# Usage: record_story_attempt <story-id> <prd-file>
record_story_attempt() {
    local story_id="$1"
    local prd_file="$2"

    local blocked_before blocked_after attempts notes tmp
    blocked_before=$(jq -r --arg id "$story_id" \
        '[.userStories[]? | select(.id == $id) | .blocked // false] | first // false' \
        "$prd_file" 2>/dev/null || echo "false")

    if [ "$blocked_before" = "true" ]; then
        return 0
    fi

    tmp=$(mktemp)
    if ! jq --arg id "$story_id" '
        .userStories |= map(
            if .id == $id then
                .attempts = ((.attempts // 0) + 1)
                | if .attempts >= 3 then . + {blocked: true} else . end
            else .
            end
        )
    ' "$prd_file" > "$tmp"; then
        log_error "Failed to record attempt for story $story_id (PRD jq mutation failed)"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$prd_file"

    attempts=$(jq -r --arg id "$story_id" \
        '[.userStories[]? | select(.id == $id) | .attempts // 0] | first // 0' \
        "$prd_file" 2>/dev/null || echo "0")
    blocked_after=$(jq -r --arg id "$story_id" \
        '[.userStories[]? | select(.id == $id) | .blocked // false] | first // false' \
        "$prd_file" 2>/dev/null || echo "false")

    log_warn "Story $story_id still incomplete after iteration (attempt $attempts/3)"

    if [ "$blocked_after" = "true" ] && [ "$blocked_before" != "true" ]; then
        notes=$(jq -r --arg id "$story_id" \
            '[.userStories[]? | select(.id == $id) | .notes // ""] | first // ""' \
            "$prd_file" 2>/dev/null || echo "")

        {
            echo ""
            echo "## ⛔ STORY PARKED: $story_id"
            echo "Blocked after 3 failed iterations. Notes: $notes"
            echo "The runner will skip this story and select the next incomplete story."
            echo ""
        } >> "$PROGRESS_FILE"

        log_error "═══════════════════════════════════════════════════════════════"
        log_error "  STORY PARKED (blocked): $story_id"
        log_error "  Notes: $notes"
        log_error "  Progress: $PROGRESS_FILE"
        log_error "═══════════════════════════════════════════════════════════════"
    fi

    return 0
}

# Run a command with a timeout. Returns the command's exit code, or 124 on timeout.
# Usage: run_with_timeout <seconds> <output_file> -- <command...>
run_with_timeout() {
    local timeout_secs="$1"
    local output_file="$2"
    shift 2
    if [ "${1:-}" = "--" ]; then
        shift
    fi

    (
        "$@"
    ) > "$output_file" 2>&1 &
    local pid=$!
    local start
    start=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(($(date +%s) - start))
        if [ "$elapsed" -ge "$timeout_secs" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            echo "Quality gate timed out after ${timeout_secs}s" >> "$output_file"
            return 124
        fi
        sleep 0.5
    done

    wait "$pid"
    return $?
}

# Detect project toolchain for the runner quality gate.
# Echoes: npm|pnpm|yarn|cargo|go|skip-java|empty (unknown)
detect_quality_gate_toolchain() {
    local root="$PROJECT_ROOT"

    if [ -f "$root/pnpm-lock.yaml" ]; then
        echo "pnpm"
        return 0
    fi
    if [ -f "$root/yarn.lock" ]; then
        echo "yarn"
        return 0
    fi
    if [ -f "$root/package-lock.json" ]; then
        echo "npm"
        return 0
    fi
    if [ -f "$root/package.json" ]; then
        echo "npm"
        return 0
    fi
    if [ -f "$root/Cargo.toml" ]; then
        echo "cargo"
        return 0
    fi
    if [ -f "$root/go.mod" ]; then
        echo "go"
        return 0
    fi
    if [ -f "$root/pom.xml" ]; then
        echo "skip-java"
        return 0
    fi
    if compgen -G "$root/build.gradle*" > /dev/null 2>&1; then
        echo "skip-java"
        return 0
    fi

    echo ""
    return 0
}

# Return 0 if package.json defines a non-empty script name.
js_script_exists() {
    local script_name="$1"
    jq -e --arg s "$script_name" '.scripts[$s] // "" | length > 0' \
        "$PROJECT_ROOT/package.json" >/dev/null 2>&1
}

# Run build then test for a JS package manager toolchain.
run_js_quality_gate() {
    local mgr="$1"
    local timeout_secs="$2"
    local output_file="$3"
    local script_name step_out run_rc

    for script_name in build test; do
        if ! js_script_exists "$script_name"; then
            log_info "Quality gate: $script_name skipped (no script in package.json)"
            continue
        fi

        step_out=$(mktemp)
        log_info "Quality gate: running $mgr run $script_name (timeout ${timeout_secs}s)..."

        run_rc=0
        case "$mgr" in
            npm)
                run_with_timeout "$timeout_secs" "$step_out" -- bash -c \
                    'cd "$1" && npm run "$2"' _ "$PROJECT_ROOT" "$script_name" || run_rc=$?
                ;;
            pnpm)
                run_with_timeout "$timeout_secs" "$step_out" -- bash -c \
                    'cd "$1" && pnpm run "$2"' _ "$PROJECT_ROOT" "$script_name" || run_rc=$?
                ;;
            yarn)
                run_with_timeout "$timeout_secs" "$step_out" -- bash -c \
                    'cd "$1" && yarn run "$2"' _ "$PROJECT_ROOT" "$script_name" || run_rc=$?
                ;;
            *)
                log_warn "Quality gate: unknown JS toolchain '$mgr'"
                rm -f "$step_out"
                return 1
                ;;
        esac

        cat "$step_out" >> "$output_file"
        rm -f "$step_out"

        if [ "$run_rc" -ne 0 ]; then
            log_error "Quality gate failed: $mgr run $script_name (exit $run_rc)"
            return "$run_rc"
        fi
        log_info "Quality gate: $script_name passed"
    done

    return 0
}

# Run cargo build + cargo test.
run_cargo_quality_gate() {
    local timeout_secs="$1"
    local output_file="$2"
    local step_out run_rc

    for step_out_cmd in "cargo build" "cargo test"; do
        step_out=$(mktemp)
        log_info "Quality gate: running $step_out_cmd (timeout ${timeout_secs}s)..."
        run_rc=0
        run_with_timeout "$timeout_secs" "$step_out" -- bash -c \
            'cd "$1" && '"$step_out_cmd" _ "$PROJECT_ROOT" || run_rc=$?
        cat "$step_out" >> "$output_file"
        rm -f "$step_out"
        if [ "$run_rc" -ne 0 ]; then
            log_error "Quality gate failed: $step_out_cmd (exit $run_rc)"
            return "$run_rc"
        fi
        log_info "Quality gate: $step_out_cmd passed"
    done
    return 0
}

# Run go build + go test.
run_go_quality_gate() {
    local timeout_secs="$1"
    local output_file="$2"
    local step_out run_rc

    for step_out_cmd in "go build ./..." "go test ./..."; do
        step_out=$(mktemp)
        log_info "Quality gate: running $step_out_cmd (timeout ${timeout_secs}s)..."
        run_rc=0
        run_with_timeout "$timeout_secs" "$step_out" -- bash -c \
            'cd "$1" && '"$step_out_cmd" _ "$PROJECT_ROOT" || run_rc=$?
        cat "$step_out" >> "$output_file"
        rm -f "$step_out"
        if [ "$run_rc" -ne 0 ]; then
            log_error "Quality gate failed: $step_out_cmd (exit $run_rc)"
            return "$run_rc"
        fi
        log_info "Quality gate: $step_out_cmd passed"
    done
    return 0
}

# Runner-enforced build/test gate after a story flip. Returns 0 on pass or skip.
run_quality_gate() {
    local gate_timeout="${LAZY_DEV_GATE_TIMEOUT:-600}"
    local output_file toolchain failed=0

    output_file=$(mktemp)
    LAST_GATE_OUTPUT=""
    toolchain=$(detect_quality_gate_toolchain)

    if [ -z "$toolchain" ]; then
        log_info "Quality gate skipped (no recognized toolchain)"
        rm -f "$output_file"
        return 0
    fi

    if [ "$toolchain" = "skip-java" ]; then
        log_info "Quality gate skipped (Java/Gradle project — no built-in gate)"
        rm -f "$output_file"
        return 0
    fi

    case "$toolchain" in
        npm|pnpm|yarn)
            run_js_quality_gate "$toolchain" "$gate_timeout" "$output_file" || failed=1
            ;;
        cargo)
            run_cargo_quality_gate "$gate_timeout" "$output_file" || failed=1
            ;;
        go)
            run_go_quality_gate "$gate_timeout" "$output_file" || failed=1
            ;;
        *)
            log_info "Quality gate skipped (unsupported toolchain: $toolchain)"
            rm -f "$output_file"
            return 0
            ;;
    esac

    if [ "$failed" -eq 0 ]; then
        log_success "Quality gate passed ($toolchain)"
        if [ "$VERBOSE" = "1" ] && [ -s "$output_file" ]; then
            log_debug "Quality gate output (last 5 lines):"
            tail -n 5 "$output_file" | while IFS= read -r line; do
                log_debug "  $line"
            done
        fi
        rm -f "$output_file"
        return 0
    fi

    LAST_GATE_OUTPUT=$(head -n 20 "$output_file")
    rm -f "$output_file"
    return 1
}

# Revert a story flip (runner-owned; used when the quality gate fails).
# Usage: revert_story_passes <story-id> <prd-file>
revert_story_passes() {
    local story_id="$1"
    local prd_file="$2"
    local tmp

    tmp=$(mktemp)
    if ! jq --arg id "$story_id" '
        .userStories |= map(
            if .id == $id then .passes = false
            else . end
        )
    ' "$prd_file" > "$tmp"; then
        log_error "Failed to revert passes for story $story_id (PRD jq mutation failed)"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$prd_file"
    return 0
}

# If the assigned story flipped to passes:true this iteration, run the quality gate.
# On failure: revert flip, record attempt, append progress note. Returns 1 if gate failed.
# Usage: handle_quality_gate_for_flip <story-id> <passes-before>
handle_quality_gate_for_flip() {
    local story_id="$1"
    local passes_before="$2"
    local passes_now excerpt

    if [ -z "$story_id" ] || [ "$passes_before" = "true" ]; then
        return 0
    fi

    passes_now=$(jq -r --arg id "$story_id" \
        '[.userStories[]? | select(.id == $id) | .passes] | first // false' \
        "$PRD_FILE" 2>/dev/null || echo "false")

    if [ "$passes_now" != "true" ]; then
        return 0
    fi

    log_info "Story $story_id marked complete — running runner quality gate..."

    if run_quality_gate; then
        return 0
    fi

    revert_story_passes "$story_id" "$PRD_FILE"
    record_story_attempt "$story_id" "$PRD_FILE"

    excerpt="${LAST_GATE_OUTPUT:-(no output captured)}"
    {
        echo ""
        echo "## 🚫 Runner quality gate FAILED for $story_id: $excerpt"
        echo "Next agent: fix the gate failures before re-marking this story."
        echo ""
    } >> "$PROGRESS_FILE"

    log_error "═══════════════════════════════════════════════════════════════"
    log_error "  QUALITY GATE FAILED for story: $story_id"
    log_error "  Flip reverted (passes: false); attempt recorded"
    log_error "  See progress.txt for output excerpt"
    log_error "═══════════════════════════════════════════════════════════════"

    return 1
}

# Commit all working-tree changes after an iteration (runner-owned).
# Usage: commit_iteration_changes [story-id]
commit_iteration_changes() {
    local story_id="${1:-${LAST_ASSIGNED_STORY_ID:-unknown}}"
    local commit_msg

    if ! working_tree_is_dirty; then
        log_error "No changes to commit for story $story_id"
        return 1
    fi

    commit_msg=$(build_iteration_commit_message "$story_id")
    log_info "Committing all changes: $commit_msg"

    if ! git -C "$PROJECT_ROOT" add -A; then
        log_error "Failed to stage changes"
        return 1
    fi
    if ! git -C "$PROJECT_ROOT" commit -m "$commit_msg"; then
        log_error "Failed to commit changes"
        return 1
    fi
    log_success "Committed story $story_id"
    return 0
}

# Revert a passes flip and exit when the iteration commit fails.
fatal_iteration_commit_failure() {
    local story_id="$1"
    local passes_before="$2"
    local passes_now

    if [ -n "$story_id" ] && [ "$passes_before" != "true" ]; then
        passes_now=$(jq -r --arg id "$story_id" \
            '[.userStories[]? | select(.id == $id) | .passes] | first // false' \
            "$PRD_FILE" 2>/dev/null || echo "false")
        if [ "$passes_now" = "true" ]; then
            revert_story_passes "$story_id" "$PRD_FILE"
            log_warn "Reverted passes:true for $story_id after commit failure"
        fi
    fi
    log_error "Iteration commit failed — stopping session (working tree may be dirty)"
    exit 1
}

# Load cumulative totals from SESSION_STATS_FILE (one line per iteration:
# iteration=N duration_s=N cost=N|unknown).
load_session_stats_totals() {
    SESSION_STATS_TOTAL_SECONDS=0
    SESSION_STATS_TOTAL_COST="0"
    SESSION_STATS_KNOWN_COSTS=0
    SESSION_STATS_LINE_COUNT=0

    if [ ! -f "$SESSION_STATS_FILE" ]; then
        return 0
    fi

    local line cost_part
    while IFS= read -r line; do
        [[ "$line" =~ ^iteration= ]] || continue
        SESSION_STATS_LINE_COUNT=$((SESSION_STATS_LINE_COUNT + 1))
        if [[ "$line" =~ duration_s=([0-9]+) ]]; then
            SESSION_STATS_TOTAL_SECONDS=$((SESSION_STATS_TOTAL_SECONDS + BASH_REMATCH[1]))
        fi
        if [[ "$line" =~ cost=([^[:space:]]+) ]]; then
            cost_part="${BASH_REMATCH[1]}"
            if [ "$cost_part" != "unknown" ]; then
                SESSION_STATS_TOTAL_COST=$(awk "BEGIN {printf \"%.6f\", $SESSION_STATS_TOTAL_COST + $cost_part}")
                SESSION_STATS_KNOWN_COSTS=$((SESSION_STATS_KNOWN_COSTS + 1))
            fi
        fi
    done < "$SESSION_STATS_FILE"
}

# Return 0 when a configured budget limit is exceeded (and stats exist).
is_session_budget_exceeded() {
    load_session_stats_totals

    if [ "${SESSION_STATS_LINE_COUNT:-0}" -eq 0 ]; then
        return 1
    fi

    if [ -n "${LAZY_DEV_MAX_MINUTES:-}" ]; then
        local max_seconds=$((LAZY_DEV_MAX_MINUTES * 60))
        if [ "${SESSION_STATS_TOTAL_SECONDS:-0}" -gt "$max_seconds" ]; then
            SESSION_BUDGET_EXCEEDED_REASON="time"
            return 0
        fi
    fi

    if [ -n "${LAZY_DEV_MAX_COST:-}" ]; then
        if [ "${SESSION_STATS_KNOWN_COSTS:-0}" -gt 0 ]; then
            if awk "BEGIN {exit ($SESSION_STATS_TOTAL_COST > $LAZY_DEV_MAX_COST) ? 0 : 1}"; then
                SESSION_BUDGET_EXCEEDED_REASON="cost"
                return 0
            fi
        fi
    fi

    return 1
}

# Loud stop when session budget is exceeded; saves state and exits 2.
report_budget_exceeded_and_exit() {
    load_session_stats_totals
    local total_min=$((SESSION_STATS_TOTAL_SECONDS / 60))
    local total_sec=$((SESSION_STATS_TOTAL_SECONDS % 60))

    echo ""
    log_error "═══════════════════════════════════════════════════════════════"
    log_error "  BUDGET EXCEEDED — stopping session (exit 2)"
    if [ "${SESSION_BUDGET_EXCEEDED_REASON:-}" = "time" ]; then
        log_error "  Time limit: ${LAZY_DEV_MAX_MINUTES}m exceeded"
        log_error "  Cumulative duration: ${total_min}m ${total_sec}s (${SESSION_STATS_TOTAL_SECONDS}s)"
    elif [ "${SESSION_BUDGET_EXCEEDED_REASON:-}" = "cost" ]; then
        log_error "  Cost limit: \$${LAZY_DEV_MAX_COST} exceeded"
        log_error "  Cumulative cost: \$${SESSION_STATS_TOTAL_COST} (${SESSION_STATS_KNOWN_COSTS} iteration(s) with known cost)"
    fi
    log_error "  Session stats: $SESSION_STATS_FILE"
    log_error "═══════════════════════════════════════════════════════════════"
    echo ""

    if working_tree_is_dirty; then
        commit_iteration_changes "${LAST_ASSIGNED_STORY_ID:-unknown}" \
            || log_warn "Could not commit pending changes before budget exit"
    fi
    exit 2
}

# Filter lazy-dev ephemeral paths from git status --porcelain lines (diagnostics only).
filter_infra_porcelain() {
    local line path

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line:3}"
        case "$path" in
            */.session-stats|*/.last-branch|*/archive/*)
                continue
                ;;
        esac
        printf '%s\n' "$line"
    done
}

# Return git status --porcelain output, capped at N lines (default 30).
# Ephemeral runtime paths are excluded.
get_git_porcelain_capped() {
    local max_lines="${1:-30}"
    git status --porcelain 2>/dev/null | filter_infra_porcelain | head -n "$max_lines"
}

# True when OUTPUT_FILE contains a terminal result NDJSON event.
output_file_has_result_event() {
    local output_file="$1"
    [ -f "$output_file" ] || return 1
    grep -qE '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null
}

# Append a killed-iteration marker to progress.txt (timeout or interrupt).
# Usage: append_killed_iteration_marker <iteration> <timeout|interrupt> <duration_s>
append_killed_iteration_marker() {
    local iter="$1"
    local reason="$2"
    local duration_s="$3"
    local porcelain

    if [ -z "${PROGRESS_FILE:-}" ] || [ ! -f "$PROGRESS_FILE" ]; then
        log_warn "Cannot append killed-iteration marker: progress file missing"
        return 0
    fi

    porcelain=$(get_git_porcelain_capped 30)

    {
        echo ""
        echo "## ⚠️ Iteration $iter was killed ($reason) after ${duration_s}s. Uncommitted changes at kill time:"
        if [ -n "$porcelain" ]; then
            echo "$porcelain"
        else
            echo "(clean working tree)"
        fi
        echo "Next agent: reconcile before planning."
        echo ""
    } >> "$PROGRESS_FILE"

    log_warn "Appended killed-iteration marker to progress.txt ($reason, iteration $iter)"
}

# Build a CONTEXT warning block when the working tree has pre-existing changes.
# Kept for diagnostics only (append_killed_iteration_marker); iterations start clean.
build_dirty_tree_warning() {
    local assigned_story="$1"
    local porcelain

    porcelain=$(get_git_porcelain_capped 30)
    if [ -z "$porcelain" ]; then
        return 0
    fi

    cat <<EOF

## Working Tree Warning

The working tree has uncommitted changes that predate this iteration:
\`\`\`
$porcelain
\`\`\`
Review them first — they may be a partially completed ${assigned_story}. Do not blindly commit or discard them.
EOF
}

# Validate PRD structure at bootstrap (called from verify_setup).
# Checks: valid JSON, non-empty userStories array, each story has id/priority/passes.
# Usage: validate_prd "$PRD_FILE"  (returns 0 on success, 1 on failure)
validate_prd() {
    local prd_file="$1"

    if [ ! -f "$prd_file" ]; then
        log_error "PRD validation failed: file not found: $prd_file"
        log_info "Copy from examples: cp $SCRIPT_DIR/examples/prd.json $prd_file"
        return 1
    fi

    if ! jq empty "$prd_file" 2>/dev/null; then
        log_error "PRD validation failed: $prd_file does not contain valid JSON"
        log_info "Remediation: restore from the last commit: git checkout -- $prd_file"
        log_info "Or copy from examples: cp $SCRIPT_DIR/examples/prd.json $prd_file"
        return 1
    fi

    local story_count
    story_count=$(jq 'if (.userStories | type) == "array" then (.userStories | length) else -1 end' "$prd_file" 2>/dev/null || echo "-1")

    if [ "$story_count" = "-1" ]; then
        log_error "PRD validation failed: .userStories must be a non-empty array"
        log_info "Remediation: fix $prd_file or restore: git checkout -- $prd_file"
        return 1
    fi

    if [ "$story_count" -eq 0 ]; then
        log_error "PRD validation failed: .userStories is empty (at least one story required)"
        log_info "Remediation: add stories to $prd_file or copy from examples"
        return 1
    fi

    local field_errors
    field_errors=$(jq -r '
        .userStories | to_entries[] |
        if (.value.id | type) != "string" or (.value.id | length) == 0 then
            "Story at index \(.key): missing or empty .id"
        elif (.value.priority | type) != "number" then
            "Story \(.value.id): .priority must be a number (got \(.value.priority | type))"
        elif (.value.passes | type) != "boolean" then
            "Story \(.value.id): .passes must be a boolean (got \(.value.passes | type))"
        else
            empty
        end
    ' "$prd_file" 2>/dev/null || echo "PRD validation failed: could not inspect story fields")

    if [ -n "$field_errors" ]; then
        while IFS= read -r err_line; do
            [ -n "$err_line" ] && log_error "PRD validation failed: $err_line"
        done <<< "$field_errors"
        log_info "Remediation: fix the fields above in $prd_file, or restore: git checkout -- $prd_file"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MODEL CONFIGURATION (persisted in ~/.lazy-dev/config.env)
# ═══════════════════════════════════════════════════════════════════════════

models_are_configured() {
    [ "${LAZY_DEV_MODELS_CONFIGURED:-0}" = "1" ]
}

# Populate global MODEL_IDS and MODEL_LABELS from cursor-agent --list-models
list_available_models() {
    local line id label list_cmd=()

    if [ "${USE_STANDALONE_CURSOR_AGENT:-0}" = "1" ]; then
        list_cmd=(cursor-agent)
    else
        list_cmd=(cursor agent)
    fi

    MODEL_IDS=()
    MODEL_LABELS=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [ "$line" = "Available models" ] && continue
        id="${line%% - *}"
        [ "$id" = "$line" ] && continue
        [ "$id" = "auto" ] && continue
        label="${line#* - }"
        MODEL_IDS+=("$id")
        MODEL_LABELS+=("$label")
    done < <("${list_cmd[@]}" --list-models 2>/dev/null)

    [ "${#MODEL_IDS[@]}" -gt 0 ]
}

prompt_model_choice() {
    local category="$1"
    local choice="" idx i

    if ! list_available_models; then
        log_error "Could not list available models from Cursor CLI."
        return 1
    fi

    while true; do
        echo "" >&2
        echo "Select ${category} model:" >&2
        for i in "${!MODEL_IDS[@]}"; do
            printf '  %d) %s - %s\n' "$((i + 1))" "${MODEL_IDS[$i]}" "${MODEL_LABELS[$i]}" >&2
        done
        echo "" >&2
        if [ -t 0 ]; then
            read -r -p "> " choice || true
        else
            read -r -p "> " choice </dev/tty || true
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MODEL_IDS[@]}" ]; then
            echo "${MODEL_IDS[$((choice - 1))]}"
            return 0
        fi

        log_warn "Invalid selection. Enter a number between 1 and ${#MODEL_IDS[@]}." >&2
    done
}

save_models_to_config() {
    local impl="$1" review="$2" review2="$3"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
LAZY_DEV_MODELS_CONFIGURED=1
LAZY_DEV_MODEL_IMPL="$impl"
LAZY_DEV_MODEL_REVIEW="$review"
LAZY_DEV_MODEL_REVIEW2="$review2"
EOF

    LAZY_DEV_MODELS_CONFIGURED=1
    LAZY_DEV_MODEL_IMPL="$impl"
    LAZY_DEV_MODEL_REVIEW="$review"
    LAZY_DEV_MODEL_REVIEW2="$review2"

    log_success "Model configuration saved to $CONFIG_FILE"
}

# Initialize per-project state under ~/.lazy-dev/<project>/ (no git changes in consumer repo).
bootstrap_lazy_dev_project() {
    if [ ! -f "$SCRIPT_DIR/lazy.sh" ]; then
        log_error "lazy-dev not installed at $LAZY_DEV_HOME"
        log_info "Run install.sh from the lazy-dev repository: ./install.sh"
        return 1
    fi

    resolve_project_state_dir
    mkdir -p "$STATE_DIR/features" "$STATE_DIR/rules/discovered"
    printf '%s\n' "$PROJECT_ROOT" > "$STATE_DIR/.project-root"
    log_debug "Project state directory: $STATE_DIR"
    return 0
}

# Interactive first-time model selection; saves ~/.lazy-dev/config.env before the agent loop starts.
ensure_models_configured() {
    local impl review review2

    if models_are_configured; then
        return 0
    fi

    if [ ! -t 0 ] && [ ! -c /dev/tty ]; then
        log_warn "Models not configured and no TTY available — using defaults (set LAZY_DEV_MODEL_* env vars)"
        return 0
    fi

    echo ""
    log_info "First-time setup: select models for each story category."
    log_info "Press Ctrl+C to cancel."

    impl=$(prompt_model_choice "implementation") || return 1
    review=$(prompt_model_choice "first code review") || return 1
    review2=$(prompt_model_choice "second code review") || return 1

    save_models_to_config "$impl" "$review" "$review2" || return 1

    echo ""
    log_info "Implementation: ${impl}"
    log_info "First review:   ${review}"
    log_info "Second review:  ${review2}"
    echo ""

    return 0
}

# Get the appropriate model for a specific story ID (type/suffix mapping)
# Usage: model=$(get_model_for_story "$story_id")
# Suffix order matters: *-REVIEW-2 is checked before *-REVIEW.
# Returns:
#   - gpt-5.3-codex for *-REVIEW (first code review)
#   - gemini-3-pro for *-REVIEW-2 (second code review)
#   - opus-4.6 for *IMPL-RECS, *IMPLEMENT-RECS, and all other stories
get_model_for_story() {
    local story_id="$1"

    case "$story_id" in
        *-REVIEW-2)
            echo "$LAZY_DEV_MODEL_REVIEW2"
            ;;
        *-REVIEW)
            echo "$LAZY_DEV_MODEL_REVIEW"
            ;;
        *IMPL-RECS|*IMPLEMENT-RECS)
            echo "$LAZY_DEV_MODEL_IMPL"
            ;;
        *)
            echo "$LAZY_DEV_MODEL_IMPL"
            ;;
    esac
}


# Get per-story model override from PRD (empty string if absent or unset)
# Usage: override=$(get_story_model_override "$PRD_FILE" "$story_id")
get_story_model_override() {
    local prd_file="$1"
    local story_id="$2"

    jq -r --arg id "$story_id" '
        [.userStories[]? | select(.id == $id) | .model // ""] | .[0] // ""
    ' "$prd_file" 2>/dev/null || true
}

# Resolve model for a story: per-story .model field wins, else suffix/type mapping
# Usage: model=$(resolve_model_for_story "$PRD_FILE" "$story_id")
resolve_model_for_story() {
    local prd_file="$1"
    local story_id="$2"
    local override

    override=$(get_story_model_override "$prd_file" "$story_id")
    if [ -n "$override" ]; then
        echo "$override"
        return 0
    fi

    get_model_for_story "$story_id"
}

# Returns 0 if story_id is a code-review story (*-REVIEW or *-REVIEW-2)
# Usage: is_review_story "$story_id" && ...
is_review_story() {
    local story_id="$1"

    case "$story_id" in
        *-REVIEW-2|*-REVIEW)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Detect the repository's main branch name (main or master)
# Usage: main_branch=$(detect_main_branch)
detect_main_branch() {
    local main_branch="main"

    if ! git show-ref --verify --quiet refs/heads/main; then
        if git show-ref --verify --quiet refs/heads/master; then
            main_branch="master"
        else
            echo ""
            return 1
        fi
    fi

    echo "$main_branch"
}


# ═══════════════════════════════════════════════════════════════════════════
# GIT SAFETY: BLOCK ALL PUSH OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════

# Install git hook to block pushes during lazy-dev session
install_push_blocker() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    
    local hook_file="$git_dir/hooks/pre-push"
    local lock_file="$git_dir/lazy-dev-session.lock"
    local lazy_marker="# LAZY-DEV-PUSH-BLOCKER"
    local existing_pid=""

    # Warn if another session's push-blocker lock is still live (different feature/repo run)
    if [ -f "$lock_file" ]; then
        existing_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$existing_pid" ] && [ "$existing_pid" != "$$" ] && kill -0 "$existing_pid" 2>/dev/null; then
            log_warn "Another lazy-dev session appears active (PID $existing_pid in $lock_file) - push blocker will still be installed for this session"
        fi
    fi

    # Create lock file to indicate active session
    echo "$$" > "$lock_file"
    
    # Check if our blocker is already installed
    if [ -f "$hook_file" ] && grep -q "$lazy_marker" "$hook_file" 2>/dev/null; then
        return 0
    fi
    
    # Backup existing hook if it exists and isn't ours
    if [ -f "$hook_file" ] && ! grep -q "$lazy_marker" "$hook_file" 2>/dev/null; then
        cp "$hook_file" "$hook_file.backup"
        log_info "Backed up existing pre-push hook to $hook_file.backup"
    fi
    
    # Create hooks directory if needed
    mkdir -p "$git_dir/hooks"
    
    # Install the hook that checks for active session
    cat > "$hook_file" << 'HOOKEOF'
#!/bin/bash
# LAZY-DEV-PUSH-BLOCKER
# This hook prevents accidental pushes ONLY during active Lazy Dev sessions

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
LOCK_FILE="$GIT_DIR/lazy-dev-session.lock"

# Only block if lazy-dev session is active
if [ -f "$LOCK_FILE" ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                    ❌ GIT PUSH BLOCKED (Lazy Dev Active) ❌               ║"
    echo "╠═══════════════════════════════════════════════════════════════════════════╣"
    echo "║  A Lazy Dev session is currently running.                                ║"
    echo "║  Pushes are blocked during active sessions to prevent conflicts.         ║"
    echo "║                                                                           ║"
    echo "║  Options:                                                                 ║"
    echo "║  1. Wait for Lazy Dev to complete (it will clean up automatically)       ║"
    echo "║  2. Stop Lazy Dev (Ctrl+C) - hook will be removed automatically          ║"
    echo "║  3. Force remove: rm $LOCK_FILE && rm .git/hooks/pre-push           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# No active session - allow push and clean up the hook
rm -f "$0"  # Remove this hook since no session is active
exit 0
HOOKEOF
    chmod +x "$hook_file"
    log_success "Git push blocker installed (commits allowed, pushes blocked during session)"
}

# Remove git hook and lock file (called on cleanup)
remove_push_blocker() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    
    local hook_file="$git_dir/hooks/pre-push"
    local lock_file="$git_dir/lazy-dev-session.lock"
    
    # Remove lock file
    if [ -f "$lock_file" ]; then
        rm -f "$lock_file"
        log_debug "Removed lazy-dev session lock file"
    fi
    
    # Remove the hook if it's ours
    if [ -f "$hook_file" ] && grep -q "# LAZY-DEV-PUSH-BLOCKER" "$hook_file" 2>/dev/null; then
        rm -f "$hook_file"
        log_info "Removed push blocker hook - you can now push manually"
        
        # Restore backup if it exists
        if [ -f "$hook_file.backup" ]; then
            mv "$hook_file.backup" "$hook_file"
            log_info "Restored original pre-push hook from backup"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# GIT: Clean tree, branch setup, runner-owned commits
# ═══════════════════════════════════════════════════════════════════════════

# True when the working tree has any uncommitted changes.
working_tree_is_dirty() {
    git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -q .
}

# Fail fast when the working tree is not clean.
assert_clean_working_tree() {
    if working_tree_is_dirty; then
        log_error "Working tree is not clean. Commit or stash changes before continuing."
        git -C "$PROJECT_ROOT" status --short
        exit 1
    fi
}

# Validate a user-supplied branch name for git.
validate_branch_name() {
    local name="$1"
    [ -n "$name" ] || return 1
    git check-ref-format --branch "$name" 2>/dev/null
}

# Build a conventional commit message for the assigned story.
build_iteration_commit_message() {
    local story_id="$1"
    local title jira_id commit_type

    title=$(jq -r --arg id "$story_id" \
        '[.userStories[]? | select(.id == $id) | .title] | first // ""' \
        "$PRD_FILE" 2>/dev/null || echo "")
    jira_id=$(jq -r '.jiraTaskId // empty' "$PRD_FILE" 2>/dev/null || echo "")

    commit_type="feat"
    if is_review_story "$story_id"; then
        commit_type="chore"
    fi

    if [ -n "$jira_id" ]; then
        printf '%s: (%s) %s' "$commit_type" "$jira_id" "$title"
    else
        printf '%s: %s - %s' "$commit_type" "$story_id" "$title"
    fi
}

# Prompt on main/master; otherwise stay on the current branch.
ensure_feature_branch() {
    if ! git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
        log_error "Not a git repository. Please run from within a git project."
        exit 1
    fi

    local current_branch branch_name main_branch
    current_branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
    main_branch=$(detect_main_branch || echo "")

    if [ -z "$current_branch" ]; then
        log_error "Detached HEAD state is not supported. Check out a branch first."
        exit 1
    fi

    if [ -n "$main_branch" ] && [ "$current_branch" = "$main_branch" ]; then
        echo ""
        echo "You are on $main_branch. Enter a branch name for this feature."
        if [ -t 0 ]; then
            read -rp "Branch name: " branch_name
        else
            read -rp "Branch name: " branch_name </dev/tty
        fi
        if ! validate_branch_name "$branch_name"; then
            log_error "Invalid branch name: '$branch_name'"
            exit 1
        fi
        if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch_name"; then
            log_info "Branch '$branch_name' already exists — checking out"
            git -C "$PROJECT_ROOT" checkout "$branch_name" --quiet
        else
            log_info "Creating branch: $branch_name"
            git -C "$PROJECT_ROOT" checkout -b "$branch_name" --quiet
        fi
        log_success "Now on branch: $branch_name"
    else
        log_info "Staying on branch: $current_branch"
    fi

    install_push_blocker

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║  Runner commits locally after each story                                  ║"
    echo "║  Git push: BLOCKED (pre-push hook installed)                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""
}


# Verify required files exist
verify_setup() {
    if [ ! -d "$FEATURE_DIR" ]; then
        log_error "Feature directory not found: $FEATURE_DIR"
        log_info "Create a feature PRD first: lazydev (option 1)"
        exit 1
    fi

    if [ ! -f "$PRD_FILE" ]; then
        log_error "PRD file not found: $PRD_FILE"
        log_info "Create a feature PRD first: lazydev (option 1)"
        exit 1
    fi

    if [ ! -f "$PROMPT_FILE" ]; then
        log_error "Prompt file not found: $PROMPT_FILE"
        exit 1
    fi

    mkdir -p "$DISCOVERED_DIR"

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install it: brew install jq"
        exit 1
    fi

    if ! validate_prd "$PRD_FILE"; then
        exit 1
    fi

    # Check if cursor CLI is available
    if ! command -v cursor &> /dev/null; then
        log_error "Cursor CLI not found. Please install it first."
        log_info "Run: cursor agent --help"
        log_info "See: https://docs.cursor.com/cli"
        exit 1
    fi
    
    # Check for cursor-agent specifically
    if command -v cursor-agent &> /dev/null; then
        log_debug "Found cursor-agent CLI"
        USE_STANDALONE_CURSOR_AGENT=1
    else
        log_debug "cursor-agent not found in PATH - will try 'cursor agent' instead"
        USE_STANDALONE_CURSOR_AGENT=0
    fi
}

# Archive previous run if branch changed
archive_previous_run() {
    if [ -f "$LAST_BRANCH_FILE" ]; then
        local current_branch last_branch
        current_branch=$(git branch --show-current 2>/dev/null || echo "")
        last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

        if [ -n "$current_branch" ] && [ -n "$last_branch" ] && [ "$current_branch" != "$last_branch" ]; then
            DATE=$(date +%Y-%m-%d)
            FOLDER_NAME=$(echo "$last_branch" | sed 's|^feature/||; s|^lazy/||; s|^dev/||; s|/|_|g')
            ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

            log_info "Archiving previous run: $last_branch"
            mkdir -p "$ARCHIVE_FOLDER"
            [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
            [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
            # Note: Shared discovered patterns (rules/discovered/) are NOT archived per-feature
            log_success "Archived to: $ARCHIVE_FOLDER"

            # Reset progress file for new run
            initialize_progress_file
        fi
    fi
}

# Track current branch (actual git branch, not PRD field)
track_branch() {
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    if [ -n "$current_branch" ]; then
        echo "$current_branch" > "$LAST_BRANCH_FILE"
    fi
}

# Initialize progress file if it doesn't exist
initialize_progress_file() {
    if [ ! -f "$PROGRESS_FILE" ]; then
        cp "$SCRIPT_DIR/examples/progress.txt" "$PROGRESS_FILE" 2>/dev/null || \
        cat > "$PROGRESS_FILE" << 'EOF'
# Progress Log

## Codebase Patterns

<!-- Consolidated patterns discovered during implementation -->
<!-- Add reusable patterns here, not story-specific details -->

---

## Session Log

Started: $(date)

---
EOF
        # Replace the date placeholder
        if [[ "$OSTYPE" == darwin* ]]; then
            sed -i '' "s/\$(date)/$(date)/" "$PROGRESS_FILE"
        else
            sed -i "s/\$(date)/$(date)/" "$PROGRESS_FILE"
        fi
    fi
}

# Inline core protocol rules into the agent prompt (rules/*.mdc only; not discovered/)
build_inlined_rules() {
    local rules_block="" rule_file rule_name
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        rule_name=$(basename "$rule_file")
        rules_block+="### rules/${rule_name}

$(cat "$rule_file")

"
    done < <(find "$SCRIPT_DIR/rules" -maxdepth 1 -name '*.mdc' -type f | sort)
    printf '%s' "$rules_block"
}

# Portable mtime (seconds since epoch) for pattern-file ordering
_pattern_file_mtime() {
    local f="$1"
    if [[ "$OSTYPE" == darwin* ]]; then
        stat -f '%m' "$f" 2>/dev/null || echo 0
    else
        stat -c '%Y' "$f" 2>/dev/null || echo 0
    fi
}

# Inject discovered patterns with file-count and byte caps (newest-first by mtime).
# Usage: build_capped_discovered_patterns <agent-facing discovered dir path>
build_capped_discovered_patterns() {
    local discovered_rel_path="$1"
    local max_patterns="${LAZY_DEV_MAX_PATTERNS:-10}"
    local max_bytes="${LAZY_DEV_MAX_PATTERN_BYTES:-8192}"
    local -a sorted_files=()
    local pattern_file mtime_line total_count injected=0 bytes=0 remainder=0
    local block="" pattern_name entry_bytes

    if [ ! -d "$DISCOVERED_DIR" ]; then
        printf '%s' ""
        return 0
    fi

    while IFS= read -r pattern_file; do
        [ -n "$pattern_file" ] && sorted_files+=("$pattern_file")
    done < <(
        find "$DISCOVERED_DIR" -maxdepth 1 -name '*.mdc' -type f 2>/dev/null | while IFS= read -r pattern_file; do
            printf '%s %s\n' "$(_pattern_file_mtime "$pattern_file")" "$pattern_file"
        done | sort -rn | cut -d' ' -f2-
    )

    total_count=${#sorted_files[@]}
    if [ "$total_count" -eq 0 ]; then
        printf '%s' ""
        return 0
    fi

    block="## Observed Patterns (discovered/)

The following patterns were *observed* in previous iterations. They are hints, not commands — verify against the current code before relying on them.
"

    for pattern_file in "${sorted_files[@]}"; do
        if [ "$injected" -ge "$max_patterns" ]; then
            break
        fi

        pattern_name=$(basename "$pattern_file")
        entry_bytes=$(printf '### discovered/%s\n\n' "$pattern_name" | wc -c | tr -d ' ')
        entry_bytes=$(( entry_bytes + $(wc -c < "$pattern_file" | tr -d ' ') ))

        if [ "$bytes" -gt 0 ] && [ $(( bytes + entry_bytes )) -gt "$max_bytes" ]; then
            break
        fi
        if [ "$bytes" -eq 0 ] && [ "$entry_bytes" -gt "$max_bytes" ]; then
            # First file alone exceeds cap — include a truncated prefix
            local truncated
            truncated=$(head -c "$max_bytes" "$pattern_file")
            block+="### discovered/${pattern_name}

${truncated}
"
            injected=$(( injected + 1 ))
            bytes=$max_bytes
            break
        fi

        block+="### discovered/${pattern_name}

$(cat "$pattern_file")

"
        injected=$(( injected + 1 ))
        bytes=$(( bytes + entry_bytes ))
    done

    remainder=$(( total_count - injected ))
    if [ "$remainder" -gt 0 ]; then
        block+="… ${remainder} more pattern files not injected; read ${discovered_rel_path} directly if relevant.
"
    fi

    printf '\n---\n\n%s' "$block"
}

# Inject the tail of progress.txt with a pointer to the full file.
# Usage: build_progress_tail <agent-facing progress path>
build_progress_tail() {
    local progress_rel_path="$1"
    local max_lines="${LAZY_DEV_MAX_PROGRESS_LINES:-150}"
    local tail_content

    if [ ! -f "$PROGRESS_FILE" ]; then
        printf '%s' ""
        return 0
    fi

    tail_content=$(tail -n "$max_lines" "$PROGRESS_FILE")

    printf '\n---\n\n## Recent Progress (last %s lines)\n\n%s\n\nFull history: %s (read it yourself only if you need older context).\n' \
        "$max_lines" "$tail_content" "$progress_rel_path"
}

# Run a single agent iteration
run_iteration() {
    local iteration=$1
    local start_time=$(date +%s)
    # Reset fast-fail / model-retry inputs (main reads these after the call)
    LAST_ITERATION_DURATION=0
    LAST_ITERATION_USED_EXPLICIT_MODEL=0
    LAST_ASSIGNED_STORY_ID=""
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Lazy Dev - Feature: $FEATURE_NAME"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Build prompt with feature context and inlined protocol rules
    PROMPT_CONTENT=$(cat "$PROMPT_FILE")
    local INLINED_RULES
    INLINED_RULES=$(build_inlined_rules)
    
    # Get current branch name
    CURRENT_GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    # Session marker for scoped orphan cleanup (one marker per lazy.sh run)
    if [ -z "${LAZY_DEV_SESSION_MARKER:-}" ]; then
        LAZY_DEV_SESSION_MARKER="lazydev-$$-$(date +%s)"
    fi
    
    # Agent-facing paths relative to project root (derived from install location)
    local LAZY_DEV_PRD_PATH="$STATE_DIR/features/$FEATURE_NAME/prd.json"
    local LAZY_DEV_PROGRESS_PATH="$STATE_DIR/features/$FEATURE_NAME/progress.txt"
    local LAZY_DEV_DISCOVERED_PATH="$STATE_DIR/rules/discovered/"

    # Resolve assigned story before building CONTEXT (runner-owned selection)
    local next_story_id
    next_story_id=$(get_next_story_id "$PRD_FILE")

    if [ -z "$next_story_id" ]; then
        log_error "No assignable story found in PRD (all complete, corrupted, or empty). Skipping agent launch."
        return 1
    fi

    LAST_ASSIGNED_STORY_ID="$next_story_id"
    CURRENT_ITERATION=$iteration
    ITERATION_START_EPOCH=$start_time
    LAZY_DEV_ITERATION_ACTIVE=0

    local next_story_title
    next_story_title=$(jq -r --arg id "$next_story_id" \
        '[.userStories[]? | select(.id == $id) | .title] | first // ""' \
        "$PRD_FILE" 2>/dev/null || true)

    local review_scope_block=""
    if is_review_story "$next_story_id"; then
        local main_branch merge_base
        main_branch=$(detect_main_branch)
        if [ -n "$main_branch" ]; then
            merge_base=$(git merge-base "$main_branch" HEAD 2>/dev/null || true)
            if [ -n "$merge_base" ]; then
                review_scope_block="

## Review Scope

Review scope: run \`git diff ${merge_base}..HEAD\` to see all feature changes."
            fi
        fi
    fi

    local discovered_block progress_block
    discovered_block=$(build_capped_discovered_patterns "$LAZY_DEV_DISCOVERED_PATH")
    progress_block=$(build_progress_tail "$LAZY_DEV_PROGRESS_PATH")

    # Feature context paths are relative to project root (workspace)
    CONTEXT="<!-- lazy-dev session: ${LAZY_DEV_SESSION_MARKER} -->

# Feature Context
- Feature: $FEATURE_NAME
- Workspace/Project Root: $PROJECT_ROOT
- Lazy-dev state directory: $STATE_DIR
- PRD: $LAZY_DEV_PRD_PATH
- Progress: $LAZY_DEV_PROGRESS_PATH
- Shared discovered patterns: $LAZY_DEV_DISCOVERED_PATH (capped injection below)
- Git Branch: $CURRENT_GIT_BRANCH

# Git: Do not run git commands. The runner commits all changes after you finish.

$PROMPT_CONTENT

---

# Injected Protocol (canonical source: ~/.lazy-dev/rules/*.mdc)

$INLINED_RULES
${discovered_block}
${progress_block}

---

## Your Assignment

This iteration you will work EXACTLY one story: ${next_story_id} — ${next_story_title}. Its full definition (description, acceptance criteria, notes) is in the PRD. Do not start any other story.

When implementation is complete:
- Update PRD (\`passes: true\` when done), \`progress.txt\`, and any \`rules/discovered/\` patterns
- **Do not revert** source changes that implement ${next_story_id}
- Temporary import/revert of files for browser verification applies only to component-only stories — not integration stories (e.g. wiring into App.vue is the deliverable for integration stories)
- **Do not run git commands** — the runner will \`git add -A\` and commit after you end your response

End your response when file updates are complete.${review_scope_block}"

    # Build cursor-agent command with appropriate flags
    # -p / --print: Run in non-interactive (headless) mode
    # --auto-review: Smart Auto — server classifier auto-runs safe tool calls
    # --output-format stream-json: NDJSON for real-time event streaming
    # --stream-partial-output: Character-level streaming for real-time display
    local CURSOR_CMD
    local CURSOR_ARGS=()
    
    # Determine which command to use
    if [ -n "${LAZY_DEV_FAKE_AGENT:-}" ]; then
        # Test hook: use the fake agent executable in place of the Cursor CLI
        # (same flags + prompt argument; still goes through tee | parse_agent_output)
        CURSOR_CMD="$LAZY_DEV_FAKE_AGENT"
        log_info "Using LAZY_DEV_FAKE_AGENT executable: $CURSOR_CMD"
    elif [ "${USE_STANDALONE_CURSOR_AGENT:-0}" = "1" ]; then
        CURSOR_CMD="cursor-agent"
    else
        CURSOR_CMD="cursor"
        CURSOR_ARGS+=("agent")
    fi
    
    # Always run in headless mode with auto-approve and streaming output
    # Note: --stream-partial-output removed - it causes character-by-character output
    # that makes the parsed output unreadable
    # --workspace points to project root so agent can access the full codebase
    CURSOR_ARGS+=("-p" "--auto-review" "--output-format" "stream-json" "--workspace" "$PROJECT_ROOT")

    # Select appropriate model for the assigned story
    # Suffix mapping: *-REVIEW → first review model; *-REVIEW-2 → second review model;
    # per-story "model" field in prd.json overrides type mapping when present
    local selected_model=""

    if [ "${LAZY_DEV_FORCE_CLI_DEFAULT_MODEL:-0}" = "1" ]; then
        log_info "Story: ${BOLD}${next_story_id}${NC} → Model: ${BOLD}CLI default${NC} (--model omitted)"
    else
        selected_model=$(resolve_model_for_story "$PRD_FILE" "$next_story_id")
        if [ -n "$selected_model" ]; then
            CURSOR_ARGS+=("--model" "$selected_model")
            LAST_ITERATION_USED_EXPLICIT_MODEL=1
            log_info "Story: ${BOLD}${next_story_id}${NC} → Model: ${BOLD}${selected_model}${NC}"
        fi
    fi

    # Pre-flight check: ensure the command exists
    if ! command -v "$CURSOR_CMD" &> /dev/null; then
        log_error "Command not found: $CURSOR_CMD"
        log_error "Please ensure Cursor CLI is installed and in your PATH"
        return 1
    fi
    
    # Debug: show exact command being run (verbose mode only)
    log_debug "Executing: $CURSOR_CMD ${CURSOR_ARGS[*]} <...prompt...>"

    if [ "${LAZY_DEV_PRINT_CONTEXT:-}" = "1" ]; then
        echo "" >&2
        echo "========== LAZY_DEV_PRINT_CONTEXT (start) ==========" >&2
        printf '%s\n' "$CONTEXT" >&2
        echo "========== LAZY_DEV_PRINT_CONTEXT (end) ==========" >&2
        echo "" >&2
    fi

    # Run cursor-agent with the prompt
    # Use the global OUTPUT_FILE (managed by main() trap) for raw NDJSON capture
    # Parse NDJSON stream through parse_agent_output for formatted display
    local exit_code=0
    
    # Clear output file for this iteration
    > "$OUTPUT_FILE"
    
    # Run command with NDJSON parsing for real-time formatted output
    # Raw JSON is saved to OUTPUT_FILE for the stall watchdog and debugging
    # Parsed output is displayed to terminal
    log_debug "Starting agent with stream-json output"
    
    # Run pipeline in a background subshell. Never use negative-PID group kills on
    # PIPELINE_PID — without job control that can SIGKILL lazy.sh on macOS.
    export VERBOSE
    export LAZY_DEV_CURRENT_ITERATION="$iteration"
    export LAZY_DEV_SESSION_STATS_FILE="$SESSION_STATS_FILE"
    (
        set -o pipefail
        if command -v stdbuf &> /dev/null; then
            log_debug "Using stdbuf for unbuffered output"
            stdbuf -oL -eL $CURSOR_CMD "${CURSOR_ARGS[@]}" "$CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
        elif command -v unbuffer &> /dev/null; then
            log_debug "Using unbuffer for output capture"
            unbuffer $CURSOR_CMD "${CURSOR_ARGS[@]}" "$CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
        elif command -v script &> /dev/null && [[ "$OSTYPE" == darwin* ]]; then
            log_debug "Using script for output capture (macOS)"
            script -q /dev/null $CURSOR_CMD "${CURSOR_ARGS[@]}" "$CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
        else
            log_debug "Using basic output capture (may buffer)"
            $CURSOR_CMD "${CURSOR_ARGS[@]}" "$CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
        fi
    ) &
    PIPELINE_PID=$!
    LAZY_DEV_ITERATION_ACTIVE=1
    log_debug "Pipeline running in subshell (PID: $PIPELINE_PID)"
    log_debug "Iteration timeout: ${ITERATION_TIMEOUT}s (override with LAZY_DEV_TIMEOUT env var)"
    
    # Wait with timeout to prevent hung iterations
    # Use short sleep intervals (0.5s) for responsive Ctrl+C handling
    local wait_start=$(date +%s)
    local timed_out=0
    local kill_reason=""
    local last_output_size=0
    local last_output_change_time=$(date +%s)
    local result_seen_time=0
    
    while kill -0 "$PIPELINE_PID" 2>/dev/null; do
        local elapsed=$(($(date +%s) - wait_start))
        if [ "$elapsed" -ge "$ITERATION_TIMEOUT" ]; then
            log_warn "Iteration timed out after ${ITERATION_TIMEOUT}s - killing process"
            timed_out=1
            kill_reason="timeout"
            break
        fi
        
        # Stall watchdog: kill if raw output file size is unchanged for effective_stall_timeout
        local current_output_size=0
        if [ -f "$OUTPUT_FILE" ]; then
            current_output_size=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
        fi
        if [ "$current_output_size" != "$last_output_size" ]; then
            last_output_size=$current_output_size
            last_output_change_time=$(date +%s)
            if output_file_has_result_event "$OUTPUT_FILE"; then
                if [ "$result_seen_time" -eq 0 ]; then
                    result_seen_time=$(date +%s)
                fi
            fi
        else
            local stall_elapsed=$(($(date +%s) - last_output_change_time))

            # Result received but pipeline still alive — cursor-cli tail hang
            if [ "$result_seen_time" -gt 0 ]; then
                local result_tail_elapsed=$(($(date +%s) - result_seen_time))
                if [ "$result_tail_elapsed" -ge "$RESULT_TAIL_HANG_TIMEOUT" ]; then
                    log_warn "Result event received but pipeline still alive (${result_tail_elapsed}s) - killing process"
                    timed_out=1
                    kill_reason="result_tail_hang"
                    break
                fi
            fi

            if [ "$stall_elapsed" -ge "$STALL_TIMEOUT" ]; then
                log_warn "Stall detected (no output for ${stall_elapsed}s) - killing process"
                kill_reason="stall"
                timed_out=1
                break
            fi
        fi
        
        # Check every 0.5 seconds for responsive Ctrl+C handling
        sleep 0.5
    done
    
    if [ "$timed_out" -eq 1 ]; then
        log_warn "Stall recovery: killed hung agent (reason: ${kill_reason:-timeout}) — continuing loop"
        kill_pipeline_safely "$PIPELINE_PID" "${kill_reason:-timeout}"
    fi
    
    if [ "$timed_out" -eq 0 ]; then
        wait $PIPELINE_PID 2>/dev/null || exit_code=$?
    else
        exit_code=124  # Standard timeout exit code
        local kill_duration=$(($(date +%s) - start_time))
        append_killed_iteration_marker "$iteration" "${kill_reason:-timeout}" "$kill_duration"
    fi
    LAZY_DEV_ITERATION_ACTIVE=0
    PIPELINE_PID=""
    
    # Clean up processes after each iteration to prevent memory buildup
    cleanup_iteration
    
    # Log resource usage (always log process count for leak detection)
    log_process_count
    if [ "$VERBOSE" = "1" ]; then
        log_memory_usage
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local story_counts
    story_counts=$(get_story_counts "$PRD_FILE")
    
    echo ""
    if [ "$exit_code" -eq 0 ]; then
        echo "═══ Iteration complete (${duration}s) - ${story_counts} stories done ═══════════════"
    else
        echo "═══ Iteration failed (exit ${exit_code}) - ${story_counts} stories done ═══════════════"
    fi
    echo ""
    
    # Expose the duration for main's fast-fail decision
    LAST_ITERATION_DURATION=$duration
    
    # Return the real exit status (0 = success, 124 = timeout, other = agent/
    # pipeline failure) so main's retry / fast-fail logic can act on it
    return $exit_code
}

# Signal handler for immediate response to Ctrl+C during wait loops
# This is called BEFORE cleanup() to kill children immediately
handle_interrupt() {
    log_info "Interrupt received - stopping agent..."

    if [ "${LAZY_DEV_ITERATION_ACTIVE:-0}" = "1" ]; then
        local interrupt_duration=$(($(date +%s) - ITERATION_START_EPOCH))
        append_killed_iteration_marker "$CURRENT_ITERATION" "interrupt" "$interrupt_duration"
    fi
    LAZY_DEV_ITERATION_ACTIVE=0
    
    # Kill pipeline immediately (don't wait for cleanup)
    if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2>/dev/null; then
        kill_pipeline_safely "$PIPELINE_PID" "interrupt"
    fi
    PIPELINE_PID=""
    
    # Exit will trigger cleanup trap
    exit 130  # 128 + SIGINT(2)
}

# Main execution
main() {
    # ═══════════════════════════════════════════════════════════════════════════
    # CRITICAL: Set up cleanup trap FIRST to prevent orphaned processes
    # ═══════════════════════════════════════════════════════════════════════════
    OUTPUT_FILE=$(mktemp)
    SPINNER_PID_FILE=$(mktemp)
    export SPINNER_PID_FILE  # Export so subshells (parse_agent_output) can write to it
    
    # Use handle_interrupt for INT to ensure immediate response to Ctrl+C
    # QUIT (Ctrl+\) and HUP (terminal closed) also trigger immediate cleanup
    trap handle_interrupt INT QUIT HUP
    trap cleanup EXIT TERM

    # Start caffeinate to prevent system sleep (keeps network connections alive)
    # -d = prevent display sleep, -i = prevent idle sleep
    if command -v caffeinate &> /dev/null; then
        caffeinate -di &
        CAFFEINATE_PID=$!
        log_info "Started caffeinate (PID: $CAFFEINATE_PID) - system won't sleep during session"
    else
        log_warn "caffeinate not found (macOS only) - system may sleep during long runs"
    fi
    
    log_debug "Script directory: $SCRIPT_DIR"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Feature directory: $FEATURE_DIR"
    log_debug "PRD file: $PRD_FILE"
    log_debug "Prompt file: $PROMPT_FILE"

    bootstrap_lazy_dev_project || exit 1
    set_feature_paths

    verify_setup
    ensure_models_configured || exit 1

    # Log initial resource state for comparison (debug only)
    if [ "$VERBOSE" = "1" ]; then
        log_memory_usage
        log_process_count
    fi
    
    # CRITICAL: Require clean tree, then set up branch and block pushes
    assert_clean_working_tree
    ensure_feature_branch
    
    archive_previous_run
    track_branch
    initialize_progress_file

    # Run continuously until all stories are complete
    local iteration=1
    local session_start=$(date +%s)
    
    while true; do
        # Check max iterations to prevent infinite loops
        if [ $iteration -gt $MAX_ITERATIONS ]; then
            log_error "Max iterations ($MAX_ITERATIONS) reached. Stopping."
            log_info "Override with: LAZY_DEV_MAX_ITERATIONS=N or --max-iterations N"
            exit 1
        fi
        
        # Stuck: incomplete PRD but every remaining story is blocked
        if is_feature_stuck "$PRD_FILE"; then
            report_stuck_and_exit "$PRD_FILE"
        fi

        # Session budget breaker (cost / cumulative duration from .session-stats)
        if is_session_budget_exceeded; then
            report_budget_exceeded_and_exit
        fi

        # Check if all stories are already complete before running iteration
        if verify_all_stories_complete "$PRD_FILE"; then
            local session_end=$(date +%s)
            local total_duration=$((session_end - session_start))
            local total_min=$((total_duration / 60))
            local total_sec=$((total_duration % 60))
            echo ""
            echo "═══════════════════════════════════════════════════════════════"
            echo "  All stories completed for feature: $FEATURE_NAME"
            echo "  Total time: ${total_min}m ${total_sec}s"
            echo "═══════════════════════════════════════════════════════════════"
            exit 0
        fi
        
        # Require a clean tree before each story (previous story must be committed)
        assert_clean_working_tree

        # Capture assigned story state before iteration (for quality-gate flip detection)
        local assigned_passes_before assigned_before_id gate_recorded_attempt=0
        assigned_before_id=$(get_next_story_id "$PRD_FILE")
        assigned_passes_before="false"
        if [ -n "$assigned_before_id" ]; then
            assigned_passes_before=$(jq -r --arg id "$assigned_before_id" \
                '[.userStories[]? | select(.id == $id) | .passes // false] | first // false' \
                "$PRD_FILE" 2>/dev/null || echo "false")
        fi

        # Run iteration with retry logic
        local retry_count=0
        local iteration_success=0
        LAZY_DEV_FORCE_CLI_DEFAULT_MODEL=0
        
        while [ $retry_count -lt $MAX_RETRIES ]; do
            if run_iteration $iteration; then
                iteration_success=1
                break
            fi
            
            retry_count=$((retry_count + 1))
            
            # Fast-fail: a failed iteration that ended quickly is almost always
            # a config/auth/model error, not a transient one - do not retry it.
            # LAZY_DEV_FASTFAIL_SECS=0 disables fast-fail entirely.
            # Exception: if we used an explicit --model, retry once with CLI default.
            if [ "$FASTFAIL_SECS" -gt 0 ] && [ "${LAST_ITERATION_DURATION:-0}" -lt "$FASTFAIL_SECS" ]; then
                if [ "${LAST_ITERATION_USED_EXPLICIT_MODEL:-0}" -eq 1 ] && \
                   [ "${LAZY_DEV_FORCE_CLI_DEFAULT_MODEL:-0}" -eq 0 ]; then
                    log_warn "Fast-fail with explicit model - retrying once with CLI default (--model omitted)"
                    LAZY_DEV_FORCE_CLI_DEFAULT_MODEL=1
                    retry_count=$((retry_count - 1))
                    continue
                fi
                log_error "Fast-fail: iteration $iteration failed after ${LAST_ITERATION_DURATION}s (< ${FASTFAIL_SECS}s) - not retrying (likely config/auth/model error)"
                break
            fi
            
            if [ $retry_count -lt $MAX_RETRIES ]; then
                local backoff_delay=${BACKOFF_SCHEDULE[$((retry_count - 1))]:-45}
                log_warn "Iteration failed, retry $retry_count of $MAX_RETRIES (backoff ${backoff_delay}s)"
                sleep "$backoff_delay"
            fi
        done
        
        if [ $iteration_success -eq 0 ]; then
            log_error "Iteration $iteration failed after $retry_count attempt(s)"
            if working_tree_is_dirty; then
                log_error "Agent left uncommitted changes — stopping session"
                git -C "$PROJECT_ROOT" status --short
                exit 1
            fi
        fi

        # Runner-owned commit: story is done only when commit succeeds
        if working_tree_is_dirty; then
            if ! commit_iteration_changes "$LAST_ASSIGNED_STORY_ID"; then
                fatal_iteration_commit_failure "$LAST_ASSIGNED_STORY_ID" "$assigned_passes_before"
            fi
        fi

        # Runner quality gate when the assigned story flipped to passes:true this iteration
        if [ -n "${LAST_ASSIGNED_STORY_ID:-}" ]; then
            if ! handle_quality_gate_for_flip "$LAST_ASSIGNED_STORY_ID" "$assigned_passes_before"; then
                gate_recorded_attempt=1
                if working_tree_is_dirty; then
                    commit_iteration_changes "$LAST_ASSIGNED_STORY_ID" \
                        || fatal_iteration_commit_failure "$LAST_ASSIGNED_STORY_ID" "$assigned_passes_before"
                fi
            fi
        fi
        
        # Record attempt when assigned story is still incomplete and not blocked
        if [ "$gate_recorded_attempt" -eq 0 ] && [ -n "${LAST_ASSIGNED_STORY_ID:-}" ]; then
            local story_still_incomplete story_was_blocked
            story_still_incomplete=$(jq -r --arg id "$LAST_ASSIGNED_STORY_ID" \
                '[.userStories[]? | select(.id == $id and (.passes != true))] | length' \
                "$PRD_FILE" 2>/dev/null || echo "0")
            story_was_blocked=$(jq -r --arg id "$LAST_ASSIGNED_STORY_ID" \
                '[.userStories[]? | select(.id == $id) | .blocked // false] | first // false' \
                "$PRD_FILE" 2>/dev/null || echo "false")

            if [ "$story_still_incomplete" -gt 0 ] && [ "$story_was_blocked" != "true" ]; then
                record_story_attempt "$LAST_ASSIGNED_STORY_ID" "$PRD_FILE"
            fi
        fi

        # Check completion after iteration
        if verify_all_stories_complete "$PRD_FILE"; then
            local session_end=$(date +%s)
            local total_duration=$((session_end - session_start))
            local total_min=$((total_duration / 60))
            local total_sec=$((total_duration % 60))
            echo ""
            echo "═══════════════════════════════════════════════════════════════"
            echo "  All stories completed for feature: $FEATURE_NAME"
            echo "  Total time: ${total_min}m ${total_sec}s"
            echo "═══════════════════════════════════════════════════════════════"
            exit 0
        fi

        # Stuck after attempt recording (last story just parked)
        if is_feature_stuck "$PRD_FILE"; then
            report_stuck_and_exit "$PRD_FILE"
        fi

        # Silently continue to next iteration
        iteration=$((iteration + 1))
        sleep 2
    done
}

# Only run main when executed directly (not when sourced for function tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${LAZY_DEV_BOOTSTRAP_ONLY:-0}" = "1" ]]; then
        bootstrap_lazy_dev_project || exit 1
        if [[ "${LAZY_DEV_PRINT_STATE_DIR:-0}" = "1" ]]; then
            echo "$STATE_DIR"
        fi
        exit 0
    fi
    main "$@"
fi
