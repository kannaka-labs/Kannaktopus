#!/bin/bash
# Test: Scheduler Lifecycle Integration
# Tests daemon start/stop, job add/list/remove, policy enforcement, and kill switches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Use a temporary scheduler directory to avoid polluting real state
export HOME="$(mktemp -d)"
SCHEDULER_DIR="${HOME}/.kannaktopus/scheduler"

# Source modules
source "${PROJECT_ROOT}/scripts/scheduler/store.sh"
source "${PROJECT_ROOT}/scripts/scheduler/cron.sh"
source "${PROJECT_ROOT}/scripts/scheduler/policy.sh"

echo "================================================================"
echo "  Scheduler Lifecycle - Integration Tests"
echo "================================================================"
echo ""
echo "Using temp HOME: $HOME"
echo ""

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

# --- Test: Store initialization ---
echo "--- Store Initialization ---"

store_init
if [[ -d "$JOBS_DIR" ]] && [[ -d "$RUNS_DIR" ]] && [[ -d "$RUNTIME_DIR" ]]; then
    pass "store_init creates directory structure"
else
    fail "store_init directory structure"
fi

if [[ -f "${LEDGER_DIR}/daily.json" ]]; then
    local_date=$(jq -r '.date' "${LEDGER_DIR}/daily.json")
    today=$(date +%Y-%m-%d)
    if [[ "$local_date" == "$today" ]]; then
        pass "Daily ledger initialized with today's date"
    else
        fail "Daily ledger date mismatch: $local_date != $today"
    fi
else
    fail "Daily ledger not created"
fi

# --- Test: Atomic write ---
echo ""
echo "--- Atomic Write ---"

test_file="${SCHEDULER_DIR}/test-atomic.json"
store_atomic_write "$test_file" '{"key":"value"}'
if [[ -f "$test_file" ]] && jq -e '.key == "value"' "$test_file" > /dev/null 2>&1; then
    pass "atomic_write creates valid JSON file"
else
    fail "atomic_write file creation"
fi

# Test invalid JSON rejection
if store_atomic_write "$test_file" 'not json' 2>/dev/null; then
    fail "atomic_write should reject invalid JSON"
else
    pass "atomic_write rejects invalid JSON"
fi

# --- Test: Job management ---
echo ""
echo "--- Job Management ---"

# Create a valid job file
VALID_JOB=$(cat <<'EOF'
{
  "id": "test-job",
  "name": "Test Job",
  "enabled": true,
  "schedule": {"cron": "0 2 * * *"},
  "task": {"workflow": "probe", "prompt": "Test research task"},
  "execution": {"workspace": "/tmp", "timeout_seconds": 60},
  "budget": {"max_cost_usd_per_run": 1.0, "max_cost_usd_per_day": 5.0},
  "security": {"sandbox": "workspace-write", "deny_flags": ["--dangerously-skip-permissions"]}
}
EOF
)

# Save job
store_atomic_write "${JOBS_DIR}/test-job.json" "$VALID_JOB"
if [[ -f "${JOBS_DIR}/test-job.json" ]]; then
    pass "Job file saved to jobs directory"
else
    fail "Job file not saved"
fi

# List jobs
job_list=$(list_jobs)
if echo "$job_list" | grep -q "test-job"; then
    pass "list_jobs finds saved job"
else
    fail "list_jobs doesn't find saved job"
fi

# Load job
loaded=$(load_job "${JOBS_DIR}/test-job.json")
loaded_id=$(echo "$loaded" | jq -r '.id')
if [[ "$loaded_id" == "test-job" ]]; then
    pass "load_job returns correct data"
else
    fail "load_job returned wrong id: $loaded_id"
fi

# --- Test: Policy checks ---
echo ""
echo "--- Policy Checks ---"

# Valid job should pass
result=$(policy_check "${JOBS_DIR}/test-job.json" 2>/dev/null)
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "true" ]]; then
    pass "Valid job passes policy check"
else
    fail "Valid job rejected by policy: $result"
fi

# Invalid workflow should fail
BAD_WORKFLOW=$(echo "$VALID_JOB" | jq '.task.workflow = "evil-command"')
bad_wf_file="${SCHEDULER_DIR}/bad-workflow.json"
store_atomic_write "$bad_wf_file" "$BAD_WORKFLOW"
result=$(policy_check "$bad_wf_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Invalid workflow rejected by policy"
else
    fail "Invalid workflow not rejected"
fi

# Path traversal should fail
BAD_PATH=$(echo "$VALID_JOB" | jq '.execution.workspace = "/tmp/../etc"')
bad_path_file="${SCHEDULER_DIR}/bad-path.json"
store_atomic_write "$bad_path_file" "$BAD_PATH"
result=$(policy_check "$bad_path_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Path traversal rejected by policy"
else
    fail "Path traversal not rejected"
fi

# Root workspace should fail
BAD_ROOT=$(echo "$VALID_JOB" | jq '.execution.workspace = "/"')
bad_root_file="${SCHEDULER_DIR}/bad-root.json"
store_atomic_write "$bad_root_file" "$BAD_ROOT"
result=$(policy_check "$bad_root_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Root workspace rejected by policy"
else
    fail "Root workspace not rejected"
fi

# Windows drive-qualified workspace must not be rejected as non-absolute
WIN_PATH=$(echo "$VALID_JOB" | jq '.execution.workspace = "C:\\Users\\runner\\project"')
win_path_file="${SCHEDULER_DIR}/win-path.json"
store_atomic_write "$win_path_file" "$WIN_PATH"
result=$(policy_check "$win_path_file" 2>/dev/null) || true
reason=$(echo "$result" | jq -r '.reason // ""')
if [[ "$reason" == *"must be an absolute path"* ]]; then
    fail "Windows workspace path rejected as non-absolute: $result"
else
    pass "Windows workspace path treated as absolute"
fi

# A Windows workspace that really exists must be admitted outright
if command -v cygpath > /dev/null 2>&1; then
    win_real=$(cygpath -w "$HOME")
    WIN_REAL=$(echo "$VALID_JOB" | jq --arg w "$win_real" '.execution.workspace = $w')
    win_real_file="${SCHEDULER_DIR}/win-real.json"
    store_atomic_write "$win_real_file" "$WIN_REAL"
    result=$(policy_check "$win_real_file" 2>/dev/null) || true
    allowed=$(echo "$result" | jq -r '.allowed')
    if [[ "$allowed" == "true" ]]; then
        pass "Existing Windows workspace passes policy"
    else
        fail "Existing Windows workspace rejected: $result"
    fi
fi

# Traversal must still be caught inside a Windows path
WIN_TRAVERSAL=$(echo "$VALID_JOB" | jq '.execution.workspace = "C:\\Users\\runner\\..\\Windows"')
win_trav_file="${SCHEDULER_DIR}/win-traversal.json"
store_atomic_write "$win_trav_file" "$WIN_TRAVERSAL"
result=$(policy_check "$win_trav_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Windows path traversal rejected by policy"
else
    fail "Windows path traversal not rejected"
fi

# Windows drive root is a root path, same as /
WIN_ROOT=$(echo "$VALID_JOB" | jq '.execution.workspace = "C:\\"')
win_root_file="${SCHEDULER_DIR}/win-root.json"
store_atomic_write "$win_root_file" "$WIN_ROOT"
result=$(policy_check "$win_root_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Windows drive root rejected by policy"
else
    fail "Windows drive root not rejected"
fi

# Relative paths must still be rejected
REL_PATH=$(echo "$VALID_JOB" | jq '.execution.workspace = "relative/project"')
rel_path_file="${SCHEDULER_DIR}/rel-path.json"
store_atomic_write "$rel_path_file" "$REL_PATH"
result=$(policy_check "$rel_path_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Relative workspace rejected by policy"
else
    fail "Relative workspace not rejected"
fi

# Dangerous flag in prompt should fail
BAD_FLAG=$(echo "$VALID_JOB" | jq '.task.prompt = "run with --dangerously-skip-permissions"')
bad_flag_file="${SCHEDULER_DIR}/bad-flag.json"
store_atomic_write "$bad_flag_file" "$BAD_FLAG"
result=$(policy_check "$bad_flag_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Dangerous flag in prompt rejected by policy"
else
    fail "Dangerous flag in prompt not rejected"
fi

# --- Test: Cron weekday domain ---
echo ""
echo "--- Cron Weekday 7 (Sunday) ---"

# date +%u reports Sunday as 7; a cron expression may write Sunday as 0 or 7
check_wday() {
    local desc="$1" expr="$2" wday="$3" expect="$4"
    local got
    if cron_matches "$expr" 0 2 15 2 "$wday" 2>/dev/null; then got=yes; else got=no; fi
    if [[ "$got" == "$expect" ]]; then
        pass "$desc ($expr @ wday=$wday)"
    else
        fail "$desc ($expr @ wday=$wday gave $got, expected $expect)"
    fi
}

check_wday "weekday 7 fires on Sunday"          "0 2 * * 7"     7 yes
check_wday "weekday 7 silent on Monday"         "0 2 * * 7"     1 no
check_wday "weekday 0 still fires on Sunday"    "0 2 * * 0"     7 yes
check_wday "list 1,7 fires on Sunday"           "0 2 * * 1,7"   7 yes
check_wday "list 1,7 fires on Monday"           "0 2 * * 1,7"   1 yes
check_wday "list 1,7 silent on Tuesday"         "0 2 * * 1,7"   2 no
check_wday "range 1-7 fires on Sunday"          "0 2 * * 1-7"   7 yes
check_wday "range 0-7 fires on Sunday"          "0 2 * * 0-7"   7 yes
check_wday "range 1-5 silent on Sunday"         "0 2 * * 1-5"   7 no

# The number after a "/" is a step count, not a weekday, and must survive intact
check_wday "step 1-7/2 fires on Sunday"         "0 2 * * 1-7/2" 7 yes
check_wday "step 1-7/2 silent on Tuesday"       "0 2 * * 1-7/2" 2 no
check_wday "step 2-7/3 skips Sunday"            "0 2 * * 2-7/3" 7 no
check_wday "step 2-7/3 fires on Tuesday"        "0 2 * * 2-7/3" 2 yes

if cron_matches "*/7 * * * *" 7 2 15 2 3 2>/dev/null; then
    pass "step */7 in minute field unaffected by weekday normalization"
else
    fail "step */7 in minute field broken by weekday normalization"
fi

# --- Test: Kill switches ---
echo ""
echo "--- Kill Switches ---"

# KILL_ALL should block
touch "${SWITCHES_DIR}/KILL_ALL"
result=$(policy_check "${JOBS_DIR}/test-job.json" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    reason=$(echo "$result" | jq -r '.reason')
    if echo "$reason" | grep -q "KILL_ALL"; then
        pass "KILL_ALL switch blocks jobs"
    else
        fail "KILL_ALL switch wrong reason: $reason"
    fi
else
    fail "KILL_ALL switch not blocking"
fi
rm -f "${SWITCHES_DIR}/KILL_ALL"

# PAUSE_ALL should block
touch "${SWITCHES_DIR}/PAUSE_ALL"
result=$(policy_check "${JOBS_DIR}/test-job.json" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "PAUSE_ALL switch blocks jobs"
else
    fail "PAUSE_ALL switch not blocking"
fi
rm -f "${SWITCHES_DIR}/PAUSE_ALL"

# After removing switches, should pass again
result=$(policy_check "${JOBS_DIR}/test-job.json" 2>/dev/null)
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "true" ]]; then
    pass "Jobs allowed after removing kill switches"
else
    fail "Jobs still blocked after removing switches"
fi

# --- Test: Ledger tracking ---
echo ""
echo "--- Ledger Tracking ---"

update_ledger "1.50" "test-job"
daily_spend=$(get_daily_spend)
if [[ "$daily_spend" == "1.5" ]]; then
    pass "Ledger tracks cost correctly (\$1.50)"
else
    fail "Ledger cost wrong: $daily_spend (expected 1.5)"
fi

update_ledger "0.75" "test-job"
daily_spend=$(get_daily_spend)
if awk -v s="$daily_spend" 'BEGIN { exit (s + 0 >= 2.2 && s + 0 <= 2.3) ? 0 : 1 }'; then
    pass "Ledger accumulates costs (\$2.25)"
else
    fail "Ledger accumulation wrong: $daily_spend (expected ~2.25)"
fi

# Budget admission with exceeded limit
BUDGET_JOB=$(echo "$VALID_JOB" | jq '.budget.max_cost_usd_per_day = 2.0')
budget_file="${SCHEDULER_DIR}/budget-job.json"
store_atomic_write "$budget_file" "$BUDGET_JOB"
result=$(policy_check "$budget_file" 2>/dev/null) || true
allowed=$(echo "$result" | jq -r '.allowed')
if [[ "$allowed" == "false" ]]; then
    pass "Budget admission rejects when daily limit exceeded"
else
    fail "Budget admission should reject (spent \$2.25, limit \$2.00)"
fi

# --- Test: Event log ---
echo ""
echo "--- Event Log ---"

append_event '{"event":"test","timestamp":"2026-02-16T00:00:00Z"}'
if [[ -f "${LEDGER_DIR}/events.jsonl" ]] && grep -q '"event":"test"' "${LEDGER_DIR}/events.jsonl"; then
    pass "Event appended to events.jsonl"
else
    fail "Event not found in events.jsonl"
fi

# --- Test: Run metadata ---
echo ""
echo "--- Run Metadata ---"

save_run "run-20260216-020000-test-job" '{"run_id":"run-20260216-020000-test-job","job_id":"test-job","status":"completed","exit_code":0,"cost_usd":0.5}'
if [[ -f "${RUNS_DIR}/run-20260216-020000-test-job.json" ]]; then
    run_status=$(jq -r '.status' "${RUNS_DIR}/run-20260216-020000-test-job.json")
    if [[ "$run_status" == "completed" ]]; then
        pass "Run metadata saved correctly"
    else
        fail "Run metadata wrong status: $run_status"
    fi
else
    fail "Run metadata file not created"
fi

# --- Cost accounting must fail closed (issue #77) ---
echo ""
echo "--- Cost Accounting (fail-closed) ---"

# Pull in the cost reader and the workspace-export guard without executing the
# module (runner.sh needs flock/setsid, which are absent on some dev hosts).
eval "$(sed -n '/^runner_metrics_base()/,/^}/p'            "${PROJECT_ROOT}/scripts/scheduler/runner.sh")"
eval "$(sed -n '/^runner_workspace_is_exportable()/,/^}/p' "${PROJECT_ROOT}/scripts/scheduler/runner.sh")"
eval "$(sed -n '/^runner_get_current_cost()/,/^}/p'        "${PROJECT_ROOT}/scripts/scheduler/runner.sh")"

COST_WS="${HOME}/costprobe"

# A genuinely-zero reading must stay readable — it is not the same as "unknown".
mkdir -p "${COST_WS}/zero/.kannaktopus"
printf '{"totals":{"estimated_cost_usd":0}}\n' > "${COST_WS}/zero/.kannaktopus/metrics-session.json"
if cost=$(runner_get_current_cost "${COST_WS}/zero") && [[ "$cost" == "0" ]]; then
    pass "Cost reader reports a genuine \$0 as known"
else
    fail "Cost reader failed on a genuine zero reading (got '${cost:-}')"
fi

mkdir -p "${COST_WS}/real/.kannaktopus"
printf '{"totals":{"estimated_cost_usd":12.34}}\n' > "${COST_WS}/real/.kannaktopus/metrics-session.json"
if cost=$(runner_get_current_cost "${COST_WS}/real") && [[ "$cost" == "12.34" ]]; then
    pass "Cost reader reports a real spend"
else
    fail "Cost reader wrong on real spend (got '${cost:-}')"
fi

# Every unreadable shape must be UNKNOWN, never \$0 — returning 0 here is what
# let a misdirected metrics path spend past its ceiling unnoticed.
mkdir -p "${COST_WS}/absent"
mkdir -p "${COST_WS}/empty/.kannaktopus";   : > "${COST_WS}/empty/.kannaktopus/metrics-session.json"
mkdir -p "${COST_WS}/garbage/.kannaktopus"; printf 'not json' > "${COST_WS}/garbage/.kannaktopus/metrics-session.json"
mkdir -p "${COST_WS}/nofield/.kannaktopus"; printf '{"totals":{}}\n' > "${COST_WS}/nofield/.kannaktopus/metrics-session.json"
unknown_ok=true
for shape in absent empty garbage nofield; do
    if runner_get_current_cost "${COST_WS}/${shape}" >/dev/null 2>&1; then
        fail "Cost reader treated '${shape}' metrics as a known cost (fails open)"
        unknown_ok=false
    fi
done
[[ "$unknown_ok" == true ]] && pass "Cost reader reports absent/empty/garbage/no-field metrics as unknown"

# The export guard must never hand orchestrate a path its own validator rejects
# (lib/validation.sh requires POSIX-absolute under \$HOME|/tmp|/var/tmp).
if runner_workspace_is_exportable "${HOME}/jobspace" && runner_workspace_is_exportable "/tmp/jobspace"; then
    pass "Workspace export guard accepts safe POSIX workspaces"
else
    fail "Workspace export guard rejected a safe workspace"
fi

guard_ok=true
for bad in 'C:\Users\nickf\jobspace' "/etc/passwd" "${HOME}/../evil" "${HOME}/a b" "${HOME}/a;rm"; do
    if runner_workspace_is_exportable "$bad"; then
        fail "Workspace export guard would export an unsafe path: $bad"
        guard_ok=false
    fi
done
[[ "$guard_ok" == true ]] && pass "Workspace export guard withholds drive/traversal/outside/metachar paths"

# --- Declared sandbox must be honoured or refused, never downgraded (issue #83) ---
echo ""
echo "--- Sandbox (fail-closed) ---"

eval "$(grep -E '^RUNNER_(ALLOWED_SANDBOXES|DEFAULT_SANDBOX)=' "${PROJECT_ROOT}/scripts/scheduler/runner.sh")"
eval "$(sed -n '/^runner_resolve_sandbox()/,/^}/p' "${PROJECT_ROOT}/scripts/scheduler/runner.sh")"

# Without this the "unsupported values are refused" assertion below passes for
# the wrong reason: a missing function also returns non-zero.
if declare -F runner_resolve_sandbox > /dev/null; then
    pass "runner_resolve_sandbox is defined"
else
    fail "runner_resolve_sandbox is not defined — sandbox is unenforced"
fi

SBX_DIR="${SCHEDULER_DIR}/sandboxprobe"; mkdir -p "$SBX_DIR"
sbx_job() { # $1 = sandbox value, or empty for "declares nothing"
    local f="${SBX_DIR}/job-${2}.json"
    if [[ -n "$1" ]]; then
        echo "$VALID_JOB" | jq --arg s "$1" '.security.sandbox = $s' > "$f"
    else
        echo "$VALID_JOB" | jq 'del(.security.sandbox)' > "$f"
    fi
    echo "$f"
}

# Each supported mode must survive to the child unchanged.
sbx_ok=true
for mode in workspace-write write read-only; do
    got=$(runner_resolve_sandbox "$(sbx_job "$mode" "$mode")") || got="<refused>"
    [[ "$got" == "$mode" ]] || { fail "Declared sandbox '$mode' resolved to '$got'"; sbx_ok=false; }
done
[[ "$sbx_ok" == true ]] && pass "Declared sandbox modes resolve unchanged"

# Declaring nothing is not a failed declaration — it takes the documented default.
got=$(runner_resolve_sandbox "$(sbx_job "" none)") || got="<refused>"
if [[ "$got" == "workspace-write" ]]; then
    pass "Undeclared sandbox falls back to the documented default"
else
    fail "Undeclared sandbox resolved to '$got' (expected workspace-write)"
fi

# An unsupported value must refuse, never silently widen to a permissive mode.
refuse_ok=true
for bad in yolo-full-access read_only "" ; do
    [[ -z "$bad" ]] && continue
    if got=$(runner_resolve_sandbox "$(sbx_job "$bad" "bad")"); then
        fail "Unsupported sandbox '$bad' was accepted as '$got' instead of refused"
        refuse_ok=false
    fi
done
[[ "$refuse_ok" == true ]] && pass "Unsupported sandbox values are refused, not downgraded"

# And admission should catch it at `add` time rather than at run time.
# NB: read `.allowed` directly — jq's `//` falls through on `false` as well as
# `null`, so `.allowed // "true"` would turn a correct rejection into "true".
result=$(policy_check_security "$(sbx_job "yolo-full-access" "policy")" 2>/dev/null) || true
if [[ "$(echo "$result" | jq -r '.allowed' 2>/dev/null)" == "false" ]]; then
    pass "Policy rejects an invalid security.sandbox at admission"
else
    fail "Policy admitted an invalid security.sandbox: $result"
fi

result=$(policy_check_security "$(sbx_job "read-only" "policyok")" 2>/dev/null) || true
if [[ -z "$result" ]]; then
    pass "Policy admits a valid security.sandbox"
else
    fail "Policy rejected a valid security.sandbox: $result"
fi

# --- Cleanup ---
echo ""
echo "Cleaning up temp HOME: $HOME"
rm -rf "$HOME"

# --- Summary ---
echo ""
echo "================================================================"
echo "  Test Results Summary"
echo "================================================================"
echo ""
echo "Total Tests: $((PASSED + FAILED))"
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"

exit $([[ $FAILED -eq 0 ]] && echo 0 || echo 1)
