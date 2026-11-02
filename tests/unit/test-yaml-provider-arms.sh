#!/usr/bin/env bash
# Embrace's YAML workflow dispatches every available arm, not only
# codex/gemini/claude: perplexity, openrouter and ollama are registered as
# optional providers and skipped when their key or server is missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/scripts/lib/yaml-workflow.sh"
YAML="$PROJECT_ROOT/config/workflows/embrace.yaml"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

log() { :; }
# shellcheck disable=SC1090
source <(tr -d '\r' < "$LIB")

providers_of() {  # phase -> provider names, one per line
    yaml_get_phase_agents "$YAML" "$1" | tr -d '\r' | cut -d: -f1
}

# Both parsers: yq when installed, the awk fallback always.
check_phases() {
    local label="$1" probe ink
    probe=$(providers_of probe | tr '\n' ' ')
    ink=$(providers_of ink | tr '\n' ' ')
    for p in codex gemini claude perplexity openrouter ollama; do
        [[ " $probe" == *" $p "* ]] && pass "$label: probe dispatches $p" || fail "$label: probe dispatches $p" "got: $probe"
    done
    [[ " $ink" == *" openrouter "* ]] && pass "$label: ink adds an openrouter review" || fail "$label: ink adds an openrouter review" "got: $ink"
    [[ " $ink" != *" ollama "* ]] && pass "$label: ink keeps the slow local model out of long reviews" || fail "$label: ink keeps ollama out" "got: $ink"
}
check_phases "parser"
if command -v yq &>/dev/null; then
    ( command() { [[ "$1 $2" == "-v yq" ]] && return 1; builtin command "$@"; }; check_phases "awk fallback" )
fi

# Every new provider has its own prompt template. Only yq reads templates;
# without it the runner builds "<role>: <prompt>" for every provider.
if command -v yq &>/dev/null; then
    for p in perplexity openrouter ollama; do
        t=$(yaml_get_agent_prompt "$YAML" probe "$p" 2>/dev/null | tr -d '\r')
        [[ "$t" == *"{{prompt}}"* ]] && pass "probe $p has a prompt template" || fail "probe $p has a prompt template" "got: ${t:0:60}"
    done
else
    echo "SKIP: prompt templates (yq not installed)"
fi

# Availability: API arms need their key.
(
    unset PERPLEXITY_API_KEY OPENROUTER_API_KEY
    yaml_provider_available perplexity && fail "perplexity without key is skipped" "reported available" || pass "perplexity without key is skipped"
    yaml_provider_available openrouter && fail "openrouter without key is skipped" "reported available" || pass "openrouter without key is skipped"
    PERPLEXITY_API_KEY=x OPENROUTER_API_KEY=y
    yaml_provider_available perplexity && pass "perplexity with key is used" || fail "perplexity with key is used" "reported unavailable"
    yaml_provider_available openrouter && pass "openrouter with key is used" || fail "openrouter with key is used" "reported unavailable"
)

# Availability: ollama must answer, not merely be installed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/ollama"; chmod +x "$WORK/bin/ollama"
PATH="$WORK/bin:$PATH" yaml_provider_available ollama && pass "ollama that answers is used" || fail "ollama that answers is used" "reported unavailable"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/ollama"
PATH="$WORK/bin:$PATH" yaml_provider_available ollama && fail "ollama that cannot connect is skipped" "reported available" || pass "ollama that cannot connect is skipped"

yaml_provider_available claude && pass "claude stays always available" || fail "claude stays always available" "reported unavailable"

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ "$FAIL_COUNT" -eq 0 ]]
