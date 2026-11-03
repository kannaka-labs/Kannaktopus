#!/bin/bash
# Test: fish completion lists every bash command, agent and option (Issue #170)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/completions.sh"

bash_out=$(generate_bash_completion | tr -d '\r') || bash_out=""
fish_out=$(generate_fish_completion | tr -d '\r') || fish_out=""

PASSED=0; FAILED=0
check() {
    if [[ "$2" == "ok" ]]; then echo "PASS: $1"; PASSED=$((PASSED+1))
    else echo "FAIL: $1"; FAILED=$((FAILED+1)); fi
}

commands=$(printf '%s\n' "$bash_out" | sed -n 's/^ *commands="\(.*\)"$/\1/p')
agents=$(printf '%s\n' "$bash_out" | sed -n 's/^ *agents="\(.*\)"$/\1/p')
options=$(printf '%s\n' "$bash_out" | sed -n 's/^ *options="\(.*\)"$/\1/p')

if [[ -n "$commands" && -n "$agents" && -n "$options" ]]; then
    check "extracted bash word lists" ok
else
    check "extracted bash word lists" bad
fi

for w in $commands; do
    if printf '%s\n' "$fish_out" | grep -qE "__fish_use_subcommand\" -a \"$w\""; then
        check "fish command: $w" ok
    else check "fish command: $w" bad; fi
done

fish_agents=$(printf '%s\n' "$fish_out" | grep 'seen_subcommand_from spawn' | sed 's/.*-a "\(.*\)"/\1/' || true)
for w in $agents; do
    if [[ " $fish_agents " == *" $w "* ]]; then
        check "fish agent: $w" ok
    else check "fish agent: $w" bad; fi
done

for w in $options; do
    name=$(printf '%s' "$w" | sed 's/^-*//')
    if [[ "$w" == --* ]]; then flag="-l"; else flag="-s"; fi
    if printf '%s\n' "$fish_out" | grep -qE -- " $flag $name( |\$)"; then
        check "fish option: $w" ok
    else check "fish option: $w" bad; fi
done

echo "Passed: $PASSED Failed: $FAILED"
[[ $FAILED -eq 0 ]]
