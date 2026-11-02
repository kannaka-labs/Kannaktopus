#!/usr/bin/env bash
# Regression test: cmd_update_clis must not die under set -e on ((updated++))
# (Kannaktopus issue #132). ((x++)) returns 1 when x was 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$PROJECT_ROOT/scripts/lib/doctor.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

# Strip CR so the test works with CRLF checkouts too
tr -d '\r' < "$DOCTOR" > "$TMP/doctor.sh"

# run_case <npm-exit-code>; sets OUT and RC
run_case() {
    local npm_rc="$1"
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nexit %s\n' "$npm_rc" > "$TMP/bin/npm"
    chmod +x "$TMP/bin/npm"
    RC=0
    OUT=$(PATH="$TMP/bin:$PATH" bash -c '
        set -euo pipefail
        RED="" GREEN="" YELLOW="" CYAN="" NC=""
        source "$1"
        cmd_update_clis
        echo REACHED_END
    ' _ "$TMP/doctor.sh" 2>&1) || RC=$?
}

# Success path: updated++ from 0 must not abort
run_case 0
if [[ $RC -eq 0 && "$OUT" == *"REACHED_END"* && "$OUT" == *"2 packages"* ]]; then
    pass "update-clis survives set -e when all updates succeed (2 packages counted)"
else
    fail "update-clis survives set -e when all updates succeed" "rc=$RC out=$OUT"
fi

# Failure path: failed++ from 0 must not abort
run_case 1
if [[ $RC -eq 0 && "$OUT" == *"REACHED_END"* && "$OUT" == *"0 updated, 2 failed"* ]]; then
    pass "update-clis survives set -e when all updates fail (2 failures counted)"
else
    fail "update-clis survives set -e when all updates fail" "rc=$RC out=$OUT"
fi

echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -eq 0 ]]
