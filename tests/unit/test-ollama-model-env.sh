#!/bin/bash
# get_agent_model maps ollama to a provider, so OCTOPUS_OLLAMA_MODEL is honoured

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Ollama model env override"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"                                 # no user providers.json
export CLAUDE_CODE_SESSION="ollama-model-env-$$"   # private resolver cache
unset XDG_RUNTIME_DIR                              # cache goes under the temp HOME
log() { :; }
source "$PROJECT_ROOT/scripts/lib/provider-routing.sh"
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"

clear_cache() { rm -f "$HOME"/.kannaktopus/cache/octo-model-cache-*-"$CLAUDE_CODE_SESSION".json; unset "${!_OCTO_MODEL_CACHE_@}"; }

test_case "OCTOPUS_OLLAMA_MODEL selects the ollama model"
clear_cache
got=$(OCTOPUS_OLLAMA_MODEL=kannaka-brain-v3 get_agent_model ollama) || got=""
if [[ "$got" == "kannaka-brain-v3" ]]; then test_pass; else test_fail "got '$got'"; fi

test_case "without the env var the default stays llama3.3"
clear_cache
got=$(unset OCTOPUS_OLLAMA_MODEL; get_agent_model ollama) || got=""
if [[ "$got" == "llama3.3" ]]; then test_pass; else test_fail "got '$got'"; fi

test_case "dispatch runs ollama without word-wrap escapes"
clear_cache
got=$(OCTOPUS_OLLAMA_MODEL=kannaka-brain-v3 get_agent_command ollama) || got=""
if [[ "$got" == "ollama run --nowordwrap kannaka-brain-v3" ]]; then test_pass; else test_fail "got '$got'"; fi

clear_cache
test_summary
