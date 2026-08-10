#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/nats-publish.sh — Optional fire-and-forget NATS publishing for
# Kannaktopus orchestrate.sh phase events.
#
# When the `nats` CLI (https://github.com/nats-io/natscli) is installed,
# orchestrate.sh emits per-phase signals on `QUEEN.phase.<armId>` so the
# Kannaka Constellation observatory (and QueenSync Queen Console) can show
# this Kannaktopus instance pulsing as it works.
#
# When the `nats` CLI is missing the helper silently no-ops — Kannaktopus
# itself never blocks on the bus.
# ─────────────────────────────────────────────────────────────────────────────

# Public bus by default. Override with NATS_URL=nats://localhost:4222 etc.
# Precedence: NATS_URL (explicit, and what the shipped systemd units set)
# wins over the constellation-wide KANNAKA_NATS_URL, which wins over the
# public default. The same order is applied in scripts/kannaktopus_listener.py
# and scripts/queensync_presence.py so every entrypoint lands on one bus.
KANNAKTOPUS_NATS_URL="${NATS_URL:-${KANNAKA_NATS_URL:-nats://swarm.ninja-portal.com:4222}}"
KANNAKTOPUS_ARM_ID="${KANNAKTOPUS_ARM_ID:-kannaktopus-01}"

# Envelope schema version from the constellation contract
# (consciousness-core/docs/nats-contract.yaml). Ratified 2026-05-02.
KANNAKTOPUS_NATS_SCHEMA_VERSION="1.0"

# nats_available — returns 0 if the `nats` CLI is on PATH.
nats_available() {
    command -v nats >/dev/null 2>&1
}

# _json_escape <string>
# Emit a string properly escaped as a JSON string value (no surrounding quotes).
# Prefers `jq` when available; falls back to a pure-bash escaper that handles
# the characters that actually appear in arm ids / task ids / phases.
_json_escape() {
    local s="$1"
    if command -v jq >/dev/null 2>&1; then
        # -Rs: read raw, slurp; jq itself adds the surrounding quotes — strip them
        # so callers can decide whether to wrap in quotes.
        local quoted
        quoted=$(printf '%s' "$s" | jq -Rs .)
        # jq prints "..."\n — strip the leading/trailing quote and trailing newline.
        quoted="${quoted%$'\n'}"
        printf '%s' "${quoted:1:${#quoted}-2}"
        return
    fi
    # Pure-bash fallback. Escape order matters — backslash first.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# _unix_ms — current time as unix MILLISECONDS (a bare integer).
#
# The contract types `ts` as a number in unix-ms on every subject. GNU date
# gives us that with %s%3N; BSD/macOS date has no %N and emits a non-numeric
# blob, so fall back to whole seconds * 1000 whenever the result isn't a
# plausible ms timestamp (>= 13 digits; seconds are only 10).
_unix_ms() {
    local ms
    ms=$(date -u +%s%3N 2>/dev/null)
    if [[ "$ms" =~ ^[0-9]{13,}$ ]]; then
        printf '%s' "$ms"
        return
    fi
    printf '%s000' "$(date -u +%s)"
}

# _envelope_fields — the canonical envelope shared by every publish.
#
# The constellation contract (consciousness-core/docs/nats-contract.yaml)
# lists schema_version, ts and agent_id as REQUIRED on every subject we
# touch. Consumers are still in log-warn-accept mode, but the revised
# migration plan flips them to drop-on-missing, so emit them now.
#
# Printed as a bare comma-separated JSON fragment (no braces) so callers
# can splice it into the front of their object literal.
_envelope_fields() {
    printf '"schema_version":"%s","ts":%s,"agent_id":"%s"' \
        "$KANNAKTOPUS_NATS_SCHEMA_VERSION" \
        "$(_unix_ms)" \
        "$(_json_escape "$KANNAKTOPUS_ARM_ID")"
}

# nats_publish <subject> <payload>
# Fire-and-forget. Backgrounded so we never delay a phase boundary.
#
# Auth: the constellation bus restricts queen.event.* / QUEEN.phase.*
# publishes to authenticated users, and an unauthenticated publish is
# silently dropped (no error, no log) — see the same note in
# scripts/queensync_presence.py::_connect_with_backoff. NATS_CREDS (a path
# to an nkey/JWT credentials file) is preferred over NATS_USER/NATS_PASSWORD
# because the user/password form puts the secret in this process's argv,
# which is world-readable via `ps`; the `nats` CLI has no env-var form for
# a plain password, so argv is the only route when creds aren't available.
nats_publish() {
    local subject="$1"
    local payload="$2"
    nats_available || return 0

    local -a auth=()
    if [[ -n "${NATS_CREDS:-}" ]]; then
        auth=(--creds "$NATS_CREDS")
    elif [[ -n "${NATS_USER:-}" && -n "${NATS_PASSWORD:-}" ]]; then
        auth=(--user "$NATS_USER" --password "$NATS_PASSWORD")
    fi

    (
        printf '%s' "$payload" \
            | nats --server "$KANNAKTOPUS_NATS_URL" \
                ${auth[@]+"${auth[@]}"} pub "$subject" \
                >/dev/null 2>&1 \
            || true
    ) &
    disown 2>/dev/null || true
}

# nats_publish_phase <phase> [taskId] [extra_json]
# Emits a QUEEN.phase.<armId> event carrying the canonical envelope, e.g.
#   {"schema_version":"1.0","ts":1777730400000,"agent_id":"kannaktopus-01",
#    "armId":"kannaktopus-01","phase":"probe","taskId":"abc"}
#
# Note: `phase` here is the embrace STAGE name (probe/grasp/tangle/ink), not
# the Kuramoto radian the contract types on QUEEN.phase.*. That divergence
# predates the envelope and is what the QueenSync arm card reads, so it is
# left alone here.
#
# All string fields are JSON-escaped. `extra_json` is treated as a raw JSON
# fragment (object/array/scalar) — caller is responsible for it being valid
# JSON. Pass nothing or an empty string to omit it.
nats_publish_phase() {
    local phase="$1"
    local task_id="${2:-}"
    local extra="${3:-}"
    local arm_id_e phase_e task_e envelope subject payload
    subject="QUEEN.phase.$(_json_escape "$KANNAKTOPUS_ARM_ID")"
    # Subject names should be plain ASCII identifiers, but if someone sets a
    # weird arm id, NATS will still accept whatever we send — just don't let
    # quotes or whitespace break the publish CLI invocation.
    subject="${subject//[^A-Za-z0-9._-]/_}"

    arm_id_e=$(_json_escape "$KANNAKTOPUS_ARM_ID")
    phase_e=$(_json_escape "$phase")
    task_e=$(_json_escape "$task_id")
    # Supplies the contract-required schema_version/ts/agent_id. `ts` moves
    # from an ISO-8601 string to the contract's unix-ms number here.
    envelope=$(_envelope_fields)

    if [[ -n "$extra" ]]; then
        payload=$(printf '{%s,"armId":"%s","phase":"%s","taskId":"%s","extra":%s}' \
            "$envelope" "$arm_id_e" "$phase_e" "$task_e" "$extra")
    else
        payload=$(printf '{%s,"armId":"%s","phase":"%s","taskId":"%s"}' \
            "$envelope" "$arm_id_e" "$phase_e" "$task_e")
    fi
    nats_publish "$subject" "$payload"
}

# nats_publish_join — one-shot presence (queen.event.join). Useful from
# orchestrate.sh on first invocation so the arm shows up immediately even
# before the long-running queensync_presence.py daemon publishes its first
# beat. The presence daemon is still preferred for continuous heartbeats.
nats_publish_join() {
    local arm_id_e display_e envelope payload
    arm_id_e=$(_json_escape "$KANNAKTOPUS_ARM_ID")
    display_e=$(_json_escape "${KANNAKTOPUS_DISPLAY_NAME:-Kannaktopus}")
    # Same envelope the presence daemon spreads into its join payload, so
    # both publishers of queen.event.join look identical on the wire.
    envelope=$(_envelope_fields)
    payload=$(printf '{%s,"armId":"%s","displayName":"%s","kind":"kannaktopus_arm"}' \
        "$envelope" "$arm_id_e" "$display_e")
    nats_publish "queen.event.join" "$payload"
}
