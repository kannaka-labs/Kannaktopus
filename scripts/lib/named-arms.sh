#!/usr/bin/env bash
# named-arms — Kannaktopus's two named arms, run by scripts/named_arms.py:
#
#   kannaka-vigil      Vigil, the auditor. Tries to refute a document before it
#                      goes out under a lab name. GLM via OpenRouter; set
#                      OCTOPUS_VIGIL_BACKEND=ollama to use the local
#                      kannaka-brain-glm LoRA once it passes its gate.
#   kannaka-ferryman   Ferryman, the steward (alias kannaka-steward). Sweeps for
#                      leads, tracks deadlines and owed replies, proposes
#                      settlements and writes drafts, all for Nick's review.
#                      Claude via the Anthropic API (ANTHROPIC_API_KEY).
#
# Neither arm has tools: each call is one HTTP request, so neither can send,
# post, pay or sign anything. Every call appends one row to an append-only,
# 0600 ledger in the rogue-agent answers.jsonl shape:
#   ${OCTOPUS_ARMS_LEDGER_ROOT:-~/.kannaktopus/ledger}/instances/<arm>/answers.jsonl
#
# Entry points:
#   orchestrate.sh vigil <file> [--source PATH|URL ...] [--fetch-links] [--kind K]
#   orchestrate.sh ferryman sweep|due|settle|draft|budget ...
#   orchestrate.sh spawn kannaka-vigil "<prompt>"     (via named_arm_execute)
#
# Settings (all optional):
#   OCTOPUS_VIGIL_BACKEND / _MODEL / _MAX_USD_RUN / _MAX_USD_WEEK / _MAX_TOKENS / _BASE_URL
#   OCTOPUS_FERRYMAN_BACKEND / _MODEL / _MAX_USD_RUN / _MAX_USD_WEEK / _MAX_TOKENS / _EFFORT
#   OCTOPUS_NAMED_ARMS_CONFIG_DIR  per-arm JSON config; default ~/.kannaktopus/config/arms
#   OCTOPUS_ARMS_LEDGER_ROOT       ledger root; default ~/.kannaktopus/ledger
#   OCTOPUS_NAMED_ARMS_NATS=true   also pulse QUEEN.phase.<arm> (verdict + cost only, never content)
#   OCTOPUS_PYTHON                 interpreter; default python3, else python
#
# Example configs: config/arms/vigil.example.json, config/arms/ferryman.example.json.
# Docs: docs/NAMED-ARMS.md.

_NAMED_ARMS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMED_ARMS_PY="${_NAMED_ARMS_LIB_DIR}/../named_arms.py"

_named_arms_python() {
    if [[ -n "${OCTOPUS_PYTHON:-}" ]]; then echo "$OCTOPUS_PYTHON"; return; fi
    local p
    for p in python3 python; do
        # the Windows Store python3 stub exists but cannot run code
        if command -v "$p" &>/dev/null && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 9))' &>/dev/null; then
            echo "$p"; return
        fi
    done
    echo python3
}

_named_arms_run() {
    PYTHONIOENCODING=utf-8 "$(_named_arms_python)" -I "$NAMED_ARMS_PY" "$@"
}

# _named_arms_after <metafile> <phase>: book each call from the meta lines into
# the session usage log (real cost, role "actual") and, when enabled, pulse NATS.
_named_arms_after() {
    local meta="$1" phase="$2" line
    [[ -s "$meta" ]] || return 0
    while IFS= read -r line; do
        local fields
        fields=$(printf '%s' "$line" | PYTHONIOENCODING=utf-8 "$(_named_arms_python)" -I -c '
import json, sys
m = json.loads(sys.stdin.read())
print("|".join(str(x) for x in (m.get("arm"), m.get("gateway_model") or m.get("model"), m.get("task"),
      m.get("cost_usd") or 0, m.get("elapsed_ms") or 0, m.get("verdict") or "", m.get("exit"), m.get("answer_id"))))
' 2>/dev/null) || continue
        local arm model task cost ms verdict code aid
        IFS='|' read -r arm model task cost ms verdict code aid <<< "$fields"
        if [[ -n "${USAGE_FILE:-}" && -d "$(dirname "$USAGE_FILE")" ]]; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$arm|$model|$phase|actual|0|0|0|$cost|$ms|named-arm" >> "${USAGE_FILE}.log"
        fi
        if [[ "${OCTOPUS_NAMED_ARMS_NATS:-false}" == "true" ]] && type nats_publish_phase &>/dev/null; then
            KANNAKTOPUS_ARM_ID="$arm" nats_publish_phase "$task" "$aid" \
                "$(printf '{"status":"%s","metrics":{"cost_usd":%s,"model":"%s"},"verdict":"%s"}' \
                    "$([[ "$code" == 0 || "$code" == 10 || "$code" == 11 ]] && echo completed || echo failed)" \
                    "$cost" "$model" "$verdict")" >/dev/null 2>&1 || true
        fi
    done < "$meta"
}

_named_arms_meta() {
    local d="${TMPDIR:-/tmp}"
    mktemp "$d/named-arms-meta.XXXXXX" 2>/dev/null || echo "$d/named-arms-meta.$$.$RANDOM"
}

# named_arm_execute <arm>: the spawn path. Prompt on stdin, reply on stdout.
named_arm_execute() {
    local arm="$1" meta rc
    case "$arm" in
        kannaka-vigil|kannaka-ferryman|kannaka-steward) ;;
        *) echo "named_arm_execute: unknown arm '$arm'" >&2; return 2 ;;
    esac
    meta=$(_named_arms_meta)
    _named_arms_run call --arm "$arm" --meta-out "$meta"
    rc=$?
    _named_arms_after "$meta" "spawn"
    rm -f "$meta"
    return $rc
}

vigil_cmd() {
    if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        cat <<'EOF'
Usage: orchestrate.sh vigil <file> [--source PATH|URL ...] [--fetch-links] [--kind KIND]
       orchestrate.sh vigil budget

Vigil (kannaka-vigil) tries to refute <file> before it goes out under a lab name.
It splits the file into claims and marks each SUPPORTED, REFUTED or UNVERIFIABLE,
citing only the given sources; knowledge from memory never counts as SUPPORTED.
It never publishes or rewrites anything.

Options:
  --source, -s PATH|URL  evidence for the claims (repeatable; URLs capped at 200 KB)
  --fetch-links          also fetch up to 10 links found in the file
  --kind KIND            market-call | essay | oration | pr | grant | draft | settlement | other

Exit codes: 0 PUBLISH, 10 FIX, 11 DROP, 3 refused by a cost cap (no call made),
4 reply failed the schema, 5 provider error, 2 usage.
The verdict JSON goes to ~/.kannaktopus/results/kannaka-vigil-<id>.json; the
call goes to the ledger (see `vigil budget`).

Model: OpenRouter z-ai/glm-5.3 by default (OPENROUTER_API_KEY).
  OCTOPUS_VIGIL_BACKEND=ollama  switch to the local kannaka-brain-glm-v1 (OLLAMA_HOST)
  OCTOPUS_VIGIL_MAX_USD_RUN / OCTOPUS_VIGIL_MAX_USD_WEEK  caps (default 0.10 / 2.00)
EOF
        return 0
    fi
    if [[ "$1" == "budget" ]]; then _named_arms_run budget --arm kannaka-vigil; return; fi
    local meta rc
    meta=$(_named_arms_meta)
    _named_arms_run audit "$@" --meta-out "$meta"
    rc=$?
    _named_arms_after "$meta" "vigil"
    rm -f "$meta"
    return $rc
}

ferryman_cmd() {
    local sub="${1:-help}"
    case "$sub" in
        sweep|due|settle|draft)
            shift
            local meta rc
            meta=$(_named_arms_meta)
            _named_arms_run "$sub" "$@" --meta-out "$meta"
            rc=$?
            _named_arms_after "$meta" "ferryman-$sub"
            rm -f "$meta"
            return $rc
            ;;
        budget) _named_arms_run budget --arm kannaka-ferryman ;;
        config) _named_arms_run config --arm kannaka-ferryman ;;
        help|--help|-h|*)
            cat <<'EOF'
Usage: orchestrate.sh ferryman <command> [options]

Ferryman (kannaka-ferryman, alias kannaka-steward) is the lab's steward. It
drafts, tracks and proposes; it never sends, signs, registers, pays or promises
Nick's time. Everything it writes waits for Nick.

Commands:
  sweep [--since 24h] [--input PATH ...]
        run the read-only collectors in ~/.kannaktopus/config/arms/ferryman.json,
        classify each lead real | plausible | liminal | scam-risk, append new
        ones to ~/.kannaktopus/ferryman/register.jsonl, write a digest to results/
  due [--days 7]
        deadlines and owed replies from the register (no model call, $0)
  settle [--market N] --evidence PATH|URL ...
        propose an outcome for each due market in the public
        Kannaka/calls-and-settlements dataset from the evidence given, then run
        Vigil on the proposal. Writes ~/.kannaktopus/ferryman/settlements-pending.jsonl.
        Never uploads to HF and never resolves a market: that stays Nick's step.
  draft <brief.md> [--input PATH ...]
        write a draft to ~/.kannaktopus/ferryman/drafts/, then run Vigil on it.
        A draft is ready for Nick only after Vigil returns PUBLISH or FIX.
  budget    spend in the last 7 days against the weekly cap
  config    the effective configuration (no secrets)

Model: Anthropic API claude-opus-5-5 by default (ANTHROPIC_API_KEY).
  OCTOPUS_FERRYMAN_MODEL, OCTOPUS_FERRYMAN_EFFORT (default medium)
  OCTOPUS_FERRYMAN_MAX_USD_RUN / OCTOPUS_FERRYMAN_MAX_USD_WEEK  caps (default 0.60 / 10.00)
EOF
            [[ "$sub" == help || "$sub" == --help || "$sub" == -h ]]
            ;;
    esac
}
