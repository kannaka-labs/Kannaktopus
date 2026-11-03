#!/bin/bash
# Test: auth status never prints short API keys in full (Issue #168)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

TMP_HOME="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
CYAN=""; GREEN=""; RED=""; YELLOW=""; NC=""; _BOX_TOP="+"; _BOX_BOT="+"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/auth.sh"

out=$(OPENAI_API_KEY=sk-1234 GEMINI_API_KEY= handle_auth_command status 2>&1) || true
[[ "$out" == *"Authenticated (API Key)"* && "$out" != *sk-1234* ]] && check "short OpenAI key not printed" ok || check "short OpenAI key not printed" no

out=$(OPENAI_API_KEY= GEMINI_API_KEY=gm-5678 handle_auth_command status 2>&1) || true
[[ "$out" == *"Gemini:  "*"Authenticated (API Key)"* && "$out" != *gm-5678* ]] && check "short Gemini key not printed" ok || check "short Gemini key not printed" no

long=sk-abcdefghijklmnopqrstuvwxyz1234
out=$(OPENAI_API_KEY=$long GEMINI_API_KEY= handle_auth_command status 2>&1) || true
[[ "$out" != *"$long"* && "$out" == *"sk-abcde...1234"* ]] && check "long key shows prefix...suffix only" ok || check "long key shows prefix...suffix only" no

echo "Passed: $PASS Failed: $FAIL"
[[ $FAIL -eq 0 ]]
