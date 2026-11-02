#!/usr/bin/env bash
# Tests that the OpenRouter and Perplexity arms send the request body to curl
# on stdin, not as a -d argument a large prompt pushes past ARG_MAX (#128).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

log() { :; }
VERBOSE=false
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/utils.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/perplexity.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/providers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export OPENROUTER_API_KEY=test-key PERPLEXITY_API_KEY=test-key

# Stub curl: refuse any argument over 4 KB (as the OS would past its argv
# limit), record the body it was given on stdin, and answer like the API.
curl() {
    local a with_code=false
    for a in "$@"; do
        (( ${#a} > 4096 )) && { echo "curl: Argument list too long" >&2; return 126; }
        [[ "$a" == "%{http_code}" ]] && with_code=true
    done
    cat > "$TMP/body"
    if [[ " $* " == *" https://api.perplexity.ai/"* ]]; then
        printf '%s' '{"output":[{"type":"message","content":[{"type":"output_text","text":"stub-ok"}]}]}'
    else
        printf '%s' '{"choices":[{"message":{"content":"stub-ok"}}]}'
    fi
    [[ "$with_code" == true ]] && printf '200'
    return 0
}

BIG=$(printf 'line of a large prompt %.0s\n' $(seq 1 4000))   # ~100 KB
MARK="end-marker-$$"
PROMPT="$BIG$MARK"

out=$(openrouter_execute_model "test/model" "$PROMPT" 2>/dev/null)
if [[ "$out" == "stub-ok" ]] && grep -q "$MARK" "$TMP/body"; then
    pass "openrouter_execute_model sends a 100 KB prompt on stdin"
else
    fail "openrouter_execute_model sends a 100 KB prompt on stdin" "out='${out:0:80}'"
fi

rm -f "$TMP/body"
out=$(perplexity_execute "sonar" "$PROMPT" 2>/dev/null)
if [[ "$out" == stub-ok* ]] && grep -q "$MARK" "$TMP/body"; then
    pass "perplexity_execute sends a 100 KB prompt on stdin"
else
    fail "perplexity_execute sends a 100 KB prompt on stdin" "out='${out:0:80}'"
fi

rm -f "$TMP/body"
out=$(printf '%s' "$PROMPT" | openrouter_execute "" 2>/dev/null)
if [[ "$out" == "stub-ok" ]] && grep -q "$MARK" "$TMP/body"; then
    pass "openrouter_execute (spawn's stdin delivery) reaches the API intact"
else
    fail "openrouter_execute (spawn's stdin delivery) reaches the API intact" "out='${out:0:80}'"
fi

if grep -v '^[[:space:]]*#' "$PROJECT_ROOT/scripts/lib/perplexity.sh" "$PROJECT_ROOT/scripts/lib/providers.sh" | grep -q -- '-d "\$payload"'; then
    fail "no curl call passes the payload as an argument" "found -d \"\$payload\""
else
    pass "no curl call passes the payload as an argument"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "api-arms-payload-stdin: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -gt 0 ]] && echo "FAILURES: $FAIL_COUNT" && exit 1
echo "All tests passed."
