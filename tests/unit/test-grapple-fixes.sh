#!/usr/bin/env bash
# Tests for grapple fixes: #136 (prompt word-split), #139 (result filename
# collision), #133 debate.sh part (run_agent_sync failure under set -e).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$PROJECT_ROOT/scripts/orchestrate.sh"
LIB="$PROJECT_ROOT/scripts/lib/debate.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Harness: runs a snippet under bash -e with debate.sh sourced (CRLF tolerant)
# and the orchestrator-provided globals/stubs it needs.
run_harness() {
    local snippet="$1"
    local prelude
    prelude='RED=""; GREEN=""; YELLOW=""; CYAN=""; MAGENTA=""; BLUE=""; NC=""
_BOX_TOP=""; _BOX_BOT=""; DRY_RUN=false
log() { :; }
preflight_check() { :; }
octopus_complete() { :; }'
    (
        cd "$TMP" || exit 99
        export PLUGIN_DIR="$PROJECT_ROOT" RESULTS_DIR="$TMP/results" LOGS_DIR="$TMP/logs" LIB
        bash -e -c "$prelude
source <(tr -d '\015' < \"\$LIB\")
$snippet" 2>&1
    )
}

# --- #136: unquoted prompt must not be word-split
out=$(cd "$TMP" && HOME="$TMP" bash "$ORCH" --dry-run grapple redis vs memcached 2>&1) || true
if grep -q "Would grapple on: redis vs memcached" <<<"$out" && grep -q "Principles: general" <<<"$out"; then
    pass "#136 unquoted prompt passed whole to grapple_debate"
else
    fail "#136 unquoted prompt passed whole to grapple_debate" "$(tail -5 <<<"$out")"
fi

# --- #139: same-second runs must not collide
out=$(run_harness '
date() { if [[ "$1" == "+%s" ]]; then echo 1700000000; else command date "$@"; fi; }
run_agent_sync() { echo "out-from-$1"; }
( grapple_debate "p" general 3 >/dev/null 2>&1 ) || true   # only the result files matter here
( grapple_debate "p" general 3 >/dev/null 2>&1 ) || true
ls "$RESULTS_DIR" | wc -l
') || true
count=$(tail -1 <<<"$out" | tr -d '[:space:]')
if [[ "$count" == "2" ]]; then
    pass "#139 two same-second grapple runs yield 2 result files"
else
    fail "#139 two same-second grapple runs yield 2 result files" "found '$count' file(s): $out"
fi

# --- #133 (debate.sh): failing run_agent_sync must reach error handling
out=$(run_harness '
run_agent_sync() { return 1; }
# set -e is ignored inside a tested command, so run it in a plain subshell
set +e
( set -e; grapple_debate p ); echo "STATUS=$?"
') || true
if grep -q "Codex proposal generation failed" <<<"$out" && grep -q "STATUS=1" <<<"$out"; then
    pass "#133 run_agent_sync failure handled (message + status 1) under set -e"
else
    fail "#133 run_agent_sync failure handled (message + status 1) under set -e" "$out"
fi

echo "Tests: $TEST_COUNT, Passed: $PASS_COUNT, Failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
