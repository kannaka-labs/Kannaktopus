#!/usr/bin/env bash
# Named arms (scripts/named_arms.py + scripts/lib/named-arms.sh): Vigil and Ferryman.
# Every provider call is faked with OCTOPUS_NAMED_ARMS_FAKE_RESPONSE; nothing here
# touches the network or a real key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$PROJECT_ROOT"   # orchestrate.sh resets PROJECT_ROOT when sourced

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "named arms: Vigil (auditor) and Ferryman (steward)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# On Windows (Git Bash) hand python the same C:/ path bash uses, so cited paths match
command -v cygpath >/dev/null 2>&1 && TMP=$(cygpath -m "$TMP")
export HOME="$TMP/home" CLAUDE_SESSION_ID="named-arms-test"
mkdir -p "$HOME"
cd "$TMP" || exit 1

set +eu
source "$REPO_ROOT/scripts/orchestrate.sh" >/dev/null 2>&1 || true
set +e
source "$REPO_ROOT/scripts/lib/named-arms.sh"

PY=$(_named_arms_python)
NA="$REPO_ROOT/scripts/named_arms.py"
export OCTOPUS_ARMS_LEDGER_ROOT="$TMP/ledger" OCTOPUS_NAMED_ARMS_RESULTS_DIR="$TMP/results"
export OCTOPUS_FERRYMAN_DIR="$TMP/ferryman" OCTOPUS_NAMED_ARMS_CONFIG_DIR="$TMP/noconfig"
export OCTOPUS_NAMED_ARMS_FAKE_REQUEST_LOG="$TMP/requests.jsonl"
export OPENROUTER_API_KEY="sk-or""-v1-$(printf 'f%.0s' {1..64})" ANTHROPIC_API_KEY="sk-ant""-api03-$(printf 'a%.0s' {1..90})"
unset OCTOPUS_VIGIL_BACKEND OCTOPUS_VIGIL_MODEL OCTOPUS_VIGIL_MAX_USD_RUN OCTOPUS_VIGIL_MAX_USD_WEEK \
      OCTOPUS_FERRYMAN_MODEL OCTOPUS_NAMED_ARMS_NATS OLLAMA_HOST

na() { PYTHONIOENCODING=utf-8 "$PY" -I "$NA" "$@"; }
pyj() { PYTHONIOENCODING=utf-8 "$PY" -I -c "$@"; }
ledger() { echo "$TMP/ledger/instances/$1/answers.jsonl"; }
reset_state() { rm -rf "$TMP/ledger" "$TMP/results" "$TMP/ferryman" "$TMP/requests.jsonl"; }

DOC="$TMP/doc.md"
SRC="$TMP/source.md"
printf 'Nebius kept its 800 MW guidance.\nThe lab shipped v2 on 2026-11-01.\n' > "$DOC"
printf 'Line 1: Year-end connected power guidance: 800 MW (unchanged).\n' > "$SRC"

# an OpenRouter-shaped reply carrying a Vigil verdict
openrouter_reply() {  # $1 = verdict JSON (as a string)
    pyj 'import json,sys; print(json.dumps({"id":"gen-1","model":"z-ai/glm-5.3",
        "choices":[{"message":{"content":sys.argv[1]},"finish_reason":"stop"}],
        "usage":{"prompt_tokens":900,"completion_tokens":200,"cost":0.00034}}))' "$1"
}
anthropic_reply() {   # $1 = text
    pyj 'import json,sys; print(json.dumps({"id":"msg_1","model":"claude-opus-5-5","stop_reason":"end_turn",
        "content":[{"type":"text","text":sys.argv[1]}],"usage":{"input_tokens":1000,"output_tokens":300}}))' "$1"
}
VERDICT_FIX='{"overall":"FIX","summary":"one claim unsupported","claims":[
 {"id":"c1","claim":"800 MW guidance kept","verdict":"SUPPORTED","evidence":[{"source":"'"$SRC"'#line1","quote":"800 MW (unchanged)"}],"invented_memory":false},
 {"id":"c2","claim":"shipped v2 on 2026-11-01","verdict":"UNVERIFIABLE","evidence":[],"invented_memory":false,"note":"no input"}],
 "fixes":["cite the v2 release or remove it"]}'
openrouter_reply "$VERDICT_FIX" > "$TMP/fix.json"

test_existing_arms_unchanged() {
    test_case "existing arms keep their commands"
    local g o c
    g=$(get_agent_command openrouter-glm5 2>/dev/null)
    o=$(OCTOPUS_ARMS_HUB= get_agent_command ollama 2>/dev/null)
    c=$(get_agent_command claude 2>/dev/null)
    if [[ "$g" == "openrouter_execute_model z-ai/glm-5" && "$o" == "ollama run --nowordwrap "* && "$c" == "claude"*"--print"* ]]; then
        test_pass
    else
        test_fail "glm5='$g' ollama='$o' claude='$c'"
    fi
}

test_dispatch_and_allowlist() {
    test_case "kannaka-vigil / kannaka-ferryman / kannaka-steward dispatch and pass the exact allowlist"
    local v f s
    v=$(get_agent_command kannaka-vigil); f=$(get_agent_command kannaka-ferryman); s=$(get_agent_command kannaka-steward)
    if [[ "$v" == "named_arm_execute kannaka-vigil" && "$f" == "named_arm_execute kannaka-ferryman" \
          && "$s" == "$f" ]] && validate_agent_command "$v" && validate_agent_command "$f" \
       && ! validate_agent_command "named_arm_execute kannaka-vigil; rm -rf /" 2>/dev/null \
       && ! validate_agent_command "named_arm_execute other" 2>/dev/null \
       && [[ " $AVAILABLE_AGENTS " == *" kannaka-vigil "* && " $AVAILABLE_AGENTS " == *" kannaka-steward "* ]]; then
        test_pass
    else
        test_fail "vigil='$v' ferryman='$f' steward='$s'"
    fi
}

test_ledger_row_shape() {
    test_case "an audit writes one rogue-shaped ledger row and exits 10 for FIX"
    reset_state
    local out rc
    out=$(OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" na audit "$DOC" --source "$SRC")
    rc=$?
    local check
    check=$(pyj '
import json, hashlib, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
r = rows[-1]
need = ["answer_id","identity","t_sent","t_done","model","model_digest","gateway_model","response_id",
        "temperature","max_tokens","system","user","recall","collective","graph","content",
        "content_sha256","usage","error"]
miss = [k for k in need if k not in r]
ok = (len(rows) == 1 and not miss and r["identity"] == "kannaka-vigil"
      and r["content_sha256"] == hashlib.sha256(r["content"].encode()).hexdigest()
      and r["verdict"] == "FIX" and r["cost_usd"] == 0.00034 and r["prompt_version"] == "vigil-v1"
      and len(r["recall"]) == 2 and r["error"] is None and r["system"].startswith("You are Vigil"))
print("ok" if ok else "bad missing=%s verdict=%s cost=%s" % (miss, r.get("verdict"), r.get("cost_usd")))
' "$(ledger kannaka-vigil)" 2>&1)
    if [[ $rc -eq 10 && "$check" == ok && "$out" == *'"overall": "FIX"'* ]] && ls "$TMP/results"/kannaka-vigil-*.json >/dev/null 2>&1; then
        test_pass
    else
        test_fail "rc=$rc check=$check out=$out"
    fi
}

test_grader_context() {
    test_case "rows are gradable by rogue-agent fab_grader (context_of non-empty, not skipped)"
    local grader="${ROGUE_AGENT_DIR:-$REPO_ROOT/../rogue-agent}/tools/fab_grader.py" res
    res=$(pyj '
import json, sys, importlib.util
row = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")][-1]
try:
    spec = importlib.util.spec_from_file_location("fab_grader", sys.argv[2])
    g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
    ctx = g.context_of(row); grade = g.grade_row(row)[0]
    print("ok" if ctx.strip() and grade is not None else f"bad grade={grade}")
except (FileNotFoundError, OSError):
    # grader not checked out next to this repo: apply its documented rules inline
    ctx = "\n".join([row.get("system") or "", row.get("user") or ""] +
                    [json.dumps(row[k]) for k in ("recall", "collective", "graph") if row.get(k)])
    print("ok" if ctx.strip() and row.get("content") and not row.get("error") else "bad")
' "$(ledger kannaka-vigil)" "$grader" 2>&1)
    [[ "$res" == ok ]] && test_pass || test_fail "$res"
}

test_run_cap_refuses_without_http() {
    test_case "a per-run cap refusal makes no HTTP call, writes an error row, exits 3"
    reset_state
    local rc
    OCTOPUS_VIGIL_MAX_USD_RUN=0.000001 OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" na audit "$DOC" >/dev/null
    rc=$?
    if [[ $rc -eq 3 && ! -s "$TMP/requests.jsonl" ]] && grep -q '"error": "budget: worst case' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "rc=$rc requests=$(cat "$TMP/requests.jsonl" 2>/dev/null | wc -l)"
    fi
}

test_week_cap_refuses() {
    test_case "the weekly cap counts the arm's own ledger and refuses past it"
    reset_state
    mkdir -p "$TMP/ledger/instances/kannaka-vigil"
    pyj 'import json,sys,time; print(json.dumps({"answer_id":"x","t_sent":time.time(),"t_done":time.time(),"cost_usd":1.998}))' \
        > "$(ledger kannaka-vigil)"
    local rc b
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" na audit "$DOC" >/dev/null
    rc=$?
    b=$(na budget --arm kannaka-vigil)
    if [[ $rc -eq 3 && ! -s "$TMP/requests.jsonl" && "$b" == *'"spent_week_usd": 1.998'* ]] \
       && grep -q 'exceeds the weekly cap' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "rc=$rc budget=$b"
    fi
}

test_secrets_never_logged_or_sent() {
    test_case "a planted key never reaches the provider or the ledger"
    reset_state
    # built at run time so no key-shaped literal sits in the repo
    local planted="sk-""ant-api03-PLANTEDsecretPLANTEDsecret0123456789" gh="ghp""_PLANTED0123456789abcdefABCDEF"
    printf 'Key for later: %s and %s\n' "$planted" "$gh" > "$TMP/leaky.md"
    printf 'audit this %s\n' "$ANTHROPIC_API_KEY" | OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" \
        na call --arm kannaka-vigil --input "$TMP/leaky.md" >/dev/null
    if ! grep -q -e "PLANTED" -e "$ANTHROPIC_API_KEY" -e "$OPENROUTER_API_KEY" "$(ledger kannaka-vigil)" "$TMP/requests.jsonl" \
       && grep -q 'REDACTED' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "secret found in ledger or request"
    fi
}

test_ledger_mode() {
    test_case "the ledger file is created 0600"
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) test_skip "POSIX modes not enforced on Windows"; return ;; esac
    local mode
    mode=$(stat -c '%a' "$(ledger kannaka-vigil)" 2>/dev/null || stat -f '%Lp' "$(ledger kannaka-vigil)")
    [[ "$mode" == 600 ]] && test_pass || test_fail "mode=$mode"
}

test_uncited_supported_fails_schema() {
    test_case "SUPPORTED without citing a provided input fails the schema (exit 4)"
    reset_state
    openrouter_reply '{"overall":"PUBLISH","summary":"x","claims":[{"id":"c1","claim":"x","verdict":"SUPPORTED","evidence":[{"source":"wikipedia#x","quote":"x"}]}],"fixes":[]}' \
        > "$TMP/uncited.json"
    local rc
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/uncited.json" na audit "$DOC" --source "$SRC" >/dev/null
    rc=$?
    if [[ $rc -eq 4 ]] && grep -q 'SUPPORTED without citing a provided input' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "rc=$rc"
    fi
}

test_not_json_is_recorded() {
    test_case "a non-JSON reply is kept in the ledger with json_valid false (exit 4)"
    reset_state
    openrouter_reply 'Looks fine to me!' > "$TMP/prose.json"
    local rc
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/prose.json" na audit "$DOC" >/dev/null
    rc=$?
    if [[ $rc -eq 4 ]] && grep -q '"json_valid": false' "$(ledger kannaka-vigil)" && grep -q 'Looks fine to me' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "rc=$rc"
    fi
}

test_vigil_local_backend_switch() {
    test_case "OCTOPUS_VIGIL_BACKEND=ollama moves Vigil to the local LoRA at \$0"
    reset_state
    OCTOPUS_VIGIL_BACKEND=ollama OLLAMA_HOST=127.0.0.1:11435 OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" \
        na audit "$DOC" --source "$SRC" >/dev/null
    local res
    res=$(pyj '
import json, sys
req = [json.loads(l) for l in open(sys.argv[1])][-1]
row = [json.loads(l) for l in open(sys.argv[2])][-1]
ok = (req["url"] == "http://127.0.0.1:11435/v1/chat/completions" and req["body"]["model"] == "kannaka-brain-glm-v1"
      and "authorization" not in [h.lower() for h in req["headers"]] and row["cost_usd"] == 0 and row["backend"] == "ollama")
print("ok" if ok else "bad %s %s %s" % (req["url"], req["body"]["model"], row["cost_usd"]))
' "$TMP/requests.jsonl" "$(ledger kannaka-vigil)" 2>&1)
    [[ "$res" == ok ]] && test_pass || test_fail "$res"
}

test_ferryman_anthropic_request() {
    test_case "Ferryman calls the Messages API with a top-level system, effort, no temperature, real cost"
    reset_state
    printf 'Reply to Jane about the grant call; ask for the deadline.\n' > "$TMP/brief.md"
    anthropic_reply '{"draft":"Hi Jane, thanks. [NICK: confirm availability]","assumptions":[],"claims_to_verify":[],"needs_nick":["availability"]}' \
        > "$TMP/msg.json"
    printf 'write it' | OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/msg.json" na call --arm kannaka-steward --task draft --input "$TMP/brief.md" >/dev/null
    local rc=$? res
    res=$(pyj '
import json, sys
req = [json.loads(l) for l in open(sys.argv[1])][-1]
row = [json.loads(l) for l in open(sys.argv[2])][-1]
b = req["body"]
ok = (req["url"].endswith("/v1/messages") and b["system"].startswith("You are Ferryman") and "temperature" not in b
      and b["output_config"] == {"effort": "medium"} and b["model"] == "claude-opus-5-5"
      and "x-api-key" in req["headers"] and abs(row["cost_usd"] - (1000*4 + 300*20)/1e6) < 1e-9
      and row["identity"] == "kannaka-ferryman" and row["verdict"] == "draft")
print("ok" if ok else "bad " + json.dumps({k: b.get(k) for k in ("model", "output_config")}) + " cost=" + str(row["cost_usd"]))
' "$TMP/requests.jsonl" "$(ledger kannaka-ferryman)" 2>&1)
    [[ $rc -eq 0 && "$res" == ok ]] && test_pass || test_fail "rc=$rc $res"
}

test_settle_needs_evidence_then_vigil() {
    test_case "settle refuses without evidence (no call), then proposes and runs Vigil on the proposal"
    reset_state
    local markets="$TMP/markets.jsonl" ev="$TMP/letter.md" rc1 rc2
    printf '%s\n' '{"call_id":"t","gs_proposal":154,"statement":"Guidance stays at or above 800 MW.","settles_by":"2026-01-01","resolution_source":"letter","status":"proposed","outcome":null}' \
                  '{"call_id":"t","gs_proposal":152,"statement":"later","settles_by":"2099-01-01","resolution_source":"x","status":"proposed","outcome":null}' > "$markets"
    printf 'Year-end connected power guidance: 800 MW.\n' > "$ev"
    na settle --markets "$markets" >/dev/null
    rc1=$?
    local fake="$TMP/fakedir"; mkdir -p "$fake"
    anthropic_reply '{"market":154,"statement":"Guidance stays at or above 800 MW.","proposed_outcome":"YES","evidence":[{"source":"'"$ev"'#1","sha256":"x","quote":"800 MW"}],"reasoning":"r","confidence":"high","missing":null}' \
        > "$fake/messages.json"
    openrouter_reply '{"overall":"PUBLISH","summary":"ok","claims":[{"id":"c1","claim":"800 MW","verdict":"SUPPORTED","evidence":[{"source":"'"$ev"'#1","quote":"800 MW"}]}],"fixes":[]}' \
        > "$fake/completions.json"
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$fake" na settle --markets "$markets" --evidence "$ev" >/dev/null
    rc2=$?
    if [[ $rc1 -eq 2 && $rc2 -eq 0 ]] && grep -q '"market": 154' "$TMP/ferryman/settlements-pending.jsonl" \
       && grep -q '"overall": "PUBLISH"' "$TMP/ferryman/settlements-pending.jsonl" \
       && ! grep -q '"market": 152' "$TMP/ferryman/settlements-pending.jsonl" \
       && grep -q '"approved_by_nick": false' "$TMP/ferryman/settlements-pending.jsonl"; then
        test_pass
    else
        test_fail "rc1=$rc1 rc2=$rc2 pending=$(cat "$TMP/ferryman/settlements-pending.jsonl" 2>/dev/null)"
    fi
}

test_sweep_register_and_due() {
    test_case "sweep appends new items to the register once; due lists them without a model call"
    reset_state
    printf 'From: jane@example.org 2026-11-05\nCan you send a proposal by 2026-11-10?\n' > "$TMP/inbox.txt"
    anthropic_reply '{"items":[{"id":"mail-jane-2026-11-05","surface":"mail","who":"jane@example.org","what":"asks for a proposal","class":"plausible","evidence":[{"source":"'"$TMP/inbox.txt"'#2","quote":"send a proposal"}],"deadline":"2026-11-10","owed_reply_since":"2026-11-05","next_step":"reply","needs_nick":true}],"notes":""}' \
        > "$TMP/sweep.json"
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/sweep.json" na sweep --input "$TMP/inbox.txt" >/dev/null
    OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/sweep.json" na sweep --input "$TMP/inbox.txt" >/dev/null
    local n calls due
    n=$(wc -l < "$TMP/ferryman/register.jsonl")
    calls=$(wc -l < "$TMP/requests.jsonl")
    due=$(na due --days 3650)
    if [[ $n -eq 1 && $calls -eq 2 && "$due" == *"jane@example.org"* ]] && [[ $(wc -l < "$TMP/requests.jsonl") -eq 2 ]]; then
        test_pass
    else
        test_fail "register=$n calls=$calls due=$due"
    fi
}

test_spawn_path() {
    test_case "named_arm_execute (the spawn path) pipes the prompt and prints the reply"
    reset_state
    local out
    out=$(printf 'audit: the sky is green' | OCTOPUS_NAMED_ARMS_FAKE_RESPONSE="$TMP/fix.json" named_arm_execute kannaka-vigil)
    if [[ "$out" == *'"overall":"FIX"'* ]] && grep -q 'the sky is green' "$(ledger kannaka-vigil)"; then
        test_pass
    else
        test_fail "out=$out"
    fi
}

test_existing_arms_unchanged
test_dispatch_and_allowlist
test_ledger_row_shape
test_grader_context
test_ledger_mode
test_run_cap_refuses_without_http
test_week_cap_refuses
test_secrets_never_logged_or_sent
test_uncited_supported_fails_schema
test_not_json_is_recorded
test_vigil_local_backend_switch
test_ferryman_anthropic_request
test_settle_needs_evidence_then_vigil
test_sweep_register_and_due
test_spawn_path

test_summary
