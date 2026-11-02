#!/usr/bin/env bash
# Tests for dispatch.sh input hardening: allowlist whitespace (#135),
# OCTOPUS_CONTEXT_BUDGET validation (#137), printf for prompts (#140)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

log() { :; }
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"

# --- #135: allowlist whitespace
export OCTOPUS_CODEX_ALLOWED_MODELS="gpt-5.4-mini, gpt-5.2-codex"
out=$(validate_model_allowed codex gpt-5.2-codex); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then pass "#135 allowlist with spaces allows listed model"
else fail "#135 allowlist with spaces" "rc=$rc out='$out'"; fi
unset OCTOPUS_CODEX_ALLOWED_MODELS

# --- #137: invalid budget
for bad in abc 12k 0 -5; do
    out=$(OCTOPUS_CONTEXT_BUDGET="$bad" enforce_context_budget "hello world" researcher 2>&1)
    if [[ "$out" == "hello world" ]]; then pass "#137 OCTOPUS_CONTEXT_BUDGET='$bad' falls back to default"
    else fail "#137 budget '$bad'" "got '$out'"; fi
done
long=$(head -c 200 /dev/zero | tr '\0' x)
out=$(OCTOPUS_CONTEXT_BUDGET=10 enforce_context_budget "$long" 2>&1)
if [[ "$out" == *"truncated"* ]]; then pass "#137 valid small budget still truncates"
else fail "#137 valid budget" "no truncation"; fi

# --- #140: echo option-like prompts
for p in -n -e -E; do
    out=$(enforce_context_budget "$p")
    if [[ "$out" == "$p" ]]; then pass "#140 prompt '$p' preserved"
    else fail "#140 prompt '$p'" "got '$out'"; fi
done

echo "Tests: $TEST_COUNT  Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
