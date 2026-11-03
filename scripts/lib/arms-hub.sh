#!/usr/bin/env bash
# arms-hub — give every arm QuantumOS and Kannaka as MCP tools through ONE
# policy-gated endpoint: the QuantumOS hub (`qos-hub serve`, QuantumOS ADR-0027).
#
# Off unless OCTOPUS_ARMS_HUB names a hub config. Then:
#   claude*              --mcp-config <file> --allowedTools mcp__quantumos
#   codex*               -c mcp_servers.quantumos.* (required at startup, tools approved)
#   gemini*              GEMINI_CLI_HOME=<dir> whose .gemini/settings.json lists the hub
#                        (API-key auth only: moving the home hides an OAuth login)
#   openrouter*, ollama* the prompt runs through QuantumOS's qos_agent.py tool loop
#                        when OCTOPUS_QOS_AGENT is set; otherwise they stay tool-less
#
# Settings:
#   OCTOPUS_ARMS_HUB            hub config for `qos-hub serve --config` (enables this)
#   OCTOPUS_ARMS_HUB_LITE       smaller config for small-context arms (ollama); default OCTOPUS_ARMS_HUB
#   OCTOPUS_ARMS_HUB_DB         hub ledger; default <config dir>/broker.db
#   OCTOPUS_ARMS_HUB_CMD        how to start the hub; default `qos-hub` (pip install quantumos-host-tools)
#   OCTOPUS_ARMS_HUB_DIR        generated per-arm files; default ~/.kannaktopus/arms-hub
#   OCTOPUS_QOS_AGENT           path to QuantumOS scripts/qos_agent.py
#   OCTOPUS_ARMS_HUB_MAX_TURNS  tool-loop turn cap for the completion arms; default 20
#   OCTOPUS_PYTHON              interpreter for qos_agent.py; default python3, else python
#
# Example configs: config/arms-hub.example.json (QuantumOS, Kannaka and the
# kannaka-tui views as `tui.*`) and config/arms-hub-lite.example.json.
#
# Paths must not contain spaces: arm commands are split on whitespace (spawn.sh).
# The hub config decides what an arm may do. For unattended arms set
# "default": "deny"; an `ask` call is stored and answered approval_required.

ARMS_HUB_NAME="quantumos"

arms_hub_enabled() {
    [[ -n "${OCTOPUS_ARMS_HUB:-}" && -f "$OCTOPUS_ARMS_HUB" ]]
}

_arms_hub_dir() {
    echo "${OCTOPUS_ARMS_HUB_DIR:-${HOME}/.kannaktopus/arms-hub}"
}

# The hub server's argv for config $1, one word per line.
_arms_hub_argv() {
    local cfg="${1:-$OCTOPUS_ARMS_HUB}"
    local db="${OCTOPUS_ARMS_HUB_DB:-$(dirname "$cfg")/broker.db}"
    local w
    # OCTOPUS_ARMS_HUB_CMD may be several words (e.g. "python3 /path/qos_hub.py")
    for w in ${OCTOPUS_ARMS_HUB_CMD:-qos-hub} serve --config "$cfg" --db "$db"; do
        printf '%s\n' "$w"
    done
}

# Sets _ARMS_HUB_CMD (first word, escaped) and _ARMS_HUB_ARGS (the rest as a
# comma-separated list of quoted, escaped strings: valid in JSON and TOML).
_arms_hub_split() {
    local w
    _ARMS_HUB_CMD=""
    _ARMS_HUB_ARGS=""
    while IFS= read -r w; do
        if [[ -z "$_ARMS_HUB_CMD" ]]; then
            _ARMS_HUB_CMD=$(json_escape "$w")
        else
            _ARMS_HUB_ARGS+="${_ARMS_HUB_ARGS:+,}\"$(json_escape "$w")\""
        fi
    done < <(_arms_hub_argv "$1")
}

# Write $2 to file $1 atomically (parallel spawns regenerate the same files).
_arms_hub_write() {
    local tmp="${1}.tmp.$$.${RANDOM}"
    printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# Generate the claude and gemini config files. Returns 1 when disabled.
arms_hub_prepare() {
    arms_hub_enabled || return 1
    local dir
    dir=$(_arms_hub_dir)
    mkdir -p "$dir/gemini-home/.gemini" || return 1
    _arms_hub_split "$OCTOPUS_ARMS_HUB"
    local server="\"command\":\"${_ARMS_HUB_CMD}\",\"args\":[${_ARMS_HUB_ARGS}]"
    _arms_hub_write "$dir/claude-mcp.json" \
        "{\"mcpServers\":{\"${ARMS_HUB_NAME}\":{${server}}}}" || return 1
    _arms_hub_write "$dir/gemini-home/.gemini/settings.json" \
        "{\"mcpServers\":{\"${ARMS_HUB_NAME}\":{${server},\"timeout\":300000,\"trust\":true}}}" || return 1
}

# Extra flags for a claude arm (empty when disabled).
arms_hub_claude_flags() {
    arms_hub_prepare || return 0
    printf -- '--mcp-config %s --allowedTools mcp__%s' "$(_arms_hub_dir)/claude-mcp.json" "$ARMS_HUB_NAME"
}

# Extra flags for a codex arm (empty when disabled). The quotes are literal:
# spawn.sh splits the command on whitespace without quote removal, and codex
# parses each -c value as TOML. `required` makes codex wait for the hub before
# the first turn (otherwise a short task can finish before the tools exist);
# `approve` lets `codex exec` (approval policy never) call them.
arms_hub_codex_flags() {
    arms_hub_enabled || return 0
    _arms_hub_split "$OCTOPUS_ARMS_HUB"
    local s="mcp_servers.${ARMS_HUB_NAME}"
    printf -- '-c %s.command="%s" -c %s.args=[%s] -c %s.required=true -c %s.startup_timeout_sec=90 -c %s.tool_timeout_sec=300 -c %s.default_tools_approval_mode="approve"' \
        "$s" "$_ARMS_HUB_CMD" "$s" "$_ARMS_HUB_ARGS" "$s" "$s" "$s" "$s"
}

# Extra env assignment for a gemini arm (empty when disabled or OAuth).
arms_hub_gemini_env() {
    arms_hub_enabled || return 0
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
        log WARN "arms hub: gemini uses OAuth here; moving its home would hide the login, so it gets no hub tools"
        return 0
    fi
    arms_hub_prepare || return 0
    printf 'GEMINI_CLI_HOME=%s' "$(_arms_hub_dir)/gemini-home"
}

# True when the completion arms can run through the tool loop.
arms_hub_tool_loop_ready() {
    arms_hub_enabled && [[ -n "${OCTOPUS_QOS_AGENT:-}" && -f "$OCTOPUS_QOS_AGENT" ]]
}

# arms_hub_tool_loop <model> <base_url> <key_env> [config] — prompt on stdin.
# Runs qos_agent.py's OpenAI-compatible tool loop against the hub.
arms_hub_tool_loop() {
    local model="$1" base_url="$2" key_env="$3" cfg="${4:-$OCTOPUS_ARMS_HUB}"
    local py="${OCTOPUS_PYTHON:-}"
    if [[ -z "$py" ]]; then
        if python3 -c 'import sys' >/dev/null 2>&1; then py=python3; else py=python; fi
    fi
    local server_cmd
    server_cmd=$(_arms_hub_argv "$cfg" | tr '\n' ' ')
    QOS_AGENT_SERVER_CMD="${server_cmd% }" "$py" "$OCTOPUS_QOS_AGENT" - \
        --provider openai --base-url "$base_url" --api-key-env "$key_env" --model "$model" \
        --max-turns "${OCTOPUS_ARMS_HUB_MAX_TURNS:-20}"
}

# The ollama arm with tools: Ollama's OpenAI-compatible /v1 endpoint, no key,
# and the lite config (a small model's context cannot hold every tool schema).
arms_hub_ollama_execute() {
    local host="${OLLAMA_HOST:-127.0.0.1:11434}"
    host="${host#http://}"
    host="${host#https://}"
    arms_hub_tool_loop "$1" "http://${host}/v1" OLLAMA_API_KEY "${OCTOPUS_ARMS_HUB_LITE:-$OCTOPUS_ARMS_HUB}"
}
