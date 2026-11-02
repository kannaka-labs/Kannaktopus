#!/usr/bin/env bash
# Tests for #134 (Ralph test command uses run_with_timeout), #138 (quotes in the
# /ralph-loop prompt are escaped) and the Ralph part of #133 (a failing
# run_agent_sync must not end the loop under set -e).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="${LIB_DIR:-$PROJECT_ROOT/scripts/lib}"
PLUGIN_DIR="$PROJECT_ROOT"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

LOG_FILE="$TMP/log.txt"
log() { echo "[$1] $2" >> "$LOG_FILE"; }
MAGENTA=""; GREEN=""; YELLOW=""; NC=""; _BOX_TOP=""; _BOX_BOT=""
DRY_RUN=false
_BARE_OPT=""
WORKSPACE_DIR="$TMP/ws"; mkdir -p "$WORKSPACE_DIR"
sleep() { :; }

# shellcheck disable=SC1090
source <(tr -d '\r' < "$PROJECT_ROOT/scripts/lib/heartbeat.sh")
# shellcheck disable=SC1090
source <(tr -d '\r' < "$LIB_DIR/agent-utils.sh")

PROMISE="<promise>COMPLETE</promise>"

# --- #134: no timeout binary on PATH --------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in bash grep sed tail cat cksum git kill sort sleep; do
    src=$(command -v "$t" 2>/dev/null) && [[ -x "$src" ]] && ln -s "$src" "$BIN/$t"
done
OLD_PATH="$PATH"
unset -f sleep   # run_with_timeout's watchdog needs a real sleep
PATH="$BIN"
hash -r
if command -v timeout &>/dev/null || command -v gtimeout &>/dev/null; then
    PATH="$OLD_PATH"; hash -r
    fail "#134 setup" "timeout still resolvable"
elif ! grep -q x <<< x 2>/dev/null; then
    # Git Bash: tools linked out of /usr/bin cannot load their DLLs on this PATH
    PATH="$OLD_PATH"; hash -r
    echo "SKIP: #134 (restricted PATH cannot run linked tools on this host)"
else
    ralph_promise_accepted "$PROMISE" $'Test command: true' same same
    rc=$?
    PATH="$OLD_PATH"; hash -r
    [[ $rc -eq 0 ]] \
        && pass "#134 test command passes without a timeout binary" \
        || fail "#134 test command passes without a timeout binary" "rc=$rc"
fi
PATH="$OLD_PATH"; hash -r
sleep() { :; }

# --- #138: quotes escaped in /ralph-loop prompt ----------------------------
claude() {
    if [[ "$1" == plugin ]]; then echo "ralph-wiggum"; return 0; fi
    printf '%s' "$1" > "$TMP/captured"
}
: > "$TMP/captured"
run_with_claude_code_ralph 'Rename "foo" to "bar" in a\b' 3 "$PROMISE" &>/dev/null
captured=$(cat "$TMP/captured")
[[ "$captured" == *'\"foo\"'* && "$captured" == *'a\\b'* ]] \
    && pass "#138 quotes and backslashes in the prompt are escaped" \
    || fail "#138 quotes and backslashes in the prompt are escaped" "got: $captured"
[[ "$captured" != *'"Rename "foo"'* ]] \
    && pass "#138 prompt is not left with bare nested quotes" \
    || fail "#138 prompt is not left with bare nested quotes" "got: $captured"
unset -f claude

# --- #133 (Ralph part): failing run_agent_sync under set -e -----------------
CALLS_FILE="$TMP/calls"; echo 0 > "$CALLS_FILE"
run_agent_sync() {
    local n; n=$(cat "$CALLS_FILE"); echo $((n+1)) > "$CALLS_FILE"
    return 1
}
(
    set -e
    run_with_ralph_loop codex "Fix the bug" 2 "$PROMISE" >/dev/null 2>&1
)
rc=$?
calls=$(cat "$CALLS_FILE")
# The loop ends at max iterations (non-zero); what matters is that it ran both
[[ "$calls" == 2 ]] \
    && pass "#133 Ralph loop survives failing run_agent_sync under set -e (calls=$calls)" \
    || fail "#133 Ralph loop survives failing run_agent_sync under set -e" "calls=$calls rc=$rc"

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
