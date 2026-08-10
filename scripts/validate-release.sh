#!/usr/bin/env bash
# validate-release.sh - Pre-release validation for kannaktopus
# Prevents common release issues like version mismatches and missing registrations
#
# Read-only by default: it inspects and reports, and never changes git or GitHub
# state. Tag creation, tag pushing, and GitHub release creation happen only with
# --publish, so a plain validation run is always safe to repeat.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PUBLISH=false

usage() {
    cat <<'EOF'
Usage: validate-release.sh [--publish]

  (no flags)  Validate only. Inspects plugin metadata, versions, registrations,
              the CHANGELOG, the expected git tag and the GitHub release, and
              reports what is missing or out of date. Makes no changes.

  --publish   Additionally create/update the release tag, push it to origin, and
              create the GitHub release from the CHANGELOG entry. Rewrites tags
              and pushes with --force; only use this from a real release.

  -h, --help  Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "validate-release.sh: unknown argument '$1'" >&2
            echo "" >&2
            usage >&2
            exit 2
            ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0

echo "🐙 Kannaktopus Release Validation"
echo "======================================"
echo ""

# ============================================================================
# 1. PLUGIN NAME CHECK (CRITICAL - DO NOT CHANGE)
# ============================================================================
echo "🔒 Checking plugin names..."

PLUGIN_NAME=$(grep '"name"' "$ROOT_DIR/.claude-plugin/plugin.json" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
MARKETPLACE_PLUGIN_NAME=$(sed -n '/"plugins"/,/]/p' "$ROOT_DIR/.claude-plugin/marketplace.json" | grep '"name"' | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')

if [[ "$PLUGIN_NAME" != "octo" ]]; then
    echo -e "  ${RED}CRITICAL ERROR: plugin.json name is '$PLUGIN_NAME' - MUST be 'octo'${NC}"
    echo -e "  ${RED}This controls command namespace (/octo:* commands)${NC}"
    errors=$((errors + 1))
else
    echo -e "  ${GREEN}✓ plugin.json name: octo (command namespace)${NC}"
fi

if [[ "$MARKETPLACE_PLUGIN_NAME" != "octo" ]]; then
    echo -e "  ${RED}CRITICAL ERROR: marketplace.json plugin name is '$MARKETPLACE_PLUGIN_NAME' - MUST be 'octo'${NC}"
    echo -e "  ${RED}This controls install command (octo@kannaka-plugins) and must match plugin.json name${NC}"
    errors=$((errors + 1))
else
    echo -e "  ${GREEN}✓ marketplace.json plugin name: octo (matches plugin.json for /plugin UI)${NC}"
fi

echo ""

# ============================================================================
# 2. VERSION SYNC CHECK
# ============================================================================
echo "📦 Checking version synchronization..."

PLUGIN_VERSION=$(grep '"version"' "$ROOT_DIR/.claude-plugin/plugin.json" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
MARKETPLACE_VERSION=$(grep '"version"' "$ROOT_DIR/.claude-plugin/marketplace.json" | grep -v "1.0.0" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
PACKAGE_VERSION=$(grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')

# Check README badge
README_BADGE_VERSION=$(grep -o 'Version-[0-9.]*' "$ROOT_DIR/README.md" | head -1 | sed 's/Version-//')

echo "  plugin.json:      $PLUGIN_VERSION"
echo "  marketplace.json: $MARKETPLACE_VERSION"
echo "  package.json:     $PACKAGE_VERSION"
echo "  README badge:     $README_BADGE_VERSION"

if [[ "$PLUGIN_VERSION" != "$MARKETPLACE_VERSION" ]]; then
    echo -e "  ${RED}ERROR: plugin.json ($PLUGIN_VERSION) != marketplace.json ($MARKETPLACE_VERSION)${NC}"
    errors=$((errors + 1))
fi

if [[ "$PLUGIN_VERSION" != "$PACKAGE_VERSION" ]]; then
    echo -e "  ${RED}ERROR: plugin.json ($PLUGIN_VERSION) != package.json ($PACKAGE_VERSION)${NC}"
    errors=$((errors + 1))
fi

if [[ "$PLUGIN_VERSION" != "$README_BADGE_VERSION" ]]; then
    echo -e "  ${YELLOW}WARNING: plugin.json ($PLUGIN_VERSION) != README badge ($README_BADGE_VERSION)${NC}"
    warnings=$((warnings + 1))
fi

if [[ $errors -eq 0 ]] && [[ "$PLUGIN_VERSION" == "$MARKETPLACE_VERSION" ]] && [[ "$PLUGIN_VERSION" == "$PACKAGE_VERSION" ]]; then
    echo -e "  ${GREEN}✓ All versions synchronized: v$PLUGIN_VERSION${NC}"
fi

echo ""

# ============================================================================
# 3. CLAUDE PLUGIN VALIDATION
# ============================================================================
echo "🧪 Checking Claude plugin validation..."

if command -v claude >/dev/null 2>&1; then
    if claude plugin validate "$ROOT_DIR/.claude-plugin/plugin.json"; then
        echo -e "  ${GREEN}✓ Claude plugin validator passed${NC}"
    else
        echo -e "  ${RED}ERROR: claude plugin validate failed for plugin.json${NC}"
        errors=$((errors + 1))
    fi

    if claude plugin validate "$ROOT_DIR/.claude-plugin/marketplace.json"; then
        echo -e "  ${GREEN}✓ Marketplace manifest validator passed${NC}"
    else
        echo -e "  ${RED}ERROR: claude plugin validate failed for marketplace.json${NC}"
        errors=$((errors + 1))
    fi
else
    echo -e "  ${YELLOW}WARNING: claude CLI not installed; skipping runtime plugin validation${NC}"
    warnings=$((warnings + 1))
fi

echo ""

# ============================================================================
# 4. COMMAND REGISTRATION CHECK
# ============================================================================
echo "📝 Checking command registration..."

# Get all .md files in commands directory
COMMAND_FILES=$(ls "$ROOT_DIR/.claude/commands/"*.md 2>/dev/null | xargs -n1 basename | sort)

# Get commands registered in plugin.json
REGISTERED_COMMANDS=$(grep -o '\.claude/commands/[^"]*\.md' "$ROOT_DIR/.claude-plugin/plugin.json" | sed 's|.*\.claude/commands/||' | sort)

# Find unregistered commands
for cmd_file in $COMMAND_FILES; do
    if ! echo "$REGISTERED_COMMANDS" | grep -q "^${cmd_file}$"; then
        echo -e "  ${RED}ERROR: Command file '$cmd_file' not registered in plugin.json${NC}"
        errors=$((errors + 1))
    fi
done

# Find registered but missing commands
for reg_cmd in $REGISTERED_COMMANDS; do
    if ! echo "$COMMAND_FILES" | grep -q "^${reg_cmd}$"; then
        echo -e "  ${RED}ERROR: Registered command '$reg_cmd' does not exist${NC}"
        errors=$((errors + 1))
    fi
done

cmd_count=$(echo "$COMMAND_FILES" | wc -l | tr -d ' ')
reg_count=$(echo "$REGISTERED_COMMANDS" | wc -l | tr -d ' ')

if [[ "$cmd_count" == "$reg_count" ]] && [[ $errors -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All $cmd_count commands properly registered${NC}"
fi

echo ""

# ============================================================================
# 5. COMMAND FRONTMATTER FORMAT CHECK
# ============================================================================
echo "📛 Checking command frontmatter format..."

invalid_frontmatter=0
for cmd_file in "$ROOT_DIR/.claude/commands/"*.md; do
    cmd_name=$(sed -n '2p' "$cmd_file" | grep -o 'command: .*' | sed 's/command: //' || true)
    # Commands should NOT have "octo:" prefix in frontmatter (Claude Code adds it automatically)
    if [[ -n "$cmd_name" ]] && [[ "$cmd_name" == *":"* ]]; then
        echo -e "  ${RED}ERROR: $(basename "$cmd_file") has 'command: $cmd_name' - must NOT include namespace prefix${NC}"
        echo -e "  ${RED}  Claude Code will automatically add '/octo:' prefix based on plugin name${NC}"
        errors=$((errors + 1))
        ((invalid_frontmatter++))
    fi
done

if [[ $invalid_frontmatter -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All command frontmatters use correct format (no namespace prefix)${NC}"
fi

echo ""

# ============================================================================
# 6. SKILL REGISTRATION CHECK
# ============================================================================
echo "🎯 Checking skill auto-discovery (skills/<name>/SKILL.md)..."

# Claude Code 2.x auto-discovers skills/<name>/SKILL.md; the manifest
# deliberately declares no skills array (3951e29). Validate the folder set:
# every folder (except blocks/, shared fragments) is a discoverable skill
# whose frontmatter name matches its folder.
skill_count=0
for skill_dir in "$ROOT_DIR/skills/"*/; do
    dir_name=$(basename "$skill_dir")
    [[ "$dir_name" == "blocks" ]] && continue
    if [[ ! -f "$skill_dir/SKILL.md" ]]; then
        echo -e "  ${RED}ERROR: skills/$dir_name/ has no SKILL.md (not discoverable)${NC}"
        errors=$((errors + 1))
        continue
    fi
    fm_name=$(grep -m1 '^name:' "$skill_dir/SKILL.md" | sed 's/^name: *//' | tr -d '\r')
    if [[ "$fm_name" != "$dir_name" ]]; then
        echo -e "  ${RED}ERROR: skills/$dir_name/SKILL.md frontmatter name is '$fm_name'${NC}"
        errors=$((errors + 1))
    fi
    skill_count=$((skill_count + 1))
done

if grep -q '"skills"' "$ROOT_DIR/.claude-plugin/plugin.json"; then
    echo -e "  ${RED}ERROR: plugin.json declares a skills array (must auto-discover)${NC}"
    errors=$((errors + 1))
fi

if [[ $errors -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All $skill_count skills auto-discoverable${NC}"
fi

echo ""

# ============================================================================
# 7. SKILL FRONTMATTER FORMAT CHECK
# ============================================================================
echo "🏷️  Checking skill frontmatter format..."

invalid_skill_names=0
for skill_file in "$ROOT_DIR/.claude/skills/"*.md; do
    skill_name=$(sed -n '2p' "$skill_file" | grep -o 'name: .*' | sed 's/name: //' || true)
    # Skip if no name found (might be a different format)
    if [[ -z "$skill_name" ]]; then
        continue
    fi
    # Skills should use descriptive prefixes (skill-, flow-, sys-, etc.) but NOT namespace prefixes (octo:)
    if [[ "$skill_name" != "skill-"* ]] && [[ "$skill_name" != "flow-"* ]] && [[ "$skill_name" != "octopus-"* ]] && [[ "$skill_name" != "sys-"* ]]; then
        echo -e "  ${RED}ERROR: $(basename "$skill_file") has 'name: $skill_name' - must use descriptive prefix${NC}"
        echo -e "  ${RED}  Use: skill-, flow-, sys-, or octopus- prefix (NOT octo:)${NC}"
        errors=$((errors + 1))
        ((invalid_skill_names++))
    fi
done

if [[ $invalid_skill_names -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All skill names use correct format (descriptive prefix)${NC}"
fi

echo ""

# ============================================================================
# 8. MARKETPLACE DESCRIPTION VERSION CHECK
# ============================================================================
echo "🏪 Checking marketplace description..."

MARKETPLACE_DESC=$(grep '"description"' "$ROOT_DIR/.claude-plugin/marketplace.json" | grep -v "Multi-tentacled orchestration" | head -1)

if echo "$MARKETPLACE_DESC" | grep -q "v$PLUGIN_VERSION"; then
    echo -e "  ${GREEN}✓ Marketplace description mentions v$PLUGIN_VERSION${NC}"
else
    echo -e "  ${YELLOW}WARNING: Marketplace description may not mention current version v$PLUGIN_VERSION${NC}"
    warnings=$((warnings + 1))
fi

echo ""

# ============================================================================
# 9. GIT TAG CHECK
# ============================================================================
echo "🔖 Checking git tag..."

# Annotation for the release tag: the CHANGELOG entry for this version, falling
# back to a bare message so `git tag -a -m` never gets an empty string.
tag_message() {
    local msg
    msg=$(awk "/## \[$PLUGIN_VERSION\]/,/^## \[/" "$ROOT_DIR/CHANGELOG.md" | head -20 | tail -n +2)
    if [[ -n "$msg" ]]; then
        printf '%s\n' "$msg"
    else
        printf 'Release %s\n' "$EXPECTED_TAG"
    fi
}

EXPECTED_TAG="v$PLUGIN_VERSION"
if git tag -l "$EXPECTED_TAG" | grep -q "$EXPECTED_TAG"; then
    TAG_COMMIT=$(git rev-list -n 1 "$EXPECTED_TAG")
    HEAD_COMMIT=$(git rev-parse HEAD)

    if [[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]]; then
        echo -e "  ${GREEN}✓ Tag $EXPECTED_TAG exists and points to HEAD${NC}"
    else
        echo -e "  ${YELLOW}WARNING: Tag $EXPECTED_TAG exists but doesn't point to HEAD${NC}"
        echo -e "  ${YELLOW}  Tag points to: ${TAG_COMMIT:0:7}${NC}"
        echo -e "  ${YELLOW}  HEAD is:       ${HEAD_COMMIT:0:7}${NC}"
        warnings=$((warnings + 1))

        if [[ "$PUBLISH" == true ]]; then
            echo -e "  ${YELLOW}  Updating tag to point to current HEAD...${NC}"

            # Delete old tag locally and remotely, create new one
            git tag -d "$EXPECTED_TAG" >/dev/null 2>&1 || true
            git push origin ":refs/tags/$EXPECTED_TAG" >/dev/null 2>&1 || true

            git tag -a "$EXPECTED_TAG" -m "$(tag_message)"
            echo -e "  ${GREEN}✓ Tag $EXPECTED_TAG updated to point to HEAD${NC}"
        else
            echo -e "  ${YELLOW}  Re-point it with: validate-release.sh --publish${NC}"
        fi
    fi
else
    echo -e "  ${YELLOW}NOTE: Tag $EXPECTED_TAG not yet created${NC}"
    warnings=$((warnings + 1))

    if [[ "$PUBLISH" == true ]]; then
        git tag -a "$EXPECTED_TAG" -m "$(tag_message)"
        echo -e "  ${GREEN}✓ Tag $EXPECTED_TAG created${NC}"
    else
        echo -e "  ${YELLOW}  Create it with: validate-release.sh --publish${NC}"
    fi
fi

echo ""

# ============================================================================
# 9. CHANGELOG ENTRY CHECK
# ============================================================================
echo "📝 Checking CHANGELOG entry..."

EXPECTED_TAG="v$PLUGIN_VERSION"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

if [[ -f "$CHANGELOG_FILE" ]]; then
    # Check if version is mentioned in CHANGELOG
    if grep -q "## \[$PLUGIN_VERSION\]" "$CHANGELOG_FILE"; then
        echo -e "  ${GREEN}✓ CHANGELOG.md has entry for v$PLUGIN_VERSION${NC}"
    else
        echo -e "  ${RED}ERROR: CHANGELOG.md missing entry for v$PLUGIN_VERSION${NC}"
        echo -e "  ${RED}  Add a changelog entry before releasing${NC}"
        errors=$((errors + 1))
    fi
else
    echo -e "  ${YELLOW}WARNING: CHANGELOG.md not found${NC}"
    warnings=$((warnings + 1))
fi

echo ""

# ============================================================================
# 10. GITHUB RELEASE CHECK & AUTO-CREATE
# ============================================================================
echo "🚀 Checking GitHub release..."

EXPECTED_TAG="v$PLUGIN_VERSION"

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo -e "  ${YELLOW}NOTE: gh CLI not installed - skipping GitHub release check${NC}"
    echo -e "  ${YELLOW}  Install with: brew install gh${NC}"
else
    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        echo -e "  ${YELLOW}NOTE: Not authenticated with GitHub - skipping release check${NC}"
        echo -e "  ${YELLOW}  Authenticate with: gh auth login${NC}"
    else
        # Check if release exists
        if gh release view "$EXPECTED_TAG" &> /dev/null; then
            echo -e "  ${GREEN}✓ GitHub release $EXPECTED_TAG exists${NC}"
        else
            echo -e "  ${YELLOW}NOTE: GitHub release $EXPECTED_TAG does not exist${NC}"

            # Check if tag exists on remote
            REMOTE_TAG_SHA=$(git ls-remote origin "refs/tags/$EXPECTED_TAG" 2>/dev/null | cut -f1)

            warnings=$((warnings + 1))

            if [[ -n "$REMOTE_TAG_SHA" ]]; then
                # Extract CHANGELOG entry for this version
                RELEASE_NOTES=$(awk "/## \\[$PLUGIN_VERSION\\]/,/^---$/" "$ROOT_DIR/CHANGELOG.md" | sed '$d' | tail -n +3)

                if [[ -z "$RELEASE_NOTES" ]]; then
                    echo -e "  ${YELLOW}WARNING: No CHANGELOG entry found for v$PLUGIN_VERSION${NC}"
                    echo -e "  ${YELLOW}  Cannot create a release without release notes${NC}"
                elif [[ "$PUBLISH" == true ]]; then
                    echo -e "  ${GREEN}  Creating GitHub release from CHANGELOG...${NC}"
                    # Create release with CHANGELOG notes and mark as latest
                    if gh release create "$EXPECTED_TAG" --title "v$PLUGIN_VERSION" --notes "$RELEASE_NOTES" --latest >/dev/null 2>&1; then
                        echo -e "  ${GREEN}✓ GitHub release $EXPECTED_TAG created${NC}"
                    else
                        echo -e "  ${YELLOW}WARNING: Failed to create GitHub release${NC}"
                    fi
                else
                    echo -e "  ${YELLOW}  Create it with: validate-release.sh --publish${NC}"
                fi
            else
                echo -e "  ${YELLOW}  Tag not yet pushed to remote${NC}"
            fi
        fi
    fi
fi

echo ""

# ============================================================================
# HELPER: Push tag if needed (v8.13.0 - deduplicated, always --force)
# ============================================================================
push_tag_if_needed() {
    local tag="$1"
    [[ "$PUBLISH" == true ]] || return 0
    if git tag -l "$tag" | grep -q "$tag"; then
        REMOTE_TAG_SHA=$(git ls-remote origin "refs/tags/$tag" 2>/dev/null | cut -f1)
        LOCAL_TAG_SHA=$(git rev-list -n 1 "$tag" 2>/dev/null)

        if [[ "$REMOTE_TAG_SHA" == "$LOCAL_TAG_SHA" ]] && [[ -n "$REMOTE_TAG_SHA" ]]; then
            echo -e "${GREEN}✓ Tag $tag already up to date on remote${NC}"
            return 0
        fi

        echo ""
        echo -e "${GREEN}📤 Pushing tag $tag to remote...${NC}"
        git push --no-verify origin "$tag" --force 2>/dev/null
        echo -e "${GREEN}✓ Tag pushed to remote${NC}"

        # Auto-create GitHub release if gh is available and authenticated
        if command -v gh &> /dev/null && gh auth status &> /dev/null; then
            if ! gh release view "$tag" &> /dev/null; then
                echo -e "${GREEN}📝 Creating GitHub release...${NC}"
                RELEASE_NOTES=$(awk "/## \\[$PLUGIN_VERSION\\]/,/^---$/" "$ROOT_DIR/CHANGELOG.md" | sed '$d' | tail -n +3)
                if [[ -n "$RELEASE_NOTES" ]] && gh release create "$tag" --title "v$PLUGIN_VERSION" --notes "$RELEASE_NOTES" --latest >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ GitHub release $tag created${NC}"
                fi
            fi
        fi
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================
echo "======================================"
if [[ $errors -gt 0 ]]; then
    echo -e "${RED}❌ VALIDATION FAILED: $errors error(s), $warnings warning(s)${NC}"
    echo ""
    echo "Fix the errors above before releasing."
    exit 1
elif [[ $warnings -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  VALIDATION PASSED WITH WARNINGS: $warnings warning(s)${NC}"
    echo ""
    echo "Consider fixing the warnings before releasing."
    push_tag_if_needed "v$PLUGIN_VERSION"
    exit 0
else
    echo -e "${GREEN}✅ VALIDATION PASSED${NC}"
    echo ""
    echo "Ready to release v$PLUGIN_VERSION!"
    push_tag_if_needed "v$PLUGIN_VERSION"
    exit 0
fi
