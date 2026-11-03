#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# lib/heartbeat.sh — Heartbeat monitoring, dynamic timeouts, portable timeout
# Extracted from orchestrate.sh (v8.19.0 heartbeat + v7.16.0 timeout)
# ═══════════════════════════════════════════════════════════════════════════════

start_heartbeat_monitor() {
    local pid="$1"
    local task_id="$2"

    local heartbeat_dir="${WORKSPACE_DIR}/.octo/agents"
    mkdir -p "$heartbeat_dir"
    local heartbeat_file="$heartbeat_dir/${pid}.heartbeat"

    # Background process: touch heartbeat every 30s, self-terminate when PID dies
    (
        while kill -0 "$pid" 2>/dev/null; do
            touch "$heartbeat_file"
            sleep 30
        done
        rm -f "$heartbeat_file"
    ) </dev/null >/dev/null 2>&1 &
    disown

    log DEBUG "Heartbeat monitor started for PID $pid (task: $task_id)"
}

check_agent_heartbeat() {
    local pid="$1"

    local heartbeat_file="${WORKSPACE_DIR}/.octo/agents/${pid}.heartbeat"

    if [[ ! -f "$heartbeat_file" ]]; then
        echo "missing"
        return
    fi

    # Get file modification time (macOS vs Linux compatible)
    local mod_time
    if stat -f %m "$heartbeat_file" &>/dev/null; then
        # macOS
        mod_time=$(stat -f %m "$heartbeat_file")
    else
        # Linux
        mod_time=$(stat -c %Y "$heartbeat_file")
    fi

    local now
    now=$(date +%s)
    local age=$((now - mod_time))

    if [[ $age -gt 90 ]]; then
        echo "stale"
    else
        echo "alive"
    fi
}

compute_dynamic_timeout() {
    local task_type="${1:-standard}"
    local prompt="${2:-}"
    local agent_type="${3:-}"  # v9.2.0: optional provider for per-provider caps

    # Env override takes precedence
    if [[ -n "${OCTOPUS_AGENT_TIMEOUT:-}" ]]; then
        local env_timeout="$OCTOPUS_AGENT_TIMEOUT"
        if ! [[ $env_timeout =~ ^[0-9]+$ ]]; then
            log WARN "invalid timeout '$env_timeout', using 120"
            env_timeout=120
        fi
        echo "$env_timeout"
        return
    fi

    # v9.2.0: Provider-specific timeout caps (OctoBench data)
    # Codex: consistently 120-183s, cap at 150s for probe tasks
    # Gemini: consistently 34-113s, cap at 90s for probe tasks
    # Claude-sonnet: consistently 35-46s, cap at 60s for probe tasks
    local provider_cap=""
    case "$agent_type" in
        codex*)     provider_cap=150 ;;
        gemini*)    provider_cap=90 ;;
        claude-sonnet*|sonnet*) provider_cap=60 ;;
        perplexity*) provider_cap=45 ;;
    esac

    # Response mode mapping
    local response_mode="${OCTOPUS_RESPONSE_MODE:-auto}"
    case "$response_mode" in
        direct|lightweight)
            echo "60"
            return
            ;;
    esac

    # v8.40.0: When CC has memory leak fixes (v2.1.63+), long sessions are stable —
    # allow longer timeouts for complex tasks since agent sessions won't degrade
    local leak_safe_boost=0
    if [[ "$SUPPORTS_MEMORY_LEAK_FIXES" == "true" ]]; then
        leak_safe_boost=60
    fi

    # Task type mapping
    case "$task_type" in
        direct|lightweight|trivial)
            echo "60"
            ;;
        full|premium|complex)
            echo "$((300 + leak_safe_boost))"
            ;;
        crossfire|debate)
            echo "$((180 + leak_safe_boost))"
            ;;
        security|audit)
            echo "$((240 + leak_safe_boost))"
            ;;
        *)
            local base_timeout=$((120 + leak_safe_boost))
            # Apply provider cap if set and lower than task-based timeout
            if [[ -n "$provider_cap" && "$provider_cap" -lt "$base_timeout" ]]; then
                echo "$provider_cap"
            else
                echo "$base_timeout"
            fi
            ;;
    esac
}

cleanup_heartbeat() {
    local pid="$1"
    rm -f "${WORKSPACE_DIR}/.octo/agents/${pid}.heartbeat"
}

# Start a watchdog that sends TERM to $1 (a pid, or -pgid for a process
# group) after $2 seconds, then KILL 10s later if it is still there (a target
# that traps TERM must not hang the caller). When it fires it writes into the
# (already created) marker file $3, so callers can tell a real timeout from a command that
# merely died of SIGTERM. Its pid is left in REPLY. It runs off the caller's
# pipes: a sleep still holding the pipeline's stdout kept
# `run_with_timeout … | tee` open for the full timeout after the command had
# finished (#127). Killing the watchdog also kills its sleep.
_run_with_timeout_watchdog() {
    local target="$1" secs="$2" marker="${3:-}"
    (
        sleep_pid=""
        trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null; exit 0' TERM
        sleep "$secs" &
        sleep_pid=$!
        if wait "$sleep_pid"; then
            [[ -n "$marker" ]] && echo 1 > "$marker"
            kill -TERM -- "$target" 2>/dev/null
            sleep 10 &
            sleep_pid=$!
            wait "$sleep_pid" && kill -KILL -- "$target" 2>/dev/null
        fi
        exit 0
    ) </dev/null >/dev/null 2>&1 &
    REPLY=$!
}

# Portable timeout function (works on macOS and Linux)
# Prefers system timeout commands, falls back to manual implementation
run_with_timeout() {
    local timeout_secs="$1"
    shift

    if ! [[ $timeout_secs =~ ^[0-9]+$ ]]; then
        log WARN "invalid timeout '$timeout_secs', using 120"
        timeout_secs=120
    fi

    local exit_code timed_out=false marker="" t0=$SECONDS

    # A shell function (openrouter_execute, openrouter_execute_model,
    # perplexity_execute) cannot be exec'd by an external timeout binary:
    # `timeout 600 openrouter_execute_model …` fails with 127 wherever
    # coreutils is installed, which is every Linux box and Git Bash on
    # Windows. Those arms only ever worked on hosts WITHOUT timeout. Run
    # functions through the in-shell fallback instead.
    if declare -F "$1" &>/dev/null; then
        local fn_pid fn_monitor_pid had_job_control=false
        [[ $- == *m* ]] && had_job_control=true
        # `<&0` keeps the caller's stdin (the piped prompt): a plain
        # background job in a non-interactive shell gets /dev/null instead.
        # Job control puts the function in its own process group, so the
        # timeout also kills the curl it is waiting on; killing only the
        # function's subshell left curl holding the pipeline open (#127).
        set -m
        "$@" <&0 &
        fn_pid=$!
        [[ "$had_job_control" == true ]] || set +m
        marker=$(mktemp "${TMPDIR:-/tmp}/octo-timeout.XXXXXX" 2>/dev/null) || marker=""
        _run_with_timeout_watchdog "-$fn_pid" "$timeout_secs" "$marker"
        fn_monitor_pid=$REPLY
        if wait "$fn_pid" 2>/dev/null; then
            exit_code=0
        else
            exit_code=$?
        fi
        kill "$fn_monitor_pid" 2>/dev/null
        wait "$fn_monitor_pid" 2>/dev/null
    # Use gtimeout (GNU) or timeout if available
    elif command -v gtimeout &>/dev/null; then
        gtimeout -k 10 "$timeout_secs" "$@"
        exit_code=$?
    elif command -v timeout &>/dev/null; then
        timeout -k 10 "$timeout_secs" "$@"
        exit_code=$?
    else
        # Fallback with proper cleanup
        local cmd_pid monitor_pid

        "$@" &
        cmd_pid=$!

        marker=$(mktemp "${TMPDIR:-/tmp}/octo-timeout.XXXXXX" 2>/dev/null) || marker=""
        _run_with_timeout_watchdog "$cmd_pid" "$timeout_secs" "$marker"
        monitor_pid=$REPLY

        if wait "$cmd_pid" 2>/dev/null; then
            exit_code=0
        else
            exit_code=$?
        fi

        # Clean up monitor process
        kill "$monitor_pid" 2>/dev/null
        wait "$monitor_pid" 2>/dev/null
    fi

    # Enhanced timeout error messaging (v7.16.0 Feature 3)
    if [[ -n "$marker" ]]; then
        # Watchdog paths: the watchdog wrote the marker when it fired
        [[ -s "$marker" ]] && timed_out=true
        rm -f "$marker"
    elif [[ $exit_code -eq 124 || $exit_code -eq 137 ]] && (( SECONDS - t0 >= timeout_secs )); then
        # timeout binary: 124/137 only counts when the time really ran out, not
        # when the command exited 124 itself or was SIGKILLed early (OOM)
        timed_out=true
    fi
    if [[ "$timed_out" == true ]]; then
        local timeout_mins=$((timeout_secs / 60))
        local recommended_timeout=$((timeout_secs * 2))
        local recommended_mins=$((recommended_timeout / 60))

        log ERROR "Operation timed out after ${timeout_secs}s (${timeout_mins}m)"
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "⚠️  TIMEOUT EXCEEDED" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "" >&2
        echo "Operation exceeded the ${timeout_secs}s (${timeout_mins}m) timeout limit." >&2
        echo "" >&2
        echo "💡 Possible solutions:" >&2
        echo "   1. Increase timeout: --timeout ${recommended_timeout} (${recommended_mins}m)" >&2
        echo "   2. Simplify the prompt to reduce processing time" >&2
        echo "   3. Check provider API status for slowness" >&2
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        return 124
    fi

    return $exit_code
}
