#!/usr/bin/env bash
# Tests for scripts/kannaka-bridge.sh and the hooks that call it.
#
#  - The bridge is executable in git, and the session hooks call it through
#    `bash` regardless of the mode bit (a 100644 bridge used to make both hooks
#    skip all HRM I/O behind an `-x` test).
#  - The bridge resolves the kannaka binary from KANNAKA_BIN / PATH / the
#    runner's own $HOME — never a path hardcoded into one user's profile.
#  - Only hooks that .claude-plugin/hooks.json actually wires exist in hooks/
#    for HRM session I/O; the unwired kannaka-session-{start,end}.sh are gone.
#
# Every kannaka binary here is a stub that records its argv. Nothing runs a
# real kannaka.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRIDGE="$PROJECT_ROOT/scripts/kannaka-bridge.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# LF copies, so a CRLF working tree on Windows still runs.
tr -d '\r' < "$BRIDGE" > "$TMP_ROOT/kannaka-bridge.sh"

# --- 1. git mode -------------------------------------------------------------
mode=$(cd "$PROJECT_ROOT" && git ls-files -s scripts/kannaka-bridge.sh 2>/dev/null | awk '{print $1}')
if [[ "$mode" == "100755" ]]; then
    pass "kannaka-bridge.sh is executable in git (100755)"
else
    fail "kannaka-bridge.sh is executable in git (100755)" "mode is '${mode:-untracked}'"
fi

# --- 2. no hardcoded user-home path -----------------------------------------
# Same denylist as scripts/validate-no-hardcoded-paths.sh.
USER_PATH_RE='/Users/[^/]*/|/home/[^/]*/|[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9._-]+'
if hits=$(grep -nE "$USER_PATH_RE" "$TMP_ROOT/kannaka-bridge.sh"); then
    fail "bridge carries no hardcoded user-home path" "$hits"
else
    pass "bridge carries no hardcoded user-home path"
fi

# --- 3. binary resolution ----------------------------------------------------
# A stub kannaka that records argv into $STUB_LOG.
make_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_LOG:?}"
echo "stub-ok"
STUB
    chmod +x "$path"
}

# The system tool dirs the bridge needs. A kannaka installed there would make
# case 3a meaningless, so that case is skipped rather than faked.
SYS_PATH="/usr/bin:/bin"
BASH_BIN="$(command -v bash)"

# run_bridge <home> <path> <args...> — runs the bridge with an isolated env
# (no inherited KANNAKA_BIN, USERPROFILE or real HOME).
run_bridge() {
    local home="$1" path="$2"; shift 2
    env -i HOME="$home" PATH="$path" STUB_LOG="$TMP_ROOT/stub.log" \
        "$BASH_BIN" "$TMP_ROOT/kannaka-bridge.sh" "$@"
}

# 3a. nothing anywhere -> unavailable (and no fallback into someone's profile)
EMPTY_HOME="$TMP_ROOT/home-empty"; mkdir -p "$EMPTY_HOME"
if PATH="$SYS_PATH" command -v kannaka >/dev/null 2>&1; then
    echo "SKIP: a kannaka exists in $SYS_PATH; the unavailable case cannot be isolated"
else
    out=$(run_bridge "$EMPTY_HOME" "$SYS_PATH" available 2>&1 || true)
    if [[ "$out" == "false" ]]; then pass "no binary on PATH or in \$HOME -> available=false"; else fail "no binary on PATH or in \$HOME -> available=false" "got '$out'"; fi
fi

# 3b. kannaka on PATH
PATH_BIN="$TMP_ROOT/path-bin"; make_stub "$PATH_BIN/kannaka"
out=$(run_bridge "$EMPTY_HOME" "$PATH_BIN:$SYS_PATH" available 2>&1 || true)
if [[ "$out" == "true" ]]; then pass "kannaka on PATH -> available=true"; else fail "kannaka on PATH -> available=true" "got '$out'"; fi

# 3c. kannaka only in the runner's own ~/.local/bin
LOCAL_HOME="$TMP_ROOT/home-local"; make_stub "$LOCAL_HOME/.local/bin/kannaka"
out=$(run_bridge "$LOCAL_HOME" "$SYS_PATH" available 2>&1 || true)
if [[ "$out" == "true" ]]; then pass "kannaka in \$HOME/.local/bin -> available=true"; else fail "kannaka in \$HOME/.local/bin -> available=true" "got '$out'"; fi
rm -f "$TMP_ROOT/stub.log"
run_bridge "$LOCAL_HOME" "$SYS_PATH" status >/dev/null 2>&1 || true
if [[ -f "$TMP_ROOT/stub.log" ]] && [[ "$(head -1 "$TMP_ROOT/stub.log")" == "status" ]]; then
    pass "resolved \$HOME/.local/bin binary is the one executed"
else
    fail "resolved \$HOME/.local/bin binary is the one executed" "stub was not called"
fi

# 3d. absorb through the bridge speaks the CLI's one comma-joined --tags
rm -f "$TMP_ROOT/stub.log"
run_bridge "$EMPTY_HOME" "$PATH_BIN:$SYS_PATH" absorb "text here" 0.7 coding "project:x" "workflow:y" >/dev/null 2>&1 || true
if [[ -f "$TMP_ROOT/stub.log" ]]; then
    argv=$(tr '\n' ' ' < "$TMP_ROOT/stub.log")
    if [[ "$argv" == "remember text here --importance 0.7 --category coding --tags project:x,workflow:y " ]]; then
        pass "bridge absorb passes one --tags a,b"
    else
        fail "bridge absorb passes one --tags a,b" "argv: $argv"
    fi
else
    fail "bridge absorb passes one --tags a,b" "stub was not called"
fi

# --- 4. hooks call a NON-executable bridge -----------------------------------
# A fake plugin root whose bridge is deliberately mode 644 and records calls.
make_plugin_root() {
    local root="$1"
    mkdir -p "$root/scripts"
    # No shebang on purpose: Git Bash/MSYS reports any file starting with `#!`
    # as executable whatever its mode, which would make this check vacuous on
    # Windows. Without one, -x is false on every platform.
    cat > "$root/scripts/kannaka-bridge.sh" <<STUB
printf '%s\n' "\$*" >> "$root/bridge.calls"
STUB
    chmod 644 "$root/scripts/kannaka-bridge.sh"
    if [[ -x "$root/scripts/kannaka-bridge.sh" ]]; then
        echo "WARN: stub bridge still reports -x; the hook checks below cannot discriminate"
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available (hook checks need it)"
else
    # session-start-memory.sh: reaches the HRM recall once preferences exist.
    PR="$TMP_ROOT/plugin-start"; make_plugin_root "$PR"
    H="$TMP_ROOT/home-start"; mkdir -p "$H"
    PROJ="$TMP_ROOT/proj-start"; mkdir -p "$PROJ/memory"
    echo "# prefs" > "$PROJ/memory/octopus-preferences.md"
    tr -d '\r' < "$PROJECT_ROOT/hooks/session-start-memory.sh" > "$TMP_ROOT/session-start-memory.sh"
    (cd "$PROJ" && HOME="$H" CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PROJECT_DIR="$PROJ" \
        bash "$TMP_ROOT/session-start-memory.sh" >/dev/null 2>&1) || true
    if [[ -f "$PR/bridge.calls" ]] && grep -q '^recall ' "$PR/bridge.calls"; then
        pass "session-start-memory.sh calls a non-executable bridge (recall)"
    else
        fail "session-start-memory.sh calls a non-executable bridge (recall)" "bridge never called"
    fi

    # session-end.sh: absorbs a session that had agent activity.
    PR="$TMP_ROOT/plugin-end"; make_plugin_root "$PR"
    H="$TMP_ROOT/home-end"; mkdir -p "$H/.kannaktopus"
    echo '{"workflow":"embrace","current_phase":"ink","total_agent_calls":4,"errors":[]}' > "$H/.kannaktopus/session.json"
    tr -d '\r' < "$PROJECT_ROOT/hooks/session-end.sh" > "$TMP_ROOT/session-end.sh"
    (cd "$TMP_ROOT" && HOME="$H" CLAUDE_PLUGIN_ROOT="$PR" \
        bash "$TMP_ROOT/session-end.sh" >/dev/null 2>&1) || true
    if [[ -f "$PR/bridge.calls" ]] && grep -q '^absorb ' "$PR/bridge.calls"; then
        pass "session-end.sh calls a non-executable bridge (absorb)"
    else
        fail "session-end.sh calls a non-executable bridge (absorb)" "bridge never called"
    fi
fi

# --- 5. no unwired HRM session hooks -----------------------------------------
for dead in kannaka-session-start.sh kannaka-session-end.sh; do
    if [[ -e "$PROJECT_ROOT/hooks/$dead" ]]; then
        if grep -q "hooks/$dead" "$PROJECT_ROOT/.claude-plugin/hooks.json"; then
            pass "hooks/$dead is wired in hooks.json"
        else
            fail "hooks/$dead is not left unwired" "present in hooks/ but not referenced by .claude-plugin/hooks.json"
        fi
    else
        pass "hooks/$dead is not left unwired"
    fi
done

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ "$FAIL_COUNT" -eq 0 ]]
