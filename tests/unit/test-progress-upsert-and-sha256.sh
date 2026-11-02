#!/bin/bash
# Test: progress record upsert (#150) and sha256 fallback for integrity checks (#152)
# Unit tests for scripts/lib/agents.sh and scripts/lib/validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { :; }
source "$PROJECT_ROOT/scripts/lib/validation.sh"
source "$PROJECT_ROOT/scripts/lib/agents.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected $3, got $2)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== #150: progress upsert ==="
export PROGRESS_TRACKING_ENABLED=true
export PROGRESS_FILE="$TMP/progress.json"
jq -n '{phase: "t", total_agents: 2, completed_agents: 0, total_time_ms: 0, total_cost: 0, agents: []}' > "$PROGRESS_FILE"

update_agent_status codex running 0 0.0 300 task-1
update_agent_status codex completed 1000 0.0 300 task-1
assert_eq "running then completed leaves one record" "$(jq '.agents | length' "$PROGRESS_FILE")" "1"
assert_eq "record has final status" "$(jq -r '.agents[0].status' "$PROGRESS_FILE")" "completed"

update_agent_status codex running 0 0.0 300 task-2
update_agent_status codex completed 1000 0.0 300 task-2
assert_eq "two ids of same type give two records" "$(jq '.agents | length' "$PROGRESS_FILE")" "2"
assert_eq "no stale running records" "$(jq '[.agents[] | select(.status == "running")] | length' "$PROGRESS_FILE")" "0"

echo "=== #152: sha256 fallback ==="
export OCTOPUS_SECURITY_V870=true
export WORKSPACE_DIR="$TMP/ws"
mkdir -p "$WORKSPACE_DIR"

# Failing shasum first on PATH; sha256sum/openssl remain behind it
STUB="$TMP/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 127\n' > "$STUB/shasum"
chmod +x "$STUB/shasum"
OLD_PATH="$PATH"
PATH="$STUB:$PATH"

f="$TMP/result.md"
echo "original" > "$f"
record_result_hash "$f"
n=$(grep -c "^$f:" "$WORKSPACE_DIR/.integrity-manifest" 2>/dev/null || true)
assert_eq "manifest entry written without working shasum" "$n" "1"
if verify_result_integrity "$f"; then pass "untouched file verifies"; else fail "untouched file verifies"; fi
echo "tampered" > "$f"
rc=0
verify_result_integrity "$f" || rc=$?
assert_eq "tampered file fails verification" "$rc" "1"
PATH="$OLD_PATH"

echo "=== #152: no working hashing tool warns once ==="
# Every hashing tool fails (function stubs shadow the binaries)
sha256sum() { return 127; }
shasum() { return 127; }
openssl() { return 127; }
WARNS=0
log() { [[ "$1" == "WARN" ]] && WARNS=$((WARNS + 1)); return 0; }
unset _SHA256_WARNED
before=$(wc -l < "$WORKSPACE_DIR/.integrity-manifest")
record_result_hash "$f"
record_result_hash "$f"
unset -f sha256sum shasum openssl
assert_eq "no manifest entry without a digest" "$(wc -l < "$WORKSPACE_DIR/.integrity-manifest")" "$before"
assert_eq "missing tool logs one WARN for two records" "$WARNS" "1"

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
