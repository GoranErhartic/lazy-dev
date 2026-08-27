#!/bin/bash
# Lazy Dev - Cursor CLI Agent Loop
# Usage: ./go.sh <feature-name>
#
# Each feature gets its own subfolder with isolated state.
# Runs continuously until ALL user stories in PRD have passes: true.
# Always runs in headless mode with auto-approve (YOLO mode).
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        ⚠️  GIT SAFETY POLICY  ⚠️                           ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  ✅ ALLOWED: git commit                                                   ║
# ║  ❌ FORBIDDEN: git push (NEVER - this is STRICTLY BLOCKED)               ║
# ║                                                                           ║
# ║  This script will:                                                        ║
# ║  1. Ensure you're on the latest main branch                              ║
# ║  2. Create a feature branch: feature/<feature-name>                      ║
# ║  3. Block ALL push operations                                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CLI ENTRY POINT — direct execution only, NOT when sourced
#
# Sourcing this file (e.g. `source ./go.sh __test__`) only defines the
# functions and globals above, for function-level tests. Flag parsing,
# argument validation, and main() are skipped.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

# Parse flags
VERBOSE=""
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
        --help|-h)
            echo "Usage: ./go.sh [OPTIONS] <feature-name>"
            echo ""
            echo "Options:"
            echo "  --verbose, -v          Enable verbose/debug output"
            echo "  --max-iterations N     Set maximum iterations (default: 20)"
            echo "  --help, -h             Show this help message"
            echo ""
            echo "Runs continuously until ALL user stories in PRD have passes: true."
            echo "Agent runs in headless mode with auto-approve enabled."
            echo "Maximum iterations: $MAX_ITERATIONS (override with --max-iterations or LAZY_DEV_MAX_ITERATIONS)"
            echo ""
            echo "Examples:"
            echo "  ./go.sh my-feature              # Run agent for feature"
            echo "  ./go.sh features/user-auth      # Also accepts features/ prefix"
            echo "  ./go.sh -v my-feature           # With verbose output"
            echo "  ./go.sh --max-iterations 30 my-feature  # Custom max iterations"
            echo ""
            echo "Environment variables:"
            echo "  LAZY_DEV_TIMEOUT=<s>         Per-iteration timeout in seconds (default: 1800)"
            echo "  LAZY_DEV_MAX_ITERATIONS=<n>  Maximum iterations (default: 20)"
            echo "  LAZY_DEV_FASTFAIL_SECS=<s>   Failed iterations shorter than this are not retried (default: 60; 0 disables)"
            echo "  LAZY_DEV_FAKE_AGENT=<path>   Test hook: run this executable instead of the Cursor CLI"
            echo ""
            echo "To create a new feature:"
            echo "  mkdir -p features/<feature-name>"
            echo "  cp examples/prd.json features/<feature-name>/"
            echo "  cp examples/progress.txt features/<feature-name>/"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ -z "$1" ]; then
    echo "Usage: ./go.sh [OPTIONS] <feature-name>"
    echo ""
    echo "Options:"
    echo "  --verbose, -v          Enable verbose/debug output"
    echo "  --max-iterations N     Set maximum iterations (default: 20)"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Runs continuously until ALL user stories in PRD have passes: true."
    echo "Agent runs in headless mode with auto-approve enabled."
    echo "Maximum iterations: 20 (override with --max-iterations or LAZY_DEV_MAX_ITERATIONS)"
    echo ""
    echo "Examples:"
    echo "  ./go.sh my-feature              # Run agent for feature"
    echo "  ./go.sh features/user-auth      # Also accepts features/ prefix"
    echo "  ./go.sh -v my-feature           # With verbose output"
    echo "  ./go.sh --max-iterations 30 my-feature  # Custom max iterations"
    echo ""
    echo "Environment variables:"
    echo "  LAZY_DEV_TIMEOUT=<s>         Per-iteration timeout in seconds (default: 1800)"
    echo "  LAZY_DEV_MAX_ITERATIONS=<n>  Maximum iterations (default: 20)"
    echo "  LAZY_DEV_FASTFAIL_SECS=<s>   Failed iterations shorter than this are not retried (default: 60; 0 disables)"
    echo "  LAZY_DEV_FAKE_AGENT=<path>   Test hook: run this executable instead of the Cursor CLI"
    echo ""
    echo "To create a new feature:"
    echo "  mkdir -p features/<feature-name>"
    echo "  cp examples/prd.json features/<feature-name>/"
    echo "  cp examples/progress.txt features/<feature-name>/"
    exit 1
fi

fi  # ── end CLI entry point (direct execution only) ──

# Configuration
# Strip "features/" prefix if provided (allows both "features/my-feature" and "my-feature")
FEATURE_NAME="${1#features/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT is the git root / workspace root (go up from .cursor/lazy-dev)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEATURE_DIR="$SCRIPT_DIR/features/$FEATURE_NAME"
PRD_FILE="$FEATURE_DIR/prd.json"
PROGRESS_FILE="$FEATURE_DIR/progress.txt"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
ARCHIVE_DIR="$FEATURE_DIR/archive"
LAST_BRANCH_FILE="$FEATURE_DIR/.last-branch"
# Shared discovered patterns directory (cross-feature learning)
DISCOVERED_DIR="$SCRIPT_DIR/rules/discovered"

# Will be set by verify_setup - determines which command to use
USE_CURSOR_AGENT_SUBCOMMAND=0

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

# Timeout for each iteration in seconds (30 minutes default)
# Override with LAZY_DEV_TIMEOUT environment variable
ITERATION_TIMEOUT="${LAZY_DEV_TIMEOUT:-1800}"

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
#   LAZY_DEV_FAKE_AGENT=/path/to/fake-agent.sh ./go.sh my-feature
LAZY_DEV_FAKE_AGENT="${LAZY_DEV_FAKE_AGENT:-}"

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

# Normalize newlines in text: ensure every \n is preceded by \r for proper cursor reset
# This fixes multi-line content where newlines don't reset cursor to column 0
normalize_newlines() {
    # Replace all \n with \r\n (but avoid \r\r\n if \r already present)
    if command -v perl &> /dev/null; then
        perl -pe 's/(?<!\r)\n/\r\n/g'
    else
        # Fallback: simple sed replacement
        sed $'s/\n/\r\n/g'
    fi
}

# Print a line with proper newline and carriage return to reset cursor position
# This ensures each line starts at column 0
# Uses echo -e to interpret color escape sequences
print_line() {
    # First output \r\n to start on a fresh line at column 0
    # Then use echo -e to interpret the color codes in the content
    printf '\r\n'
    echo -e "$1"
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
    
    # Track if we've received first output (don't start spinner until then)
    local first_output_received=0
    local last_output_time=$(date +%s)
    # Track currently displayed user story to avoid repeating banners
    local current_story=""
    # Track if we're in a thinking block (for streaming output)
    local thinking_started=0
    # Track if we're in an assistant streaming block
    local assistant_streaming=0
    # Set to 1 when the final result event reports is_error=true; the function
    # returns 1 in that case so the pipeline (pipefail) sees the agent failure
    local result_failed=0
    
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
                # Thinking events - stream thinking text like chat for real-time feel
                local thinking_text
                thinking_text=$(safe_jq '.text // ""' "$line")
                
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
                        story_match=$(echo "$content" | grep -oE 'US-[A-Z0-9-]+' | head -1)
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
                        
                        last_output_time=$(date +%s)
                    fi
                fi
                ;;
            "tool_call")
                # Display tool calls in condensed format
                # Cursor CLI structure: { "type": "tool_call", "tool_call": { "readToolCall": { "args": {...} } } }
                
                # Only show "started" events, skip "completed" to avoid duplicates
                local subtype
                subtype=$(safe_jq '.subtype // ""' "$line")
                if [ "$subtype" = "completed" ]; then
                    continue
                fi
                
                local tool_name display_param
                
                # Tool name is the first KEY inside .tool_call object (e.g., "readToolCall", "writeToolCall")
                tool_name=$(safe_jq '.tool_call | keys | .[0] // ""' "$line")
                
                # Skip if no tool name extracted
                if [ -z "$tool_name" ] || [ "$tool_name" = "null" ]; then
                    continue
                fi
                
                # Extract the path/command from args based on tool type
                case "$tool_name" in
                    readToolCall|read_file)
                        display_param=$(safe_jq '.tool_call.readToolCall.args.path // .tool_call.read_file.args.path // ""' "$line")
                        tool_name="read"
                        ;;
                    writeToolCall|write)
                        display_param=$(safe_jq '.tool_call.writeToolCall.args.path // .tool_call.write.args.path // ""' "$line")
                        tool_name="write"
                        ;;
                    editToolCall|edit|search_replace)
                        display_param=$(safe_jq '.tool_call.editToolCall.args.path // .tool_call.edit.args.path // ""' "$line")
                        tool_name="edit"
                        ;;
                    terminalToolCall|run_terminal_cmd|terminal)
                        display_param=$(safe_jq '.tool_call.terminalToolCall.args.command // .tool_call.terminal.args.command // ""' "$line")
                        tool_name="run"
                        # Truncate long commands
                        if [ ${#display_param} -gt 60 ]; then
                            display_param="${display_param:0:57}..."
                        fi
                        ;;
                    grepToolCall|grep)
                        display_param=$(safe_jq '.tool_call.grepToolCall.args.pattern // .tool_call.grep.args.pattern // ""' "$line")
                        tool_name="grep"
                        if [ ${#display_param} -gt 40 ]; then
                            display_param="${display_param:0:37}..."
                        fi
                        ;;
                    searchToolCall|codebase_search|search)
                        display_param=$(safe_jq '.tool_call.searchToolCall.args.query // .tool_call.codebase_search.args.query // ""' "$line")
                        tool_name="search"
                        if [ ${#display_param} -gt 40 ]; then
                            display_param="${display_param:0:37}..."
                        fi
                        ;;
                    listDirToolCall|list_dir)
                        display_param=$(safe_jq '.tool_call.listDirToolCall.args.path // .tool_call.list_dir.args.path // ""' "$line")
                        tool_name="ls"
                        ;;
                    *)
                        # For unknown tools, try to get first arg value
                        display_param=$(safe_jq ".tool_call.${tool_name}.args | to_entries | .[0].value // \"\"" "$line")
                        if [ ${#display_param} -gt 50 ]; then
                            display_param="${display_param:0:47}..."
                        fi
                        # Simplify tool name (remove "ToolCall" suffix)
                        tool_name="${tool_name%ToolCall}"
                        ;;
                esac
                
                # Close assistant streaming block if active
                if [ "$assistant_streaming" = "1" ]; then
                    printf "${NC}\r\n"
                    assistant_streaming=0
                fi
                
                # Close thinking block if we were thinking
                if [ "$thinking_started" = "1" ]; then
                    printf "${NC}\r\n\r\n"  # Reset color and add spacing
                    thinking_started=0
                fi
                
                # Now stop spinner and display the tool call
                stop_spinner
                
                if [ -n "$display_param" ] && [ "$display_param" != "null" ]; then
                    print_line "  ${DIM}→ ${tool_name}: ${display_param}${NC}"
                else
                    print_line "  ${DIM}→ ${tool_name}${NC}"
                fi
                
                start_spinner "Agent working"
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
                
                if [ "$is_error" = "true" ]; then
                    result_failed=1
                    print_line "${RED}[RESULT]${NC} ${RED}Failed${NC} in ${duration_s}s"
                else
                    print_line "${GREEN}[RESULT]${NC} ${GREEN}Success${NC} in ${duration_s}s"
                fi
                ;;
            *)
                # Unknown event type - show in debug mode only
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

# Kill all descendants of a PID with both TERM and KILL
# Usage: kill_descendants PID
# First tries killing by process group (negative PID), then falls back to tree traversal
kill_descendants() {
    local pid="$1"
    
    if [ -z "$pid" ]; then
        return 0
    fi
    
    # First try: kill by process group (most effective for subshells with job control)
    # Negative PID kills the entire process group
    kill -TERM -"$pid" 2>/dev/null || true
    
    # Second try: traverse the tree manually
    kill_tree "$pid" "TERM"
    
    # Brief pause for graceful shutdown
    sleep 0.3
    
    # Force kill pass: process group first, then tree
    kill -9 -"$pid" 2>/dev/null || true
    kill_tree "$pid" "9"
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
    
    # Kill cursor-agent processes associated with our workspace (session-specific)
    # These may have been orphaned and reparented to init
    if [ -n "$PROJECT_ROOT" ]; then
        log_debug "Killing session-specific orphaned processes..."
        pkill -9 -f "cursor-agent.*$PROJECT_ROOT" 2>/dev/null || true
        pkill -9 -f "node.*dist/entry/worker.*$PROJECT_ROOT" 2>/dev/null || true
        pkill -9 -f "script -q /dev/null.*cursor.*$PROJECT_ROOT" 2>/dev/null || true
    fi
    
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
    # Try process group first (most effective), then tree traversal
    if [ -n "$PIPELINE_PID" ]; then
        log_debug "Killing pipeline process group/tree (PID: $PIPELINE_PID)..."
        # Process group kill (negative PID)
        kill -TERM -"$PIPELINE_PID" 2>/dev/null || true
        kill_descendants "$PIPELINE_PID"
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
    
    # Kill session-specific orphaned processes (reparented to init)
    if [ -n "$PROJECT_ROOT" ]; then
        pkill -9 -f "cursor-agent.*$PROJECT_ROOT" 2>/dev/null || true
        pkill -9 -f "node.*dist/entry/worker.*$PROJECT_ROOT" 2>/dev/null || true
    fi
    
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
    
    jq -r "[.userStories[]? | $PRD_INCOMPLETE_STORY] | sort_by(.priority) | .[0].id // \"\"" "$prd_file" 2>/dev/null || true
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

# Get the appropriate model for a specific story ID
# Usage: model=$(get_model_for_story "$story_id")
# Returns:
#   - gpt-5.3-codex for US-REVIEW (first code review)
#   - gemini-3-pro for US-REVIEW-2 (second code review)
#   - opus-4.6 for all other stories (implementation)
get_model_for_story() {
    local story_id="$1"
    
    case "$story_id" in
        "US-REVIEW")
            echo "gpt-5.3-codex"
            ;;
        "US-REVIEW-2")
            echo "gemini-3-pro"
            ;;
        *)
            echo "opus-4.6"
            ;;
    esac
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
# GIT STASH: Stash/pop lazy-dev files (script + features) during branch switching
# ═══════════════════════════════════════════════════════════════════════════

# Global flag to track if we stashed lazy-dev files
LAZY_DEV_FILES_STASHED=0

# Stash changes in the entire lazy-dev directory before switching branches
# This includes the go.sh script itself, feature folders, rules, etc.
stash_lazy_dev_files() {
    local lazy_dev_dir="$1"
    local stash_message="lazy-dev-stash-$(date +%s)"
    
    # Check if there are any changes (tracked or untracked) in the lazy-dev directory
    local has_changes=0
    
    # Check for tracked changes in lazy-dev directory
    if git status --porcelain -- "$lazy_dev_dir" 2>/dev/null | grep -q .; then
        has_changes=1
    fi
    
    # Check for untracked files in the lazy-dev directory
    if [ -d "$lazy_dev_dir" ] && [ "$(ls -A "$lazy_dev_dir" 2>/dev/null)" ]; then
        # There are files in the lazy-dev directory
        if git status --porcelain -- "$lazy_dev_dir" 2>/dev/null | grep -q "^??"; then
            has_changes=1
        fi
    fi
    
    if [ "$has_changes" = "1" ]; then
        log_info "Stashing changes in lazy-dev folder: $lazy_dev_dir"
        # Stash including untracked files (-u) for the entire lazy-dev directory
        if git stash push -u -m "$stash_message" -- "$lazy_dev_dir" 2>/dev/null; then
            log_success "Lazy-dev folder changes stashed (including go.sh script)"
            LAZY_DEV_FILES_STASHED=1
            return 0
        else
            log_warn "Could not stash lazy-dev folder changes (they may not be tracked)"
            return 1
        fi
    else
        log_debug "No changes to stash in lazy-dev folder"
    fi
    
    return 1  # Nothing was stashed
}

# Pop the stashed lazy-dev files after branch setup
pop_lazy_dev_stash() {
    if [ "$LAZY_DEV_FILES_STASHED" = "1" ]; then
        log_info "Restoring stashed lazy-dev folder changes..."
        if git stash pop 2>/dev/null; then
            log_success "Lazy-dev folder changes restored"
            LAZY_DEV_FILES_STASHED=0
        else
            log_warn "Could not restore stashed changes automatically"
            log_info "You may need to run 'git stash pop' manually or resolve conflicts"
            log_info "Check stash with: git stash list"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# GIT BRANCH SETUP: Always branch from latest main
# ═══════════════════════════════════════════════════════════════════════════

setup_feature_branch() {
    local feature_name="$1"
    local branch_name="feature/$feature_name"
    
    # Verify we're in a git repository
    if ! git rev-parse --git-dir &>/dev/null; then
        log_error "Not a git repository. Please run from within a git project."
        exit 1
    fi
    
    # Get current branch
    local current_branch
    current_branch=$(git branch --show-current)
    
    # If already on the feature branch, just ensure we're up to date
    if [ "$current_branch" = "$branch_name" ]; then
        log_info "Already on branch: $branch_name"
        install_push_blocker
        return 0
    fi
    
    # Stash lazy-dev folder files (including go.sh script) BEFORE checking for other uncommitted changes
    # Note: || true prevents set -e from exiting when nothing needs to be stashed (return 1)
    stash_lazy_dev_files "$SCRIPT_DIR" || true
    
    # Check for uncommitted changes (excluding already-stashed lazy-dev folder)
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_error "You have uncommitted changes outside the lazy-dev folder."
        log_info "Please commit or stash them first."
        log_info "Run: git status"
        # Restore stashed lazy-dev files before exiting
        pop_lazy_dev_stash
        exit 1
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                      🌿 GIT BRANCH SETUP                                  ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Determine main branch name (main or master)
    local main_branch="main"
    if ! git show-ref --verify --quiet refs/heads/main; then
        if git show-ref --verify --quiet refs/heads/master; then
            main_branch="master"
        else
            log_error "Could not find 'main' or 'master' branch."
            pop_lazy_dev_stash
            exit 1
        fi
    fi
    
    log_info "Main branch detected: $main_branch"
    
    # Fetch latest from origin (if remote exists)
    if git remote | grep -q "origin"; then
        log_info "Fetching latest from origin..."
        git fetch origin "$main_branch" --quiet 2>/dev/null || log_warn "Could not fetch from origin (offline?)"
    fi
    
    # Switch to main branch
    log_info "Switching to $main_branch branch..."
    git checkout "$main_branch" --quiet
    
    # Pull latest changes (if remote exists)
    if git remote | grep -q "origin"; then
        log_info "Pulling latest changes..."
        git pull origin "$main_branch" --quiet 2>/dev/null || log_warn "Could not pull from origin (offline?)"
    fi
    
    # Check if feature branch already exists
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        log_warn "Branch '$branch_name' already exists."
        log_info "Switching to existing branch..."
        git checkout "$branch_name" --quiet
        
        # Optionally rebase on latest main
        log_info "Rebasing on latest $main_branch..."
        git rebase "$main_branch" --quiet 2>/dev/null || {
            log_warn "Rebase had conflicts. Aborting rebase."
            git rebase --abort 2>/dev/null || true
        }
    else
        # Create new feature branch from main
        log_info "Creating new branch: $branch_name"
        git checkout -b "$branch_name" --quiet
    fi
    
    log_success "Now on branch: $branch_name (based on latest $main_branch)"
    
    # Restore stashed lazy-dev folder files
    pop_lazy_dev_stash
    
    # Install push blocker
    install_push_blocker
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Git commit: ALLOWED                                                  ║"
    echo "║  ❌ Git push: BLOCKED (pre-push hook installed)                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

# Verify required files exist
verify_setup() {
    if [ ! -d "$FEATURE_DIR" ]; then
        log_error "Feature directory not found: $FEATURE_DIR"
        log_info "Create it with:"
        log_info "  mkdir -p $FEATURE_DIR"
        log_info "  cp $SCRIPT_DIR/examples/prd.json $FEATURE_DIR/"
        log_info "  cp $SCRIPT_DIR/examples/progress.txt $FEATURE_DIR/"
        exit 1
    fi

    if [ ! -f "$PRD_FILE" ]; then
        log_error "PRD file not found: $PRD_FILE"
        log_info "Copy from examples: cp $SCRIPT_DIR/examples/prd.json $FEATURE_DIR/"
        exit 1
    fi

    if [ ! -f "$PROMPT_FILE" ]; then
        log_error "Prompt file not found: $PROMPT_FILE"
        exit 1
    fi

    # Create discovered directory if it doesn't exist
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
    if ! command -v cursor-agent &> /dev/null; then
        log_debug "cursor-agent not found in PATH - will try 'cursor agent' instead"
        USE_CURSOR_AGENT_SUBCOMMAND=1
    else
        log_debug "Found cursor-agent CLI"
        USE_CURSOR_AGENT_SUBCOMMAND=0
    fi
}

# Archive previous run if branch changed
archive_previous_run() {
    if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
        CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
        LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

        if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
            DATE=$(date +%Y-%m-%d)
            FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^feature/||; s|^lazy/||; s|^dev/||; s|/|_|g')
            ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

            log_info "Archiving previous run: $LAST_BRANCH"
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

# Track current branch
track_branch() {
    if [ -f "$PRD_FILE" ]; then
        CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
        if [ -n "$CURRENT_BRANCH" ]; then
            echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
        fi
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
        sed -i '' "s/\$(date)/$(date)/" "$PROGRESS_FILE" 2>/dev/null || \
        sed -i "s/\$(date)/$(date)/" "$PROGRESS_FILE" 2>/dev/null || true
    fi
}

# Run a single agent iteration
run_iteration() {
    local iteration=$1
    local start_time=$(date +%s)
    # Reset the fast-fail input (main reads this after the call)
    LAST_ITERATION_DURATION=0
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Lazy Dev - Feature: $FEATURE_NAME"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Build prompt with feature context
    PROMPT_CONTENT=$(cat "$PROMPT_FILE")
    
    # Get current branch name
    CURRENT_GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    # Add feature-specific context with STRICT git policy
    # All paths are relative to project root (workspace)
    CONTEXT="
# Feature Context
- Feature: $FEATURE_NAME
- Workspace/Project Root: $PROJECT_ROOT
- PRD: .cursor/lazy-dev/features/$FEATURE_NAME/prd.json
- Progress: .cursor/lazy-dev/features/$FEATURE_NAME/progress.txt
- Shared discovered patterns: .cursor/lazy-dev/rules/discovered/ (READ these first - cross-feature learning)
- Git Branch: $CURRENT_GIT_BRANCH

# ⚠️ CRITICAL GIT POLICY - READ CAREFULLY ⚠️

## ALLOWED Git Operations:
- git add <files>
- git commit -m \"message\"
- git status
- git diff
- git log

## ❌ STRICTLY FORBIDDEN - NEVER USE:
- git push (ABSOLUTELY FORBIDDEN - DO NOT USE UNDER ANY CIRCUMSTANCES)
- git push origin <anything>
- git push --force
- Any variation of push command

The pre-push hook will block any push attempts. All work stays local.
When you need to save progress, use: git add . && git commit -m \"...\"

$PROMPT_CONTENT"

    # Build cursor-agent command with appropriate flags
    # -p / --print: Run in non-interactive (headless) mode
    # --force: Auto-approve all changes (YOLO mode always on)
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
    elif [ "${USE_CURSOR_AGENT_SUBCOMMAND:-0}" = "1" ]; then
        CURSOR_CMD="cursor"
        CURSOR_ARGS+=("agent")
    else
        CURSOR_CMD="cursor-agent"
    fi
    
    # Always run in headless mode with auto-approve and streaming output
    # Note: --stream-partial-output removed - it causes character-by-character output
    # that makes the parsed output unreadable
    # --workspace points to project root so agent can access the full codebase
    CURSOR_ARGS+=("-p" "--force" "--output-format" "stream-json" "--workspace" "$PROJECT_ROOT")

    # Select appropriate model based on the next story to be processed
    # - US-REVIEW: GPT 5.3 Codex (first code review)
    # - US-REVIEW-2: Gemini 3 Pro (second code review)
    # - All other stories: Opus 4.6 (implementation)
    local next_story_id
    next_story_id=$(get_next_story_id "$PRD_FILE")
    local selected_model
    selected_model=$(get_model_for_story "$next_story_id")
    
    if [ -n "$selected_model" ]; then
        CURSOR_ARGS+=("--model" "$selected_model")
        log_info "Story: ${BOLD}${next_story_id}${NC} → Model: ${BOLD}${selected_model}${NC}"
    fi

    local full_cmd="$CURSOR_CMD ${CURSOR_ARGS[*]} <prompt>"
    

    # Pre-flight check: ensure the command exists
    if ! command -v "$CURSOR_CMD" &> /dev/null; then
        log_error "Command not found: $CURSOR_CMD"
        log_error "Please ensure Cursor CLI is installed and in your PATH"
        return 1
    fi
    
    # Debug: show exact command being run (verbose mode only)
    log_debug "Executing: $CURSOR_CMD ${CURSOR_ARGS[*]} <...prompt...>"

    # Run cursor-agent with the prompt
    # Use the global OUTPUT_FILE (managed by main() trap) for raw output storage
    # Parse NDJSON stream through parse_agent_output for formatted display
    local exit_code=0
    
    # Clear output file for this iteration
    > "$OUTPUT_FILE"
    
    # Run command with NDJSON parsing for real-time formatted output
    # Raw JSON is saved to OUTPUT_FILE for completion signal detection
    # Parsed output is displayed to terminal
    log_debug "Starting agent with stream-json output"
    
    # Run pipeline in a subshell
    # NOTE: Removed set -m (job control) as it causes SIGTTOU when background
    # processes try to write to terminal, stopping the entire pipeline
    # Export VERBOSE so subshell's parse_agent_output can access it
    export VERBOSE
    (
        # Failure detection: make the subshell exit non-zero if ANY pipeline
        # stage fails (notably the agent itself). Without pipefail the status
        # would be parse_agent_output's (always 0), masking agent crashes.
        set -o pipefail
        # Create new process group for cleanup
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
    log_debug "Pipeline running in subshell (PID: $PIPELINE_PID)"
    log_debug "Iteration timeout: ${ITERATION_TIMEOUT}s (override with LAZY_DEV_TIMEOUT env var)"
    
    # Wait with timeout to prevent hung iterations
    # Use short sleep intervals (0.5s) for responsive Ctrl+C handling
    local wait_start=$(date +%s)
    local timed_out=0
    
    while kill -0 "$PIPELINE_PID" 2>/dev/null; do
        local elapsed=$(($(date +%s) - wait_start))
        if [ "$elapsed" -ge "$ITERATION_TIMEOUT" ]; then
            log_warn "Iteration timed out after ${ITERATION_TIMEOUT}s - killing process"
            timed_out=1
            # Kill the process group (negative PID kills the group)
            kill -TERM -"$PIPELINE_PID" 2>/dev/null || kill -TERM "$PIPELINE_PID" 2>/dev/null || true
            pkill -TERM -P "$PIPELINE_PID" 2>/dev/null || true
            sleep 1
            kill -9 -"$PIPELINE_PID" 2>/dev/null || kill -9 "$PIPELINE_PID" 2>/dev/null || true
            pkill -9 -P "$PIPELINE_PID" 2>/dev/null || true
            break
        fi
        # Check every 0.5 seconds for responsive Ctrl+C handling
        sleep 0.5
    done
    
    if [ "$timed_out" -eq 0 ]; then
        wait $PIPELINE_PID 2>/dev/null || exit_code=$?
    else
        exit_code=124  # Standard timeout exit code
    fi
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
    
    # Kill pipeline immediately (don't wait for cleanup)
    if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2>/dev/null; then
        # Kill the entire process group
        kill -TERM -"$PIPELINE_PID" 2>/dev/null || kill -TERM "$PIPELINE_PID" 2>/dev/null || true
        pkill -TERM -P "$PIPELINE_PID" 2>/dev/null || true
        sleep 0.3
        kill -9 -"$PIPELINE_PID" 2>/dev/null || kill -9 "$PIPELINE_PID" 2>/dev/null || true
        pkill -9 -P "$PIPELINE_PID" 2>/dev/null || true
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

    verify_setup
    
    # Log initial resource state for comparison (debug only)
    if [ "$VERBOSE" = "1" ]; then
        log_memory_usage
        log_process_count
    fi
    
    # CRITICAL: Setup git branch from latest main and block pushes
    setup_feature_branch "$FEATURE_NAME"
    
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
        
        # Run iteration with retry logic
        local retry_count=0
        local iteration_success=0
        
        while [ $retry_count -lt $MAX_RETRIES ]; do
            if run_iteration $iteration; then
                iteration_success=1
                break
            fi
            
            retry_count=$((retry_count + 1))
            
            # Fast-fail: a failed iteration that ended quickly is almost always
            # a config/auth/model error, not a transient one - do not retry it.
            # LAZY_DEV_FASTFAIL_SECS=0 disables fast-fail entirely.
            if [ "$FASTFAIL_SECS" -gt 0 ] && [ "${LAST_ITERATION_DURATION:-0}" -lt "$FASTFAIL_SECS" ]; then
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
            # Continue to next iteration anyway - the story might still be incomplete
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

        # Silently continue to next iteration
        iteration=$((iteration + 1))
        sleep 2
    done
}

# Only run main when executed directly (not when sourced for function tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
