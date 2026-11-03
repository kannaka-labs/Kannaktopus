#!/usr/bin/env bash
# Arms hub (scripts/lib/arms-hub.sh): with OCTOPUS_ARMS_HUB set, every arm gets
# QuantumOS + Kannaka MCP tools through one hub; without it nothing changes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$PROJECT_ROOT"   # orchestrate.sh resets PROJECT_ROOT when sourced

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "arms hub: QuantumOS + Kannaka MCP tools for every arm"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_SESSION_ID="arms-hub-test"
mkdir -p "$HOME"
cd "$TMP" || exit 1

# orchestrate.sh does not load cleanly under the framework's set -eu
set +eu
source "$REPO_ROOT/scripts/orchestrate.sh" >/dev/null 2>&1 || true
set +e

printf '{"servers":{},"policy":{},"default":"deny"}\n' > "$TMP/hub.json"
printf '{"servers":{},"policy":{},"default":"deny"}\n' > "$TMP/hub-lite.json"
export OCTOPUS_ARMS_HUB_DIR="$TMP/armsdir"
unset OCTOPUS_ARMS_HUB OCTOPUS_ARMS_HUB_LITE OCTOPUS_QOS_AGENT OCTOPUS_ARMS_HUB_CMD OCTOPUS_ARMS_HUB_DB

# Fake qos_agent: record argv, the server command and stdin (run with OCTOPUS_PYTHON=bash)
cat > "$TMP/fake_agent.sh" <<'EOF'
printf 'ARGV:%s\n' "$*"
printf 'SERVER:%s\n' "$QOS_AGENT_SERVER_CMD"
printf 'STDIN:%s\n' "$(cat)"
EOF

json_ok() {
    if command -v jq >/dev/null 2>&1; then jq -e . "$1" >/dev/null 2>&1
    else python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" 2>/dev/null; fi
}

test_off_by_default() {
    test_case "without OCTOPUS_ARMS_HUB no arm changes"
    local c x g o
    c=$(get_agent_command claude 2>/dev/null) || c=""
    x=$(get_agent_command codex 2>/dev/null) || x=""
    g=$(GEMINI_API_KEY=k get_agent_command gemini 2>/dev/null) || g=""
    o=$(get_agent_command ollama 2>/dev/null) || o=""
    if [[ "$c" != *mcp-config* && "$x" != *mcp_servers* && "$g" != *GEMINI_CLI_HOME* && "$o" == "ollama run"* ]]; then
        test_pass
    else
        test_fail "claude='$c' codex='$x' gemini='$g' ollama='$o'"
    fi
}

test_claude_flags_and_file() {
    test_case "claude arm gets --mcp-config and the mcp__quantumos tools"
    local c f="$TMP/armsdir/claude-mcp.json"
    c=$(OCTOPUS_ARMS_HUB="$TMP/hub.json" get_agent_command claude 2>/dev/null) || c=""
    if [[ "$c" == *"--mcp-config $f --allowedTools mcp__quantumos"* ]] && json_ok "$f" \
        && grep -q '"command":"qos-hub","args":\["serve","--config","'"$TMP"'/hub.json","--db","'"$TMP"'/broker.db"\]' "$f"; then
        test_pass
    else
        test_fail "cmd='$c' file=$(cat "$f" 2>/dev/null)"
    fi
}

test_codex_flags_before_stdin_dash() {
    test_case "codex arm gets the mcp_servers overrides before the stdin '-'"
    local x
    x=$(OCTOPUS_ARMS_HUB="$TMP/hub.json" OCTOPUS_ARMS_HUB_CMD="python3 /opt/qos_hub.py" get_agent_command codex 2>/dev/null) || x=""
    if [[ "$x" == *'-c mcp_servers.quantumos.command="python3"'* \
        && "$x" == *'-c mcp_servers.quantumos.args=["/opt/qos_hub.py","serve","--config",'* \
        && "$x" == *'mcp_servers.quantumos.required=true'* \
        && "$x" == *'mcp_servers.quantumos.default_tools_approval_mode="approve" -' ]]; then
        test_pass
    else
        test_fail "cmd='$x'"
    fi
}

test_gemini_home_with_key_only() {
    test_case "gemini arm gets GEMINI_CLI_HOME with an API key, not with OAuth"
    local g n f="$TMP/armsdir/gemini-home/.gemini/settings.json"
    g=$(OCTOPUS_ARMS_HUB="$TMP/hub.json" GEMINI_API_KEY=k get_agent_command gemini 2>/dev/null) || g=""
    n=$(OCTOPUS_ARMS_HUB="$TMP/hub.json" GEMINI_API_KEY="" get_agent_command gemini 2>/dev/null) || n=""
    if [[ "$g" == "env NODE_NO_WARNINGS=1 GEMINI_CLI_HOME=$TMP/armsdir/gemini-home gemini "* ]] \
        && [[ "$n" != *GEMINI_CLI_HOME* ]] && json_ok "$f" && grep -q '"trust":true' "$f"; then
        test_pass
    else
        test_fail "with key='$g' without='$n'"
    fi
}

test_ollama_tool_loop() {
    test_case "ollama arm runs the tool loop on the lite config"
    local o out
    export OCTOPUS_ARMS_HUB="$TMP/hub.json" OCTOPUS_ARMS_HUB_LITE="$TMP/hub-lite.json"
    export OCTOPUS_QOS_AGENT="$TMP/fake_agent.sh" OCTOPUS_PYTHON=bash OLLAMA_HOST="http://127.0.0.1:11435"
    o=$(get_agent_command ollama 2>/dev/null) || o=""
    out=$(printf 'boot it' | arms_hub_ollama_execute kannaka-brain-v3 2>/dev/null) || out=""
    unset OCTOPUS_ARMS_HUB OCTOPUS_ARMS_HUB_LITE OCTOPUS_QOS_AGENT OCTOPUS_PYTHON OLLAMA_HOST
    if [[ "$o" == "arms_hub_ollama_execute "* \
        && "$out" == *"ARGV:- --provider openai --base-url http://127.0.0.1:11435/v1 --api-key-env OLLAMA_API_KEY --model kannaka-brain-v3"* \
        && "$out" == *"SERVER:qos-hub serve --config $TMP/hub-lite.json --db $TMP/broker.db"* \
        && "$out" == *"STDIN:boot it"* ]]; then
        test_pass
    else
        test_fail "cmd='$o' out='$out'"
    fi
}

test_openrouter_tool_loop() {
    test_case "openrouter arm sends the prompt through the tool loop"
    local out
    export OCTOPUS_ARMS_HUB="$TMP/hub.json" OCTOPUS_QOS_AGENT="$TMP/fake_agent.sh" OCTOPUS_PYTHON=bash
    out=$(printf 'read kannaka' | OPENROUTER_API_KEY=k openrouter_execute_model z-ai/glm-5 2>/dev/null) || out=""
    unset OCTOPUS_ARMS_HUB OCTOPUS_QOS_AGENT OCTOPUS_PYTHON
    if [[ "$out" == *"--base-url https://openrouter.ai/api/v1 --api-key-env OPENROUTER_API_KEY --model z-ai/glm-5"* \
        && "$out" == *"SERVER:qos-hub serve --config $TMP/hub.json"* && "$out" == *"STDIN:read kannaka"* ]]; then
        test_pass
    else
        test_fail "out='$out'"
    fi
}

test_no_agent_keeps_plain_arms() {
    test_case "hub on but no OCTOPUS_QOS_AGENT: ollama stays a plain completion arm"
    local o
    o=$(OCTOPUS_ARMS_HUB="$TMP/hub.json" get_agent_command ollama 2>/dev/null) || o=""
    if [[ "$o" == "ollama run --nowordwrap "* ]]; then
        test_pass
    else
        test_fail "cmd='$o'"
    fi
}

test_off_by_default
test_claude_flags_and_file
test_codex_flags_before_stdin_dash
test_gemini_home_with_key_only
test_ollama_tool_loop
test_openrouter_tool_loop
test_no_agent_keeps_plain_arms

test_summary
