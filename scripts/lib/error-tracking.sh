#!/usr/bin/env bash
# error-tracking.sh — Extracted from orchestrate.sh
# Functions: record_error, update_task_progress, get_active_form_verb

# ═══════════════════════════════════════════════════════════════════════════════
# UX ENHANCEMENTS: Feature 1 - Enhanced Spinner Verbs (v7.16.0)
# Dynamic task progress updates with context-aware verbs
# ═══════════════════════════════════════════════════════════════════════════════

# Update Claude Code task progress with activeForm
update_task_progress() {
    local task_id="$1"
    local active_form="$2"

    # Skip if task progress disabled or missing parameters
    if [[ "$TASK_PROGRESS_ENABLED" != "true" ]]; then
        log DEBUG "Task progress disabled - skipping update"
        return 0
    fi

    if [[ -z "$task_id" || -z "$active_form" ]]; then
        log DEBUG "Missing task_id or active_form - skipping update"
        return 0
    fi

    if [[ -z "${CLAUDE_CODE_CONTROL_PIPE:-}" ]]; then
        log DEBUG "CLAUDE_CODE_CONTROL_PIPE not set - skipping update"
        return 0
    fi

    if [[ ! -p "$CLAUDE_CODE_CONTROL_PIPE" ]]; then
        log WARN "CLAUDE_CODE_CONTROL_PIPE is not a pipe: $CLAUDE_CODE_CONTROL_PIPE"
        return 1
    fi

    # Strip newlines from fields so a message stays a single line
    local safe_id="${task_id//[$'\n\r']/ }"
    local safe_form="${active_form//[$'\n\r']/ }"
    local line="TASK_UPDATE:${safe_id}:activeForm:${safe_form}"

    # Write to control pipe for Claude Code to update spinner.
    # Opening a FIFO with no reader blocks forever, so bound the write
    # (timeout, gtimeout on macOS, or a background write killed after 2s).
    local timeout_cmd="" rc=0
    command -v timeout >/dev/null 2>&1 && timeout_cmd=timeout
    [[ -z "$timeout_cmd" ]] && command -v gtimeout >/dev/null 2>&1 && timeout_cmd=gtimeout
    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" 2 bash -c 'printf "%s\n" "$1" >> "$2"' _ "$line" "$CLAUDE_CODE_CONTROL_PIPE" 2>/dev/null || rc=$?
    else
        ( printf '%s\n' "$line" >> "$CLAUDE_CODE_CONTROL_PIPE" ) 2>/dev/null &
        local writer=$! i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$writer" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$writer" 2>/dev/null; then
            kill "$writer" 2>/dev/null; rc=124
        fi
        wait "$writer" 2>/dev/null || { [[ $rc -eq 0 ]] && rc=1; }
    fi
    if [[ $rc -ne 0 ]]; then
        log WARN "Failed to write to control pipe"
        return 1
    fi

    log DEBUG "Updated task $task_id: $active_form"
    return 0
}

# Get context-aware activeForm verb for agent + phase combination
get_active_form_verb() {
    local phase="$1"
    local agent="$2"
    local prompt_context="${3:-}"  # Optional: for even more specific verbs

    # Normalize phase name (aliases to canonical names)
    case "$phase" in
        probe) phase="discover" ;;
        grasp) phase="define" ;;
        tangle) phase="develop" ;;
        ink) phase="deliver" ;;
    esac

    # Normalize agent name (remove version suffixes)
    local agent_base
    agent_base=$(echo "$agent" | sed 's/-[0-9].*$//' | sed 's/:.*//')

    # Generate phase/agent-specific verb with emoji indicators
    local verb=""
    case "$phase" in
        discover)
            case "$agent_base" in
                codex*) verb="🔴 Researching technical patterns (Codex)" ;;
                gemini*) verb="🟡 Exploring ecosystem and options (Gemini)" ;;
                claude*) verb="🔵 Synthesizing research findings" ;;
                *) verb="🔍 Researching and exploring" ;;
            esac
            ;;
        define)
            case "$agent_base" in
                codex*) verb="🔴 Analyzing technical requirements (Codex)" ;;
                gemini*) verb="🟡 Clarifying scope and constraints (Gemini)" ;;
                claude*) verb="🔵 Building consensus on approach" ;;
                *) verb="🎯 Defining requirements" ;;
            esac
            ;;
        develop)
            case "$agent_base" in
                codex*) verb="🔴 Generating implementation code (Codex)" ;;
                gemini*) verb="🟡 Exploring alternative approaches (Gemini)" ;;
                claude*) verb="🔵 Integrating and validating solution" ;;
                *) verb="🛠️  Developing implementation" ;;
            esac
            ;;
        deliver)
            case "$agent_base" in
                codex*) verb="🔴 Analyzing code quality (Codex)" ;;
                gemini*) verb="🟡 Testing edge cases and security (Gemini)" ;;
                claude*) verb="🔵 Final review and recommendations" ;;
                *) verb="✅ Validating and testing" ;;
            esac
            ;;
        *)
            verb="Processing with $agent"
            ;;
    esac

    echo "$verb"
}

# ═══════════════════════════════════════════════════════════════════════════════
# v8.19.0 FEATURE: ERROR LEARNING LOOP (Veritas-inspired)
# Structured error capture with similar-error detection and repeat flagging.
# ═══════════════════════════════════════════════════════════════════════════════

record_error() {
    local agent="$1"
    local task="$2"
    local error_msg="$3"
    local exit_code="${4:-1}"
    local attempt_desc="${5:-}"

    local error_dir="${WORKSPACE_DIR}/.octo/errors"
    local error_file="$error_dir/error-log.md"
    mkdir -p "$error_dir"

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Sanitize error message (truncate, remove control chars)
    local safe_error="${error_msg:0:500}"
    safe_error=$(echo "$safe_error" | tr -d '\000-\011\013-\037')

    # Hold a lock around count, trim and append (flock, or mkdir fallback).
    # Hidden names so the lock never looks like a log or temp file.
    local lock_file="$error_dir/.error-log.lock" lock_dir="$error_dir/.error-log.lockdir"
    local use_flock="" rc=0
    if command -v flock >/dev/null 2>&1; then
        use_flock=1
        exec 9>"$lock_file"
        flock 9
    else
        # The holder stamps the lock; only a lock older than 10s (a killed
        # holder) is broken, so a slow live writer keeps it
        local lock_ts
        while ! mkdir "$lock_dir" 2>/dev/null; do
            lock_ts=$(cat "$lock_dir/ts" 2>/dev/null) || lock_ts=""
            if [[ "$lock_ts" =~ ^[0-9]+$ ]] && (( $(date +%s) - lock_ts > 10 )); then
                rm -rf "$lock_dir" 2>/dev/null || true
            fi
            sleep 0.05
        done
        date +%s > "$lock_dir/ts" 2>/dev/null || true
    fi

    # Trim and append inside a subshell-free block whose status we keep, so
    # the lock is released on every path below
    {
        # Cap at 100 entries: count existing, trim oldest if needed
        if [[ -f "$error_file" ]]; then
            local entry_count
            entry_count=$(grep -c "^### ERROR |" "$error_file" 2>/dev/null) || entry_count=0
            if [[ "$entry_count" -ge 100 ]]; then
                # Remove first entry (everything up to second ### ERROR)
                local second_entry_line
                second_entry_line=$(grep -n "^### ERROR |" "$error_file" | sed -n '2p' | cut -d: -f1)
                if [[ -n "$second_entry_line" ]]; then
                    local tmp_file
                    tmp_file=$(mktemp "${error_file}.XXXX") &&
                    # Copy back rather than mv, so the log keeps its own permissions
                    tail -n +"$second_entry_line" "$error_file" > "$tmp_file" &&
                    cat "$tmp_file" > "$error_file"
                    rm -f "${tmp_file:-}"
                fi
            fi
        fi

        cat >> "$error_file" << ERREOF

### ERROR | $timestamp | agent: $agent | exit_code: $exit_code
**Task:** ${task:0:200}
**Error:** $safe_error
**Attempt:** ${attempt_desc:-Initial attempt}
**Root Cause:** Pending analysis
**Prevention:** Pending
---
ERREOF
    } || rc=$?

    if [[ -n "$use_flock" ]]; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
    else
        rm -rf "$lock_dir" 2>/dev/null || true
    fi

    [[ $rc -eq 0 ]] || return "$rc"
    log DEBUG "Recorded error: agent=$agent, exit_code=$exit_code"
}
