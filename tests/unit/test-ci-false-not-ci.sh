#!/bin/bash
# Test: CI=false must not be treated as a CI environment
# Covers Kannaktopus #167 (scripts/lib/interactive.sh, scripts/orchestrate.sh)
# Optional $1: alternate interactive.sh to test (used to prove failure without the fix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$PROJECT_ROOT/scripts/lib/interactive.sh"
if [[ $# -gt 0 ]]; then SRC="$1"; fi

PASSED=0
FAILED=0
pass() {
    echo "✓ $1"
    PASSED=$((PASSED + 1))
}
fail() {
    echo "✗ $1"
    FAILED=$((FAILED + 1))
}

RUNNER="$(mktemp)"
trap 'rm -f "$RUNNER"' EXIT
cat > "$RUNNER" <<'EOS'
set -eo pipefail
log() {
    :
}
source "$SRC"
AUTONOMY_MODE="supervised"
init_ci_mode
echo "CI_MODE=$CI_MODE AUTONOMY_MODE=$AUTONOMY_MODE"
EOS

# Run init_ci_mode in a clean shell with CI=$1 (GITHUB_ACTIONS etc. unset)
run_case() {
    env -u CI -u GITHUB_ACTIONS -u GITLAB_CI -u JENKINS_URL SRC="$SRC" CI="$1" bash "$RUNNER" 2>/dev/null || true
}

out="$(run_case false)"
case "$out" in
    *"CI_MODE=true"*) fail "CI=false set CI_MODE=true ($out)" ;;
    *"CI_MODE="*) pass "CI=false does not enable CI_MODE" ;;
    *) fail "CI=false case produced no output (source failed?)" ;;
esac
case "$out" in
    *"AUTONOMY_MODE=supervised"*) pass "CI=false leaves AUTONOMY_MODE unchanged" ;;
    *) fail "CI=false changed AUTONOMY_MODE ($out)" ;;
esac

out="$(run_case 0)"
case "$out" in
    *"CI_MODE=true"*) fail "CI=0 set CI_MODE=true ($out)" ;;
    *"CI_MODE="*) pass "CI=0 does not enable CI_MODE" ;;
    *) fail "CI=0 case produced no output" ;;
esac

# Controls
for v in true TRUE 1 yes; do
    out="$(run_case "$v")"
    case "$out" in
        *"CI_MODE=true AUTONOMY_MODE=autonomous"*) pass "CI=$v enables CI mode" ;;
        *) fail "CI=$v did not enable CI mode ($out)" ;;
    esac
done

# GITHUB_ACTIONS still detected
out="$(env -u CI -u GITLAB_CI GITHUB_ACTIONS=true SRC="$SRC" bash "$RUNNER" 2>/dev/null || true)"
case "$out" in
    *"CI_MODE=true AUTONOMY_MODE=autonomous"*) pass "GITHUB_ACTIONS still enables CI mode" ;;
    *) fail "GITHUB_ACTIONS not detected ($out)" ;;
esac

# Static: orchestrate.sh top-level CI check must go through _truthy
if grep -q '^if _truthy .*CI' "$PROJECT_ROOT/scripts/orchestrate.sh"; then
    pass "orchestrate.sh uses truthy CI check"
else
    fail "orchestrate.sh does not use _truthy for CI"
fi

echo "Passed: $PASSED Failed: $FAILED"
[[ $FAILED -eq 0 ]]

