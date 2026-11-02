#!/usr/bin/env bash
# Tests for issue #119 part 1: run_with_ralph_loop must not accept a
# <promise>COMPLETE</promise> unless work actually happened and the agent did
# not say it could not do the work.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$PROJECT_ROOT"
LIB="$PROJECT_ROOT/scripts/lib/agent-utils.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stubs for things agent-utils.sh expects from the orchestrator
LOG_FILE="$TMP/log.txt"
log() { echo "[$1] $2" >> "$LOG_FILE"; }
MAGENTA=""; GREEN=""; YELLOW=""; NC=""; _BOX_TOP=""; _BOX_BOT=""
DRY_RUN=false
WORKSPACE_DIR="$TMP/ws"; mkdir -p "$WORKSPACE_DIR"
sleep() { :; }

# Source (tolerate CRLF checkouts); heartbeat.sh provides run_with_timeout, as in orchestrate.sh
# shellcheck disable=SC1090
source <(tr -d '\r' < "$PROJECT_ROOT/scripts/lib/heartbeat.sh")
# shellcheck disable=SC1090
source <(tr -d '\r' < "$LIB")

# Scratch git repo so snapshots are meaningful
REPO="$TMP/repo"; mkdir -p "$REPO"
cd "$REPO"
git init -q .
git config user.email t@t; git config user.name t
echo base > base.txt; git add base.txt; git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base

PROMISE="<promise>COMPLETE</promise>"
CALLS_FILE="$TMP/calls"

# run_agent_sync stub: AGENT_MODE selects behaviour
run_agent_sync() {
    local n; n=$(cat "$CALLS_FILE" 2>/dev/null || echo 0); echo $((n+1)) > "$CALLS_FILE"
    case "$AGENT_MODE" in
        refuse)        echo "I cannot complete this, command execution is blocked. $PROMISE" ;;
        noop)          echo "All done. $PROMISE" ;;
        edit)          echo "edit $n" >> base.txt; echo "Done. $PROMISE" ;;
        untracked)     echo x > "new_$n.txt"; echo "Done. $PROMISE" ;;
        edit_refuse)   echo "edit $n" >> base.txt; echo "Unable to run tests, read-only sandbox. $PROMISE" ;;
        commit)        echo "c$n" >> base.txt; git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qam "c$n"; echo "Committed. $PROMISE" ;;
        fixed_cannot)  echo "edit $n" >> base.txt; echo "Fixed the bug where users cannot log in. $PROMISE" ;;
        state_only)    mkdir -p .kannaktopus; echo "s$n" > .kannaktopus/state.json; echo "Done. $PROMISE" ;;
        edit_on_third) [[ $n -ge 2 ]] && echo "e$n" >> base.txt; echo "Done. $PROMISE" ;;
    esac
}

# run_ralph <mode> <prompt> -> sets CALLS, STATE, OUT
run_ralph() {
    AGENT_MODE="$1"; echo 0 > "$CALLS_FILE"; : > "$LOG_FILE"
    git checkout -q -- . ; git clean -fdq
    OUT=$(run_with_ralph_loop codex "$2" 3 "$PROMISE" 2>&1)
    CALLS=$(cat "$CALLS_FILE")
    STATE=$(grep -m1 '^status:' "$WORKSPACE_DIR/ralph-state.md" | awk '{print $2}')
}

# 1. Refusal + promise, nothing changed: must not end after one iteration
run_ralph refuse "Fix the bug"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "refusal with promise is rejected and loop continues (calls=$CALLS)" \
    || fail "refusal with promise is rejected and loop continues" "calls=$CALLS state=$STATE"
grep -q "rejected" "$LOG_FILE" \
    && pass "rejection reason is logged" || fail "rejection reason is logged" "no 'rejected' in log"

# 2. Promise with no change and no test command: rejected
run_ralph noop "Fix the bug"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "promise with no working-tree change is rejected" \
    || fail "promise with no working-tree change is rejected" "calls=$CALLS state=$STATE"

# 3. Tracked edit + promise: accepted on iteration 1
run_ralph edit "Fix the bug"
[[ "$CALLS" == 1 && "$STATE" == completed ]] \
    && pass "promise after a tracked-file change is accepted" \
    || fail "promise after a tracked-file change is accepted" "calls=$CALLS state=$STATE"

# 4. Untracked file + promise: accepted
run_ralph untracked "Fix the bug"
[[ "$CALLS" == 1 && "$STATE" == completed ]] \
    && pass "promise after creating an untracked file is accepted" \
    || fail "promise after creating an untracked file is accepted" "calls=$CALLS state=$STATE"

# 5. Change but output says it could not do the work: rejected
run_ralph edit_refuse "Fix the bug"
[[ "$CALLS" == 3 && "$STATE" != completed ]] && grep -q "could not be done" "$LOG_FILE" \
    && pass "promise with 'unable to'/'read-only' is rejected even if files changed" \
    || fail "promise with 'unable to'/'read-only' is rejected even if files changed" "state=$STATE"

# 6. No change but the prompt's test command passes: accepted
run_ralph noop "Fix the bug.
Test command: true"
[[ "$CALLS" == 1 && "$STATE" == completed ]] \
    && pass "promise accepted when the prompt's test command passes" \
    || fail "promise accepted when the prompt's test command passes" "calls=$CALLS state=$STATE"

# 7. No change and the test command fails: rejected
run_ralph noop "Fix the bug.
Test command: false"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "promise rejected when the prompt's test command fails" \
    || fail "promise rejected when the prompt's test command fails" "state=$STATE"

# 8. Refusal wording with a passing test command: still rejected
run_ralph refuse "Fix the bug.
Test command: true"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "refusal wording beats a passing test command" \
    || fail "refusal wording beats a passing test command" "state=$STATE"

# 9. Loop continues past rejections and accepts once work happens
run_ralph edit_on_third "Fix the bug"
[[ "$CALLS" == 3 && "$STATE" == completed ]] \
    && pass "loop continues after rejection and accepts once a change appears" \
    || fail "loop continues after rejection and accepts once a change appears" "calls=$CALLS state=$STATE"

# 10. Work committed during the iteration (clean tree before and after): accepted
run_ralph commit "Fix the bug"
[[ "$CALLS" == 1 && "$STATE" == completed ]] \
    && pass "promise after a commit is accepted" \
    || fail "promise after a commit is accepted" "calls=$CALLS state=$STATE"

# 11. "cannot" describing the fixed bug is not a refusal
run_ralph fixed_cannot "Fix the bug"
[[ "$CALLS" == 1 && "$STATE" == completed ]] \
    && pass "a summary mentioning 'cannot' in passing is not a refusal" \
    || fail "a summary mentioning 'cannot' in passing is not a refusal" "calls=$CALLS state=$STATE"

# 12. Only the orchestrator's .kannaktopus files changed: rejected
run_ralph state_only "Fix the bug"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "changes under .kannaktopus do not count as work" \
    || fail "changes under .kannaktopus do not count as work" "calls=$CALLS state=$STATE"

# 13. A "Tests:" line is prose, not a command
run_ralph noop "Fix the bug.
Tests: true"
[[ "$CALLS" == 3 && "$STATE" != completed ]] \
    && pass "only an explicit 'Test command:' line is run" \
    || fail "only an explicit 'Test command:' line is run" "calls=$CALLS state=$STATE"

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
