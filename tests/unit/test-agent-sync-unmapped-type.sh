#!/bin/bash
# Test: run_agent_sync logs an error and records nothing for an unmapped agent type (Issue #154)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/log.txt"
FLAG_FILE="$TMP/record_called"
: > "$LOG_FILE"

define_stubs() {
    log() { echo "$1 $2" >> "$LOG_FILE"; }
    classify_task() { echo "standard"; }
    apply_persona() { echo "$2"; }
    build_provider_context() { echo ""; }
    get_agent_model() { echo "stub-model"; }
    record_agent_call() { touch "$FLAG_FILE"; }
    get_agent_command() { return 1; }
}

define_stubs
source "${PROJECT_ROOT}/scripts/lib/agent-sync.sh"
define_stubs   # re-apply in case sourcing redefined any

PASSED=0; FAILED=0
check() {
    if [[ "$2" == "ok" ]]; then echo "PASS: $1"; PASSED=$((PASSED+1)); else echo "FAIL: $1"; FAILED=$((FAILED+1)); fi
}

RESULTS_DIR="$TMP"
run_agent_sync bogus "x" 30 r p >/dev/null 2>&1
rc=$?

[[ $rc -eq 1 ]] && check "returns 1" ok || check "returns 1 (got $rc)" bad
grep -q "ERROR.*bogus" "$LOG_FILE" && check "ERROR line names bogus" ok || check "ERROR line names bogus" bad
[[ ! -e "$FLAG_FILE" ]] && check "record_agent_call not called" ok || check "record_agent_call not called" bad

echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
