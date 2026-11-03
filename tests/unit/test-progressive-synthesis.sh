#!/usr/bin/env bash
# tests/unit/test-progressive-synthesis.sh
# Issue #162: progressive synthesis never started (inverted string tests) and the
# partial synthesis skipped every result file that existed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

LOG_FILE=""
log() { [[ -n "$LOG_FILE" ]] && echo "$*" >> "$LOG_FILE"; return 0; }

export RESULTS_DIR="$TEST_TMP_DIR/results"
mkdir -p "$RESULTS_DIR"
source "$PROJECT_ROOT/scripts/lib/progressive.sh"

MONITOR_PID=""
trap '[[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null; cleanup_test_environment' EXIT

big_result() {  # file [first-line]
    { [[ -n "${2:-}" ]] && echo "$2"; printf 'X%.0s' {1..600}; } > "$1"
}

wait_for() {  # file seconds
    local i
    for (( i = 0; i < $2 * 4; i++ )); do [[ -s "$1" ]] && return 0; sleep 0.25; done
    return 1
}

stop_monitor() {  # group
    touch "$RESULTS_DIR/probe-synthesis-$1.md"
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
}

test_monitor_starts_partial_synthesis() {
    local g="start" partial="$RESULTS_DIR/.partial-synthesis-start.md"
    big_result "$RESULTS_DIR/a-probe-$g-1.md"
    big_result "$RESULTS_DIR/b-probe-$g-2.md"
    progressive_synthesis_monitor "$g" "p" 2 &
    MONITOR_PID=$!
    wait_for "$partial" 15 || { stop_monitor "$g"; test_fail "partial synthesis never started"; return 1; }
    # Check before stopping: the monitor deletes the partial file on exit
    local ok=0; grep -q "Partial Synthesis (2/2 results)" "$partial" || ok=1
    stop_monitor "$g"
    [[ $ok -eq 0 ]] || { test_fail "partial synthesis missing the 2/2 header"; return 1; }
    [[ ! -e "$partial" ]] || { test_fail "partial file not cleaned up when the monitor stopped"; return 1; }
}

test_partial_synthesis_reads_existing_results() {
    local g="content" out
    big_result "$RESULTS_DIR/a-probe-$g-1.md" "UNIQUE_MARKER_1"
    big_result "$RESULTS_DIR/b-probe-$g-2.md" 'UNIQUE_MARKER_2 C:\new\temp'
    out=$(synthesize_probe_results_partial "$g" "p" 2) || out=""
    assert_contains "$out" "Partial Synthesis (2/2 results)" || return 1
    assert_contains "$out" "UNIQUE_MARKER_1" || return 1
    # Backslashes in agent output survive, and the separator is a real newline
    assert_contains "$out" 'UNIQUE_MARKER_2 C:\new\temp' || return 1
    assert_not_contains "$out" '\n\n---' || return 1
}

test_monitor_starts_once_and_logs_updates() {
    local g="once" marker="$RESULTS_DIR/marker-once"
    LOG_FILE="$RESULTS_DIR/log-once"
    big_result "$RESULTS_DIR/a-probe-$g-1.md"
    big_result "$RESULTS_DIR/b-probe-$g-2.md"
    local real; real=$(declare -f synthesize_probe_results_partial)
    synthesize_probe_results_partial() { echo run >> "$marker"; }
    progressive_synthesis_monitor "$g" "p" 2 &
    MONITOR_PID=$!
    wait_for "$marker" 15
    big_result "$RESULTS_DIR/c-probe-$g-3.md"   # a third result arrives after the start
    wait_for "$LOG_FILE" 15
    local i; for (( i = 0; i < 40; i++ )); do grep -q updating "$LOG_FILE" 2>/dev/null && break; sleep 0.25; done
    stop_monitor "$g"
    eval "$real"
    LOG_FILE=""
    assert_equals "1" "$(wc -l < "$marker" 2>/dev/null | tr -d ' ')" "partial synthesis should start exactly once" || return 1
    grep -q "updating (3 results)" "$RESULTS_DIR/log-once" || { test_fail "no update logged for the third result"; return 1; }
}

test_suite "Progressive Synthesis (#162)"
run_test test_monitor_starts_partial_synthesis
run_test test_partial_synthesis_reads_existing_results
run_test test_monitor_starts_once_and_logs_updates
test_summary
