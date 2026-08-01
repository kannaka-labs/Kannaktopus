#!/usr/bin/env bash
# Test suite for AI Debate Hub integration
# Verifies skill-debate.md, command routing, attribution, and version consistency

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "AI Debate Hub Integration"

test_debate_skill_exists() {
    test_case "Debate skill exists (skill-debate.md)"

    local skill_file="$PROJECT_ROOT/.claude/skills/skill-debate.md"

    if [[ -f "$skill_file" ]]; then
        test_pass
    else
        test_fail "skill-debate.md not found at $skill_file"
        return 1
    fi
}

test_skill_has_frontmatter() {
    test_case "skill-debate.md has YAML frontmatter"

    local skill_file="$PROJECT_ROOT/.claude/skills/skill-debate.md"

    if grep -q "^---$" "$skill_file" && \
       grep -q "^name: skill-debate$" "$skill_file" && \
       grep -q "^description:" "$skill_file"; then
        test_pass
    else
        test_fail "skill-debate.md missing required YAML frontmatter"
        return 1
    fi
}

test_skill_has_attribution() {
    test_case "skill-debate.md includes wolverin0 attribution"

    local skill_file="$PROJECT_ROOT/.claude/skills/skill-debate.md"

    if grep -q "wolverin0" "$skill_file" && \
       grep -q "https://github.com/wolverin0/claude-skills" "$skill_file"; then
        test_pass
    else
        test_fail "Missing attribution to wolverin0"
        return 1
    fi
}

test_debate_skill_auto_discoverable() {
    test_case "Debate skill is auto-discoverable (skills/skill-debate/SKILL.md)"

    # Claude Code 2.x auto-discovers plugin skills from skills/<name>/SKILL.md.
    # The flat skills array was deliberately removed from plugin.json (3951e29);
    # re-adding it triggers folder-shadowed-by-manifest warnings.
    local plugin_file="$PROJECT_ROOT/.claude-plugin/plugin.json"

    if [[ -f "$PROJECT_ROOT/skills/skill-debate/SKILL.md" ]] && \
       ! grep -q '"skills"' "$plugin_file"; then
        test_pass
    else
        test_fail "skills/skill-debate/SKILL.md missing, or plugin.json declares a skills array (skills must auto-discover)"
        return 1
    fi
}

test_all_skills_auto_discoverable() {
    test_case "Every skills/<name>/ folder is a valid auto-discoverable skill"

    # Set-based: enumerate the real set instead of naming one member. A skill
    # folder added without SKILL.md, or whose frontmatter name does not match
    # its folder name, fails here. skills/blocks/ holds shared fragments, not
    # a skill, and is the only folder allowed to lack SKILL.md.
    local bad=""
    local d dirname name

    for d in "$PROJECT_ROOT"/skills/*/; do
        dirname=$(basename "$d")
        [[ "$dirname" == "blocks" ]] && continue

        if [[ ! -f "$d/SKILL.md" ]]; then
            bad="$bad $dirname(no-SKILL.md)"
            continue
        fi

        name=$(grep -m1 '^name:' "$d/SKILL.md" | sed 's/^name: *//' | tr -d '\r')
        [[ "$name" == "$dirname" ]] || bad="$bad $dirname(name=$name)"
        grep -q '^description:' "$d/SKILL.md" || bad="$bad $dirname(no-description)"
    done

    if [[ -z "$bad" ]]; then
        test_pass
    else
        test_fail "invalid skill folders:$bad"
        return 1
    fi
}

test_plugin_description_counts() {
    test_case "plugin.json description counts match the real artifact sets"

    local plugin_file="$PROJECT_ROOT/.claude-plugin/plugin.json"
    local claimed actual_skills actual_commands actual_personas

    claimed=$(grep -o '[0-9]* personas, [0-9]* commands, [0-9]* skills' "$plugin_file")
    actual_personas=$(find "$PROJECT_ROOT/agents/personas" -name "*.md" -type f | wc -l | tr -d ' ')
    actual_commands=$(grep -c '\./\.claude/commands/' "$plugin_file")
    actual_skills=$(find "$PROJECT_ROOT/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')

    if [[ "$claimed" == "$actual_personas personas, $actual_commands commands, $actual_skills skills" ]]; then
        test_pass
    else
        test_fail "description claims '$claimed' but repo has $actual_personas personas, $actual_commands commands, $actual_skills skills"
        return 1
    fi
}

test_debate_skill_content() {
    test_case "skill-debate.md contains expected content"

    local skill_file="$PROJECT_ROOT/.claude/skills/skill-debate.md"

    if [[ ! -f "$skill_file" ]]; then
        test_fail "skill-debate.md not found"
        return 1
    fi

    if grep -q "Debate" "$skill_file" && \
       grep -q "Gemini" "$skill_file" && \
       grep -q "Codex" "$skill_file"; then
        test_pass
    else
        test_fail "skill-debate.md missing expected content"
        return 1
    fi
}

test_debate_has_quality_gates() {
    test_case "skill-debate.md includes quality gates (merged from integration)"

    local skill_file="$PROJECT_ROOT/.claude/skills/skill-debate.md"

    if grep -q "Quality Gates" "$skill_file" && \
       grep -q "Cost Tracking" "$skill_file"; then
        test_pass
    else
        test_fail "skill-debate.md missing quality gates or cost tracking sections"
        return 1
    fi
}

test_debate_command_routing() {
    test_case "Debate command routing exists in orchestrate.sh"

    local orch="$PROJECT_ROOT/scripts/orchestrate.sh"
    local libs="$PROJECT_ROOT/scripts/lib/*.sh"

    if grep -rq "debate|deliberate|consensus)" $orch $libs && \
       grep -rq "wolverin0" $orch $libs; then
        test_pass
    else
        test_fail "orchestrate.sh/lib missing debate command routing or attribution"
        return 1
    fi
}

test_readme_attribution() {
    test_case "README.md includes AI Debate Hub attribution"

    local readme="$PROJECT_ROOT/README.md"

    if grep -q "wolverin0" "$readme" && \
       grep -q "AI Debate Hub" "$readme" && \
       grep -q "https://github.com/wolverin0/claude-skills" "$readme"; then
        test_pass
    else
        test_fail "README.md missing AI Debate Hub attribution"
        return 1
    fi
}

test_changelog_attribution() {
    test_case "CHANGELOG.md has version entries"

    local changelog="$PROJECT_ROOT/CHANGELOG.md"

    if [[ -f "$changelog" ]] && grep -q '\[8\.' "$changelog"; then
        test_pass
    else
        test_fail "CHANGELOG.md missing or has no version entries"
        return 1
    fi
}

test_version_consistency() {
    test_case "Version consistency across all files"

    local plugin_json="$PROJECT_ROOT/.claude-plugin/plugin.json"
    local package_json="$PROJECT_ROOT/package.json"
    local marketplace_json="$PROJECT_ROOT/.claude-plugin/marketplace.json"

    local plugin_version=$(grep '"version"' "$plugin_json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
    local package_version=$(grep '"version"' "$package_json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
    local marketplace_version=$(grep -A 3 '"octo"' "$marketplace_json" | grep '"version"' | sed 's/.*"version": *"\([^"]*\)".*/\1/')

    if [[ "$plugin_version" == "$package_version" ]] && \
       [[ "$package_version" == "$marketplace_version" ]]; then
        test_pass
    else
        test_fail "Version mismatch: plugin=$plugin_version, package=$package_version, marketplace=$marketplace_version"
        return 1
    fi
}

# Run all tests
test_debate_skill_exists
test_skill_has_frontmatter
test_skill_has_attribution
test_debate_skill_auto_discoverable
test_all_skills_auto_discoverable
test_plugin_description_counts
test_debate_skill_content
test_debate_has_quality_gates
test_debate_command_routing
test_readme_attribution
test_changelog_attribution
test_version_consistency

test_summary
