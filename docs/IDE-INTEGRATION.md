# IDE Integration Guide

Kannaktopus can be used from any IDE that supports the Model Context Protocol (MCP). The existing MCP server exposes all Octopus workflows as tools — no extension code required.

## Quick Start

```bash
# Auto-detect your IDE and configure MCP
./scripts/ide-attach.sh

# Or specify an IDE explicitly
./scripts/ide-attach.sh --ide vscode
./scripts/ide-attach.sh --ide cursor
./scripts/ide-attach.sh --ide zed
```

Restart your IDE after running the script.

## Supported IDEs

| IDE | Support Level | Setup |
|-----|--------------|-------|
| **Cursor** | Native MCP | `ide-attach.sh --ide cursor` |
| **VS Code** | Native MCP (Copilot Agent Mode) | `ide-attach.sh --ide vscode` |
| **Zed** | Native MCP | `ide-attach.sh --ide zed` |
| **Windsurf** | Native MCP | `ide-attach.sh --ide windsurf` |
| **Neovim** | Via `mcp.nvim` community plugin | See [Neovim Setup](#neovim-setup) |
| **JetBrains** | Planned (Phase 3) | Not yet available |
| **Visual Studio (Windows)** | Limited — see [below](#visual-studio-windows) | Manual WSL2 setup |

## Architecture

```
IDE (VS Code / Cursor / Zed / Neovim)
    |
    | MCP Protocol (stdio)
    v
Octopus MCP Server (TypeScript)
    |
    | execFile() (no shell)
    v
orchestrate.sh (bash core — unchanged)
    |
    v
Codex CLI / Gemini CLI / Claude subagents
```

The IDE communicates with the MCP server over stdio. The MCP server delegates to `orchestrate.sh` via `execFile` (safe, no shell injection). The same bash engine that runs in the terminal — no behavior changes.

## Available MCP Tools

After setup, these tools appear in your IDE's AI chat:

| Tool | Description |
|------|-------------|
| `octopus_discover` | Multi-provider research (Codex + Gemini) |
| `octopus_define` | Consensus building on requirements |
| `octopus_develop` | Implementation with quality gates |
| `octopus_deliver` | Final validation and review |
| `octopus_embrace` | Full 4-phase Double Diamond workflow |
| `octopus_debate` | Three-way AI debate |
| `octopus_review` | Multi-provider code review |
| `octopus_security` | Security audit with OWASP checks |
| `octopus_set_editor_context` | Inject IDE state into workflows |
| `octopus_list_skills` | Browse available skills |
| `octopus_status` | Check provider availability |

## Editor Context Injection

The `octopus_set_editor_context` tool lets your IDE pass state into Octopus workflows:

```json
{
  "filename": "/path/to/active/file.ts",
  "selection": "function handleAuth() { ... }",
  "cursor_line": 42,
  "language_id": "typescript",
  "workspace_root": "/path/to/project"
}
```

This context is injected as environment variables (`OCTOPUS_IDE_*`) into `orchestrate.sh`. Currently these variables are passed through for future consumption — orchestrate.sh does not yet act on them, but they establish the contract for IDE-aware workflows in a future release. Input validation enforces path safety and a 50KB selection size limit.

## Manual Configuration

If `ide-attach.sh` doesn't support your IDE, you can configure MCP manually.

### VS Code

Create `.vscode/mcp.json` in your project:

```json
{
  "servers": {
    "kannaktopus": {
      "command": "npx",
      "args": ["tsx", "/path/to/kannaktopus/mcp-server/src/index.ts"],
      "env": {
        "OPENAI_API_KEY": "${env:OPENAI_API_KEY}",
        "GEMINI_API_KEY": "${env:GEMINI_API_KEY}"
      }
    }
  }
}
```

### Cursor

> **Important:** Cursor does **not** have Claude Code's plugin/slash-command system. You will not get `/octo:*` commands. Instead, Octopus runs as an MCP server exposing tools like `octopus_discover`, `octopus_review`, etc. that you invoke through Cursor's AI chat.

**What works in Cursor:**
- All MCP tools (research, review, debate, security audit, etc.)
- Multi-provider dispatch (Codex + Gemini + Claude via the MCP server)
- Editor context injection via `octopus_set_editor_context`

**What doesn't work in Cursor:**
- `/octo:*` slash commands (Claude Code plugin feature only)
- Hooks, statusline HUD, and session state (require Claude Code's plugin runtime)
- Discipline mode auto-invoke gates (require Claude Code hooks)

**Option 1: Auto-setup (recommended)**

```bash
git clone --depth 1 https://github.com/NickFlach/Kannaktopus.git ~/.cursor/kannaktopus
cd ~/.cursor/kannaktopus && scripts/ide-attach.sh --ide cursor
```

**Option 2: Manual config**

Create `.cursor/mcp.json` in your project (per-project) or `~/.cursor/mcp.json` (global):

```json
{
  "mcpServers": {
    "kannaktopus": {
      "command": "npx",
      "args": ["tsx", "${userHome}/.cursor/kannaktopus/mcp-server/src/index.ts"],
      "env": {
        "OPENAI_API_KEY": "${env:OPENAI_API_KEY}",
        "GEMINI_API_KEY": "${env:GEMINI_API_KEY}"
      }
    }
  }
}
```

Restart Cursor after setup. Tools appear in Settings → Tools & MCP.

**Using Octopus in Cursor:** Ask naturally in Cursor's AI chat — e.g. "use octopus_discover to research OAuth patterns" or "run octopus_review on this PR". Cursor's agent will invoke the MCP tools automatically.

**Cursor Rules (optional):** To customize Octopus behavior, you can add a `.cursor/rules/octopus.md` file with project-specific instructions. This is similar to how `CLAUDE.md` works in Claude Code — it gives the AI context about your project conventions. See [Cursor Rules docs](https://cursor.com/docs/context/rules) for details.

### Zed

Add to `.zed/settings.json` in your project:

```json
{
  "context_servers": {
    "kannaktopus": {
      "command": {
        "path": "npx",
        "args": ["tsx", "/path/to/kannaktopus/mcp-server/src/index.ts"],
        "env": {
          "OPENAI_API_KEY": "${env:OPENAI_API_KEY}",
          "GEMINI_API_KEY": "${env:GEMINI_API_KEY}"
        }
      }
    }
  }
}
```

### Neovim Setup

Install the `mcp.nvim` community plugin, then add to your config:

```lua
require('mcp').setup({
  servers = {
    ['kannaktopus'] = {
      command = 'npx',
      args = { 'tsx', '/path/to/kannaktopus/mcp-server/src/index.ts' },
    },
  },
})
```

## Visual Studio (Windows)

Visual Studio 2026 supports `.mcp.json` natively via its AI integration, but Kannaktopus has significant constraints on Windows:

**Prerequisite: Git Bash.** `orchestrate.sh` is an 18K-line bash script using POSIX features (PIDs, signals, named pipes, GNU tools), so it needs a bash to run it. Windows cannot execute a `.sh` file directly, so both adapters — the MCP server and the OpenClaw extension — launch it as `bash orchestrate.sh …` on Windows, resolving `bash` from `PATH`. Git Bash (bundled with [Git for Windows](https://git-scm.com/download/win), default `C:\Program Files\Git\bin\bash.exe`), an MSYS2 bash, or WSL's `bash.exe` all satisfy this. If no `bash` is on `PATH`, the tools return an error saying so rather than a bare `ENOENT`.

The bash-native features the script relies on are not all equally happy under Git Bash, so a heavier-weight option below may still suit you better for long workflows.

**Options:**

1. **WSL2 (Most faithful to the target environment):** Install Kannaktopus inside WSL2. Visual Studio can invoke the MCP server through `wsl.exe`:
   ```json
   {
     "servers": {
       "kannaktopus": {
         "command": "wsl",
         "args": ["npx", "tsx", "/home/user/kannaktopus/mcp-server/src/index.ts"]
       }
     }
   }
   ```

2. **GitHub Copilot Chat:** Claude is available as a model within GitHub Copilot Chat in Visual Studio. This doesn't provide Octopus workflows but gives access to Claude directly.

3. **Dev Container:** Use a `.devcontainer/devcontainer.json` to run the full Linux environment inside VS.

**Our recommendation:** If you're a Visual Studio user, use Claude Code in the integrated terminal for Octopus workflows, or use VS Code alongside Visual Studio for AI-assisted work. A native Visual Studio extension is not planned due to the effort-to-impact tradeoff.

## Troubleshooting

### MCP server not starting

```bash
# Verify dependencies are installed
cd /path/to/kannaktopus/mcp-server && npm install

# Test the server directly
npx tsx /path/to/kannaktopus/mcp-server/src/index.ts
# Should hang waiting for stdio input (Ctrl+C to exit)
```

### Tools not appearing in IDE

- Restart the IDE after adding MCP config
- Check that API keys are set in your environment
- Verify the path to `index.ts` is absolute and correct
- Check IDE logs for MCP connection errors

### Provider not available

If Codex or Gemini workflows fail, check:
```bash
command -v codex   # Codex CLI installed?
command -v gemini  # Gemini CLI installed?
```

Run `octopus_status` tool to see provider availability.

## Roadmap

- **Phase 1 (Current):** MCP bridge — zero-UI integration for VS Code, Cursor, Zed
- **Phase 2:** Thin VS Code extension — sidebar with live state, skill gallery, Marketplace distribution
- **Phase 3:** JetBrains plugin, cross-IDE gateway server
