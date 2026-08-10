#!/usr/bin/env bash
# Kannaktopus Scheduler - Cron Expression Parser (v8.15.0)
# Pure Bash/awk 5-field cron parser: minute hour day month weekday
# Supports: wildcards (*), ranges (1-5), steps (*/15), lists (1,3,5)
# Shortcuts: @hourly, @daily, @weekly, @monthly, @yearly

set -euo pipefail

# Expand a shortcut to standard 5-field cron expression
cron_expand_shortcut() {
    local expr="$1"
    case "$expr" in
        @yearly|@annually) echo "0 0 1 1 *" ;;
        @monthly)          echo "0 0 1 * *" ;;
        @weekly)           echo "0 0 * * 0" ;;
        @daily|@midnight)  echo "0 0 * * *" ;;
        @hourly)           echo "0 * * * *" ;;
        *)                 echo "$expr" ;;
    esac
}

# Check if a single cron field matches a given value
# Field syntax: *, N, N-M, */S, N-M/S, N,M,O
# Args: field_expr current_value min_value max_value
cron_field_matches() {
    local field="$1"
    local value="$2"
    local min_val="$3"
    local max_val="$4"

    # Handle comma-separated lists by checking each element
    if [[ "$field" == *,* ]]; then
        local IFS=','
        local part
        for part in $field; do
            if cron_field_matches "$part" "$value" "$min_val" "$max_val"; then
                return 0
            fi
        done
        return 1
    fi

    # Handle step values: */S or N-M/S
    local step=1
    if [[ "$field" == */* ]]; then
        step="${field##*/}"
        field="${field%/*}"
    fi

    # Handle wildcard
    if [[ "$field" == "*" ]]; then
        if (( step == 1 )); then
            return 0
        fi
        # */S means every S-th value starting from min
        if (( (value - min_val) % step == 0 )); then
            return 0
        fi
        return 1
    fi

    # Handle range: N-M
    if [[ "$field" == *-* ]]; then
        local range_start="${field%-*}"
        local range_end="${field#*-}"
        if (( value >= range_start && value <= range_end )); then
            if (( step == 1 )); then
                return 0
            fi
            if (( (value - range_start) % step == 0 )); then
                return 0
            fi
        fi
        return 1
    fi

    # Handle exact value
    if (( field == value )); then
        return 0
    fi

    return 1
}

# Normalize weekday 7 (Sunday) to 0 in a cron weekday field expression.
# Only weekday *values* are rewritten: the number after a "/" is a step count,
# so "*/7" and the "/2" of "1-7/2" are left untouched.
cron_normalize_wday() {
    local field="$1"
    local out=""
    local parts
    IFS=',' read -ra parts <<< "$field"
    local part
    for part in "${parts[@]}"; do
        local base="$part"
        local step=""
        local step_val=1
        if [[ "$part" == */* ]]; then
            base="${part%/*}"
            step="/${part##*/}"
            step_val="${part##*/}"
        fi

        local extra=""
        if [[ "$base" == *-* ]]; then
            local range_start="${base%-*}"
            local range_end="${base#*-}"
            if [[ "$range_end" == "7" ]]; then
                if [[ "$range_start" == "7" ]]; then
                    base="0"
                    step=""
                else
                    base="${range_start}-6"
                    # Sunday is only reached if the step sequence actually lands on 7
                    if (( step_val > 0 && range_start > 0 && (7 - range_start) % step_val == 0 )); then
                        extra=",0"
                    fi
                fi
            fi
        elif [[ "$base" == "7" ]]; then
            base="0"
        fi

        out="${out:+${out},}${base}${step}${extra}"
    done
    printf '%s' "$out"
}

# Check if a cron expression matches the given time
# Args: cron_expr minute hour day month weekday
# Returns: 0 if matches, 1 if not
cron_matches() {
    local expr="$1"
    local minute="${2:-$(date +%-M)}"
    local hour="${3:-$(date +%-H)}"
    local day="${4:-$(date +%-d)}"
    local month="${5:-$(date +%-m)}"
    local weekday="${6:-$(date +%u)}"

    # Expand shortcuts
    expr="$(cron_expand_shortcut "$expr")"

    # Parse fields
    local fields
    read -ra fields <<< "$expr"

    if (( ${#fields[@]} != 5 )); then
        echo "ERROR: cron expression must have exactly 5 fields: $expr" >&2
        return 2
    fi

    local cron_min="${fields[0]}"
    local cron_hour="${fields[1]}"
    local cron_day="${fields[2]}"
    local cron_month="${fields[3]}"
    local cron_wday="${fields[4]}"

    # Normalize weekday: cron uses 0=Sun..6=Sat, but date %u gives 1=Mon..7=Sun
    # Convert %u to cron-style: 7->0 (Sun), 1->1 (Mon), ..., 6->6 (Sat)
    if (( weekday == 7 )); then
        weekday=0
    fi

    # The expression may also use 7 for Sunday; fold it into the 0-6 domain
    cron_wday="$(cron_normalize_wday "$cron_wday")"

    # Check each field
    cron_field_matches "$cron_min"   "$minute"  0 59 || return 1
    cron_field_matches "$cron_hour"  "$hour"    0 23 || return 1
    cron_field_matches "$cron_month" "$month"   1 12 || return 1

    # Day-of-month and day-of-week: if both are restricted (not *), match either
    local day_restricted=false
    local wday_restricted=false
    [[ "$cron_day" != "*" ]]  && day_restricted=true
    [[ "$cron_wday" != "*" ]] && wday_restricted=true

    if $day_restricted && $wday_restricted; then
        # Standard cron behavior: OR logic when both are specified
        if cron_field_matches "$cron_day" "$day" 1 31 || cron_field_matches "$cron_wday" "$weekday" 0 6; then
            return 0
        fi
        return 1
    fi

    cron_field_matches "$cron_day"  "$day"     1 31 || return 1
    cron_field_matches "$cron_wday" "$weekday" 0 6  || return 1

    return 0
}

# Calculate next run time from a cron expression (approximate, for display only)
# Returns ISO 8601 timestamp of next match within 48 hours, or "unknown"
cron_next_run() {
    local expr="$1"
    local now
    now=$(date +%s)

    # Check each minute for next 48 hours (2880 iterations max)
    local check_time=$now
    local max_time=$((now + 172800))

    while (( check_time < max_time )); do
        local min hour day month wday
        min=$(date -r "$check_time" +%-M 2>/dev/null || date -d "@$check_time" +%-M 2>/dev/null)
        hour=$(date -r "$check_time" +%-H 2>/dev/null || date -d "@$check_time" +%-H 2>/dev/null)
        day=$(date -r "$check_time" +%-d 2>/dev/null || date -d "@$check_time" +%-d 2>/dev/null)
        month=$(date -r "$check_time" +%-m 2>/dev/null || date -d "@$check_time" +%-m 2>/dev/null)
        wday=$(date -r "$check_time" +%u 2>/dev/null || date -d "@$check_time" +%u 2>/dev/null)

        if cron_matches "$expr" "$min" "$hour" "$day" "$month" "$wday" 2>/dev/null; then
            date -r "$check_time" +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
                date -d "@$check_time" +%Y-%m-%dT%H:%M:%S 2>/dev/null
            return 0
        fi

        check_time=$((check_time + 60))
    done

    echo "unknown"
}

# Validate a cron expression (returns 0 if valid, 1 if invalid)
cron_validate() {
    local expr="$1"
    expr="$(cron_expand_shortcut "$expr")"

    local fields
    read -ra fields <<< "$expr"

    if (( ${#fields[@]} != 5 )); then
        echo "ERROR: expected 5 fields, got ${#fields[@]}" >&2
        return 1
    fi

    # Basic syntax check via regex
    local field_pattern='^([0-9*]+(-[0-9]+)?(/[0-9]+)?,?)+$'
    local i
    for i in 0 1 2 3 4; do
        local f="${fields[$i]}"
        if [[ ! "$f" =~ $field_pattern ]]; then
            echo "ERROR: invalid cron field [$i]: $f" >&2
            return 1
        fi
    done

    return 0
}
