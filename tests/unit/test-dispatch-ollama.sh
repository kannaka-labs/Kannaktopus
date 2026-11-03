#!/usr/bin/env bash
# Kannaktopus #169: detected Ollama must be used in get_dispatch_strategy,
# and its probe curl must carry --max-time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$BIN/ollama"
printf '#!/bin/sh\necho "$@" > "%s/curl.args"\nexit 0\n' "$BIN" > "$BIN/curl"
chmod +x "$BIN/ollama" "$BIN/curl"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/embrace.sh"

OLD_PATH="$PATH"
unset OLLAMA_HOST
PATH="$BIN"
for wf in research review architecture; do
  out=$(get_dispatch_strategy "x" "$wf") || out=""
  if [[ "$out" == "2:ollama,claude-sonnet:medium" ]]; then pass "Ollama-only $wf strategy is ollama + claude-sonnet ($out)"
  else fail "Ollama-only $wf strategy includes ollama" "got '$out'"; fi
done
PATH="$OLD_PATH"

if grep -q -- '--max-time 2' "$BIN/curl.args" 2>/dev/null; then pass "curl probe uses --max-time 2"
else fail "curl probe uses --max-time 2" "no --max-time in curl args"; fi
if grep -q -- 'http://localhost:11434/api/tags' "$BIN/curl.args" 2>/dev/null; then pass "probe defaults to localhost:11434"
else fail "probe defaults to localhost:11434" "args: $(cat "$BIN/curl.args" 2>/dev/null)"; fi

# The probe follows OLLAMA_HOST, like the ollama CLI
PATH="$BIN"
OLLAMA_HOST=127.0.0.1:11435 get_dispatch_strategy "x" research >/dev/null || true
PATH="$OLD_PATH"
if grep -q -- 'http://127.0.0.1:11435/api/tags' "$BIN/curl.args" 2>/dev/null; then pass "probe follows OLLAMA_HOST"
else fail "probe follows OLLAMA_HOST" "args: $(cat "$BIN/curl.args" 2>/dev/null)"; fi

# A host with no port gets the CLI default 11434, not curl's port 80
PATH="$BIN"
OLLAMA_HOST=myhost get_dispatch_strategy "x" research >/dev/null || true
PATH="$OLD_PATH"
if grep -q -- 'http://myhost:11434/api/tags' "$BIN/curl.args" 2>/dev/null; then pass "OLLAMA_HOST without a port uses 11434"
else fail "OLLAMA_HOST without a port uses 11434" "args: $(cat "$BIN/curl.args" 2>/dev/null)"; fi

# codex + ollama: ollama now counts toward the multi-provider strategy
printf '#!/bin/sh
exit 0
' > "$BIN/codex"; chmod +x "$BIN/codex"
PATH="$BIN"
out=$(get_dispatch_strategy "x" research) || out=""
PATH="$OLD_PATH"
rm -f "$BIN/codex"
if [[ "$out" == "3:codex,ollama,claude-sonnet:high" ]]; then pass "codex + ollama research strategy uses both ($out)"
else fail "codex + ollama research strategy uses both" "got '$out'"; fi

# No ollama binary: still claude-only
rm "$BIN/ollama"
PATH="$BIN"
out=$(get_dispatch_strategy "x" research) || out=""
PATH="$OLD_PATH"
if [[ "$out" == 1:claude-sonnet* ]]; then pass "no ollama -> claude-only"; else fail "no ollama -> claude-only" "got '$out'"; fi

echo "Passed $PASS_COUNT/$TEST_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
