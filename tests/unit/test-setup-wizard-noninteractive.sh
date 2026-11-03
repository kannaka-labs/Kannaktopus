#!/bin/bash
# Test: setup wizard installs correct Gemini package and skips prompts non-interactively
# Covers Kannaktopus #163 (scripts/lib/config-display.sh)
# Optional $1: alternate config-display.sh to test (used to prove failure without the fix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$PROJECT_ROOT/scripts/lib/config-display.sh"
if [[ $# -gt 0 ]]; then SRC="$1"; fi

PASSED=0
FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED + 1)); }

# 1. Static: wrong package name must not appear
if grep -q '@anthropic/gemini-cli' "$SRC"; then
    fail "config-display.sh references @anthropic/gemini-cli"
else
    pass "no @anthropic/gemini-cli reference"
fi
if grep -q 'npm install -g @google/gemini-cli 2>&1 | sed' "$SRC"; then
    pass "wizard installs @google/gemini-cli"
else
    fail "wizard install command does not use @google/gemini-cli"
fi

# 2. Behavioural: non-interactive wizard with no codex/gemini
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/bin/bash\necho "$@" >> "%s/npm-marker"\n' "$TMP" > "$TMP/bin/npm"
chmod +x "$TMP/bin/npm"

cat > "$TMP/runner.sh" <<'EOS'
set -eo pipefail
WORKSPACE_DIR="$HOME/.kannaktopus"
SETUP_CONFIG_FILE="$WORKSPACE_DIR/.setup-complete"
source "$SRC"
open_browser() { :; }
save_providers_config() { :; }
preflight_cache_invalidate() { :; }
init_step_intent() { :; }
install_tool() { :; }
init_workspace() { :; }
get_tool_description() { echo stub; }
is_tool_installed() { return 1; }
show_config_summary() { :; }
setup_wizard
EOS

export SRC
# A real codex/gemini next to bash (e.g. npm globals in /usr/bin on CI) would send the
# wizard down its "already installed" path and make the skip-hint checks meaningless
for t in codex gemini; do
    if [[ -x "$(dirname "$BASH_BIN")/$t" ]]; then
        echo "SKIP: $t is installed next to bash; cannot test the not-installed path"
        echo "Passed: $PASSED  Failed: $FAILED"; [[ $FAILED -eq 0 ]]; exit
    fi
done
rc=0
out="$(PATH="$TMP/bin:$(dirname "$BASH_BIN")" HOME="$TMP/home" CLAUDE_SESSION_ID="" "$BASH_BIN" "$TMP/runner.sh" </dev/null 2>&1)" || rc=$?

# setup_wizard deliberately returns 1 when codex/gemini/keys are missing ("Some
# tentacles need attention"), so exit 0 is impossible here; what matters is that it
# ran to the end (the pre-fix abort under set -e at EOF gave rc=1 with no summary).
if [[ $rc -eq 1 && "$out" == *"Some tentacles need attention"* ]]; then pass "wizard ran to final summary (rc=$rc)"; else fail "wizard aborted early (rc=$rc)"; echo "$out" | tail -5; fi
if [[ "$out" == *"Step 3"* ]]; then pass "wizard reached Step 3"; else fail "wizard did not reach Step 3"; fi
if [[ ! -e "$TMP/npm-marker" ]]; then pass "npm was not invoked"; else fail "npm invoked: $(cat "$TMP/npm-marker")"; fi
if [[ "$out" == *"Install later: npm install -g @openai/codex"* ]]; then pass "codex install skipped without prompting"; else fail "missing codex skip hint"; fi
if [[ "$out" == *"Install later: npm install -g @google/gemini-cli"* ]]; then pass "skip hint names @google/gemini-cli"; else fail "missing gemini skip hint"; fi

echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
