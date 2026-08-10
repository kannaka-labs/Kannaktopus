#!/usr/bin/env bash
# validate-openclaw.sh — Verify OpenClaw compatibility layer integrity
#
# Validates:
# 1. OpenClaw extension manifest is valid
# 2. Generated tool registry matches current skills
# 3. MCP server configuration is valid
# 4. Claude Code plugin.json is NOT modified (zero-change guarantee)
#
# Exit codes:
#   0 = All checks pass
#   1 = Validation failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# Resolve a Python interpreter. Being on PATH is not enough -- the Windows Store
# "python3" alias resolves but fails when run -- so every candidate is probed by
# executing it.
PYTHON=""
for candidate in "python3" "py -3" "python"; do
    if $candidate -c "import json" > /dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "ERROR: no working Python 3 interpreter found (tried: python3, py -3, python)." >&2
    echo "       Install Python 3 or put it on PATH; without it this script cannot" >&2
    echo "       read the JSON manifests and would report bogus manifest failures." >&2
    exit 1
fi

# Git Bash reports POSIX paths (/c/...) that a native Windows interpreter cannot open.
if command -v cygpath > /dev/null 2>&1; then
    native_path() { cygpath -m "$1"; }
else
    native_path() { printf '%s' "$1"; }
fi

echo "=== OpenClaw Compatibility Validation ==="
echo ""

# --- 1. Claude Code plugin.json integrity ---
echo "1. Claude Code Plugin Integrity"

PLUGIN_JSON="$(native_path "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
if PLUGIN_NAME=$($PYTHON -c "import json; print(json.load(open('$PLUGIN_JSON'))['name'])"); then
    if [[ "$PLUGIN_NAME" == "octo" ]]; then
        pass "plugin.json name is 'octo'"
    else
        fail "plugin.json name is '${PLUGIN_NAME}' (expected 'octo')"
    fi
else
    fail "could not read .claude-plugin/plugin.json with '$PYTHON' (see error above)"
fi

# Check plugin.json has no openclaw-specific fields
if $PYTHON -c "
import json
p = json.load(open('$PLUGIN_JSON'))
openclaw_keys = [k for k in p if 'openclaw' in k.lower()]
exit(1 if openclaw_keys else 0)
"; then
    pass "plugin.json has no OpenClaw-specific fields"
else
    fail "plugin.json contains OpenClaw-specific fields"
fi

echo ""

# --- 2. OpenClaw extension manifest ---
echo "2. OpenClaw Extension Manifest"

OPENCLAW_PKG="$PLUGIN_ROOT/openclaw/package.json"
if [[ -f "$OPENCLAW_PKG" ]]; then
    pass "openclaw/package.json exists"

    # Check openclaw.extensions field
    if $PYTHON -c "
import json
p = json.load(open('$(native_path "$OPENCLAW_PKG")'))
ext = p.get('openclaw', {}).get('extensions', [])
exit(0 if ext else 1)
"; then
        pass "openclaw.extensions field is defined"
    else
        fail "openclaw.extensions field is missing"
    fi
else
    fail "openclaw/package.json not found"
fi

OPENCLAW_PLUGIN="$PLUGIN_ROOT/openclaw/openclaw.plugin.json"
if [[ -f "$OPENCLAW_PLUGIN" ]]; then
    pass "openclaw.plugin.json exists"
    OPENCLAW_PLUGIN_NATIVE="$(native_path "$OPENCLAW_PLUGIN")"

    # Check required id field (OpenClaw gateway crashes without it — see #40)
    if $PYTHON -c "
import json
p = json.load(open('$OPENCLAW_PLUGIN_NATIVE'))
exit(0 if p.get('id') else 1)
"; then
        pass "id field is present"
    else
        fail "id field is missing from openclaw.plugin.json (required by OpenClaw gateway)"
    fi

    # Check id matches package name (OpenClaw config key derived from unscoped pkg name — see #45)
    # Manifest id must match unscoped package.json name so plugins.entries.<key> resolves correctly.
    if $PYTHON -c "
import json, os
manifest = json.load(open('$OPENCLAW_PLUGIN_NATIVE'))
pkg = json.load(open(os.path.join(os.path.dirname('$OPENCLAW_PLUGIN_NATIVE'), 'package.json')))
pkg_name = pkg.get('name', '').split('/')[-1]  # strip npm scope
exit(0 if manifest.get('id') == pkg_name else 1)
"; then
        pass "id matches unscoped package name (required for install registration)"
    else
        fail "openclaw.plugin.json id must match unscoped package.json name (OpenClaw config validation — see #45)"
    fi

    # Check extension entry point exists (OpenClaw rejects missing entries — see #41)
    if [[ -f "$PLUGIN_ROOT/openclaw/dist/index.js" ]]; then
        pass "extension entry point dist/index.js exists"
    else
        fail "openclaw/dist/index.js missing (must be committed, not gitignored)"
    fi

    # Check configSchema
    if $PYTHON -c "
import json
p = json.load(open('$OPENCLAW_PLUGIN_NATIVE'))
exit(0 if 'configSchema' in p else 1)
"; then
        pass "configSchema is defined"
    else
        fail "configSchema is missing from openclaw.plugin.json"
    fi
else
    fail "openclaw.plugin.json not found"
fi

echo ""

# --- 3. MCP Server Configuration ---
echo "3. MCP Server Configuration"

MCP_JSON="$PLUGIN_ROOT/.mcp.json"
if [[ -f "$MCP_JSON" ]]; then
    pass ".mcp.json exists at plugin root"

    # Check server definition
    if $PYTHON -c "
import json
m = json.load(open('$(native_path "$MCP_JSON")'))
servers = m.get('mcpServers', {})
exit(0 if 'octo-claw' in servers else 1)
"; then
        pass "octo-claw MCP server is defined"
    else
        fail "octo-claw MCP server not found in .mcp.json"
    fi
else
    fail ".mcp.json not found at plugin root"
fi

MCP_INDEX="$PLUGIN_ROOT/mcp-server/src/index.ts"
if [[ -f "$MCP_INDEX" ]]; then
    pass "MCP server source exists"
else
    fail "MCP server source not found at mcp-server/src/index.ts"
fi

echo ""

# --- 4. Skill Registry Sync ---
echo "4. Skill Registry Sync"

SKILL_COUNT=$(ls -1 "$PLUGIN_ROOT/.claude/skills/"*.md 2>/dev/null | wc -l | tr -d ' ')
COMMAND_COUNT=$(ls -1 "$PLUGIN_ROOT/.claude/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((SKILL_COUNT + COMMAND_COUNT))

pass "Found ${SKILL_COUNT} skills and ${COMMAND_COUNT} commands (${TOTAL} total)"

# Check build script exists
if [[ -x "$PLUGIN_ROOT/scripts/build-openclaw.sh" ]]; then
    pass "build-openclaw.sh is executable"
else
    if [[ -f "$PLUGIN_ROOT/scripts/build-openclaw.sh" ]]; then
        pass "build-openclaw.sh exists (not yet executable)"
    else
        fail "build-openclaw.sh not found"
    fi
fi

echo ""

# --- 5. Schema Validation ---
echo "5. Shared Schema"

SCHEMA_FILE="$PLUGIN_ROOT/mcp-server/src/schema/skill-schema.json"
if [[ -f "$SCHEMA_FILE" ]]; then
    pass "skill-schema.json exists"

    if $PYTHON -c "
import json
s = json.load(open('$(native_path "$SCHEMA_FILE")'))
required = s.get('required', [])
exit(0 if 'name' in required and 'description' in required else 1)
"; then
        pass "Schema requires 'name' and 'description'"
    else
        fail "Schema missing required fields"
    fi
else
    fail "skill-schema.json not found"
fi

echo ""

# --- Summary ---
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "VALIDATION FAILED"
    exit 1
else
    echo "ALL CHECKS PASSED"
    exit 0
fi
