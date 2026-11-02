#!/usr/bin/env bash
# Tests for Kannaktopus #119 parts 2+3:
#   - fan_out/map_reduce resolve their fleet (not a hardcoded codex+gemini pair)
#   - Codex is routed away from implementing/code-reading roles on Windows,
#     unless OCTOPUS_CODEX_FORCE_EXEC=true; doctor says so plainly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"
PLUGIN_DIR="$PROJECT_ROOT"
SCRIPT_DIR="$PROJECT_ROOT/scripts"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }
assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}

# ── Stubs: logging, colors, uname, and `command -v` (so host CLIs don't leak in) ─────
log() { :; }
export -f log
CYAN=""; MAGENTA=""; YELLOW=""; GREEN=""; RED=""; NC=""; BOLD=""; DIM="";
FAKE_UNAME="Linux"
uname() { echo "$FAKE_UNAME"; }
export -f uname
FAKE_BINS=""
command() {
  if [[ "$1" == "-v" ]]; then
    local want="$2"
    case " $FAKE_BINS " in
      *" $want "*) echo "/fake/$want"; return 0 ;;
    esac
    return 1
  fi
  builtin command "$@"
}
export -f command

source "$LIB_DIR/agent-utils.sh"
source "$LIB_DIR/parallel.sh"
source "$LIB_DIR/agents.sh"

# The real is_windows_host / codex_blocked_on_windows are exercised; only uname is stubbed.
# Stand-in for embrace.sh's get_dispatch_strategy (the provider list probe uses).
DISPATCH_PROVIDERS="codex,gemini,claude-sonnet"
get_dispatch_strategy() { echo "3:${DISPATCH_PROVIDERS}:high"; }

unset OPENROUTER_API_KEY PERPLEXITY_API_KEY OCTOPUS_CODEX_FORCE_EXEC OCTOPUS_DISPATCH_STRATEGY || true

fleet() { resolve_fleet_agents "$@" | tr '\n' ' ' | sed 's/ $//'; }

# ── Part 2: fleet resolution ─────────────────────────────────────────────────
FAKE_UNAME="Linux"
FAKE_BINS="codex gemini"
assert_eq "$(OPENROUTER_API_KEY=k PERPLEXITY_API_KEY=k fleet)" \
  "codex gemini claude-sonnet openrouter perplexity" \
  "default fleet includes Claude, OpenRouter and Perplexity arms"

assert_eq "$(fleet)" "codex gemini claude-sonnet" \
  "OpenRouter/Perplexity skipped without keys"

FAKE_BINS="gemini"
assert_eq "$(fleet)" "gemini claude-sonnet" "missing codex CLI is skipped"

FAKE_BINS=""
assert_eq "$(fleet)" "claude-sonnet" "no CLIs: falls back to Claude only"

FAKE_BINS="codex gemini"
assert_eq "$(fleet gemini perplexity claude-opus)" "gemini claude-opus" \
  "explicit list honoured; unavailable arm (perplexity) skipped"
assert_eq "$(fleet gemini gemini)" "gemini" "explicit list is de-duplicated"

DISPATCH_PROVIDERS="gemini,claude-sonnet"
assert_eq "$(fleet)" "gemini claude-sonnet" \
  "default fleet follows the dispatch-strategy provider list"
DISPATCH_PROVIDERS="codex,gemini,claude-sonnet"

# fan_out / map_reduce must spawn the resolved arms. Mocks (spawn_agent, sleep,
# wait, gemini, aggregate_results) live in a subshell so they don't leak; counters
# are passed back through a file.
COUNTS_FILE="$(mktemp)"
(
SPAWNED_FILE="$(mktemp)"
spawn_agent() { 
  echo "$1" >> "$SPAWNED_FILE"
  echo 1; 
}
export -f spawn_agent
sleep() { :; }
RESULTS_DIR="$(mktemp -d)"
FAKE_BINS="codex gemini"
export OPENROUTER_API_KEY=k
> "$SPAWNED_FILE"
fan_out "p"
got_spawned=$(tr '\n' ' ' < "$SPAWNED_FILE" | sed 's/ $//')
assert_eq "$got_spawned" "codex gemini claude-sonnet openrouter" \
  "fan_out spawns the full resolved fleet"
unset OPENROUTER_API_KEY
> "$SPAWNED_FILE"
fan_out "p" gemini claude-sonnet
got_spawned=$(tr '\n' ' ' < "$SPAWNED_FILE" | sed 's/ $//')
assert_eq "$got_spawned" "gemini claude-sonnet" "fan_out accepts an explicit agent list"

# map_reduce: stub the decomposer (gemini), wait and aggregation
gemini() { printf '1. a\n2. b\n3. c\n'; }
wait() { :; }
aggregate_results() { :; }
DRY_RUN=false
> "$SPAWNED_FILE"
map_reduce "task" gemini claude-sonnet >/dev/null 2>&1
got_spawned=$(tr '\n' ' ' < "$SPAWNED_FILE" | sed 's/ $//')
assert_eq "$got_spawned" "gemini claude-sonnet gemini" \
  "map_reduce rotates subtasks over the explicit fleet"
FAKE_BINS="gemini"
> "$SPAWNED_FILE"
map_reduce "task" >/dev/null 2>&1
got_spawned=$(tr '\n' ' ' < "$SPAWNED_FILE" | sed 's/ $//')
assert_eq "$got_spawned" "gemini claude-sonnet gemini" \
  "map_reduce default fleet follows resolution (no codex when absent)"
rm -rf "$RESULTS_DIR" "$SPAWNED_FILE"
echo "$TEST_COUNT $PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
)
read -r TEST_COUNT PASS_COUNT FAIL_COUNT < "$COUNTS_FILE"
rm -f "$COUNTS_FILE"

# ── Part 3: Windows routing ──────────────────────────────────────────────────
for u in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  FAKE_UNAME="$u"
  if is_windows_host; then pass "$u detected as Windows"; else fail "$u detected as Windows" "no"; fi
done
FAKE_UNAME="Linux"
if is_windows_host; then fail "Linux is not Windows" "detected"; else pass "Linux is not Windows"; fi

assert_eq "$(get_role_agent implementer)" "codex" "Linux: implementer stays on codex"
assert_eq "$(get_role_agent reviewer)" "codex-review" "Linux: reviewer stays on codex-review"

FAKE_UNAME="MINGW64_NT-10.0"
for r in implementer reviewer architect; do
  got="$(get_role_agent "$r")"
  case "$got" in
    codex*) fail "Windows: $r routed away from codex" "got $got" ;;
    *)      pass "Windows: $r routed away from codex" ;;
  esac
done
assert_eq "$(get_role_agent researcher)" "gemini" "Windows: researcher unchanged"
assert_eq "$(OCTOPUS_CODEX_FORCE_EXEC=true get_role_agent implementer)" "codex" \
  "Windows: OCTOPUS_CODEX_FORCE_EXEC=true restores codex"
FAKE_BINS="codex gemini"
assert_eq "$(fleet)" "gemini claude-sonnet" "Windows: codex dropped from fleet"
assert_eq "$(OCTOPUS_CODEX_FORCE_EXEC=true fleet)" "codex gemini claude-sonnet" \
  "Windows: override keeps codex in fleet"

# get_tiered_agent must agree with get_role_mapping/doctor (Claude on Windows)
FAKE_UNAME="Linux"
assert_eq "$(get_tiered_agent coding 2)" "codex-standard" "Linux: coding 2 stays on codex-standard"
assert_eq "$(get_tiered_agent review 2)" "codex-review" "Linux: review stays on codex-review"
FAKE_UNAME="MINGW64_NT-10.0"
assert_eq "$(get_tiered_agent coding 2)" "claude-sonnet" "Windows: coding 2 routed to claude-sonnet"
assert_eq "$(get_tiered_agent review 2)" "claude-sonnet" "Windows: review routed to claude-sonnet"
assert_eq "$(OCTOPUS_CODEX_FORCE_EXEC=true get_tiered_agent coding 2)" "codex-standard" \
  "Windows+override: coding 2 stays on codex-standard"
assert_eq "$(OCTOPUS_CODEX_FORCE_EXEC=true get_tiered_agent review 2)" "codex-review" \
  "Windows+override: review stays on codex-review"

# ── Part 3: doctor ───────────────────────────────────────────────────────────
source "$LIB_DIR/doctor.sh"
doctor_run() {
  DOCTOR_RESULTS_NAME=(); DOCTOR_RESULTS_CAT=(); DOCTOR_RESULTS_STATUS=()
  DOCTOR_RESULTS_MSG=(); DOCTOR_RESULTS_DETAIL=()
  doctor_check_providers >/dev/null 2>&1 || true
  local i
  for i in "${!DOCTOR_RESULTS_NAME[@]}"; do
    if [[ "${DOCTOR_RESULTS_NAME[$i]}" == "codex-windows-exec" ]]; then
      echo "${DOCTOR_RESULTS_STATUS[$i]}|${DOCTOR_RESULTS_MSG[$i]}"
      return
    fi
  done
  echo "none"
}
FAKE_UNAME="MINGW64_NT-10.0"
out="$(doctor_run)"
case "$out" in
  "warn|Codex cannot execute commands on Windows"*) pass "doctor warns plainly on Windows" ;;
  *) fail "doctor warns plainly on Windows" "$out" ;;
esac
out="$(OCTOPUS_CODEX_FORCE_EXEC=true doctor_run)"
case "$out" in
  info\|*override*) pass "doctor reports the override" ;;
  *) fail "doctor reports the override" "$out" ;;
esac
FAKE_UNAME="Linux"
assert_eq "$(doctor_run)" "none" "doctor silent about Codex-on-Windows on Linux"

echo ""
echo "Results: $PASS_COUNT/$TEST_COUNT passed"
[[ $FAIL_COUNT -eq 0 ]]
