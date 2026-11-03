#!/bin/bash
# Test: get_agent_config returns comma-free list fields so expertise matches (Issue #194)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { :; }
source "$PROJECT_ROOT/scripts/lib/agents.sh"
AGENTS_CONFIG="$PROJECT_ROOT/agents/config.yaml"

PASSED=0; FAILED=0
check() {
    if [[ "$2" == "ok" ]]; then echo "PASS: $1"; PASSED=$((PASSED+1)); else echo "FAIL: $1"; FAILED=$((FAILED+1)); fi
}

exp=$(get_agent_config "backend-architect" "expertise" || true)
[[ "$exp" == "api-design microservices distributed-systems" ]] && check "expertise has no commas" ok || check "expertise has no commas (got $exp)" bad

fe=$(get_agent_config "frontend-developer" "expertise" || true)
[[ "$fe" == "react nextjs state-management accessibility" ]] && check "other list field has no commas" ok || check "other list field no commas (got $fe)" bad

# Fixture: CRLF line endings and irregular spacing inside the list
FIXTURE=$(mktemp)
printf 'agents:\r\n  fixture-agent:\r\n    expertise: [ alpha ,  beta,gamma ]\r\n    tier: standard\r\n' > "$FIXTURE"
got=$(AGENTS_CONFIG="$FIXTURE" get_agent_config "fixture-agent" "expertise" || true)
rm -f "$FIXTURE"
[[ "$got" == "alpha beta gamma" ]] && check "CRLF and spacing normalized" ok || check "CRLF and spacing normalized (got $(printf '%q' "$got"))" bad

got=$(select_curated_agent "design the api-design layer" "" true || true)
[[ "$got" == "backend-architect" ]] && check "first skill matches (backend-architect)" ok || check "first skill matches (got $got)" bad

got=$(select_curated_agent "check for owasp issues" "" true || true)
[[ "$got" == "security-auditor" ]] && check "match_only: security-auditor first skill" ok || check "match_only security-auditor (got $got)" bad

got=$(select_curated_agent "run the unit-tests suite" "" true || true)
[[ "$got" == "test-automator" ]] && check "first skill of test-automator matches" ok || check "test-automator (got $got)" bad

got=$(select_curated_agent "tune the redis config" "" true || true)
[[ -z "$got" ]] && check "match_only: no match prints nothing" ok || check "match_only no match (got $got)" bad

echo "Passed: $PASSED Failed: $FAILED"
[[ $FAILED -eq 0 ]]
