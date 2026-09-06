#!/bin/bash
# Lazy Dev — Headless PRD Generation Script
# Usage: ./prd.sh [OPTIONS] [feature-name]
#
# Generates a structured Product Requirements Document (prd.json) and progress.txt
# inside ~/.lazy-dev/<project>/features/<feature-name>/ using cursor-agent headless mode.
# Streams formatted output without launching the interactive Cursor TUI.
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        GIT POLICY (runner-owned)                          ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  1. Fail fast if working tree is not clean at session start               ║
# ║  2. On main/master: prompt for branch name; otherwise stay on current     ║
# ║  3. PRD files live outside repo under ~/.lazy-dev/ (not committed)        ║
# ║  4. Agent does NOT run git commands                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Configuration
LAZY_DEV_HOME="${LAZY_DEV_HOME:-$HOME/.lazy-dev}"
CONFIG_FILE="$LAZY_DEV_HOME/config.env"
TIMEOUT_SECS="${LAZY_DEV_PRD_TIMEOUT:-900}" # 15 minutes default
STALL_TIMEOUT="${LAZY_DEV_STALL_TIMEOUT:-300}" # 5 minutes idle watchdog

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug()   { [ "$VERBOSE" = "1" ] && echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Global state
VERBOSE=""
FEATURE_NAME=""
JIRA_TASK_ID=""
FEATURE_DESC=""
FEATURE_NOTES=""
PROJECT_ROOT=""
PROJECT_SLUG=""
STATE_DIR=""
FEATURE_DIR=""
PRD_FILE=""
PROGRESS_FILE=""
BRANCH_NAME=""

OUTPUT_FILE=""
SPINNER_PID_FILE=""
SPINNER_PID=""
PIPELINE_PID=""
CAFFEINATE_PID=""

CURSOR_CMD=""
CURSOR_ARGS=()

# Spinner animation frames
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

start_spinner() {
    stop_spinner
    local message="${1:-Processing...}"
    (
        local i=0
        while true; do
            echo -ne "\r${CYAN}${SPINNER_FRAMES[$i]}${NC} ${DIM}${message}${NC} "
            i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    if [ -n "$SPINNER_PID_FILE" ]; then
        echo "$SPINNER_PID" >> "$SPINNER_PID_FILE"
    fi
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    SPINNER_PID=""
    if [ -n "$SPINNER_PID_FILE" ] && [ -f "$SPINNER_PID_FILE" ]; then
        while IFS= read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done < "$SPINNER_PID_FILE"
        > "$SPINNER_PID_FILE"
    fi
    printf '\r\033[K'
}

# Recursively kill process tree
kill_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]] && return 0
    [ "$pid" = "$$" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 0

    local children
    children=$(pgrep -P "$pid" 2>/dev/null)
    for child in $children; do
        kill_tree "$child" "$signal"
    done
    kill -"$signal" "$pid" 2>/dev/null || true
}

kill_descendants() {
    local pid="$1"
    [ -z "$pid" ] && return 0
    kill_tree "$pid" "TERM"
    sleep 0.2
    kill_tree "$pid" "9"
}

kill_pipeline_safely() {
    local pid="$1"
    local reason="${2:-unknown}"
    [ -z "$pid" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 0

    log_debug "Safely killing pipeline PID $pid (reason: $reason)"
    kill_descendants "$pid"
    local i=0
    while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.3
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        kill_descendants "$pid"
    fi
}

cleanup() {
    local exit_code=$?
    stop_spinner

    if [ -n "$CAFFEINATE_PID" ] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        kill "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    CAFFEINATE_PID=""

    if [ -n "$PIPELINE_PID" ]; then
        kill_descendants "$PIPELINE_PID"
    fi
    PIPELINE_PID=""

    if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE"
    fi
    if [ -n "$SPINNER_PID_FILE" ] && [ -f "$SPINNER_PID_FILE" ]; then
        rm -f "$SPINNER_PID_FILE"
    fi
}
trap cleanup EXIT INT TERM

safe_jq() {
    local filter="$1"
    local input="$2"
    echo "$input" | jq -r "try ($filter) catch \"\"" 2>/dev/null || echo ""
}

strip_ansi() {
    if command -v perl &> /dev/null; then
        perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r//g; s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g; s/^\^D//'
    else
        sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/^\^D//' | tr -d '\r\x00-\x08\x0B\x0C\x0E-\x1F'
    fi
}

print_line() {
    printf '\r\n'
    printf '%b\n' "$1"
}

# NDJSON stream formatter
parse_agent_output() {
    if ! command -v jq &> /dev/null; then
        cat
        return
    fi

    local thinking_started=0
    local assistant_streaming=0
    local result_failed=0

    while IFS= read -r line; do
        line=$(printf '%s' "$line" | strip_ansi)
        [ -z "$line" ] && continue

        local event_type
        event_type=$(safe_jq '.type // ""' "$line")
        [ -z "$event_type" ] && continue

        case "$event_type" in
            "system")
                local subtype
                subtype=$(safe_jq '.subtype // ""' "$line")
                if [ "$subtype" = "init" ]; then
                    local model session_id
                    model=$(safe_jq '.model // ""' "$line")
                    session_id=$(safe_jq '.session_id // ""' "$line")
                    session_id="${session_id:0:8}"
                    stop_spinner
                    print_line "${CYAN}[INIT]${NC} Session ${DIM}${session_id}${NC} — Model: ${BOLD}${model}${NC}"
                    start_spinner "Generating PRD..."
                elif [ "$VERBOSE" = "1" ]; then
                    stop_spinner
                    print_line "${DIM}[SYSTEM]${NC} subtype=$subtype"
                    start_spinner "Generating PRD..."
                fi
                ;;
            "thinking")
                local thinking_subtype thinking_text
                thinking_subtype=$(safe_jq '.subtype // ""' "$line")
                thinking_text=$(safe_jq '.text // .delta.text // ""' "$line")

                if [ -n "$thinking_text" ]; then
                    if [ "$thinking_started" != "1" ]; then
                        stop_spinner
                        thinking_started=1
                        printf '\r\n'
                        printf "${MAGENTA}💭 Thinking...${NC}\r\n"
                        printf "${DIM}"
                    fi
                    thinking_text="${thinking_text//$'\n'/$'\r\n'}"
                    printf '%s' "$thinking_text"
                elif [ "$thinking_subtype" = "completed" ]; then
                    if [ "$thinking_started" = "1" ]; then
                        printf "${NC}\r\n\r\n"
                        thinking_started=0
                    fi
                fi
                ;;
            "assistant")
                local content
                content=$(safe_jq '.delta.content // .message.content[0].text // .content // .text // ""' "$line")
                if [ -n "$content" ] && [ "$content" != "false" ] && [ "$content" != "true" ] && [ "$content" != "null" ]; then
                    content=$(printf '%s' "$content" | strip_ansi)
                    local trimmed="${content//[$'\t\r\n ']}"
                    if [ -n "$trimmed" ]; then
                        if [ "$thinking_started" = "1" ]; then
                            printf "${NC}\r\n\r\n"
                            thinking_started=0
                        fi
                        if [ "$assistant_streaming" != "1" ]; then
                            stop_spinner
                            assistant_streaming=1
                            printf '\r\n'
                            printf "${GREEN}▶${NC} "
                        fi
                        content="${content//$'\n'/$'\r\n'}"
                        printf '%s' "$content"
                    fi
                fi
                ;;
            "tool_call")
                continue
                ;;
            "result")
                if [ "$assistant_streaming" = "1" ]; then
                    printf "${NC}\r\n"
                    assistant_streaming=0
                fi
                stop_spinner

                local duration_ms is_error duration_s
                duration_ms=$(safe_jq '.duration_ms // 0' "$line")
                is_error=$(safe_jq '.is_error // false' "$line")
                [[ "$duration_ms" =~ ^[0-9]+$ ]] || duration_ms=0
                duration_s=$((duration_ms / 1000))

                if [ "$is_error" = "true" ]; then
                    result_failed=1
                    print_line "${RED}[RESULT]${NC} ${RED}Failed${NC} in ${duration_s}s"
                else
                    print_line "${GREEN}[RESULT]${NC} ${GREEN}Success${NC} in ${duration_s}s"
                fi
                ;;
            *)
                if [ "$VERBOSE" = "1" ]; then
                    stop_spinner
                    local truncated="${line:0:160}"
                    print_line "${DIM}[DEBUG]${NC} $truncated"
                    start_spinner "Generating PRD..."
                fi
                ;;
        esac
    done

    if [ "$thinking_started" = "1" ]; then
        printf "${NC}\r\n"
        thinking_started=0
    fi
    if [ "$assistant_streaming" = "1" ]; then
        printf "${NC}\r\n"
    fi
    stop_spinner
    printf '\r\n'

    [ "$result_failed" = "1" ] && return 1
    return 0
}

# Resolve cursor command
resolve_cursor_cmd() {
    if [ -n "${LAZY_DEV_FAKE_AGENT:-}" ]; then
        CURSOR_CMD="$LAZY_DEV_FAKE_AGENT"
        CURSOR_ARGS=()
        log_info "Using LAZY_DEV_FAKE_AGENT executable: $CURSOR_CMD"
        return 0
    fi
    if command -v cursor-agent &> /dev/null; then
        CURSOR_CMD="cursor-agent"
        CURSOR_ARGS=()
    elif command -v cursor &> /dev/null; then
        CURSOR_CMD="cursor"
        CURSOR_ARGS=("agent")
    else
        log_error "Cursor CLI not found. Install cursor-agent or the Cursor CLI."
        log_info "See: https://docs.cursor.com/cli"
        exit 1
    fi
}

check_auth() {
    if [ -n "${LAZY_DEV_FAKE_AGENT:-}" ]; then
        return 0
    fi
    if ! "$CURSOR_CMD" "${CURSOR_ARGS[@]}" status &> /dev/null; then
        log_error "Not authenticated with Cursor CLI."
        log_info "Run: $CURSOR_CMD ${CURSOR_ARGS[*]} login"
        exit 1
    fi
}

# Git helpers
project_slug_from_root() {
    local root="$1"
    basename "$root" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

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
    mkdir -p "$STATE_DIR/features"
    echo "$PROJECT_ROOT" > "$STATE_DIR/.project-root"
}

detect_main_branch() {
    if git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/main; then
        echo "main"
    elif git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/master; then
        echo "master"
    else
        echo ""
    fi
}

validate_branch_name() {
    local name="$1"
    [ -n "$name" ] || return 1
    git check-ref-format --branch "$name" 2>/dev/null
}

working_tree_is_dirty() {
    git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -q .
}

assert_clean_working_tree() {
    if [ "${LAZY_DEV_SKIP_DIRTY_CHECK:-0}" = "1" ]; then
        return 0
    fi
    if working_tree_is_dirty; then
        echo ""
        log_error "Working tree is not clean. Commit or stash changes before creating a PRD."
        git -C "$PROJECT_ROOT" status --short
        exit 1
    fi
}

setup_git_branch() {
    local current_branch main_branch default_branch suggested_branch branch_input
    current_branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
    main_branch=$(detect_main_branch)

    if [ -z "$current_branch" ]; then
        log_error "Detached HEAD state is not supported. Check out a branch first."
        exit 1
    fi

    if [ "${LAZY_DEV_SKIP_BRANCH_CHECK:-0}" = "1" ]; then
        BRANCH_NAME="${BRANCH_NAME:-$current_branch}"
        log_info "Skipping branch setup (test mode). Using branch: $BRANCH_NAME"
        return 0
    fi

    if [ -n "$main_branch" ] && [ "$current_branch" = "$main_branch" ]; then
        if [ -z "$BRANCH_NAME" ]; then
            if [ -n "$JIRA_TASK_ID" ]; then
                suggested_branch="feature/${JIRA_TASK_ID}_${FEATURE_NAME}"
            else
                suggested_branch="feature/${FEATURE_NAME}"
            fi

            echo ""
            echo "You are on $main_branch. Branch name for this feature:"
            read -r -p "Branch name [${suggested_branch}]: " branch_input || true
            BRANCH_NAME="${branch_input:-$suggested_branch}"
        fi

        if ! validate_branch_name "$BRANCH_NAME"; then
            log_error "Invalid branch name: '$BRANCH_NAME'"
            exit 1
        fi

        if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
            log_info "Branch '$BRANCH_NAME' exists — checking out"
            git -C "$PROJECT_ROOT" checkout "$BRANCH_NAME" --quiet
        else
            log_info "Creating branch: $BRANCH_NAME"
            git -C "$PROJECT_ROOT" checkout -b "$BRANCH_NAME" --quiet
        fi
        log_success "Now on branch: $BRANCH_NAME"
    else
        BRANCH_NAME="${BRANCH_NAME:-$current_branch}"
        log_info "Staying on branch: $BRANCH_NAME"
    fi
}

print_usage() {
    echo "Usage: ./prd.sh [OPTIONS] [feature-name]"
    echo ""
    echo "Options:"
    echo "  --feature, -f <name>    Feature name (kebab-case)"
    echo "  --jira, -j <id>         Jira task ID (e.g. MED-523)"
    echo "  --branch, -b <name>     Target branch name (skip prompt)"
    echo "  --desc, -d <text>       Feature description"
    echo "  --notes <text>          Additional technical notes or constraints"
    echo "  --verbose, -v           Enable debug output"
    echo "  --help, -h              Show this help message"
    echo ""
    echo "Creates prd.json and progress.txt under ~/.lazy-dev/<project>/features/<feature-name>/"
    echo "using headless cursor-agent with real-time stream formatting."
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --feature|-f)
            FEATURE_NAME="$2"
            shift 2
            ;;
        --jira|-j)
            JIRA_TASK_ID="$2"
            shift 2
            ;;
        --branch|-b)
            BRANCH_NAME="$2"
            shift 2
            ;;
        --desc|-d)
            FEATURE_DESC="$2"
            shift 2
            ;;
        --notes)
            FEATURE_NOTES="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE="1"
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            if [ -z "$FEATURE_NAME" ]; then
                FEATURE_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Preflight
if _git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    PROJECT_ROOT="$(cd "$_git_root" && pwd -P)"
else
    log_error "Not a git repository. Please run from within a git project."
    exit 1
fi
unset _git_root

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install it: brew install jq"
    exit 1
fi

resolve_cursor_cmd
check_auth
resolve_project_state_dir
assert_clean_working_tree

# Interactive collection if parameters missing
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Lazy Dev — Create Feature PRD (Headless)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

while [ -z "$FEATURE_NAME" ]; do
    read -r -p "Feature name (kebab-case, e.g. task-priority): " FEATURE_NAME || true
    FEATURE_NAME=$(echo "$FEATURE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/^-*//;s/-*$//')
    if [ -z "$FEATURE_NAME" ]; then
        log_warn "Feature name cannot be empty."
    fi
done

FEATURE_DIR="$STATE_DIR/features/$FEATURE_NAME"
PRD_FILE="$FEATURE_DIR/prd.json"
PROGRESS_FILE="$FEATURE_DIR/progress.txt"

if [ -f "$PRD_FILE" ]; then
    echo ""
    log_warn "Feature '$FEATURE_NAME' already exists ($PRD_FILE)."
    read -r -p "Overwrite existing PRD? [y/N]: " confirm_overwrite || true
    case "$confirm_overwrite" in
        y|Y|yes|YES)
            log_info "Proceeding with overwrite."
            ;;
        *)
            log_info "Aborted by user."
            exit 0
            ;;
    esac
fi

if [ -z "$JIRA_TASK_ID" ]; then
    read -r -p "Jira Task ID (optional, e.g. MED-523, Enter to skip): " JIRA_TASK_ID || true
    JIRA_TASK_ID=$(echo "$JIRA_TASK_ID" | tr -d '[:space:]')
fi

while [ -z "$FEATURE_DESC" ]; do
    read -r -p "Brief feature description & primary goals: " FEATURE_DESC || true
    if [ -z "$FEATURE_DESC" ]; then
        log_warn "Description cannot be empty."
    fi
done

if [ -z "$FEATURE_NOTES" ]; then
    read -r -p "Technical constraints, non-goals, or notes (optional, Enter to skip): " FEATURE_NOTES || true
fi

# Set up git branch
setup_git_branch

# Prepare directories
mkdir -p "$FEATURE_DIR"

# Select model: LAZY_DEV_MODEL_PRD > LAZY_DEV_MODEL_IMPL > opus-4.6
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
SELECTED_MODEL="${LAZY_DEV_MODEL_PRD:-${LAZY_DEV_MODEL_IMPL:-opus-4.6}}"

# Temp files for stream capture
OUTPUT_FILE=$(mktemp "/tmp/lazy-dev-prd-out.XXXXXX")
SPINNER_PID_FILE=$(mktemp "/tmp/lazy-dev-prd-spinner.XXXXXX")
> "$SPINNER_PID_FILE"

# Start caffeinate on macOS
if command -v caffeinate &> /dev/null && [[ "$OSTYPE" == darwin* ]]; then
    caffeinate -dimsu &
    CAFFEINATE_PID=$!
fi

# Build PRD generation prompt
PROMPT_CONTEXT="You are a Principal Product Manager and Principal Software Architect.
Your task is to generate a comprehensive, production-ready Product Requirements Document (PRD) for a new feature, and write it directly to:
${PRD_FILE}

Also create the initial progress file at:
${PROGRESS_FILE}

## Project Context
- Workspace / Project Root: ${PROJECT_ROOT}
- Lazy-dev State Directory: ${STATE_DIR}
- Feature Name: ${FEATURE_NAME}
- Jira Task ID: ${JIRA_TASK_ID:-none}
- Target Branch: ${BRANCH_NAME}
- Feature Summary: ${FEATURE_DESC}
- Additional Constraints / Notes: ${FEATURE_NOTES:-none}

## CRITICAL RULES FOR PRD GENERATION:

1. **Strict File Writing**:
   - Write the finalized JSON file directly to: \`${PRD_FILE}\`
   - Write the progress log file directly to: \`${PROGRESS_FILE}\`
   - **DO NOT** edit any files in the consumer git repository.
   - **DO NOT** run git commands (branch checkout has already been performed by the runner).

2. **User Story Decomposition**:
   - Break the feature into **2 to 7 atomic user stories**.
   - Each story must be small enough to complete in a single agent iteration (~15-30 minutes).
   - Order stories by dependency: foundational work first, dependent features later.
   - Each story must have 2 to 5 specific, verifiable acceptance criteria.
   - EVERY user story must include: \"Build/typecheck passes\" in its acceptanceCriteria.
   - UI stories must include: \"Verify in browser\" in its acceptanceCriteria.
   - Every story must have \`\"passes\": false\` and \`\"attempts\": 0\`.

3. **Story ID Convention**:
   - If Jira task is provided (${JIRA_TASK_ID:-}): use \`${JIRA_TASK_ID}-001\`, \`${JIRA_TASK_ID}-002\`, etc.
   - If no Jira task is provided: use \`US-001\`, \`US-002\`, etc.

4. **STRICTLY UNIQUE PRIORITIES**:
   - Every user story MUST have a strictly unique integer priority (1, 2, 3...). No duplicates!

5. **REQUIRED REVIEW STORIES**:
   Every PRD MUST include these three final user stories:
   - Priority 997: First code review story (\`${JIRA_TASK_ID:-US}-REVIEW\`), output findings to \`${FEATURE_DIR}/review-gpt.md\`
   - Priority 998: Second code review story (\`${JIRA_TASK_ID:-US}-REVIEW-2\`), output findings to \`${FEATURE_DIR}/review-gemini.md\`
   - Priority 999: Implementation of recommendations (\`${JIRA_TASK_ID:-US}-IMPL-RECS\`), reading both review files.

6. **DUAL-PERSPECTIVE REVIEW LOOP**:
   Before writing the file, conduct an internal dual-perspective review:
   - **Product Owner Review**: Validate business value, user benefit, clear non-goals, and unambiguous acceptance criteria.
   - **Fullstack Developer Review**: Validate technical feasibility, component decomposition, error handling, edge cases, and architectural alignment.
   Refine the stories and criteria to resolve all gaps identified in both reviews.

7. **PRD JSON Schema**:
\`\`\`json
{
  \"project\": \"$(basename "$PROJECT_ROOT")\",
  $([ -n "$JIRA_TASK_ID" ] && echo "\"jiraTaskId\": \"$JIRA_TASK_ID\",")
  \"branchName\": \"${BRANCH_NAME}\",
  \"description\": \"${FEATURE_DESC}\",
  \"userStories\": [
    {
      \"id\": \"${JIRA_TASK_ID:-US}-001\",
      \"title\": \"...\",
      \"description\": \"As a ..., I want ... so that ...\",
      \"acceptanceCriteria\": [
        \"Specific verifiable criterion 1\",
        \"Build/typecheck passes\"
      ],
      \"priority\": 1,
      \"passes\": false,
      \"attempts\": 0,
      \"notes\": \"...\"
    }
  ]
}
\`\`\`

8. **Initial progress.txt Format**:
\`\`\`markdown
# Progress Log

## Codebase Patterns

<!-- 
Consolidated patterns discovered during implementation.
Add REUSABLE patterns here - things that apply across the codebase.
Keep entries concise (1-2 lines each).
-->

---

## Session Log

<!-- 
Each iteration appends its progress here.
Do not modify previous entries.
-->
\`\`\`

Execute the review, write \`${PRD_FILE}\` and \`${PROGRESS_FILE}\`, and output a clear markdown summary of the created user stories."

# Build command flags
CURSOR_ARGS+=("-p" "--auto-review" "--output-format" "stream-json" "--workspace" "$PROJECT_ROOT")
if [ -n "$SELECTED_MODEL" ]; then
    CURSOR_ARGS+=("--model" "$SELECTED_MODEL")
fi

echo ""
log_info "Generating PRD for ${BOLD}${FEATURE_NAME}${NC} (model: ${BOLD}${SELECTED_MODEL}${NC})..."
echo ""

# Run pipeline in background subshell with unbuffering
export VERBOSE
(
    set -o pipefail
    if command -v stdbuf &> /dev/null; then
        stdbuf -oL -eL $CURSOR_CMD "${CURSOR_ARGS[@]}" "$PROMPT_CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
    elif command -v unbuffer &> /dev/null; then
        unbuffer $CURSOR_CMD "${CURSOR_ARGS[@]}" "$PROMPT_CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
    elif command -v script &> /dev/null && [[ "$OSTYPE" == darwin* ]]; then
        script -q /dev/null $CURSOR_CMD "${CURSOR_ARGS[@]}" "$PROMPT_CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
    else
        $CURSOR_CMD "${CURSOR_ARGS[@]}" "$PROMPT_CONTEXT" 2>&1 | tee "$OUTPUT_FILE" | parse_agent_output
    fi
) &
PIPELINE_PID=$!

# Watchdog loop
wait_start=$(date +%s)
last_output_size=0
last_output_change_time=$(date +%s)
timed_out=0
kill_reason=""

while kill -0 "$PIPELINE_PID" 2>/dev/null; do
    elapsed=$(($(date +%s) - wait_start))
    if [ "$elapsed" -ge "$TIMEOUT_SECS" ]; then
        log_warn "PRD generation timed out after ${TIMEOUT_SECS}s"
        timed_out=1
        kill_reason="timeout"
        break
    fi

    current_output_size=0
    if [ -f "$OUTPUT_FILE" ]; then
        current_output_size=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    fi

    if [ "$current_output_size" != "$last_output_size" ]; then
        last_output_size=$current_output_size
        last_output_change_time=$(date +%s)
    else
        stall_elapsed=$(($(date +%s) - last_output_change_time))
        if [ "$stall_elapsed" -ge "$STALL_TIMEOUT" ]; then
            log_warn "Stall detected (no output for ${stall_elapsed}s)"
            timed_out=1
            kill_reason="stall"
            break
        fi
    fi

    sleep 0.5
done

if [ "$timed_out" -eq 1 ]; then
    kill_pipeline_safely "$PIPELINE_PID" "$kill_reason"
    log_error "PRD generation aborted due to $kill_reason."
    exit 1
fi

wait "$PIPELINE_PID" 2>/dev/null || true
PIPELINE_PID=""

# Ensure initial progress.txt exists if agent omitted it
if [ ! -f "$PROGRESS_FILE" ]; then
    cat > "$PROGRESS_FILE" << 'PROGRESSEOF'
# Progress Log

## Codebase Patterns

<!-- 
Consolidated patterns discovered during implementation.
Add REUSABLE patterns here - things that apply across the codebase.
Keep entries concise (1-2 lines each).
-->

---

## Session Log

<!-- 
Each iteration appends its progress here.
Do not modify previous entries.
-->
PROGRESSEOF
fi

# Validate generated PRD
echo ""
echo "───────────────────────────────────────────────────────────────"
if [ ! -f "$PRD_FILE" ]; then
    log_error "PRD file was not created: $PRD_FILE"
    exit 1
fi

if ! jq empty "$PRD_FILE" 2>/dev/null; then
    log_error "Generated PRD is not valid JSON: $PRD_FILE"
    exit 1
fi

total_stories=$(jq '[.userStories[]?] | length' "$PRD_FILE" 2>/dev/null || echo "0")
if [ "$total_stories" -eq 0 ]; then
    log_error "Generated PRD contains no user stories: $PRD_FILE"
    exit 1
fi

# Check for duplicate priorities
dup_priorities=$(jq '[.userStories[]?.priority] | group_by(.) | map(select(length > 1)) | length' "$PRD_FILE" 2>/dev/null || echo "0")
if [ "$dup_priorities" -gt 0 ]; then
    log_warn "PRD has duplicate story priorities. Unique priorities are recommended."
fi

log_success "PRD generated successfully: ${BOLD}${FEATURE_NAME}${NC}"
echo ""
echo "Feature Details:"
echo "  Project:     $(jq -r '.project // "unknown"' "$PRD_FILE")"
echo "  Branch:      $(jq -r '.branchName // "unknown"' "$PRD_FILE")"
echo "  Description: $(jq -r '.description // "none"' "$PRD_FILE")"
echo "  PRD Path:    $PRD_FILE"
echo ""
echo "Generated User Stories ($total_stories total):"
echo "───────────────────────────────────────────────────────────────"
printf "  %-16s %-8s %s\n" "STORY ID" "PRIORITY" "TITLE"
printf "  %-16s %-8s %s\n" "────────" "────────" "─────"

while IFS=$'\t' read -r sid prio title; do
    printf "  %-16s %-8s %s\n" "$sid" "$prio" "$title"
done < <(jq -r '.userStories[]? | "\(.id)\t\(.priority)\t\(.title)"' "$PRD_FILE" 2>/dev/null)

echo "───────────────────────────────────────────────────────────────"
echo ""
log_info "To implement this feature, run 'lazydev' and choose option 2:"
echo "  lazydev"
echo "or run directly:"
echo "  lazy.sh $FEATURE_NAME"
echo ""
