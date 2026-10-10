#!/usr/bin/env bash
# Tests for the MCP server's kannaka CLI helpers (mcp-server/src/kannaka-cli.ts)
#
# kannaka_absorb must speak the flags `kannaka remember` actually parses
# (kannaka-memory src/bin/kannaka.rs): ONE comma-joined --tags and --modality.
# A per-tag `--tag` is an unknown flag there — the CLI exits 2 and stores
# nothing — and --category is a free-form label, not the modality.
#
# /api/experiments/xi must read the metrics from `consciousness.*` of the
# `observe --json` report (src/observe.rs SystemReport) and must never answer
# 200 without xi/phi.
#
# Runs against the COMMITTED dist/ — that is what .mcp.json launches. CI's
# mcp-server job separately fails when dist/ differs from a fresh build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPERS="$PROJECT_ROOT/mcp-server/dist/kannaka-cli.js"
MCP_SRC="$PROJECT_ROOT/mcp-server/src/index.ts"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 - $2"; }

finish() {
    echo ""
    echo "Results: $PASS_COUNT/$TEST_COUNT passed"
    [[ "$FAIL_COUNT" -eq 0 ]]
}

# --- Source wiring: the tool and the route must use the tested helpers ------
if grep -q 'buildRememberArgs(' "$MCP_SRC"; then
    pass "kannaka_absorb builds its argv with buildRememberArgs"
else
    fail "kannaka_absorb builds its argv with buildRememberArgs" "not referenced in index.ts"
fi
if grep -q 'extractXiMetrics(' "$MCP_SRC"; then
    pass "/api/experiments/xi uses extractXiMetrics"
else
    fail "/api/experiments/xi uses extractXiMetrics" "not referenced in index.ts"
fi
if grep -qE '"--tag"|'"'"'--tag'"'" "$MCP_SRC"; then
    fail "index.ts never passes a per-tag --tag" "a literal --tag flag is still present"
else
    pass "index.ts never passes a per-tag --tag"
fi

# --- Behaviour of the compiled helpers --------------------------------------
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available (behavioural checks need it)"
    finish
    exit $?
fi
if [[ ! -f "$HELPERS" ]]; then
    fail "compiled helpers exist" "$HELPERS missing — run tsc in mcp-server/"
    finish
    exit $?
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

cat > "$TMP_ROOT/check.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const { buildRememberArgs, extractXiMetrics } = await import(pathToFileURL(process.argv[2]).href);

const results = [];
const check = (name, ok, detail) => results.push({ name, ok: !!ok, detail });
const j = (v) => JSON.stringify(v);

// 1. tags: one comma-joined --tags, never --tag
{
  const a = buildRememberArgs({ content: "hello", tags: ["neuro", "waves"] });
  check("tags become one --tags a,b", j(a) === j(["remember", "hello", "--tags", "neuro,waves"]), j(a));
  check("no per-tag --tag flag", !a.includes("--tag"), j(a));
  check("--tags appears exactly once", a.filter((x) => x === "--tags").length === 1, j(a));
}
{
  const a = buildRememberArgs({ content: "x", tags: [" a ", "", "b"] });
  check("blank tags dropped and trimmed", j(a) === j(["remember", "x", "--tags", "a,b"]), j(a));
  const none = buildRememberArgs({ content: "x", tags: [] });
  check("empty tag list adds no flag", j(none) === j(["remember", "x"]), j(none));
}

// 2. modality is --modality, not --category
{
  const a = buildRememberArgs({ content: "c", importance: 0.8, modality: "audio" });
  check("modality passed as --modality", j(a) === j(["remember", "c", "--importance", "0.8", "--modality", "audio"]), j(a));
  check("modality never sent as --category", !a.includes("--category"), j(a));
}

// 3. every flag emitted is one `kannaka remember` parses
{
  const known = new Set(["--importance", "--category", "--modality", "--tags", "--effective", "--observed", "--expires", "--substrate", "--nats-url"]);
  const a = buildRememberArgs({ content: "c", importance: 0.1, modality: "mixed", tags: ["t"] });
  const unknown = a.filter((x) => x.startsWith("--") && !known.has(x));
  check("no flag the CLI would reject (exit 2)", unknown.length === 0, j(unknown));
}

// 4. /api/experiments/xi reads consciousness.* from the real observe shape
const observe = {
  timestamp: "2026-10-09T00:00:00Z",
  consciousness: { phi: 0.42, xi: 0.17, mean_order: 0.63, num_clusters: 7, total_memories: 1234,
                   active_memories: 900, total_skip_links: 55, level: "Coherent" },
  topology: {}, waves: {}, clusters: { num_clusters: 7, clusters: [] }, health: {},
  ncs_switch_points: 0, ncs_metrics: {},
};
{
  const r = extractXiMetrics(JSON.stringify(observe));
  check("xi route answers 200 for a real observe report", r.status === 200, j(r));
  check("xi read from consciousness.xi", r.body.xi === 0.17, j(r.body));
  check("phi read from consciousness.phi", r.body.phi === 0.42, j(r.body));
  check("mean_order/num_clusters/total_memories read", r.body.mean_order === 0.63 && r.body.num_clusters === 7 && r.body.total_memories === 1234, j(r.body));
  check("consciousness_level read from consciousness.level", r.body.consciousness_level === "Coherent", j(r.body));
  check("hemispheric_divergence (not in observe) is explicit null + listed missing",
        r.body.hemispheric_divergence === null && Array.isArray(r.body.missing) && r.body.missing.includes("hemispheric_divergence"), j(r.body));
  check("response is never {}", Object.keys(r.body).length > 0 && r.body.xi !== undefined, j(r.body));
}
{
  const flat = { xi: 0.1, phi: 0.2 }; // the shape the old route assumed — observe never emits it
  const r = extractXiMetrics(JSON.stringify(flat));
  check("no consciousness block -> 502, not 200", r.status === 502, j(r));
  check("502 names the missing fields", Array.isArray(r.body.missing) && r.body.missing.includes("xi") && r.body.missing.includes("phi"), j(r.body));
}
{
  const r = extractXiMetrics(JSON.stringify({ consciousness: { xi: 0.3, phi: null } }));
  check("null phi (NaN serialised by serde) -> 502", r.status === 502, j(r));
}
{
  const r = extractXiMetrics(JSON.stringify({ consciousness: { xi: 0.3, phi: 0.4 } }));
  check("partial report -> 200 with nulls listed in missing", r.status === 200 && r.body.mean_order === null && r.body.missing.includes("mean_order"), j(r));
}
{
  const r = extractXiMetrics("Error: store locked");
  check("unparseable observe output -> 502, not raw 200", r.status === 502, j(r));
}

for (const r of results) console.log(`${r.ok ? "OK" : "NOT_OK"}\t${r.name}\t${r.ok ? "" : r.detail}`);
JS

node_out=""
node_rc=0
node_out=$(node "$TMP_ROOT/check.mjs" "$HELPERS" 2>&1) || node_rc=$?
if [[ "$node_rc" -ne 0 ]]; then
    fail "helper checks ran" "node exited $node_rc: $node_out"
else
    while IFS=$'\t' read -r status name detail; do
        [[ -z "$status" ]] && continue
        if [[ "$status" == "OK" ]]; then pass "$name"; else fail "$name" "$detail"; fi
    done <<<"$node_out"
fi

finish
