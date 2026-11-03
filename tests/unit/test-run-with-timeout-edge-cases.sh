#!/usr/bin/env bash
# Tests for run_with_timeout / heartbeat edge cases (#166):
#  2. SIGKILL escalation when a timed-out command ignores SIGTERM
#  4. start_heartbeat_monitor must not hold a $(...) pipe open
#  5. TIMEOUT banner only when the timeout actually fired
#  6. non-numeric timeout values are validated, not fed to $(( ))
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

log() { :; }
SUPPORTS_MEMORY_LEAK_FIXES=false
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"

TMP=$(mktemp -d)
WORKSPACE_DIR="$TMP/ws"
trap 'rm -rf "$TMP"' EXIT

# --- #2: SIGKILL escalation -------------------------------------------------
start=$SECONDS
run_with_timeout 1 bash -c 'trap "" TERM; sleep 20' >/dev/null 2>&1
rc=$?
took=$((SECONDS - start))
if (( took < 14 )) && [[ $rc -eq 124 ]]; then
    pass "binary path: TERM-ignoring command is KILLed (${took}s, rc=$rc)"
else
    fail "binary path: TERM-ignoring command is KILLed" "took ${took}s rc=$rc"
fi

term_ignoring_fn() {
    trap "" TERM
    sleep 20
}
start=$SECONDS
run_with_timeout 1 term_ignoring_fn >/dev/null 2>&1
rc=$?
took=$((SECONDS - start))
if (( took < 14 )) && [[ $rc -eq 124 ]]; then
    pass "watchdog path: TERM-ignoring function is KILLed (${took}s, rc=$rc)"
else
    fail "watchdog path: TERM-ignoring function is KILLed" "took ${took}s rc=$rc"
fi

# --- #4: heartbeat loop detached from caller's stdout -----------------------
start=$SECONDS
x=$( (sleep 1) & p=$!; start_heartbeat_monitor "$p" t; echo "$p" )
took=$((SECONDS - start))
if (( took < 5 )); then
    pass "start_heartbeat_monitor does not hold \$(...) open (${took}s)"
else
    fail "start_heartbeat_monitor does not hold \$(...) open" "took ${took}s"
fi

# --- #5: banner only on a real timeout --------------------------------------
err=$(run_with_timeout 30 bash -c 'kill -TERM $$' 2>&1 >/dev/null); rc=$?
if [[ $rc -eq 143 && "$err" != *"TIMEOUT EXCEEDED"* ]]; then
    pass "self-SIGTERM: no banner, rc=143"
else
    fail "self-SIGTERM: no banner, rc=143" "rc=$rc err='$err'"
fi

self_term_fn() {
    bash -c 'kill -TERM $$'
}
err=$(run_with_timeout 30 self_term_fn 2>&1 >/dev/null); rc=$?
if [[ $rc -eq 143 && "$err" != *"TIMEOUT EXCEEDED"* ]]; then
    pass "watchdog path self-SIGTERM: no banner, rc=143"
else
    fail "watchdog path self-SIGTERM: no banner, rc=143" "rc=$rc err='$err'"
fi

err=$(run_with_timeout 30 bash -c 'exit 124' 2>&1 >/dev/null); rc=$?
if [[ $rc -eq 124 && "$err" != *"TIMEOUT EXCEEDED"* ]]; then
    pass "command exiting 124 by itself: no banner, rc=124"
else
    fail "command exiting 124 by itself: no banner, rc=124" "rc=$rc err='$err'"
fi

err=$(run_with_timeout 1 bash -c 'sleep 20' 2>&1 >/dev/null); rc=$?
if [[ $rc -eq 124 && "$err" == *"TIMEOUT EXCEEDED"* ]]; then
    pass "a real timeout still prints the banner and returns 124"
else
    fail "a real timeout still prints the banner and returns 124" "rc=$rc"
fi

# --- #6: timeout validation -------------------------------------------------
out=$(OCTOPUS_AGENT_TIMEOUT=5m compute_dynamic_timeout 2>/dev/null)
if [[ $out =~ ^[0-9]+$ ]]; then
    pass "compute_dynamic_timeout sanitises OCTOPUS_AGENT_TIMEOUT=5m ($out)"
else
    fail "compute_dynamic_timeout sanitises OCTOPUS_AGENT_TIMEOUT=5m" "got '$out'"
fi

out=$(run_with_timeout 5m bash -c 'exit 124' >/dev/null 2>&1; echo "rc=$?")
if [[ "$out" == "rc=124" ]]; then
    pass "run_with_timeout 5m survives and reaches the caller (rc=124)"
else
    fail "run_with_timeout 5m survives and reaches the caller" "got '$out'"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "run-with-timeout-edge-cases: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -gt 0 ]] && echo "FAILURES: $FAIL_COUNT" && exit 1
echo "All tests passed."

