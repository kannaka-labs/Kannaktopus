#!/bin/bash
# tests/unit/test-error-learning.sh
# Tests error learning loop (v8.19.0)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Error Learning Loop"

# Combined search target (functions decomposed to lib/ in v9.7.7+)
ALL_SRC=$(mktemp)
cat "$PROJECT_ROOT/scripts/orchestrate.sh" "$PROJECT_ROOT/scripts/lib/"*.sh > "$ALL_SRC" 2>/dev/null

test_record_error_function_exists() {
    test_case "record_error function exists"

    if grep -q "record_error()" "$ALL_SRC"; then
        test_pass
    else
        test_fail "record_error function not found"
    fi
}

test_search_similar_errors_function_exists() {
    test_case "search_similar_errors function exists"

    if grep -q "search_similar_errors()" "$ALL_SRC"; then
        test_pass
    else
        test_fail "search_similar_errors function not found"
    fi
}

test_flag_repeat_error_function_exists() {
    test_case "flag_repeat_error function exists"

    if grep -q "flag_repeat_error()" "$ALL_SRC"; then
        test_pass
    else
        test_fail "flag_repeat_error function not found"
    fi
}

test_error_format() {
    test_case "Error format includes required fields"

    local func_body
    func_body=$(sed -n '/^record_error()/,/^}/p' "$ALL_SRC")

    if echo "$func_body" | grep -q "### ERROR |" && \
       echo "$func_body" | grep -q "Task:" && \
       echo "$func_body" | grep -q "Error:" && \
       echo "$func_body" | grep -q "Root Cause:" && \
       echo "$func_body" | grep -q "Prevention:"; then
        test_pass
    else
        test_fail "Error format missing required fields"
    fi
}

test_error_cap_100() {
    test_case "Error log capped at 100 entries"

    local func_body
    func_body=$(sed -n '/^record_error()/,/^}/p' "$ALL_SRC")

    if echo "$func_body" | grep -q "100"; then
        test_pass
    else
        test_fail "100 entry cap not found"
    fi
}

test_error_recording_in_spawn_agent() {
    test_case "record_error called in spawn_agent failure path"

    if grep -B 2 -A 2 "record_error.*spawn_agent" "$ALL_SRC" | grep -q "record_error"; then
        test_pass
    else
        test_fail "record_error not called in spawn_agent failure"
    fi
}

test_error_context_in_retries() {
    test_case "Error context injected into retry prompts"

    if grep -A 60 "retry_failed_subtasks()" "$ALL_SRC" | grep -q "search_similar_errors\|RETRY CONTEXT"; then
        test_pass
    else
        test_fail "Error context not injected into retries"
    fi
}

test_repeat_detection() {
    test_case "Repeat error detection triggers structured decision"

    local func_body
    func_body=$(sed -n '/^flag_repeat_error()/,/^}/p' "$ALL_SRC")

    if echo "$func_body" | grep -q "write_structured_decision" && echo "$func_body" | grep -q "ge 2"; then
        test_pass
    else
        test_fail "Repeat detection not properly implemented"
    fi
}

test_dry_run_with_error_learning() {
    test_case "Dry-run works with error learning code"

    local output
    output=$("$PROJECT_ROOT/scripts/orchestrate.sh" -n tangle "test" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        test_pass
    else
        test_fail "Dry-run failed: $exit_code"
    fi
}

test_control_pipe_no_reader_does_not_hang() {
    test_case "update_task_progress does not hang on FIFO with no reader"

    local T rc=0 tcmd
    tcmd=$(command -v timeout || command -v gtimeout) || tcmd=""
    if [[ -z "$tcmd" ]]; then
        echo "  SKIP: no timeout/gtimeout to bound the check"
        test_pass
        return
    fi
    T=$(mktemp -d)
    if ! mkfifo "$T/p" 2>/dev/null; then
        rm -rf "$T"
        echo "  SKIP: mkfifo not supported"
        test_pass
        return
    fi
    TASK_PROGRESS_ENABLED=true CLAUDE_CODE_CONTROL_PIPE="$T/p" "$tcmd" 6 bash -c \
        'source "$1/scripts/lib/error-tracking.sh"; log(){ :; }; update_task_progress t x' _ "$PROJECT_ROOT" \
        >/dev/null 2>&1 || rc=$?
    rm -rf "$T"
    if [[ "$rc" -eq 124 ]]; then
        test_fail "update_task_progress hung on dead control pipe (timeout)"
    else
        test_pass
    fi
}

test_record_error_concurrent_safe() {
    test_case "concurrent record_error keeps log intact at the 100 cap"

    local T i
    T=$(mktemp -d)
    mkdir -p "$T/.octo/errors"
    for i in $(seq 1 100); do
        printf '\n### ERROR | 2026-01-01T00:00:00Z | agent: seed | exit_code: 1\n**Task:** seed%s\n**Error:** seed\n**Attempt:** x\n**Root Cause:** Pending analysis\n**Prevention:** Pending\n---\n' "$i" >> "$T/.octo/errors/error-log.md"
    done
    WORKSPACE_DIR="$T" PROJECT_ROOT="$PROJECT_ROOT" timeout 120 bash -c '
        source "$PROJECT_ROOT/scripts/lib/error-tracking.sh"; log(){ :; }
        for n in $(seq 1 20); do record_error agent t "uniqmsg-$n" 1 & done
        wait' >/dev/null 2>&1 || true
    local f="$T/.octo/errors/error-log.md" bad=0 found=0 hdrs
    hdrs=$(grep -c "^### ERROR |" "$f" 2>/dev/null) || hdrs=0
    bad=$(tr -d '\r' < "$f" | grep "^### ERROR |" | grep -vc -E '^### ERROR \| [0-9T:Z-]+ \| agent: [a-z]+ \| exit_code: [0-9]+$') || true
    for i in $(seq 1 20); do
        if tr -d '\r' < "$f" | grep -q "^\*\*Error:\*\* uniqmsg-$i\$"; then found=$((found + 1)); fi
    done
    local leftovers
    leftovers=$(ls "$T/.octo/errors" | grep -c -E 'error-log\.md\.[A-Za-z0-9]{4}$') || leftovers=0
    rm -rf "$T"
    if [[ "$bad" -eq 0 && "$found" -eq 20 && "$hdrs" -eq 100 && "$leftovers" -eq 0 ]]; then
        test_pass
    else
        test_fail "headers=$hdrs bad=$bad found=$found/20 leftover_tmp=$leftovers"
    fi
}

# Run tests
test_record_error_function_exists
test_search_similar_errors_function_exists
test_flag_repeat_error_function_exists
test_error_format
test_error_cap_100
test_error_recording_in_spawn_agent
test_error_context_in_retries
test_repeat_detection
test_dry_run_with_error_learning
test_control_pipe_no_reader_does_not_hang
test_record_error_concurrent_safe

rm -f "$ALL_SRC"
test_summary
