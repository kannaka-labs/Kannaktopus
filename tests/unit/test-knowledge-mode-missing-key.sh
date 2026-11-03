#!/usr/bin/env bash
# Issue #164: knowledge mode must persist when config lacks knowledge_work_mode key
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export USER_CONFIG_FILE="$TMP/config.yaml"
export OCTOPUS_PLATFORM=Linux
export WORKSPACE_DIR="$TMP/ws"
RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; DIM=""; NC=""
log() { :; }

write_cfg() {
    printf 'version: "1.0"\nintent:\n  primary: "general"\nresource_tier: "standard"\n' > "$USER_CONFIG_FILE"
}

# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/config-display.sh"

write_cfg
update_knowledge_mode_config true || true
if grep -q '^knowledge_work_mode: "true"' "$USER_CONFIG_FILE"; then
    pass "update_knowledge_mode_config appends missing key"
else
    fail "update_knowledge_mode_config appends missing key" "key not persisted"
fi

write_cfg
toggle_knowledge_work_mode on >/dev/null 2>&1 || true
out=$(toggle_knowledge_work_mode status 2>&1) || out=""
if echo "$out" | grep -q "Knowledge Mode" && ! echo "$out" | grep -q "Auto-Detect"; then
    pass "status reports Knowledge Mode after toggle on"
else
    fail "status reports Knowledge Mode after toggle on" "$out"
fi

echo "Passed $PASS_COUNT/$TEST_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
