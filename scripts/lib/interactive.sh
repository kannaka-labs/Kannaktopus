#!/usr/bin/env bash
# interactive.sh — Interactive mode initialization, error display, CI mode, preflight recovery
#
# Functions: init_interactive, show_error,
#            preflight_with_recovery, init_ci_mode, ci_output
# Data:      ERROR_CODES array, CI_MODE, AUDIT_LOG
#
# Extracted from orchestrate.sh (v9.7.8)
# Source-safe: no main execution block.

# ═══════════════════════════════════════════════════════════════════════════════
# v4.3 FEATURE: INTERACTIVE SETUP WIZARD (DEPRECATED in v4.9)
# Use 'detect-providers' command instead for Claude Code integration
# ═══════════════════════════════════════════════════════════════════════════════

init_interactive() {
    echo ""
    echo -e "${YELLOW}⚠ WARNING: 'init_interactive' is deprecated and will be removed in v5.0${NC}"
    echo ""
    echo -e "${CYAN}The interactive setup wizard has been deprecated in favor of a simpler flow.${NC}"
    echo ""
    echo -e "${CYAN}New approach:${NC}"
    echo -e "  1. Run: ${GREEN}./scripts/orchestrate.sh detect-providers${NC}"
    echo -e "     This will check your current setup and give you clear next steps."
    echo ""
    echo -e "  2. Or use: ${GREEN}/kannaktopus:setup${NC} in Claude Code"
    echo -e "     This provides full setup instructions within Claude Code."
    echo ""
    echo -e "${CYAN}Why the change?${NC}"
    echo -e "  • Faster onboarding - you only need ONE provider (Codex OR Gemini)"
    echo -e "  • Clearer instructions - no confusing interactive prompts"
    echo -e "  • Works in Claude Code - no need to leave and run terminal commands"
    echo -e "  • Environment variables for API keys (more secure)"
    echo ""
    echo -e "${CYAN}Quick migration:${NC}"
    echo -e "  Instead of this wizard, just set environment variables in your shell profile:"
    echo -e "    ${GREEN}export OPENAI_API_KEY=\"sk-...\"${NC}  (for Codex)"
    echo -e "    ${GREEN}export GEMINI_API_KEY=\"AIza...\"${NC}  (for Gemini)"
    echo ""
    echo -e "  Then run: ${GREEN}./scripts/orchestrate.sh detect-providers${NC}"
    echo ""
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# v4.3 FEATURE: CONTEXTUAL ERROR CODES AND RECOVERY
# Provides actionable error messages with unique codes
# ═══════════════════════════════════════════════════════════════════════════════

# Error code registry (bash 3.2 compatible - uses regular array)
ERROR_CODES=(
    "E001:OPENAI_API_KEY not set:export OPENAI_API_KEY=\"sk-...\" && orchestrate.sh preflight:help api-setup"
    "E002:Gemini API key not set — set GEMINI_API_KEY or GOOGLE_API_KEY (if in ~/.bashrc, move to ~/.profile — bashrc is skipped in non-interactive shells):export GEMINI_API_KEY=\"AIza...\" && orchestrate.sh preflight:help api-setup"
    "E003:Codex CLI not found:npm install -g @openai/codex:help setup"
    "E004:Gemini CLI not found:npm install -g @google/gemini-cli:help setup"
    "E005:Workspace not initialized:orchestrate.sh init:help init"
    "E006:Agent spawn failed:Check API keys and network connection:help troubleshoot"
    "E007:Quality gate failed:Review output and retry with lower threshold (-q 60):help quality"
    "E008:Timeout exceeded:Increase timeout with -t 600 or break into smaller tasks:help timeout"
    "E009:Invalid agent type:Use: codex, codex-mini, gemini, gemini-fast:help agents"
    "E010:Task file parse error:Check JSON syntax with: jq . tasks.json:help tasks"
)

# Display contextual error with recovery steps
show_error() {
    local code="$1"
    local context="${2:-}"

    # Find error definition
    local error_def=""
    for entry in "${ERROR_CODES[@]}"; do
        if [[ "$entry" == "$code:"* ]]; then
            error_def="$entry"
            break
        fi
    done

    if [[ -z "$error_def" ]]; then
        # Unknown error code, show generic message
        echo -e "${RED}✗ Error: $context${NC}" >&2
        return 1
    fi

    # Parse error definition (code:message:fix:help)
    IFS=':' read -r err_code err_msg err_fix err_help <<< "$error_def"

    echo "" >&2
    octopus_header "Error $err_code" "$RED" >&2
    echo "" >&2
    echo -e "  ${RED}$err_msg${NC}" >&2

    if [[ -n "$context" ]]; then
        echo -e "  ${YELLOW}Context: $context${NC}" >&2
    fi

    echo "" >&2
    echo -e "  ${GREEN}Fix this:${NC}" >&2
    echo -e "    $err_fix" >&2
    echo "" >&2
    echo -e "  ${CYAN}Learn more:${NC}" >&2
    echo -e "    orchestrate.sh $err_help" >&2
    echo "" >&2

    return 1
}

# Check for common issues and provide contextual help
preflight_with_recovery() {
    local has_errors=false

    # Check OpenAI API Key
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        show_error "E001"
        has_errors=true
    fi

    # Check Gemini API Key (v9.2.1: try resolving from profile/.env first, check OAuth)
    # Accept GEMINI_API_KEY, GOOGLE_API_KEY, or OAuth creds
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
        resolve_provider_env "GEMINI_API_KEY" 2>/dev/null
    fi
    if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
        resolve_provider_env "GOOGLE_API_KEY" 2>/dev/null
    fi
    if [[ -z "${GEMINI_API_KEY:-}" ]] && [[ -z "${GOOGLE_API_KEY:-}" ]] && [[ ! -f "$HOME/.gemini/oauth_creds.json" ]]; then
        show_error "E002"
        has_errors=true
    fi

    # Check Codex CLI
    if ! command -v codex &> /dev/null; then
        show_error "E003"
        has_errors=true
    fi

    # Check Gemini CLI
    if ! command -v gemini &> /dev/null; then
        show_error "E004"
        has_errors=true
    fi

    # Check workspace
    if [[ ! -d "${WORKSPACE_DIR:-$HOME/.kannaktopus}" ]]; then
        show_error "E005"
        has_errors=true
    fi

    if $has_errors; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# v4.4 FEATURE: CI/CD MODE AND AUDIT TRAILS
# Non-interactive execution for GitHub Actions and audit logging
# ═══════════════════════════════════════════════════════════════════════════════

CI_MODE="${CI:-false}"
AUDIT_LOG="${WORKSPACE_DIR:-$HOME/.kannaktopus}/audit.log"

# True for 1/true/yes (case-insensitive); CI=false / CI=0 / empty are not CI.
# Uses tr rather than ${var,,} to stay compatible with bash 3.2 (macOS).
_truthy() {
    local v
    v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" ]]
}

# Initialize CI mode from environment
init_ci_mode() {
    # Detect CI environment
    if _truthy "${CI:-}" || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
        CI_MODE=true
        AUTONOMY_MODE="autonomous"  # No prompts in CI
        log INFO "CI environment detected - running in autonomous mode"
    fi
}

# Write structured JSON output for CI consumption
ci_output() {
    local status="$1"
    local phase="$2"
    local message="$3"
    local output_file="${4:-}"

    if [[ "$CI_MODE" == "true" ]]; then
        local json_output
        json_output=$(cat << EOF
{
  "status": "$status",
  "phase": "$phase",
  "message": "$message",
  "timestamp": "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)",
  "output_file": "$output_file"
}
EOF
)
        echo "$json_output"

        # Also set GitHub Actions outputs if available
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
            echo "status=$status" >> "$GITHUB_OUTPUT"
            echo "phase=$phase" >> "$GITHUB_OUTPUT"
            [[ -n "$output_file" ]] && echo "output_file=$output_file" >> "$GITHUB_OUTPUT"
        fi
    fi
}
