#!/usr/bin/env bash
# Kannaktopus Scheduler - Job Runner (v8.15.0)
# Executes a scheduled job: lock acquisition, process group management,
# timeout enforcement, cost monitoring, and run metadata recording.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${SCRIPT_DIR}/store.sh"
source "${SCRIPT_DIR}/policy.sh"

ORCHESTRATE_SH="${PLUGIN_DIR}/scripts/orchestrate.sh"
LOCK_FILE="${RUNTIME_DIR}/orchestrate.lock"
COST_POLL_INTERVAL="${COST_POLL_INTERVAL:-15}"

# Polls to wait for metrics to appear before treating a cost-limited run as
# unaccounted. Metrics do not exist for the first moments of a run, so some
# slack is required; at the default poll interval this is ~60s.
SCHEDULER_COST_GRACE_POLLS="${SCHEDULER_COST_GRACE_POLLS:-4}"

# Metrics base for a job workspace. Both the runner (reader) and orchestrate's
# metrics-tracker (writer) must resolve to this same directory, or the cost
# ceiling silently measures a file nobody writes.
runner_metrics_base() {
    echo "${1}/.kannaktopus"
}

# Would orchestrate.sh accept this path as CLAUDE_OCTOPUS_WORKSPACE?
# validate_workspace_path() in lib/validation.sh requires a POSIX-absolute path
# under $HOME|/tmp|/var/tmp and rejects traversal, so a Windows drive path fails
# it. Answers conservatively: a "no" only costs us the workspace alignment,
# never the cost accounting.
runner_workspace_is_exportable() {
    local path="$1"
    [[ -n "$path" && "$path" != "null" ]] || return 1
    [[ "$path" != *".."* ]] || return 1
    # Allowlist rather than a metacharacter blocklist: being stricter than the
    # validator only costs us the workspace alignment, while being looser would
    # export a path orchestrate then rejects, aborting the job.
    [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$path" == /* ]] || return 1
    local prefix
    for prefix in "$HOME" "/tmp" "/var/tmp"; do
        [[ -n "$prefix" && "$path" == "$prefix"* ]] && return 0
    done
    return 1
}

# Run a job. Args: job_file
# Returns: 0 on success, 1 on failure
runner_execute() {
    local job_file="$1"
    local job_id run_id workflow prompt workspace timeout max_cost_per_run
    local start_time end_time exit_code=0 final_cost=0

    job_id=$(jq -r '.id' "$job_file")
    workflow=$(jq -r '.task.workflow' "$job_file")
    prompt=$(jq -r '.task.prompt' "$job_file")
    workspace=$(jq -r '.execution.workspace' "$job_file")
    timeout=$(jq -r '.execution.timeout_seconds // 3600' "$job_file")
    max_cost_per_run=$(jq -r '.budget.max_cost_usd_per_run // 0' "$job_file")

    start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    run_id="run-$(date +%Y%m%d-%H%M%S)-${job_id}"

    # Log directory for this job
    local job_log_dir="${LOGS_DIR}/${job_id}"
    mkdir -p "$job_log_dir"
    local log_file="${job_log_dir}/$(date +%Y-%m-%dT%H:%M:%S).log"

    # Record run start
    local run_data
    run_data=$(cat <<EOF
{"run_id":"${run_id}","job_id":"${job_id}","workflow":"${workflow}","status":"running","started_at":"${start_time}","ended_at":null,"exit_code":null,"cost_usd":0}
EOF
)
    save_run "$run_id" "$run_data"
    append_event "{\"event\":\"run_started\",\"run_id\":\"${run_id}\",\"job_id\":\"${job_id}\",\"timestamp\":\"${start_time}\"}"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting job: $job_id ($workflow)" >> "$log_file"

    # Acquire orchestrate lock (non-blocking)
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Could not acquire orchestrate lock (another job running)" >> "$log_file"
        runner_record_finish "$run_id" "$job_id" "$start_time" 1 0 "lock_failed"
        exec 200>&-
        return 1
    fi

    # Set up environment for the job
    export OCTOPUS_JOB_ID="$job_id"
    export OCTOPUS_RUN_ID="$run_id"
    export OCTOPUS_CODEX_SANDBOX="${OCTOPUS_CODEX_SANDBOX:-workspace-write}"
    if [[ "$max_cost_per_run" != "0" ]] && [[ "$max_cost_per_run" != "null" ]]; then
        export OCTOPUS_MAX_COST_USD="$max_cost_per_run"
    fi

    # Point the metrics writer at the same file the monitor loop reads.
    # METRICS_BASE wins over WORKSPACE_DIR in metrics-tracker.sh and is not
    # subject to workspace validation, so it holds on every platform and
    # regardless of CLAUDE_PLUGIN_DATA (which outranks CLAUDE_OCTOPUS_WORKSPACE
    # in orchestrate.sh and would otherwise redirect metrics silently).
    local metrics_base
    metrics_base=$(runner_metrics_base "$workspace")
    export METRICS_BASE="$metrics_base"
    mkdir -p "$metrics_base"

    # Align orchestrate's workspace too, but only when the path satisfies the
    # validator orchestrate applies to it (POSIX-absolute, under $HOME|/tmp|
    # /var/tmp). A Windows drive path is a legitimate scheduler workspace and
    # would be rejected there, aborting the job — so it is left unset and only
    # METRICS_BASE governs the cost ceiling.
    if runner_workspace_is_exportable "$workspace"; then
        export CLAUDE_OCTOPUS_WORKSPACE="$workspace"
    else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] NOTE: workspace not exportable to orchestrate (not under \$HOME|/tmp|/var/tmp); METRICS_BASE=${metrics_base} still governs cost accounting" >> "$log_file"
    fi

    # Spawn orchestrate.sh in its own process group via setsid
    local child_pid
    (
        cd "$workspace"
        setsid "$ORCHESTRATE_SH" "$workflow" "$prompt" >> "$log_file" 2>&1
    ) &
    child_pid=$!

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Spawned orchestrate.sh PID=$child_pid (PGID via setsid)" >> "$log_file"

    # Monitor loop: check timeout, cost, and kill switches
    local elapsed=0
    local poll_counter=0
    local unaccounted_polls=0
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        poll_counter=$((poll_counter + 1))

        # Timeout check
        if (( elapsed >= timeout )); then
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TIMEOUT: killing job after ${timeout}s" >> "$log_file"
            runner_kill_process_group "$child_pid"
            exit_code=124
            break
        fi

        # Kill switch check
        if [[ -f "${SWITCHES_DIR}/KILL_ALL" ]]; then
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] KILL_ALL switch detected, terminating" >> "$log_file"
            runner_kill_process_group "$child_pid"
            exit_code=130
            break
        fi

        # Cost polling (every COST_POLL_INTERVAL seconds)
        if (( poll_counter >= COST_POLL_INTERVAL )); then
            poll_counter=0

            local cost_now
            if cost_now=$(runner_get_current_cost "$workspace"); then
                final_cost="$cost_now"
                unaccounted_polls=0

                if [[ "$max_cost_per_run" != "0" ]] && [[ "$max_cost_per_run" != "null" ]]; then
                    local over
                    over=$(awk -v cost="$final_cost" -v limit="$max_cost_per_run" \
                        'BEGIN { print (cost + 0 >= limit + 0) ? "yes" : "no" }')
                    if [[ "$over" == "yes" ]]; then
                        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] COST LIMIT: \$${final_cost} >= \$${max_cost_per_run}" >> "$log_file"
                        runner_kill_process_group "$child_pid"
                        exit_code=125
                        break
                    fi
                fi
            elif [[ "$max_cost_per_run" != "0" ]] && [[ "$max_cost_per_run" != "null" ]]; then
                # Spend is unknown while a ceiling is in force. Tolerate it
                # briefly (metrics do not exist yet at startup), then fail
                # closed — a limit that cannot measure is not a limit.
                unaccounted_polls=$((unaccounted_polls + 1))
                echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: cost unaccounted (${unaccounted_polls}/${SCHEDULER_COST_GRACE_POLLS}) — no readable spend at $(runner_metrics_base "$workspace")/metrics-session.json while \$${max_cost_per_run} limit is in force" >> "$log_file"

                if (( unaccounted_polls >= SCHEDULER_COST_GRACE_POLLS )); then
                    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] COST UNACCOUNTED: killing job — spend could not be measured for ${unaccounted_polls} polls, so the \$${max_cost_per_run} ceiling cannot be enforced. Check that orchestrate writes metrics to $(runner_metrics_base "$workspace")" >> "$log_file"
                    runner_kill_process_group "$child_pid"
                    exit_code=126
                    break
                fi
            fi
        fi
    done

    # Collect exit code if process ended naturally
    if (( exit_code == 0 )); then
        wait "$child_pid" 2>/dev/null || exit_code=$?
    fi

    # Release lock
    flock -u 200
    exec 200>&-

    # Final cost reading. An unreadable figure is recorded as unaccounted
    # rather than as $0, so the daily ledger's shortfall stays visible.
    local cost_accounted=true
    if ! final_cost=$(runner_get_current_cost "$workspace"); then
        final_cost=0
        cost_accounted=false
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: final spend unaccounted — ledger will under-report this run" >> "$log_file"
    fi

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Job finished: exit_code=$exit_code, cost=\$${final_cost}, accounted=${cost_accounted}" >> "$log_file"

    # Determine status
    local status="completed"
    case $exit_code in
        0)   status="completed" ;;
        124) status="timeout" ;;
        125) status="cost_limit" ;;
        126) status="cost_unaccounted" ;;
        130) status="killed" ;;
        *)   status="failed" ;;
    esac

    runner_record_finish "$run_id" "$job_id" "$start_time" "$exit_code" "$final_cost" "$status" "$cost_accounted"

    # Clean up env
    unset OCTOPUS_JOB_ID OCTOPUS_RUN_ID

    return $exit_code
}

# Kill a process group
runner_kill_process_group() {
    local pid="$1"

    # Try SIGTERM first, then SIGKILL after 5s
    kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true

    wait "$pid" 2>/dev/null || true
}

# Read current cost from metrics-session.json in the job's metrics base.
# Prints the cost and returns 0 when the spend is genuinely known; prints
# nothing and returns 1 when it is UNKNOWN (file absent, empty, unparseable,
# or missing the field). The distinction is the fix: reporting 0 for an
# unreadable file is what let a broken metrics path read as "spent nothing".
runner_get_current_cost() {
    local workspace="$1"
    local metrics_file
    metrics_file="$(runner_metrics_base "$workspace")/metrics-session.json"

    [[ -s "$metrics_file" ]] || return 1

    local cost
    cost=$(jq -er '.totals.estimated_cost_usd' "$metrics_file" 2>/dev/null) || return 1
    [[ "$cost" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 1

    echo "$cost"
}

# Record run finish
runner_record_finish() {
    local run_id="$1" job_id="$2" start_time="$3" exit_code="$4" cost="$5" status="$6"
    local cost_accounted="${7:-true}"
    local end_time
    end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local run_data
    run_data=$(cat <<EOF
{"run_id":"${run_id}","job_id":"${job_id}","status":"${status}","started_at":"${start_time}","ended_at":"${end_time}","exit_code":${exit_code},"cost_usd":${cost},"cost_accounted":${cost_accounted}}
EOF
)
    save_run "$run_id" "$run_data"
    update_ledger "$cost" "$job_id"
    append_event "{\"event\":\"run_finished\",\"run_id\":\"${run_id}\",\"job_id\":\"${job_id}\",\"status\":\"${status}\",\"exit_code\":${exit_code},\"cost_usd\":${cost},\"cost_accounted\":${cost_accounted},\"timestamp\":\"${end_time}\"}"
}
