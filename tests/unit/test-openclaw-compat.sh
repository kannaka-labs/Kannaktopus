#!/bin/bash
# tests/unit/test-openclaw-compat.sh
# Tests for v8.22.0 OpenClaw compatibility layer
# Covers: MCP config, OpenClaw extension manifest, skill registry,
#         build tooling, schema validation, cross-platform parity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "OpenClaw Compatibility Layer (v8.22.0)"

# ═══════════════════════════════════════════════════════════════════════════════
# MCP Server Configuration
# ═══════════════════════════════════════════════════════════════════════════════

test_mcp_json_exists() {
    test_case ".mcp.json exists at plugin root"
    if [[ -f "$PROJECT_ROOT/.mcp.json" ]]; then
        test_pass
    else
        test_fail ".mcp.json not found at plugin root"
    fi
}

test_mcp_json_valid_json() {
    test_case ".mcp.json is valid JSON"
    if python3 -m json.tool "$PROJECT_ROOT/.mcp.json" >/dev/null 2>&1; then
        test_pass
    else
        test_fail ".mcp.json is not valid JSON"
    fi
}

test_mcp_server_entry_point() {
    test_case ".mcp.json references correct server entry point"
    if grep -q 'mcp-server/dist/index.js' "$PROJECT_ROOT/.mcp.json"; then
        test_pass
    else
        test_fail ".mcp.json should reference mcp-server/dist/index.js"
    fi
}

test_mcp_env_variable() {
    test_case ".mcp.json sets CLAUDE_OCTOPUS_MCP_MODE env var"
    if grep -q 'CLAUDE_OCTOPUS_MCP_MODE' "$PROJECT_ROOT/.mcp.json"; then
        test_pass
    else
        test_fail ".mcp.json should set CLAUDE_OCTOPUS_MCP_MODE"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MCP Server Package
# ═══════════════════════════════════════════════════════════════════════════════

test_mcp_package_json() {
    test_case "mcp-server/package.json exists"
    if [[ -f "$PROJECT_ROOT/mcp-server/package.json" ]]; then
        test_pass
    else
        test_fail "mcp-server/package.json not found"
    fi
}

test_mcp_depends_on_sdk() {
    test_case "mcp-server depends on @modelcontextprotocol/sdk"
    if grep -q '@modelcontextprotocol/sdk' "$PROJECT_ROOT/mcp-server/package.json"; then
        test_pass
    else
        test_fail "mcp-server should depend on @modelcontextprotocol/sdk"
    fi
}

test_mcp_server_has_tools() {
    test_case "MCP server exposes required Octopus tools"
    local src="$PROJECT_ROOT/mcp-server/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "mcp-server/src/index.ts not found"
        return
    fi

    local missing=""
    for tool in octopus_discover octopus_define octopus_develop octopus_deliver \
                octopus_embrace octopus_debate octopus_review octopus_security \
                octopus_list_skills octopus_status; do
        if ! grep -q "$tool" "$src"; then
            missing="$missing $tool"
        fi
    done

    if [[ -z "$missing" ]]; then
        test_pass
    else
        test_fail "Missing tools in MCP server:$missing"
    fi
}

test_mcp_correct_command_mapping() {
    test_case "MCP server uses correct orchestrate.sh command names"
    local src="$PROJECT_ROOT/mcp-server/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "mcp-server/src/index.ts not found"
        return
    fi

    # Verify correct command mappings (not the wrong names)
    local ok=true
    # debate maps to grapple, not "debate"
    if grep -q '"grapple"' "$src"; then
        : # correct
    else
        ok=false
    fi
    # security maps to squeeze, not "security"
    if grep -q '"squeeze"' "$src"; then
        : # correct
    else
        ok=false
    fi
    # review maps to code-review (v8.50.0 redesign from codex-review)
    if grep -q '"code-review"' "$src"; then
        : # correct
    else
        ok=false
    fi

    if $ok; then
        test_pass
    else
        test_fail "MCP server uses wrong command names (should use grapple/squeeze/code-review)"
    fi
}

test_mcp_flags_before_command() {
    test_case "MCP server passes flags before command in args"
    local src="$PROJECT_ROOT/mcp-server/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "mcp-server/src/index.ts not found"
        return
    fi

    # orchestrate.sh requires flags before command
    # Pattern: [...flags, command, prompt]
    if grep -q '\.\.\.\(flags\|extraFlags\).*command.*prompt\]\|\.\.\.flags, command' "$src"; then
        test_pass
    else
        # Alternative: check for the spread pattern
        if grep -q 'flags, command, prompt' "$src"; then
            test_pass
        else
            test_fail "MCP server should pass flags before command in args array"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MCP Server Schema
# ═══════════════════════════════════════════════════════════════════════════════

test_skill_schema_exists() {
    test_case "Skill schema JSON exists"
    if [[ -f "$PROJECT_ROOT/mcp-server/src/schema/skill-schema.json" ]]; then
        test_pass
    else
        test_fail "skill-schema.json not found"
    fi
}

test_skill_schema_valid_json() {
    test_case "Skill schema is valid JSON"
    if python3 -m json.tool "$PROJECT_ROOT/mcp-server/src/schema/skill-schema.json" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "skill-schema.json is not valid JSON"
    fi
}

test_skill_schema_required_fields() {
    test_case "Skill schema requires name and description"
    local schema="$PROJECT_ROOT/mcp-server/src/schema/skill-schema.json"
    if grep -q '"required"' "$schema" && grep -q '"name"' "$schema" && grep -q '"description"' "$schema"; then
        test_pass
    else
        test_fail "Skill schema should require name and description"
    fi
}

test_skill_schema_platform_support() {
    test_case "Skill schema supports claude-code and openclaw platforms"
    local schema="$PROJECT_ROOT/mcp-server/src/schema/skill-schema.json"
    if grep -q 'claude-code' "$schema" && grep -q 'openclaw' "$schema"; then
        test_pass
    else
        test_fail "Skill schema should support both claude-code and openclaw platforms"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# OpenClaw Extension
# ═══════════════════════════════════════════════════════════════════════════════

test_openclaw_package_json() {
    test_case "openclaw/package.json exists"
    if [[ -f "$PROJECT_ROOT/openclaw/package.json" ]]; then
        test_pass
    else
        test_fail "openclaw/package.json not found"
    fi
}

test_openclaw_extensions_field() {
    test_case "openclaw/package.json has openclaw.extensions field"
    if grep -q '"openclaw"' "$PROJECT_ROOT/openclaw/package.json" && \
       grep -q '"extensions"' "$PROJECT_ROOT/openclaw/package.json"; then
        test_pass
    else
        test_fail "openclaw/package.json should have openclaw.extensions field"
    fi
}

test_openclaw_plugin_json() {
    test_case "openclaw.plugin.json exists with configSchema"
    if [[ -f "$PROJECT_ROOT/openclaw/openclaw.plugin.json" ]] && \
       grep -q 'configSchema' "$PROJECT_ROOT/openclaw/openclaw.plugin.json"; then
        test_pass
    else
        test_fail "openclaw.plugin.json should exist with configSchema"
    fi
}

test_openclaw_correct_command_mapping() {
    test_case "OpenClaw extension uses correct orchestrate.sh command names"
    local src="$PROJECT_ROOT/openclaw/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "openclaw/src/index.ts not found"
        return
    fi

    local ok=true
    if ! grep -q '"grapple"' "$src"; then ok=false; fi
    if ! grep -q '"squeeze"' "$src"; then ok=false; fi
    if ! grep -q '"code-review"' "$src"; then ok=false; fi

    if $ok; then
        test_pass
    else
        test_fail "OpenClaw extension uses wrong command names"
    fi
}

test_openclaw_introspection_tools() {
    test_case "OpenClaw extension registers octopus_list_skills and octopus_status"
    local src="$PROJECT_ROOT/openclaw/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "openclaw/src/index.ts not found"
        return
    fi

    local missing=""
    for tool in octopus_list_skills octopus_status; do
        if ! grep -q "name: \"$tool\"" "$src"; then
            missing="$missing $tool"
        fi
    done

    if [[ -z "$missing" ]]; then
        test_pass
    else
        test_fail "Introspection tools not registered in OpenClaw extension:$missing"
    fi
}

test_openclaw_default_workflows_match_manifest() {
    test_case "Runtime default workflow set matches openclaw.plugin.json"
    local manifest="$PROJECT_ROOT/openclaw/openclaw.plugin.json"
    local src="$PROJECT_ROOT/openclaw/src/index.ts"

    if [[ ! -f "$manifest" ]] || [[ ! -f "$src" ]]; then
        test_fail "openclaw.plugin.json or openclaw/src/index.ts not found"
        return
    fi

    local output exit_code
    output=$(python3 -c '
import json, re, sys
declared = json.load(open(sys.argv[1], encoding="utf-8"))["configSchema"]["properties"]["enabledWorkflows"]["default"]
match = re.search(r"DEFAULT_ENABLED_WORKFLOWS\s*=\s*(\[[^\]]*\])", open(sys.argv[2], encoding="utf-8").read())
if not match:
    sys.exit("DEFAULT_ENABLED_WORKFLOWS not found in openclaw/src/index.ts")
runtime = json.loads(match.group(1))
if runtime != declared:
    sys.exit("runtime %s != manifest %s" % (runtime, declared))
' "$manifest" "$src" 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        test_pass
    else
        test_fail "Default workflow set drifted from the manifest: $output"
    fi
}

test_openclaw_flags_before_command() {
    test_case "OpenClaw extension passes flags before command"
    local src="$PROJECT_ROOT/openclaw/src/index.ts"
    if [[ ! -f "$src" ]]; then
        test_fail "openclaw/src/index.ts not found"
        return
    fi

    # Pattern: [...flags, command, ...postFlags, prompt] or [...flags, command, prompt]
    if grep -q '\.\.\.flags, command' "$src"; then
        test_pass
    else
        test_fail "OpenClaw extension should pass flags before command"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Skill Registry & Build Tooling
# ═══════════════════════════════════════════════════════════════════════════════

test_build_script_exists() {
    test_case "build-openclaw.sh exists and is executable"
    if [[ -x "$PROJECT_ROOT/scripts/build-openclaw.sh" ]]; then
        test_pass
    else
        test_fail "build-openclaw.sh should exist and be executable"
    fi
}

test_registry_generated() {
    test_case "Skill registry index.ts exists"
    if [[ -f "$PROJECT_ROOT/openclaw/src/tools/index.ts" ]]; then
        test_pass
    else
        test_fail "openclaw/src/tools/index.ts not found"
    fi
}

test_registry_contains_skills_and_commands() {
    test_case "Registry contains both skills and commands"
    local registry="$PROJECT_ROOT/openclaw/src/tools/index.ts"
    if grep -q 'type: "skill"' "$registry" && grep -q 'type: "command"' "$registry"; then
        test_pass
    else
        test_fail "Registry should contain both skill and command entries"
    fi
}

test_registry_count_matches() {
    test_case "Registry count matches actual entries"
    local registry="$PROJECT_ROOT/openclaw/src/tools/index.ts"
    local declared_count
    declared_count=$(grep 'REGISTRY_COUNT' "$registry" | grep -o '[0-9]*')
    local actual_count
    actual_count=$(grep -c 'name: "' "$registry")

    if [[ "$declared_count" == "$actual_count" ]]; then
        test_pass
    else
        test_fail "REGISTRY_COUNT ($declared_count) != actual entries ($actual_count)"
    fi
}

test_build_check_mode() {
    test_case "build-openclaw.sh --check mode succeeds (registry in sync)"
    local output exit_code
    output=$("$PROJECT_ROOT/scripts/build-openclaw.sh" --check 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        test_pass
    else
        test_fail "build-openclaw.sh --check failed (registry out of sync): $output"
    fi
}

test_build_script_handles_crlf_frontmatter() {
    test_case "build-openclaw.sh parses CRLF frontmatter (Windows checkouts)"
    local tmpdir
    tmpdir=$(mktemp -d) || { test_fail "could not create temp dir"; return; }
    mkdir -p "$tmpdir/skills" "$tmpdir/commands" "$tmpdir/out"

    # A skill whose frontmatter uses CRLF, as Git checks it out when
    # core.autocrlf=true. The filename deliberately differs from the declared
    # name so a parse failure shows up as the filename fallback.
    printf -- '---\r\nname: crlf-probe\r\ndescription: CRLF probe skill\r\n---\r\n\r\nBody\r\n' \
        > "$tmpdir/skills/zz-fixture.md"

    local output
    output=$(SKILLS_DIR="$tmpdir/skills" COMMANDS_DIR="$tmpdir/commands" \
        OUTPUT_DIR="$tmpdir/out" "$PROJECT_ROOT/scripts/build-openclaw.sh" 2>&1)

    if grep -q 'name: "crlf-probe", description: "CRLF probe skill"' "$tmpdir/out/index.ts" 2>/dev/null; then
        test_pass
    else
        test_fail "CRLF frontmatter not parsed: $(cat "$tmpdir/out/index.ts" 2>/dev/null) | $output"
    fi

    rm -rf "$tmpdir"
}

test_skill_loader_handles_crlf_frontmatter() {
    test_case "Skill loader parses CRLF frontmatter (Windows checkouts)"
    local loader="$PROJECT_ROOT/openclaw/dist/skill-loader.js"

    if ! command -v node >/dev/null 2>&1; then
        test_skip "node not available"
        return
    fi
    if [[ ! -f "$loader" ]]; then
        test_fail "openclaw/dist/skill-loader.js not found (run: cd openclaw && npm run build)"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d) || { test_fail "could not create temp dir"; return; }
    mkdir -p "$tmpdir/.claude/skills"
    printf -- '---\r\nname: crlf-probe\r\ndescription: CRLF probe skill\r\n---\r\n\r\nBody\r\n' \
        > "$tmpdir/.claude/skills/zz-fixture.md"

    cat > "$tmpdir/probe.mjs" <<'PROBE'
import { pathToFileURL } from "node:url";

const [loaderPath, pluginRoot] = process.argv.slice(2);
const { loadSkills } = await import(pathToFileURL(loaderPath).href);
const skills = await loadSkills(pluginRoot);
const probe = skills.find((s) => s.name === "crlf-probe");

if (!probe) {
  console.error(`crlf-probe skill was dropped; loaded: ${JSON.stringify(skills)}`);
  process.exit(1);
}
if (probe.description !== "CRLF probe skill") {
  console.error(`wrong description: ${probe.description}`);
  process.exit(1);
}
PROBE

    local output exit_code
    output=$(node "$tmpdir/probe.mjs" "$loader" "$tmpdir" 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        test_pass
    else
        test_fail "Skill loader dropped a CRLF skill: $output"
    fi

    rm -rf "$tmpdir"
}

test_skill_loader_parses_frontmatter() {
    test_case "Skill loader module exists for YAML frontmatter parsing"
    if [[ -f "$PROJECT_ROOT/openclaw/src/skill-loader.ts" ]]; then
        if grep -q 'parseFrontmatter\|loadSkills\|loadCommands' "$PROJECT_ROOT/openclaw/src/skill-loader.ts"; then
            test_pass
        else
            test_fail "skill-loader.ts should have parseFrontmatter/loadSkills/loadCommands"
        fi
    else
        test_fail "openclaw/src/skill-loader.ts not found"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TypeScript Configuration
# ═══════════════════════════════════════════════════════════════════════════════

test_mcp_tsconfig_module_resolution() {
    test_case "MCP server uses node16 moduleResolution"
    if grep -q '"node16"' "$PROJECT_ROOT/mcp-server/tsconfig.json"; then
        test_pass
    else
        test_fail "mcp-server tsconfig should use node16 moduleResolution"
    fi
}

test_openclaw_tsconfig_module_resolution() {
    test_case "OpenClaw extension uses node16 moduleResolution"
    if grep -q '"node16"' "$PROJECT_ROOT/openclaw/tsconfig.json"; then
        test_pass
    else
        test_fail "openclaw tsconfig should use node16 moduleResolution"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-Platform Parity
# ═══════════════════════════════════════════════════════════════════════════════

test_tool_naming_consistency() {
    test_case "MCP and OpenClaw use same tool names"
    local mcp_src="$PROJECT_ROOT/mcp-server/src/index.ts"
    local oclaw_src="$PROJECT_ROOT/openclaw/src/index.ts"

    if [[ ! -f "$mcp_src" ]] || [[ ! -f "$oclaw_src" ]]; then
        test_fail "Source files not found"
        return
    fi

    # Extract tool names from both (octopus_* pattern)
    local mcp_tools oclaw_tools
    mcp_tools=$(grep -o 'octopus_[a-z_]*' "$mcp_src" | sort -u)
    oclaw_tools=$(grep -o 'octopus_[a-z_]*' "$oclaw_src" | sort -u)

    # The OpenClaw extension may not have all MCP tools (list_skills, status are introspection)
    # But the core workflow tools should match
    local ok=true
    for tool in octopus_discover octopus_define octopus_develop octopus_deliver \
                octopus_embrace octopus_debate octopus_review octopus_security; do
        if ! echo "$mcp_tools" | grep -q "$tool"; then
            ok=false
        fi
        if ! echo "$oclaw_tools" | grep -q "$tool"; then
            ok=false
        fi
    done

    if $ok; then
        test_pass
    else
        test_fail "Core workflow tools should be named identically in both MCP and OpenClaw"
    fi
}

test_plugin_json_unchanged() {
    test_case "plugin.json not modified by OpenClaw layer"
    local plugin_json="$PROJECT_ROOT/.claude-plugin/plugin.json"
    # OpenClaw compatibility should NOT add itself to plugin.json skills/commands
    if grep -q 'openclaw' "$plugin_json" || grep -q 'mcp-server' "$plugin_json"; then
        test_fail "plugin.json should not reference openclaw or mcp-server directories"
    else
        test_pass
    fi
}

test_no_openclaw_in_skills() {
    test_case "No OpenClaw-specific code in .claude/skills/ or .claude/commands/ (excluding claw files)"
    local found=""
    # skill-claw.md and claw.md are intentionally OpenClaw-specific (sysadmin skill for managing OpenClaw instances)
    if grep -rl 'openclaw\|OpenClaw' "$PROJECT_ROOT/.claude/skills/" 2>/dev/null | grep -v 'skill-claw\.md' | head -1 | grep -q .; then
        found="skills"
    fi
    if grep -rl 'openclaw\|OpenClaw' "$PROJECT_ROOT/.claude/commands/" 2>/dev/null | grep -v 'claw\.md' | head -1 | grep -q .; then
        found="$found commands"
    fi

    if [[ -z "$found" ]]; then
        test_pass
    else
        test_fail "OpenClaw references found in: $found (skills/commands should be platform-agnostic)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Validation Suite Integration
# ═══════════════════════════════════════════════════════════════════════════════

test_validate_script_exists() {
    test_case "validate-openclaw.sh exists and is executable"
    if [[ -x "$PROJECT_ROOT/tests/validate-openclaw.sh" ]]; then
        test_pass
    else
        test_fail "tests/validate-openclaw.sh should exist and be executable"
    fi
}

test_validate_script_passes() {
    test_case "validate-openclaw.sh passes all checks"
    local output exit_code
    output=$("$PROJECT_ROOT/tests/validate-openclaw.sh" 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        test_pass
    else
        test_fail "validate-openclaw.sh failed: $output"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════════

# MCP Server Configuration
test_mcp_json_exists
test_mcp_json_valid_json
test_mcp_server_entry_point
test_mcp_env_variable

# MCP Server Package
test_mcp_package_json
test_mcp_depends_on_sdk
test_mcp_server_has_tools
test_mcp_correct_command_mapping
test_mcp_flags_before_command

# Schema
test_skill_schema_exists
test_skill_schema_valid_json
test_skill_schema_required_fields
test_skill_schema_platform_support

# OpenClaw Extension
test_openclaw_package_json
test_openclaw_extensions_field
test_openclaw_plugin_json
test_openclaw_correct_command_mapping
test_openclaw_introspection_tools
test_openclaw_default_workflows_match_manifest
test_openclaw_flags_before_command

# Build Tooling
test_build_script_exists
test_registry_generated
test_registry_contains_skills_and_commands
test_registry_count_matches
test_build_check_mode
test_build_script_handles_crlf_frontmatter
test_skill_loader_handles_crlf_frontmatter
test_skill_loader_parses_frontmatter

# TypeScript Config
test_mcp_tsconfig_module_resolution
test_openclaw_tsconfig_module_resolution

# Cross-Platform Parity
test_tool_naming_consistency
test_plugin_json_unchanged
test_no_openclaw_in_skills

# Validation Suite
test_validate_script_exists
test_validate_script_passes

test_summary
