#!/usr/bin/env bash
# Issue 192: spawn must forward task_id/role/phase, and the curated agent's
# readonly frontmatter must not turn a write task read-only unless that agent
# was actually chosen (a real expertise match, or a role-less spawn's phase).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$PROJECT_ROOT"   # orchestrate.sh resets PROJECT_ROOT when sourced

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "spawn role forwarding and curated-agent readonly (#192)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_SESSION_ID="spawn-role-test"
mkdir -p "$HOME"
cd "$TMP" || exit 1

# orchestrate.sh does not load cleanly under the framework's set -eu
set +eu
source "$REPO_ROOT/scripts/orchestrate.sh" >/dev/null 2>&1 || true
set +e

OCTOPUS_TOOL_POLICIES=true
SUPPORTS_AGENT_TYPE_ROUTING=true
FIX_PROMPT="Fix the off-by-one in the parser and add a test"
MATCH_PROMPT="Fix the retry logic across our distributed-systems services"

test_cli_forwards_role() {
    test_case "spawn CLI forwards task_id and role to spawn_agent"
    local out
    out=$(cd "$TMP" && OPENROUTER_API_KEY=test-key bash "$REPO_ROOT/scripts/orchestrate.sh" \
        -n spawn openrouter "$FIX_PROMPT" tid192 implementer 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; true)
    if [[ "$out" == *"task: tid192, role: implementer"* ]]; then
        test_pass
    else
        test_fail "dry-run output did not show the forwarded task id and role"
    fi
}

test_default_fallback_is_not_readonly() {
    test_case "no expertise match: the backend-architect default does not restrict"
    local agent
    agent=$(_spawn_readonly_agent "$FIX_PROMPT" "" false 2>/dev/null) || agent="?"
    if [[ -z "$agent" ]]; then
        test_pass
    else
        test_fail "expected no readonly agent, got '$agent'"
    fi
}

test_fallback_prompt_gets_no_policy() {
    test_case "role-less fix prompt keeps write access (reviewer role, no match)"
    local agent prompt
    agent=$(_spawn_readonly_agent "$FIX_PROMPT" "" false 2>/dev/null) || agent=""
    prompt=$(apply_persona reviewer "$FIX_PROMPT" false "$agent" 2>/dev/null) || prompt=""
    if [[ -n "$prompt" && "$prompt" != *"TOOL POLICY"* ]]; then
        test_pass
    else
        test_fail "prompt carries a tool policy"
    fi
}

test_explicit_role_ignores_guessed_agent() {
    test_case "explicit role: a keyword-matched readonly agent does not restrict"
    local agent prompt
    agent=$(_spawn_readonly_agent "$MATCH_PROMPT" "" true 2>/dev/null) || agent="?"
    prompt=$(apply_persona implementer "$MATCH_PROMPT" false "$agent" 2>/dev/null) || prompt=""
    if [[ -z "$agent" && "$prompt" != *"TOOL POLICY"* ]]; then
        test_pass
    else
        test_fail "agent='$agent', prompt restricted"
    fi
}

test_real_match_still_readonly() {
    test_case "role-less spawn with a real expertise match keeps readonly"
    local agent prompt
    agent=$(_spawn_readonly_agent "$MATCH_PROMPT" "" false 2>/dev/null) || agent=""
    prompt=$(apply_persona reviewer "$MATCH_PROMPT" false "$agent" 2>/dev/null) || prompt=""
    if [[ "$agent" == "backend-architect" && "$prompt" == *"TOOL POLICY (readonly: true)"* ]]; then
        test_pass
    else
        test_fail "agent='$agent', readonly policy missing"
    fi
}

test_select_default_unchanged() {
    test_case "select_curated_agent without match_only still defaults"
    local agent
    agent=$(select_curated_agent "$FIX_PROMPT" "" 2>/dev/null) || agent=""
    if [[ "$agent" == "backend-architect" ]]; then
        test_pass
    else
        test_fail "expected backend-architect, got '$agent'"
    fi
}

test_cli_forwards_role
test_default_fallback_is_not_readonly
test_fallback_prompt_gets_no_policy
test_explicit_role_ignores_guessed_agent
test_real_match_still_readonly
test_select_default_unchanged

test_summary
