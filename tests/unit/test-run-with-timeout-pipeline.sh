#!/usr/bin/env bash
# Tests for run_with_timeout on shell-function arms (#127): a function that
# finishes must release the pipeline at once, not after the full timeout.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

log() { :; }
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo_stdin_fail() { cat; return 3; }
slow_fn() { cat >/dev/null; sleep 30; }

# 1. A finished function releases spawn_agent's pipeline shape at once
start=$(date +%s)
printf 'prompt-text' | run_with_timeout 20 echo_stdin_fail 2>/dev/null | tee "$TMP/raw" > "$TMP/out"
rc=${PIPESTATUS[1]}
took=$(( $(date +%s) - start ))
if (( took < 8 )); then
    pass "a finished function does not hold the pipeline for the timeout (${took}s)"
else
    fail "a finished function does not hold the pipeline for the timeout" "took ${took}s with a 20s timeout"
fi

# 2. The piped prompt reaches the function and its output and exit code come back
if [[ "$(cat "$TMP/out")" == "prompt-text" && "$rc" == 3 ]]; then
    pass "stdin, stdout and exit code pass through"
else
    fail "stdin, stdout and exit code pass through" "out='$(cat "$TMP/out")' rc=$rc"
fi

# 3. A function that outlives the timeout is still killed
start=$(date +%s)
printf 'x' | run_with_timeout 2 slow_fn 2>/dev/null | cat > /dev/null
rc=${PIPESTATUS[1]}
took=$(( $(date +%s) - start ))
if (( took < 15 )) && [[ "$rc" != 0 ]]; then
    pass "a function past the timeout is killed (${took}s, rc=$rc)"
else
    fail "a function past the timeout is killed" "took ${took}s rc=$rc"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "run-with-timeout-pipeline: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -gt 0 ]] && echo "FAILURES: $FAIL_COUNT" && exit 1
echo "All tests passed."
