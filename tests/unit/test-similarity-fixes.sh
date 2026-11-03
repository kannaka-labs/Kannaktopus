#!/usr/bin/env bash
# Tests for scripts/lib/similarity.sh: check_convergence args, Jaccard dedup, CR stripping
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/similarity.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Finding 3: check_convergence uses all expanded args ---
export OCTOPUS_CONVERGENCE_ENABLED=true
for name in plain "with space"; do
    d="$TMP/$name"
    mkdir -p "$d"
    printf '# Title\n## Section\n' > "$d/a.md"
    printf '# Title\n## Section\n' > "$d/b.md"
    rc=0; check_convergence "$d"/*.md || rc=$?
    if [[ $rc -eq 0 ]]; then pass "check_convergence converges on glob in '$name'"
    else fail "check_convergence converges on glob in '$name'" "rc=$rc"; fi
done

# Negative cases: different headings, and the feature switched off
mkdir -p "$TMP/diff"
printf '# Alpha\n## One\n' > "$TMP/diff/a.md"
printf '# Beta\n## Two\n' > "$TMP/diff/b.md"
rc=0; check_convergence "$TMP/diff"/*.md || rc=$?
if [[ $rc -ne 0 ]]; then pass "check_convergence rejects different headings"
else fail "check_convergence rejects different headings" "rc=0"; fi
rc=0; OCTOPUS_CONVERGENCE_ENABLED=false check_convergence "$TMP/plain"/*.md || rc=$?
if [[ $rc -ne 0 ]]; then pass "check_convergence off when disabled"
else fail "check_convergence off when disabled" "rc=0"; fi

# --- Finding 5: duplicates do not push score above 1 ---
out=$(bigram_similarity "review the code review the code" "review the code") || out=""
[[ "$out" == "0.67" ]] && pass "bigram_similarity dedups (0.67)" || fail "bigram_similarity dedups" "got '$out'"
out=$(jaccard_similarity $'# x\n# x' '# x') || out=""
[[ "$out" == "1.00" ]] && pass "jaccard_similarity dedups (1.00)" || fail "jaccard_similarity dedups" "got '$out'"

# --- Finding 6: CRLF headings equal LF headings ---
printf '# A\r\n' > "$TMP/crlf.md"
printf '# A\n' > "$TMP/lf.md"
out=$(jaccard_similarity "$(extract_headings "$TMP/crlf.md")" "$(extract_headings "$TMP/lf.md")") || out=""
[[ "$out" == "1.00" ]] && pass "CRLF headings score 1.00" || fail "CRLF headings score 1.00" "got '$out'"

# $(...) may drop CR on some shells (Git Bash), so also check the raw pipe
cr_count=$(extract_headings "$TMP/crlf.md" | tr -cd '\r' | wc -c | tr -d ' ') || cr_count=""
[[ "$cr_count" == "0" ]] && pass "extract_headings emits no CR" || fail "extract_headings emits no CR" "CR count '$cr_count'"

echo "Total: $TEST_COUNT Pass: $PASS_COUNT Fail: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
