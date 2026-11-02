#!/bin/bash
# tests/unit/test-auto-route-keywords.sh
# Issue #151: routing keywords match next to punctuation and in capitals

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Auto-route keyword matching"

log() { :; }

WORKSPACE_DIR=$(mktemp -d)
export WORKSPACE_DIR
trap 'rm -rf "$WORKSPACE_DIR"' EXIT
source "$PROJECT_ROOT/scripts/lib/routing.sh"
source "$PROJECT_ROOT/scripts/lib/auto-route.sh"

RULES="$WORKSPACE_DIR/.octo/routing-rules.json"

check() {
    local name="$1" prompt="$2" want="$3" out
    test_case "$name"
    out=$(match_routing_rule "" "$prompt") || out=""
    if [[ "$out" == "$want" ]]; then test_pass; else test_fail "got '$out', want '$want'"; fi
}

# Default rules
create_default_routing_rules >/dev/null 2>&1
check "keyword followed by comma matches" "Review the database, then plan." "database-architect"
check "keyword at sentence end matches" "Please fix the schema." "database-architect"
check "substrings do not match" "databases are fun" ""

# One custom rule per case, written whole
rule() { printf '{"rules": [{"match": {"keywords": "%s"}, "prefer": "%s"}]}\n' "$1" "$2" > "$RULES"; }

rule "Frontend React Component" "frontend-developer"
check "capitalised rule keyword matches" "build a react widget" "frontend-developer"

rule "ci-cd" "deployment-engineer"
check "hyphenated rule keyword matches ci-cd" "set up ci-cd for this repo" "deployment-engineer"
check "hyphenated rule keyword matches CI/CD" "Fix our CI/CD." "deployment-engineer"
check "hyphenated rule keyword needs both words" "fix our ci" ""

test_summary
