#!/usr/bin/env bash
# spawn_agent copies the prompt into the result header. A prompt that quotes
# the SubagentStop-hook marker ("Capture: SubagentStop hook") must not make
# spawn_agent think the hook already wrote the result: the agent's output was
# dropped and the result never got a "## Status" line.
# (No set -u: orchestrate.sh does not load cleanly under it.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_SESSION_ID="hook-marker-test"
mkdir -p "$HOME"
cd "$TMP" || exit 1   # orchestrate.sh keeps state under ./.kannaktopus

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/orchestrate.sh" >/dev/null 2>&1
set +e +u

RESULTS_DIR="$TMP/results"; mkdir -p "$RESULTS_DIR"
SUPPORTS_HOOK_LAST_MESSAGE=true
OPENROUTER_API_KEY=test-key
# Stub arm: read the prompt from stdin, answer with a fixed line
openrouter_execute() { cat >/dev/null; echo "AGENT-ANSWER-42"; }

wait_status() {  # result file -> 0 once it has a status line
    local f="$1" i
    for i in $(seq 1 60); do
        [[ -f "$f" ]] && grep -q '^# Completed' "$f" && return 0
        sleep 0.5
    done
    return 1
}

prompt='Audit this line: grep -q "Capture: SubagentStop hook" "$result_file"
## Capture: SubagentStop hook (last_assistant_message)'
spawn_agent openrouter "$prompt" "t1" >/dev/null 2>&1
result="$RESULTS_DIR/openrouter-t1.md"
wait_status "$result"

if grep -q '^## Status: SUCCESS' "$result" 2>/dev/null; then
    pass "a prompt quoting the hook marker still gets a status"
else
    fail "a prompt quoting the hook marker still gets a status" "no status line in the result"
fi
if grep -q 'AGENT-ANSWER-42' "$result" 2>/dev/null; then
    pass "the agent's output is kept"
else
    fail "the agent's output is kept" "answer not in the result file"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "spawn-hook-marker-in-prompt: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -gt 0 ]] && echo "FAILURES: $FAIL_COUNT" && exit 1
echo "All tests passed."
