#!/usr/bin/env bash
# Kannaktopus Scheduler - State Store (v8.15.0)
# JSON state read/write utilities reusing atomic_write pattern from state-manager.sh

set -euo pipefail

SCHEDULER_DIR="${HOME}/.kannaktopus/scheduler"
JOBS_DIR="${SCHEDULER_DIR}/jobs"
RUNS_DIR="${SCHEDULER_DIR}/runs"
RUNTIME_DIR="${SCHEDULER_DIR}/runtime"
LOGS_DIR="${SCHEDULER_DIR}/logs"
LEDGER_DIR="${SCHEDULER_DIR}/ledger"
SWITCHES_DIR="${SCHEDULER_DIR}/switches"

# Initialize scheduler directory structure
store_init() {
    # #87: `mkdir -m 700` fails outright on NTFS (Git Bash, WSL on /mnt/c).
    # Create plainly, then tighten where the filesystem allows it.
    mkdir -p "$JOBS_DIR" "$RUNS_DIR" "$RUNTIME_DIR" "$LOGS_DIR" \
             "$LEDGER_DIR" "$SWITCHES_DIR"
    chmod 700 "$SCHEDULER_DIR" "$JOBS_DIR" "$RUNS_DIR" "$RUNTIME_DIR" "$LOGS_DIR" \
              "$LEDGER_DIR" "$SWITCHES_DIR" 2>/dev/null || true

    # Initialize daily ledger if missing
    local today
    today=$(date +%Y-%m-%d)
    local daily_file="${LEDGER_DIR}/daily.json"
    if [[ ! -f "$daily_file" ]] || [[ "$(jq -r '.date // ""' "$daily_file" 2>/dev/null)" != "$today" ]]; then
        store_atomic_write "$daily_file" "{\"date\":\"$today\",\"total_cost_usd\":0,\"runs\":0}"
    fi
}

# Atomic write: temp file -> validate -> backup -> mv
store_atomic_write() {
    local target="$1"
    local content="$2"
    local temp_file="${target}.tmp.$$"

    echo "$content" > "$temp_file"

    if ! jq empty "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        echo "ERROR: invalid JSON, write aborted for $target" >&2
        return 1
    fi

    if [[ -f "$target" ]]; then
        cp "$target" "${target}.bak"
    fi

    mv "$temp_file" "$target"
}

# Load a job definition file, returns JSON on stdout
load_job() {
    local job_file="$1"
    if [[ ! -f "$job_file" ]]; then
        echo "ERROR: job file not found: $job_file" >&2
        return 1
    fi
    if ! jq empty "$job_file" 2>/dev/null; then
        echo "ERROR: invalid JSON in job file: $job_file" >&2
        return 1
    fi
    cat "$job_file"
}

# List all job files (raw pipe-delimited)
list_jobs() {
    local job_file
    for job_file in "$JOBS_DIR"/*.json; do
        [[ -f "$job_file" ]] || continue
        local id name enabled cron
        id=$(jq -r '.id // "unknown"' "$job_file")
        name=$(jq -r '.name // "Untitled"' "$job_file")
        enabled=$(jq -r '.enabled // false' "$job_file")
        cron=$(jq -r '.schedule.cron // "* * * * *"' "$job_file")
        echo "${id}|${name}|${enabled}|${cron}|${job_file}"
    done
}

# List jobs with last-run status for dashboard display
# Output: id|name|enabled|backend|cron|last_status|last_run_age|last_cost
list_jobs_rich() {
    local job_file
    for job_file in "$JOBS_DIR"/*.json; do
        [[ -f "$job_file" ]] || continue
        local id name enabled backend cron
        id=$(jq -r '.id // "unknown"' "$job_file")
        name=$(jq -r '.name // "Untitled"' "$job_file")
        enabled=$(jq -r '.enabled // false' "$job_file")
        backend=$(jq -r '.backend // "daemon"' "$job_file")
        cron=$(jq -r '.schedule.cron // "* * * * *"' "$job_file")

        # Find most recent run for this job
        local last_status="never" last_run_age="-" last_cost="-"
        local latest_run
        latest_run=$(ls -t "$RUNS_DIR"/run-*-"${id}".json 2>/dev/null | head -1)
        if [[ -n "$latest_run" && -f "$latest_run" ]]; then
            local exit_code started_at cost
            exit_code=$(jq -r '.exit_code // null' "$latest_run")
            started_at=$(jq -r '.started_at // ""' "$latest_run")
            cost=$(jq -r '.cost_usd // 0' "$latest_run")

            if [[ "$exit_code" == "0" ]]; then
                last_status="ok"
            elif [[ "$exit_code" == "null" ]]; then
                last_status="running"
            else
                last_status="fail(${exit_code})"
            fi

            if [[ -n "$started_at" ]]; then
                local started_epoch now_epoch age_secs
                started_epoch=$(date -d "$started_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || echo "0")
                now_epoch=$(date +%s)
                age_secs=$(( now_epoch - started_epoch ))
                if (( age_secs < 60 )); then
                    last_run_age="${age_secs}s ago"
                elif (( age_secs < 3600 )); then
                    last_run_age="$((age_secs / 60))m ago"
                elif (( age_secs < 86400 )); then
                    last_run_age="$((age_secs / 3600))h ago"
                else
                    last_run_age="$((age_secs / 86400))d ago"
                fi
            fi

            last_cost=$(awk -v c="$cost" 'BEGIN { printf "%.3f", c+0 }')
        fi

        echo "${id}|${name}|${enabled}|${backend}|${cron}|${last_status}|${last_run_age}|${last_cost}"
    done
}

# Save run metadata
save_run() {
    local run_id="$1"
    local data="$2"
    store_atomic_write "${RUNS_DIR}/${run_id}.json" "$data"
}

# Update the daily cost ledger
update_ledger() {
    local cost="$1"
    local job_id="$2"
    local daily_file="${LEDGER_DIR}/daily.json"
    local today
    today=$(date +%Y-%m-%d)

    # Reset ledger if date changed
    if [[ ! -f "$daily_file" ]] || [[ "$(jq -r '.date // ""' "$daily_file" 2>/dev/null)" != "$today" ]]; then
        store_atomic_write "$daily_file" "{\"date\":\"$today\",\"total_cost_usd\":0,\"runs\":0}"
    fi

    local updated
    updated=$(jq --arg cost "$cost" --arg job "$job_id" '
        .total_cost_usd = (.total_cost_usd + ($cost | tonumber)) |
        .runs = (.runs + 1) |
        .last_job = $job |
        .last_updated = (now | todate)
    ' "$daily_file")

    store_atomic_write "$daily_file" "$updated"
}

# Get current daily spend
get_daily_spend() {
    local daily_file="${LEDGER_DIR}/daily.json"
    local today
    today=$(date +%Y-%m-%d)

    if [[ ! -f "$daily_file" ]] || [[ "$(jq -r '.date // ""' "$daily_file" 2>/dev/null)" != "$today" ]]; then
        echo "0"
        return
    fi

    jq -r '.total_cost_usd // 0' "$daily_file"
}

# Append to event log
append_event() {
    local event_json="$1"
    local events_file="${LEDGER_DIR}/events.jsonl"
    echo "$event_json" >> "$events_file"
}

# Get recent runs for a job
get_job_runs() {
    local job_id="$1"
    local limit="${2:-10}"
    local run_file
    local count=0

    # List run files in reverse chronological order
    for run_file in $(ls -t "$RUNS_DIR"/run-*-"${job_id}".json 2>/dev/null); do
        [[ -f "$run_file" ]] || continue
        cat "$run_file"
        echo ""
        count=$((count + 1))
        (( count >= limit )) && break
    done
}
