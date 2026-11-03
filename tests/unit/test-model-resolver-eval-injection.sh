#!/bin/bash
# #161: resolve_octopus_model must not eval code embedded in cached/env model names

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Model resolver eval injection (#161)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export USER="tester161"
export CLAUDE_CODE_SESSION="evalinj-$$"
unset XDG_RUNTIME_DIR OCTOPUS_CODEX_MODEL
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"

CACHE="$HOME/.kannaktopus/cache/octo-model-cache-$USER-$CLAUDE_CODE_SESSION.json"
reset() {
    local v
    for v in $(compgen -A variable _OCTO_MODEL_CACHE_); do unset "$v"; done
    rm -f "$CACHE" "$T/pwned" "$T/pwned2" "/tmp/octo-model-cache-$USER-$CLAUDE_CODE_SESSION.json"
}

test_case "planted cache value with command substitution is not executed"
reset
mkdir -p "$(dirname "$CACHE")"
PLANT=$(printf '{"MC_codex_A_codex_P__R_":"x$(touch %s/pwned)"}' "$T")
echo "$PLANT" > "$CACHE"
# Also plant at the legacy shared-/tmp location so the test fails against the old code
LEGACY="/tmp/octo-model-cache-$USER-$CLAUDE_CODE_SESSION.json"
echo "$PLANT" > "$LEGACY"
trap 'rm -rf "$T" "$LEGACY"' EXIT
out=$(resolve_octopus_model codex codex) || out=""
if [[ ! -e "$T/pwned" ]]; then test_pass; else test_fail "command executed"; fi

test_case "planted cache value is returned verbatim"
if [[ "$out" == 'x$(touch '"$T"'/pwned)' ]]; then test_pass; else test_fail "got '$out'"; fi

test_case "OCTOPUS_CODEX_MODEL with command substitution is not executed"
reset
out=$(OCTOPUS_CODEX_MODEL='x$(touch '"$T"'/pwned2)' resolve_octopus_model codex codex) || out=""
if [[ ! -e "$T/pwned2" ]]; then test_pass; else test_fail "command executed"; fi

test_case "model value containing double quote and backtick is cached intact"
reset
weird='a"b`c'
# In this shell, not a subshell: the old eval-based cache assignment broke on these characters
OCTOPUS_CODEX_MODEL="$weird" resolve_octopus_model codex codex >/dev/null 2>&1 || true
if [[ "${_OCTO_MODEL_CACHE_MC_codex_A_codex_P__R_:-}" == "$weird" ]]; then test_pass; else test_fail "cached '${_OCTO_MODEL_CACHE_MC_codex_A_codex_P__R_:-}'"; fi

test_case "cache lives in per-user dir, not /tmp"
reset
out=$(resolve_octopus_model codex codex) || out=""
if [[ -f "$CACHE" && ! -e "/tmp/octo-model-cache-$USER-$CLAUDE_CODE_SESSION.json" ]]; then test_pass; else test_fail "cache not at $CACHE"; fi

test_summary
