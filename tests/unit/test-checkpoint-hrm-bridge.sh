#!/usr/bin/env bash
# Tests for save_session_checkpoint -> kannaka-bridge.sh (#104)
# Phase checkpoints must reach Kannaka HRM through scripts/kannaka-bridge.sh,
# not only the legacy claude-mem bridge, and a missing or failing HRM bridge
# must never fail the phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSION_LIB="$PROJECT_ROOT/scripts/lib/session.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available (save_session_checkpoint is a no-op without it)"
    exit 0
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
tr -d '\r' < "$SESSION_LIB" > "$TMP_ROOT/session.sh"

# Run save_session_checkpoint in a subshell with a stub kannaka-bridge.sh that
# answers `available` with $1 and exits $2 on `absorb`, recording its args.
# Echoes the function's exit status.
run_checkpoint() {
    local available="$1" absorb_rc="$2" case_dir="$TMP_ROOT/$3"
    mkdir -p "$case_dir/scripts"
    cat > "$case_dir/scripts/kannaka-bridge.sh" <<STUB
#!/usr/bin/env bash
case "\$1" in
    available) echo "$available" ;;
    absorb) shift; printf '%s\n' "\$@" > "$case_dir/absorb.args"; exit $absorb_rc ;;
esac
STUB
    # Deliberately NOT executable: the call must not depend on the mode bit,
    # which kannaka-bridge.sh does not carry in git.
    chmod -x "$case_dir/scripts/kannaka-bridge.sh"
    echo '{"workflow":"embrace","phases":{}}' > "$case_dir/session.json"
    local rc=0
    (
        set -euo pipefail
        SCRIPT_DIR="$case_dir/scripts"
        WORKSPACE_DIR="$case_dir"
        SESSION_FILE="$case_dir/session.json"
        log() { :; }
        set_current_workflow() { :; }
        update_metrics() { :; }
        write_state_md() { :; }
        # shellcheck source=/dev/null
        source "$TMP_ROOT/session.sh"
        save_session_checkpoint "probe" "completed" "/tmp/probe-out.md"
        wait
    ) || rc=$?
    echo "$rc"
}

rc=$(run_checkpoint true 0 ok)
if [[ "$rc" -eq 0 ]]; then pass "checkpoint succeeds with HRM available"; else fail "checkpoint succeeds with HRM available" "exit $rc"; fi
if [[ -f "$TMP_ROOT/ok/absorb.args" ]]; then
    pass "checkpoint is absorbed into HRM via kannaka-bridge.sh"
    args=$(cat "$TMP_ROOT/ok/absorb.args")
    if grep -q "Octopus probe phase completed" <<<"$args" && grep -q "Workflow: embrace" <<<"$args"; then
        pass "absorbed text names phase, status and workflow"
    else
        fail "absorbed text names phase, status and workflow" "$args"
    fi
    if grep -qx "phase:probe" <<<"$args" && grep -qx "workflow:embrace" <<<"$args"; then
        pass "absorb is tagged with phase and workflow"
    else
        fail "absorb is tagged with phase and workflow" "$args"
    fi
else
    fail "checkpoint is absorbed into HRM via kannaka-bridge.sh" "bridge absorb was never called"
fi

phase=$(jq -r '.phases.probe.status' "$TMP_ROOT/ok/session.json")
if [[ "$phase" == "completed" ]]; then pass "session.json checkpoint still written"; else fail "session.json checkpoint still written" "got '$phase'"; fi

rc=$(run_checkpoint false 0 unavailable)
if [[ "$rc" -eq 0 ]]; then pass "checkpoint succeeds with HRM unavailable"; else fail "checkpoint succeeds with HRM unavailable" "exit $rc"; fi
if [[ ! -f "$TMP_ROOT/unavailable/absorb.args" ]]; then pass "no absorb when HRM is unavailable"; else fail "no absorb when HRM is unavailable" "absorb was called"; fi

rc=$(run_checkpoint true 1 failing)
if [[ "$rc" -eq 0 ]]; then pass "a failing HRM absorb does not fail the phase"; else fail "a failing HRM absorb does not fail the phase" "exit $rc"; fi

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ "$FAIL_COUNT" -eq 0 ]]
