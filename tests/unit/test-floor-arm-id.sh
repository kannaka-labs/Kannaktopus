#!/usr/bin/env bash
# Tests for KANNAKTOPUS_ARM_ID validation in scripts/kannaktopus_floor.py (#94)
# The radio floor keeps a floor_join id only when it matches
# /^[a-z0-9_:.-]{4,40}$/i and otherwise mints a random one, which makes one arm
# count twice. The daemon must refuse such an id instead of sending it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLOOR_PY="$PROJECT_ROOT/scripts/kannaktopus_floor.py"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
if [[ -z "$PYTHON" ]]; then
    echo "SKIP: python3 not available"
    exit 0
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Stub `websockets` so the daemon imports without the real dependency and can
# never open a connection: connect() raises if anything reaches it.
mkdir -p "$TMP_ROOT/stubs/websockets" "$TMP_ROOT/mod"
cat > "$TMP_ROOT/stubs/websockets/__init__.py" <<'PY'
def connect(*_a, **_k):
    raise RuntimeError("test stub: the daemon must not connect in this test")
PY
cat > "$TMP_ROOT/stubs/websockets/exceptions.py" <<'PY'
class ConnectionClosed(Exception):
    pass
PY
tr -d '\r' < "$FLOOR_PY" > "$TMP_ROOT/mod/kannaktopus_floor.py"

# PYTHONPATH in the interpreter's own path syntax (a Windows python under Git
# Bash needs `;` and native paths).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
PYSEP=$("$PYTHON" -c 'import os; print(os.pathsep)' | tr -d '\r')
STUBS="$(native "$TMP_ROOT/stubs")"
MODDIR="$(native "$TMP_ROOT/mod")"
FLOOR_COPY="$(native "$TMP_ROOT/mod/kannaktopus_floor.py")"
export PYTHONIOENCODING=utf-8

# Ask the module whether an id would be kept (prints "ok" or the reason).
check_id() {
    PYTHONPATH="${STUBS}${PYSEP}${MODDIR}" "$PYTHON" -c '
import sys
import kannaktopus_floor as f
err = f.floor_id_error(sys.argv[1])
print("ok" if err is None else err)
' "$1" | tr -d '\r'
}

for id in kannaktopus-01 KANNAKTOPUS-ALPHA kannaka-prime "agent:kt.01_x" abcd "$(printf 'a%.0s' {1..40})"; do
    r=$(check_id "$id")
    if [[ "$r" == "ok" ]]; then pass "id '$id' is accepted"; else fail "id '$id' is accepted" "$r"; fi
done

for id in abc "$(printf 'a%.0s' {1..41})" "KANNAKTOPUS-ALPHA-LONG-ID-EXCEEDS-40-CHARS-XYZ" "kannaktopus 01" "kannaktopus/01"; do
    r=$(check_id "$id")
    if [[ -n "$r" && "$r" != "ok" ]]; then pass "id '$id' is refused"; else fail "id '$id' is refused" "got '$r'"; fi
done

# Non-ASCII letters that Python's re.IGNORECASE would fold onto [a-z]
# (U+212A KELVIN SIGN -> k, U+017F LONG S -> s) are rejected by the radio's
# JS regex, so they must be refused here too.
r=$(PYTHONPATH="${STUBS}${PYSEP}${MODDIR}" "$PYTHON" -c 'import kannaktopus_floor as f; print("ok" if f.floor_id_error("Kannaktopuſ") is None else "refused")' | tr -d '\r')
if [[ "$r" == "refused" ]]; then pass "Unicode case-folding lookalikes are refused"; else fail "Unicode case-folding lookalikes are refused" "got '$r'"; fi

# A trailing newline must not slip through (Python's `$` would allow it).
r=$(PYTHONPATH="${STUBS}${PYSEP}${MODDIR}" "$PYTHON" -c 'import kannaktopus_floor as f; print("ok" if f.floor_id_error("kannaktopus-01\n") is None else "refused")' | tr -d '\r')
if [[ "$r" == "refused" ]]; then pass "id with trailing newline is refused"; else fail "id with trailing newline is refused" "got '$r'"; fi

# End to end: an invalid id exits 2 (config error) before any connection.
rc=0
out=$(KANNAKTOPUS_ARM_ID="KANNAKTOPUS-ALPHA-LONG-ID-EXCEEDS-40-CHARS-XYZ" PYTHONPATH="$STUBS" \
    "$PYTHON" "$FLOOR_COPY" 2>&1) || rc=$?
if [[ "$rc" -eq 2 ]]; then pass "invalid KANNAKTOPUS_ARM_ID exits 2"; else fail "invalid KANNAKTOPUS_ARM_ID exits 2" "exit $rc: $out"; fi
if grep -q "Not joining" <<<"$out"; then pass "invalid id is logged loudly"; else fail "invalid id is logged loudly" "$out"; fi
if ! grep -q "test stub" <<<"$out"; then pass "invalid id never reaches connect()"; else fail "invalid id never reaches connect()" "$out"; fi

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ "$FAIL_COUNT" -eq 0 ]]
