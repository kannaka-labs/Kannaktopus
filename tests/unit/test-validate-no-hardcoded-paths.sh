#!/usr/bin/env bash
# Tests for scripts/validate-no-hardcoded-paths.sh (#92)
# The validator must flag Windows absolute user paths (C:\Users\<name>,
# C:/Users/<name>, and the doubled C:\\Users\\<name> of string literals) and
# must scan .ts files — not only the Unix /Users and /home forms.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PROJECT_ROOT/scripts/validate-no-hardcoded-paths.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Build a throwaway git repo holding the validator plus one tracked fixture
# file, run the validator there, and echo its exit status.
run_validator_with() {
    local name="$1" rel_path="$2" content="$3"
    local repo="$TMP_ROOT/$name"
    mkdir -p "$repo/scripts" "$(dirname "$repo/$rel_path")"
    # Strip CR so a CRLF working copy of the validator still runs.
    tr -d '\r' < "$VALIDATOR" > "$repo/scripts/validate-no-hardcoded-paths.sh"
    printf '%s\n' "$content" > "$repo/$rel_path"
    (
        cd "$repo"
        git init -q .
        git add -A
    )
    local rc=0
    bash "$repo/scripts/validate-no-hardcoded-paths.sh" > "$repo/out.log" 2>&1 || rc=$?
    echo "$rc"
}

expect_fail() {
    local label="$1" rel_path="$2" content="$3" rc
    rc=$(run_validator_with "case$TEST_COUNT" "$rel_path" "$content")
    if [[ "$rc" -ne 0 ]]; then pass "$label"; else fail "$label" "validator passed (exit 0)"; fi
}

expect_pass() {
    local label="$1" rel_path="$2" content="$3" rc
    rc=$(run_validator_with "case$TEST_COUNT" "$rel_path" "$content")
    if [[ "$rc" -eq 0 ]]; then pass "$label"; else fail "$label" "validator failed (exit $rc)"; fi
}

expect_pass "clean .ts file passes" "src/index.ts" 'const p = resolve(homedir(), ".kannaka");'

# The exact shape from #92: escaped backslashes in a TypeScript string literal.
expect_fail "C:\\\\Users\\\\<name> in a .ts string literal is flagged" "src/index.ts" \
    "const p = resolve('C:\\\\Users\\\\someone\\\\Source\\\\x\\\\state.json');"
expect_fail "C:\\Users\\<name> in a .md file is flagged" "docs/x.md" \
    'Data lives in C:\Users\someone\Source\kannaka-memory'
expect_fail "C:/Users/<name> in a .sh file is flagged" "scripts/x.sh" \
    'DATA=C:/Users/someone/.kannaka'
expect_fail "lowercase drive d:\\Users\\<name> in .json is flagged" "config/x.json" \
    '{"path": "d:\\Users\\someone\\x"}'
expect_fail "Unix /home/<name>/ in a .ts file is flagged" "src/y.ts" \
    'const p = "/home/someone/data";'
expect_fail "Unix /Users/<name>/ in a .js file still flagged" "src/z.js" \
    'const p = "/Users/someone/data";'

# Placeholders in docs are not real paths.
expect_pass "placeholder C:\\Users\\<name> is not flagged" "docs/p.md" \
    'Install to C:\Users\<name>\.local\bin'
expect_pass "placeholder C:\\Users\\%USERNAME% is not flagged" "docs/q.md" \
    'Install to C:\Users\%USERNAME%\.local\bin'

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ "$FAIL_COUNT" -eq 0 ]]
