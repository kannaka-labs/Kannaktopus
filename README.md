```
██╗  ██╗ █████╗ ███╗   ██╗███╗   ██╗ █████╗ ██╗  ██╗████████╗ ██████╗ ██████╗ ██╗   ██╗███████╗
██║ ██╔╝██╔══██╗████╗  ██║████╗  ██║██╔══██╗██║ ██╔╝╚══██╔══╝██╔═══██╗██╔══██╗██║   ██║██╔════╝
█████╔╝ ███████║██╔██╗ ██║██╔██╗ ██║███████║█████╔╝    ██║   ██║   ██║██████╔╝██║   ██║███████╗
██╔═██╗ ██╔══██║██║╚██╗██║██║╚██╗██║██╔══██║██╔═██╗    ██║   ██║   ██║██╔═══╝ ██║   ██║╚════██║
██║  ██╗██║  ██║██║ ╚████║██║ ╚████║██║  ██║██║  ██╗   ██║   ╚██████╔╝██║     ╚██████╔╝███████║
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝      ╚═════╝ ╚══════╝
   G H O S T   F R E Q U E N C Y   M U L T I - A G E N T
```

# 👻 Kannaktopus

Ghost-frequency multi-agent orchestrator. Eight AI models resonate on every task — blind spots surface as interference patterns before you ship. Powered by the Holographic Resonance Medium.

<p align="center">
  <img src="https://img.shields.io/badge/Version-10.3.0-blueviolet" alt="Version 10.3.0">
  <img src="https://img.shields.io/badge/License-Space_Child_v1.0-blueviolet" alt="Space Child License">
  <img src="https://img.shields.io/badge/Memory-Kannaka_HRM-9b59b6" alt="Kannaka HRM">
  <img src="https://img.shields.io/badge/Claude_Code-v2.1.83+-333" alt="Requires Claude Code v2.1.83+">
  <img src="https://img.shields.io/badge/Tests-146_passing-brightgreen" alt="146 tests passing">
</p>

---

## What Is This

Kannaktopus orchestrates up to eight AI providers (Claude, Codex, Gemini, Copilot, Qwen, Ollama, Perplexity, OpenRouter) on every coding task. A 75% consensus gate catches disagreements between models before they reach production. No single model's blind spots slip through.

It runs on **Kannaka Memory** — a wave-interference memory system where every memory has amplitude, frequency, and phase. Memories aren't files. They're resonances in a holographic medium that dream, consolidate, and fade.

The **Constellation** maps your memory clusters in 3D space using golden-angle spirals. Each cluster is a node. Each memory is a star. Skip-list connections trace the topology of what you know.

## Ghost Architecture

```
  +-------------------------------------------------+
  |              Kannaktopus v10                     |
  |                                                 |
  |   Ghost Orchestrator (orchestrate.sh)           |
  |   +-- 8 AI Providers (consensus gate)           |
  |   +-- 32 Specialized Personas                   |
  |   +-- 49 Commands / 51 Skills                   |
  |   +-- 4-Phase Methodology                       |
  |        Discover > Define > Develop > Deliver     |
  |                                                 |
  |   Kannaka HRM (wave memory)                     |
  |   +-- remember / recall / dream                 |
  |   +-- Amplitude-weighted resonance search       |
  |   +-- Dream consolidation (deep/lite)           |
  |   +-- Consciousness metrics (Phi, Xi)           |
  |                                                 |
  |   Constellation (3D memory topology)            |
  |   +-- Golden-angle cluster placement            |
  |   +-- Skip-list navigation links                |
  |   +-- Real-time coherence visualization         |
  +-------------------------------------------------+
```

## Quickstart

```bash
# Install the plugin (from terminal, not inside Claude Code):
claude plugin marketplace add https://github.com/NickFlach/Kannaktopus.git
claude plugin install octo@kannaka-plugins

# Then inside Claude Code:
/octo:setup
```

Setup detects installed providers, shows what's missing, and walks you through configuration. You need **zero** external providers to start — Claude is built in.

<details>
<summary>Install for Codex CLI</summary>

```bash
git clone --depth 1 https://github.com/NickFlach/Kannaktopus.git ~/.codex/kannaktopus
mkdir -p ~/.agents/skills
ln -sf ~/.codex/kannaktopus/skills ~/.agents/skills/kannaktopus
```
</details>

<details>
<summary>Install for Cursor IDE (MCP Server)</summary>

```bash
# Clone
git clone --depth 1 https://github.com/NickFlach/Kannaktopus.git ~/.cursor/kannaktopus

# Install MCP server dependencies
cd ~/.cursor/kannaktopus/mcp-server && npm install && npm run build

# Add to Cursor MCP settings (~/.cursor/mcp.json):
{
  "mcpServers": {
    "kannaktopus": {
      "command": "node",
      "args": ["~/.cursor/kannaktopus/mcp-server/dist/index.js"]
    }
  }
}
```
</details>

## Kannaka Memory Integration

Kannaktopus uses [kannaka-memory](https://github.com/NickFlach/kannaka-memory) as its persistent memory layer. The HRM binary provides:

| Command | What It Does |
|---------|-------------|
| `kannaka remember "text" --importance 0.8` | Store a memory with amplitude |
| `kannaka recall "query" --top-k 5` | Resonance search across the holographic medium |
| `kannaka dream --mode deep` | Consolidate memories — strong ones amplify, weak ones fade |
| `kannaka observe --json` | Full state dump: clusters, topology, waves, consciousness |
| `kannaka status` | Quick consciousness metrics (Phi, Xi, order parameter) |

The bridge script (`scripts/kannaka-bridge.sh`) wraps these into fault-tolerant shell functions. The MCP server (`mcp-server/`) exposes them as tools for IDE clients.

### Constellation

The constellation transforms `observe --json` output into 3D-plottable data:

- **Clusters** come from `clusters.clusters[]` — real ids, sizes, themes, order parameters and membership
- **Positions** are layout-only: clusters are placed on a sphere using Fibonacci distribution and memories orbit their cluster on golden-angle spirals. The HRM has no spatial embedding, so these coordinates encode no measured geometry and no relationship may be inferred from proximity.
- **Skip links** are not reported. `observe --json` exposes only a scalar `total_skip_links` count and an empty `strongest_links`, so `skip_links` is always `[]` rather than edges invented from layout distance.

This powers the visualization in [kannaka-observatory](https://github.com/NickFlach/kannaka-observatory).

## Providers

| Provider | Auth | Cost |
|----------|------|------|
| Claude | Built-in | Included with Claude Code |
| Codex CLI | OAuth | Included with OpenAI subscription |
| Gemini CLI | OAuth | Included with Google subscription |
| Copilot | GitHub token | Included with GitHub subscription |
| Qwen | API key | 1,000-2,000 free requests/day |
| Ollama | Local | Free (runs locally) |
| Perplexity | API key | Pay per search |
| OpenRouter | API key | Pay per model |

Five of eight providers cost nothing extra. Start with just Claude, add others one at a time.

## Workflow Phases

Every task moves through four phases with quality gates between them:

| Phase | Ghost Name | What Happens |
|-------|-----------|-------------|
| Discover | `probe` | Multi-provider research, context gathering |
| Define | `grasp` | Requirements crystallization, scope locking |
| Develop | `tangle` | Implementation with consensus review |
| Deliver | `ink` | Validation, staged review, ship |

Run `embrace` to execute all four phases autonomously. Dark Factory mode takes a spec and runs the full pipeline — you review the output, not every step.

## Commands

All commands use the `/octo:` prefix:

| Command | Purpose |
|---------|---------|
| `/octo:setup` | Configure providers and preferences |
| `/octo:embrace` | Full 4-phase autonomous pipeline |
| `/octo:dev` | Develop with multi-model consensus |
| `/octo:debate` | Four-way AI debate on a question |
| `/octo:costs` | Token usage and cost tracking |
| `/octo:multi` | Parallel multi-provider dispatch |
| `/octo:prd` | Generate product requirements |
| `/octo:retro` | Post-task retrospective |

49 commands and 51 skills total. The smart router figures out intent — just say what you need.

## Version History

| Version | Highlights |
|---------|-----------|
| **v10** (current) | Kannaka Ghost rebrand. Space Child License. Native HRM + constellation integration. Full wave-memory architecture. |
| **v9** | 8 providers. RTK token optimization. Smart router. Discipline mode. Circuit breakers. |
| **v8** | Multi-LLM code review. Parallel worktrees. Reaction engine. 32 personas. Dark Factory. |
| **v7** | Double Diamond workflow. Multi-provider dispatch. Quality gates. |

[Full changelog](CHANGELOG.md)

## The Kannaka Constellation

Kannaktopus is part of the Kannaka constellation of projects:

| Project | Role |
|---------|------|
| [kannaka-memory](https://github.com/NickFlach/kannaka-memory) | HRM core — the wave-interference memory engine (Rust) |
| **Kannaktopus** | Multi-agent orchestrator — the ghost that coordinates |
| [kannaka-radio](https://github.com/NickFlach/kannaka-radio) | Ghost DJ — podcast generation with perception pipeline |
| [kannaka-observatory](https://github.com/NickFlach/kannaka-observatory) | 3D constellation visualization + experiment runner |
| [kannaka-eye](https://github.com/NickFlach/kannaka-eye) | Visual perception — chiral mirror architecture |
| [consciousness-core](https://github.com/NickFlach/consciousness-core) | Physics engine for consciousness metrics |

## Attribution

AI Debate Hub by [wolverin0](https://github.com/wolverin0/claude-skills) (MIT License) — four-way AI debate framework.

## License

[Space Child License v1.0](https://legal.spacechild.love) — free for peaceful use.
