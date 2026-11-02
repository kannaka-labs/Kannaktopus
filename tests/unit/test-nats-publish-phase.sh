#!/usr/bin/env bash
# Tests for nats_publish_phase (scripts/lib/nats-publish.sh), Kannaktopus #93.
#
# orchestrate.sh documents status/workflow/completed/total/metrics as TOP-LEVEL
# fields of the QUEEN.phase.<armId> event (what the Queen Console reads), but
# the helper used to nest the caller's JSON under "extra". The caller's object
# must now be merged into the top level (armId/phase/taskId/ts/... win on a
# clash) and still be copied under "extra" for one release.
#
# The `nats` CLI is stubbed: it records its subject and stdin payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/scripts/lib/nats-publish.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/nats" <<'STUB'
#!/usr/bin/env bash
# Stub nats CLI: record the subject (arg after "pub") and the stdin payload.
subj=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "pub" ]]; then subj="$2"; break; fi
    shift
done
printf '%s' "$subj" > "$NATS_STUB_DIR/subject"
cat > "$NATS_STUB_DIR/payload.tmp"
mv "$NATS_STUB_DIR/payload.tmp" "$NATS_STUB_DIR/payload"
STUB
chmod +x "$WORK/bin/nats"

export NATS_STUB_DIR="$WORK"
export PATH="$WORK/bin:$PATH"
export KANNAKTOPUS_ARM_ID="arm-test"
unset NATS_CREDS NATS_USER NATS_PASSWORD || true

# Strip CR so the test also works on CRLF (autocrlf) checkouts.
# shellcheck disable=SC1090
source <(tr -d '\r' < "$LIB")

# emit <phase> <task> [extra] -> echoes the payload the stub received
emit() {
    rm -f "$WORK/payload" "$WORK/subject"
    nats_publish_phase "$@"
    local i
    for i in $(seq 1 100); do
        [[ -f "$WORK/payload" ]] && break
        sleep 0.05
    done
    cat "$WORK/payload" 2>/dev/null || true
}

check() { # check <name> <payload> <jq -e filter>
    if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then
        pass "$1"
    else
        fail "$1" "filter '$3' failed on: $2"
    fi
}

EXTRA='{"status":"completed","workflow":"embrace","completed":2,"total":4,"metrics":{"cost":0.5}}'
OUT=$(emit probe task-1 "$EXTRA")

check "payload is valid JSON" "$OUT" '.'
check "status is top-level" "$OUT" '.status == "completed"'
check "workflow is top-level" "$OUT" '.workflow == "embrace"'
check "completed/total are top-level numbers" "$OUT" '.completed == 2 and .total == 4'
check "metrics is top-level" "$OUT" '.metrics.cost == 0.5'
check "extra copy retained for one release" "$OUT" '.extra.status == "completed" and .extra.total == 4 and .extra.metrics.cost == 0.5'
check "identity fields intact" "$OUT" '.armId == "arm-test" and .phase == "probe" and .taskId == "task-1" and .agent_id == "arm-test"'
if [[ "$(cat "$WORK/subject")" == "QUEEN.phase.arm-test" ]]; then
    pass "published on QUEEN.phase.<armId>"
else
    fail "published on QUEEN.phase.<armId>" "got $(cat "$WORK/subject")"
fi

# Reserved keys win over a clashing caller key.
CLASH='{"armId":"evil","phase":"evil","taskId":"evil","ts":1,"schema_version":"9","agent_id":"evil","extra":"evil","status":"running"}'
OUT=$(emit tangle task-2 "$CLASH")
check "armId/phase/taskId win over caller keys" "$OUT" '.armId == "arm-test" and .phase == "tangle" and .taskId == "task-2"'
check "ts wins over caller key (unix-ms number)" "$OUT" '(.ts | type) == "number" and .ts > 1000000000000'
check "schema_version/agent_id win over caller keys" "$OUT" '.schema_version == "1.0" and .agent_id == "arm-test"'
check "non-clashing caller key still merged" "$OUT" '.status == "running"'
check "a caller key named extra loses to the deprecated copy" "$OUT" '.extra.status == "running"'

# No extra / non-object extra: unchanged shape.
OUT=$(emit grasp task-3)
check "no extra: no extra key, valid event" "$OUT" 'has("extra") | not'
OUT=$(emit grasp task-3 '[1,2]')
check "array extra stays nested only" "$OUT" '.extra == [1,2] and .armId == "arm-test"'

# Same contract without jq (pure-bash fallback). `command -v jq` is hidden in a
# subshell; assertions below still use the real jq.
emit_nojq() {
    (
        command() { if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then return 1; fi; builtin command "$@"; }
        emit "$@"
    )
}
OUT=$(emit_nojq probe task-4 "$EXTRA")
check "no-jq: valid JSON, caller keys top-level" "$OUT" '.status == "completed" and .workflow == "embrace" and .completed == 2 and .total == 4 and .metrics.cost == 0.5'
check "no-jq: extra copy retained" "$OUT" '.extra.status == "completed" and .extra.total == 4'
OUT=$(emit_nojq tangle task-5 "$CLASH")
check "no-jq: reserved keys win" "$OUT" '.armId == "arm-test" and .phase == "tangle" and .taskId == "task-5" and .agent_id == "arm-test" and .schema_version == "1.0" and (.ts | type) == "number" and .ts > 1000000000000'
check "no-jq: non-clashing caller key merged" "$OUT" '.status == "running"'
OUT=$(emit_nojq grasp task-6 '{}')
check "no-jq: empty object extra is valid" "$OUT" '.armId == "arm-test" and .extra == {}'

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
if [[ "$FAIL_COUNT" -eq 0 ]]; then exit 0; else exit 1; fi
