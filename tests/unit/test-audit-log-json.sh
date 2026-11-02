#!/usr/bin/env bash
# Tests for audit_log JSON escaping (issue #153)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUDIT_LOG="$TMP/audit.log"
VERBOSE=false

# Strip CR: these files are CRLF in this checkout
tr -d '\r' < "$PROJECT_ROOT/scripts/lib/utils.sh" > "$TMP/utils.sh"
tr -d '\r' < "$PROJECT_ROOT/scripts/lib/audit.sh" > "$TMP/audit.sh"
source "$TMP/utils.sh"
source "$TMP/audit.sh"

got=""
audit_log review p rejected 'say "no"'
if got=$(tail -1 "$AUDIT_LOG" | jq -er .reason | tr -d '\r') && [[ "$got" == 'say "no"' ]]; then
    pass "quoted reason is valid JSON and round-trips"
else
    fail "quoted reason is valid JSON and round-trips" "got: $got"
fi

got=""
audit_log review p rejected 'C:\path\x'
if got=$(tail -1 "$AUDIT_LOG" | jq -er .reason | tr -d '\r') && [[ "$got" == 'C:\path\x' ]]; then
    pass "backslash reason round-trips"
else
    fail "backslash reason round-trips" "got: $got"
fi

got=""
nl=$(printf 'a\nb')
before=$(wc -l < "$AUDIT_LOG")
audit_log review p rejected "$nl"
after=$(wc -l < "$AUDIT_LOG")
if [[ $((after - before)) -eq 1 ]] && got=$(tail -1 "$AUDIT_LOG" | jq -er .reason | tr -d '\r') && [[ "$got" == "$nl" ]]; then
    pass "newline reason adds exactly one line"
else
    fail "newline reason adds exactly one line" "added $((after - before)), got: $got"
fi

got=""
esc=$'\e[31mred\e[0m \x01'
audit_log review p rejected "$esc"
if got=$(tail -1 "$AUDIT_LOG" | jq -er .reason | tr -d '\r') && [[ "$got" == "$esc" ]]; then
    pass "control characters (ESC, 0x01) round-trip"
else
    fail "control characters (ESC, 0x01) round-trip" "got: $got"
fi

got=""
audit_log review p rejected '-n'
if got=$(tail -1 "$AUDIT_LOG" | jq -er .reason | tr -d '\r') && [[ "$got" == '-n' ]]; then
    pass "reason of exactly -n survives"
else
    fail "reason of exactly -n survives" "got: $got"
fi

if jq -e . "$AUDIT_LOG" >/dev/null; then
    pass "entire audit log parses with jq"
else
    fail "entire audit log parses with jq" "jq failed"
fi

echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -eq 0 ]]
