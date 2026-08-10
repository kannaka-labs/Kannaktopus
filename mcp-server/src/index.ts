#!/usr/bin/env node
/**
 * Kannaktopus MCP Server
 *
 * Exposes Kannaktopus workflows (Double Diamond phases, debate, review)
 * as MCP tools that any MCP client (OpenClaw, Claude.ai, Cursor, etc.) can consume.
 *
 * This server delegates to the existing orchestrate.sh infrastructure,
 * preserving all existing behavior without duplication.
 *
 * Command mapping (MCP tool → orchestrate.sh command):
 *   octopus_discover → probe
 *   octopus_define   → grasp
 *   octopus_develop  → tangle
 *   octopus_deliver  → ink
 *   octopus_embrace  → embrace
 *   octopus_debate   → grapple
 *   octopus_review   → codex-review
 *   octopus_security → squeeze
 *
 * IDE integration tools:
 *   octopus_set_editor_context → Inject IDE state (file, selection, cursor) into orchestration
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { resolve, dirname, delimiter as pathDelimiter } from "node:path";
import { fileURLToPath } from "node:url";
import { readFile, readdir, access } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { createServer, type IncomingMessage } from "node:http";
import { timingSafeEqual } from "node:crypto";

const execFileAsync = promisify(execFile);

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, "../..");
const ORCHESTRATE_SH = resolve(PLUGIN_ROOT, "scripts/orchestrate.sh");

// --- orchestrate.sh launcher (issues #46 / #29) ---
//
// Windows has no notion of an executable `.sh`, so `execFile(ORCHESTRATE_SH, …)`
// there fails with a bare ENOENT that says nothing about the real cause. On
// win32 we launch `bash <script> <args…>` instead. `bash` is resolved from PATH
// rather than a hardcoded Git install location, so Git Bash, an MSYS2 bash or
// WSL's bash all satisfy it — and every one of them accepts native Windows
// paths, so `cwd` and each argument pass through untranslated.
//
// POSIX keeps exec'ing the script directly: the platform that already works is
// deliberately left untouched.
//
// This block is mirrored in openclaw/src/index.ts — the two adapters ship as
// separate packages with no shared module, and drifting apart is exactly how
// they came to have the same bug in two files.

/** Candidate file names for `bash`, in PATH-scan order, per platform. */
const BASH_EXECUTABLE_NAMES =
  process.platform === "win32" ? ["bash.exe", "bash"] : ["bash"];

/**
 * Actionable message returned in the tool response — not just written in the
 * docs — when no bash can be found. A silent ENOENT from execFile is what makes
 * this undiagnosable today.
 */
const BASH_NOT_FOUND_MESSAGE = [
  "`bash` was not found on PATH, and Kannaktopus needs it on Windows.",
  "",
  "orchestrate.sh is a bash script; Windows cannot execute it directly, so it is",
  "launched as `bash orchestrate.sh …`. Install Git for Windows (which ships Git",
  "Bash) and make sure its bash is on PATH — the default installer location is",
  "C:\\Program Files\\Git\\bin\\bash.exe. A WSL or MSYS2 bash on PATH works too.",
  "",
  "Restart your MCP client afterwards so it inherits the updated PATH.",
].join("\n");

/**
 * Find `bash` by scanning PATH ourselves rather than handing a bare name to
 * execFile, so a missing bash is a diagnosable condition instead of an ENOENT
 * that is indistinguishable from a missing orchestrate.sh.
 */
function findBashOnPath(): string | null {
  const rawPath = process.env.PATH ?? "";
  if (!rawPath) return null;

  for (const entry of rawPath.split(pathDelimiter)) {
    // Windows PATH entries are sometimes quoted; an empty entry means "cwd",
    // which we do not want to search for an interpreter.
    const dir = entry.trim().replace(/^"|"$/g, "");
    if (!dir) continue;
    for (const name of BASH_EXECUTABLE_NAMES) {
      const candidate = resolve(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

/** How to spawn a `.sh` entry point on the current platform. */
type ScriptLaunch =
  | { ok: true; file: string; args: string[] }
  | { ok: false; error: string };

function resolveScriptLaunch(script: string, args: string[]): ScriptLaunch {
  if (process.platform !== "win32") {
    return { ok: true, file: script, args };
  }
  const bash = findBashOnPath();
  if (!bash) return { ok: false, error: BASH_NOT_FOUND_MESSAGE };
  return { ok: true, file: bash, args: [script, ...args] };
}

/**
 * Windows-only environment supplement for the orchestrate child. The forwarded
 * POSIX allowlist below is the minimum a POSIX child needs; on Windows the
 * equivalent minimum is different — without SystemRoot and PATHEXT, programs
 * that bash goes on to spawn fail in ways that look nothing like a launcher
 * problem. Still an explicit allowlist: process.env is never forwarded whole.
 */
function windowsChildEnv(): Record<string, string | undefined> {
  if (process.platform !== "win32") return {};
  return {
    ...(process.env.SystemRoot && { SystemRoot: process.env.SystemRoot }),
    ...(process.env.SystemDrive && { SystemDrive: process.env.SystemDrive }),
    ...(process.env.PATHEXT && { PATHEXT: process.env.PATHEXT }),
    ...(process.env.USERPROFILE && { USERPROFILE: process.env.USERPROFILE }),
    ...(process.env.TEMP && { TEMP: process.env.TEMP }),
    ...(process.env.TMP && { TMP: process.env.TMP }),
  };
}

// Kannaka HRM binary configuration
const KANNAKA_BIN = process.env.KANNAKA_BIN || "kannaka";

/**
 * Home directory that is correct on every platform: Windows exposes it as
 * USERPROFILE (HOME is usually unset outside a POSIX shell), POSIX as HOME.
 * Falls back to os.homedir() so we never invent a path for somebody else's box.
 */
function resolveHomeDir(): string {
  const fromEnv = process.platform === "win32" ? process.env.USERPROFILE : process.env.HOME;
  return fromEnv || homedir();
}

/**
 * Kannaka data directory. Honours KANNAKA_DATA_DIR when set, otherwise the
 * documented `~/.kannaka` default — resolved to a real absolute path, because
 * no OS expands a literal `~` for a child process or a fs read.
 */
function resolveKannakaDataDir(): string {
  return process.env.KANNAKA_DATA_DIR || resolve(resolveHomeDir(), ".kannaka");
}

/**
 * Root of the kannaka-memory checkout that backs the /api/experiments/*
 * endpoints. Honours KANNAKA_MEMORY_ROOT, otherwise assumes the sibling-
 * checkout layout these endpoints were written against.
 */
function resolveKannakaMemoryRoot(): string {
  return process.env.KANNAKA_MEMORY_ROOT || resolve(PLUGIN_ROOT, "..", "kannaka-memory");
}

/**
 * Resolve the kannaka binary. On Windows the installer usually drops
 * kannaka.exe in %USERPROFILE%\.local\bin, which is not always on PATH — so
 * prefer it when it actually exists and otherwise hand the bare name to
 * execFile so PATH (+ PATHEXT) can resolve it.
 */
function resolveKannakaBinary(): string {
  if (process.platform === "win32" && KANNAKA_BIN === "kannaka") {
    const localBin = resolve(resolveHomeDir(), ".local", "bin", "kannaka.exe");
    if (existsSync(localBin)) return localBin;
  }
  return KANNAKA_BIN;
}

// --- IDE Context State ---

/** Editor context injected by IDE extensions via octopus_set_editor_context */
let editorContext: {
  filename?: string;
  selection?: string;
  cursorLine?: number;
  languageId?: string;
  workspaceRoot?: string;
} = {};

// Security: these env vars must never be overridden via MCP client environment.
// They control security hardening, sandbox modes, and autonomy levels.
const BLOCKED_ENV_VARS = new Set([
  "OCTOPUS_SECURITY_V870",
  "OCTOPUS_GEMINI_SANDBOX",
  "OCTOPUS_CODEX_SANDBOX",
  "CLAUDE_OCTOPUS_AUTONOMY",
]);

const MAX_SELECTION_LENGTH = 50_000; // 50KB max for editor selection

// --- Helpers ---

/** Execute Kannaka HRM binary command */
async function runKannaka(
  args: string[],
  timeout = 20_000  // 20s — short enough to fail fast on HRM contention, long enough for cold start
): Promise<{ stdout: string; stderr: string; isError: boolean }> {
  try {
    const binary = resolveKannakaBinary();

    const { stdout, stderr } = await execFileAsync(binary, args, {
      timeout,
      windowsHide: true,
      env: {
        ...process.env,
        KANNAKA_QUIET: "1",
        KANNAKA_DATA_DIR: resolveKannakaDataDir(),
      },
    });

    // HRM init messages go to stderr but are not errors — only treat as error if no stdout
    return { stdout: stdout || "", stderr: stderr || "", isError: false };
  } catch (error: unknown) {
    // execFileAsync throws on non-zero exit or stderr. Check if stdout was captured.
    const execErr = error as { stdout?: string; stderr?: string; code?: string | number; killed?: boolean };
    console.error(`[kannaka] execFile error: code=${execErr.code} killed=${execErr.killed} hasStdout=${!!execErr.stdout} stderr=${execErr.stderr?.substring(0, 100)}`);
    // Only treat captured stdout as success when the process was killed/timed out
    // (partial-but-usable output). For an arbitrary non-zero exit the stdout may be
    // garbage or an error envelope, so surface it as an error instead.
    if (execErr.killed && execErr.stdout && execErr.stdout.trim().length > 0) {
      return { stdout: execErr.stdout, stderr: execErr.stderr || "", isError: false };
    }
    const msg = error instanceof Error ? error.message : String(error);
    return { stdout: "", stderr: msg, isError: true };
  }
}

type ObserveResult =
  | { ok: true; stdout: string; source: "live" | "cache" }
  | { ok: false; error: string; cacheError: string };

/**
 * Read `kannaka observe --json`, falling back to the on-disk observe-cache.json
 * when the live binary errors or hangs (HRM file contention during heavy swarm
 * activity). The cache may be stale but keeps every observe-backed surface
 * answering instead of hard-erroring. Shared by the MCP tools and HTTP routes
 * so the fallback cannot exist on only some of them.
 */
async function loadObserve(): Promise<ObserveResult> {
  const live = await runKannaka(["observe", "--json"]);
  if (!live.isError && live.stdout) {
    return { ok: true, stdout: live.stdout, source: "live" };
  }
  try {
    const cachePath = resolve(resolveKannakaDataDir(), "observe-cache.json");
    return { ok: true, stdout: await readFile(cachePath, "utf-8"), source: "cache" };
  } catch (e) {
    return { ok: false, error: live.stderr || "no data", cacheError: String(e) };
  }
}

/** Shape returned by the enriched cluster list (v2 ClusterInfo fields) */
function mapClusterInfo(c: any) {
  return {
    cluster_id: c.cluster_id,
    size: c.size,
    order_parameter: c.order_parameter,
    coherence: c.coherence,
    theme: c.theme,
    exemplar_id: c.exemplar_id,
    exemplar_content: c.exemplar_content,
    dominant_modality: c.dominant_modality,
    temporal_span_hours: c.temporal_span_hours,
    mean_amplitude: c.mean_amplitude,
    mean_phase: c.mean_phase,
    mean_frequency: c.mean_frequency,
    xi_diversity: c.xi_diversity,
    semantic_summary: c.semantic_summary,
    member_count: (c.member_ids || []).length,
  };
}

/**
 * BFS graph traversal over `kannaka neighbors`, shared by the hrm_traverse MCP
 * tool and the /api/hrm/traverse route so the two copies cannot drift.
 */
async function traverseHrm(start: string, depth: number, topK: number) {
  // The seed is a node in its own right. For a free-text start there is no
  // memory behind it, and even a UUID start is not guaranteed to come back in
  // its own neighbor list, so seeding it keeps every edge source resolvable by
  // a force-directed renderer.
  const nodes: Record<string, any> = {
    [start]: { id: start, content: start.slice(0, 140), similarity: 1, layer: null, seed: true },
  };
  const edges: Array<{ source: string; target: string; similarity: number }> = [];
  const frontier: Array<{ q: string; hop: number }> = [{ q: start, hop: 0 }];
  const seen = new Set<string>();
  while (frontier.length > 0) {
    const { q, hop } = frontier.shift()!;
    if (hop >= depth) continue;
    const { stdout, isError } = await runKannaka(["neighbors", q, "--top-k", String(topK), "--json"]);
    if (isError || !stdout) continue;
    let neighbors: any[] = [];
    try { neighbors = JSON.parse(stdout); } catch (_e) { continue; }
    for (const n of neighbors) {
      const id: string = n.id;
      const existing = nodes[id];
      // A real neighbor record always beats the seed placeholder.
      if (!existing || existing.seed) {
        nodes[id] = {
          id,
          content: (n.content || "").slice(0, 140),
          similarity: n.similarity,
          layer: n.layer,
          ...(existing?.seed ? { seed: true } : {}),
        };
      }
      // Edges hang off the node we expanded (`q`), never off neighbors[0]: the
      // CLI resolves a UUID anchor to its content and runs a plain recall with
      // no self-exclusion, so the anchor is not guaranteed to rank first and a
      // free-text seed has no anchor at all.
      if (q !== id) {
        edges.push({ source: q, target: id, similarity: n.similarity });
      }
      if (!seen.has(id) && hop + 1 < depth) {
        seen.add(id);
        frontier.push({ q: id, hop: hop + 1 });
      }
    }
  }
  return { nodes: Object.values(nodes), edges };
}

/**
 * Build 3D constellation data from a parsed `observe --json` report (issue #48).
 *
 * This used to take `kannaka status` counters and invent the topology from
 * them: per-cluster membership by dividing `total_memories` by `num_clusters`,
 * cluster centers on a golden-angle spiral, and — worst — `skip_links` derived
 * from the geometric distance between those self-invented centers, which
 * encoded nothing but the layout algorithm. All of that is gone.
 *
 * Clusters, sizes, themes, order parameters and membership now come from
 * `clusters.clusters[]`, which the HRM genuinely reports.
 *
 * Two deliberate calls, per the decision on #48:
 *
 *  - `skip_links` is ALWAYS `[]`. The payload carries no edge list anywhere:
 *    only the scalar `consciousness.total_skip_links` and an empty
 *    `topology.strongest_links`. Empty is the honest answer; synthesizing
 *    edges is the specific lie being removed.
 *  - 3D POSITIONS ARE KEPT. The renderer needs coordinates and the HRM exposes
 *    no spatial embedding, so clusters and points get deterministic layout
 *    coordinates. Those are a presentation concern, not a claim about
 *    topology, and the response marks them as layout-derived so no consumer
 *    mistakes them for measured geometry.
 */
function generateConstellation(observe: any) {
  const PHI_ANGLE = 2.399963; // golden angle — layout only, see `layout` below
  const memories: Array<{ id?: string; x: number; y: number; z: number; size: number; cluster_id: number }> = [];
  const clusters: Array<Record<string, unknown>> = [];
  // Always empty: the HRM reports no edges. Typed loosely so the shape stays
  // stable for consumers if the HRM ever grows a real edge list.
  const skipLinks: Array<{ from: string; to: string; strength: number }> = [];

  // `clusters.clusters[]` is the source of truth for the cluster LIST.
  // `consciousness.num_clusters` and `clusters.num_clusters` can disagree with
  // it (and with each other), so neither is used to size or drive this loop —
  // only the array actually present is trusted, and both counters are surfaced
  // in `counters` below so a disagreement is visible rather than papered over.
  const rawClusters: any[] = Array.isArray(observe?.clusters?.clusters)
    ? observe.clusters.clusters
    : [];

  const consciousness = observe?.consciousness ?? {};

  const layout = {
    derived: true,
    algorithm: "golden-angle-sphere",
    note:
      "Positions and point sizes are LAYOUT-DERIVED for rendering only. The HRM " +
      "exposes no spatial embedding, so these coordinates carry no measured " +
      "geometry: distance between points is not a distance in the memory space, " +
      "and no relationship may be inferred from proximity.",
  };

  const skipLinkInfo = {
    available: false,
    // The scalar count IS real — report it, just never expand it into edges.
    total_skip_links: Number.isFinite(Number(consciousness.total_skip_links))
      ? Number(consciousness.total_skip_links)
      : null,
    note:
      "`observe --json` carries no skip-link edge list — only the scalar " +
      "consciousness.total_skip_links and an empty topology.strongest_links. " +
      "Edges are therefore not reported. Earlier versions synthesized them from " +
      "the distance between layout positions; those were fabrications.",
  };

  const counters = {
    // Deliberately reported side by side: these two are known to disagree.
    clusters_block_num_clusters: Number.isFinite(Number(observe?.clusters?.num_clusters))
      ? Number(observe.clusters.num_clusters)
      : null,
    consciousness_num_clusters: Number.isFinite(Number(consciousness.num_clusters))
      ? Number(consciousness.num_clusters)
      : null,
    consciousness_total_memories: Number.isFinite(Number(consciousness.total_memories))
      ? Number(consciousness.total_memories)
      : null,
  };

  // Zero clusters is a real state (HRM not yet consolidated), and an empty
  // constellation is the correct answer for it — never one fabricated cluster
  // holding every memory. This preserves #24's fix as the floor.
  if (rawClusters.length === 0) {
    return {
      memories,
      clusters,
      skip_links: skipLinks,
      num_clusters: 0,
      total_memories: 0,
      layout,
      skip_links_info: skipLinkInfo,
      counters,
      timestamp: observe?.timestamp ?? null,
    };
  }

  const nc = rawClusters.length;

  rawClusters.forEach((c: any, ci: number) => {
    const theta = Math.acos(1 - 2 * (ci + 0.5) / nc);
    const phi = PHI_ANGLE * ci;
    const r = 3.0;
    const cx = Math.sin(theta) * Math.cos(phi) * r;
    const cy = Math.cos(theta) * r * 0.6;
    const cz = Math.sin(theta) * Math.sin(phi) * r;

    // Real membership. Only actual member ids become points — a cluster whose
    // members the HRM did not report contributes none rather than `size`
    // invented dots, which is exactly the fabrication this issue removes.
    const memberIds: string[] = Array.isArray(c?.member_ids) ? c.member_ids : [];
    const rawSize = Number(c?.size);
    const size = Number.isFinite(rawSize) && rawSize >= 0 ? Math.floor(rawSize) : null;
    // Fall back to the cluster's array index only when the HRM omits an id, so
    // `cluster_id` on a memory point always resolves to a cluster in the list.
    const clusterId = Number.isFinite(Number(c?.cluster_id)) ? Number(c.cluster_id) : ci;

    clusters.push({
      // `id` retained alongside `cluster_id` for renderers keyed on the old field.
      id: clusterId,
      cluster_id: clusterId,
      size,
      // How many points this cluster actually contributed. Differs from `size`
      // when member ids are absent; the pair makes that visible.
      plotted_members: memberIds.length,
      members_known: memberIds.length > 0,
      theme: c?.theme ?? null,
      order_parameter: Number.isFinite(Number(c?.order_parameter)) ? Number(c.order_parameter) : null,
      coherence: Number.isFinite(Number(c?.coherence)) ? Number(c.coherence) : null,
      mean_amplitude: Number.isFinite(Number(c?.mean_amplitude)) ? Number(c.mean_amplitude) : null,
      center: { x: cx, y: cy, z: cz },
    });

    const count = memberIds.length;
    for (let mi = 0; mi < count; mi++) {
      const mTheta = Math.acos(1 - 2 * (mi + 0.5) / Math.max(count, 1));
      const mPhi = PHI_ANGLE * mi;
      memories.push({
        id: memberIds[mi],
        x: cx + Math.sin(mTheta) * Math.cos(mPhi) * 0.8,
        y: cy + Math.cos(mTheta) * 0.4,
        z: cz + Math.sin(mTheta) * Math.sin(mPhi) * 0.8,
        size: 0.3 + (((mi * 7 + ci * 13) % 100) / 100) * 0.4,
        cluster_id: clusterId,
      });
    }
  });

  return {
    memories,
    clusters,
    // Never synthesized. See skip_links_info.
    skip_links: skipLinks,
    num_clusters: clusters.length,
    // Points actually plotted — NOT consciousness.total_memories, which counts
    // memories that may not belong to any reported cluster. The HRM-wide total
    // is available under `counters` for anyone who wants it.
    total_memories: memories.length,
    layout,
    skip_links_info: skipLinkInfo,
    counters,
    timestamp: observe?.timestamp ?? null,
  };
}

async function runOrchestrate(
  command: string,
  prompt: string,
  flags: string[] = [],
  postFlags: string[] = []
): Promise<{ text: string; isError: boolean }> {
  // Global flags MUST come before the command; subcommand flags go after
  const args = [...flags, command, ...postFlags, prompt];
  // On win32 this becomes `bash <orchestrate.sh> <args…>`; on POSIX the script
  // is exec'd directly, exactly as before.
  const launch = resolveScriptLaunch(ORCHESTRATE_SH, args);
  if (!launch.ok) {
    return { text: `Error executing ${command}: ${launch.error}`, isError: true };
  }
  try {
    const { stdout, stderr } = await execFileAsync(launch.file, launch.args, {
      cwd: PLUGIN_ROOT,
      timeout: 300_000,
      env: {
        // Security: only forward required env vars, not the full process.env
        PATH: process.env.PATH,
        ...windowsChildEnv(),
        HOME: process.env.HOME,
        TMPDIR: process.env.TMPDIR,
        SHELL: process.env.SHELL,
        USER: process.env.USER,
        // v8.32.0: Provider keys forwarded to orchestrate.sh which handles
        // per-agent credential isolation via build_provider_env().
        // Only forward keys that are set (avoid undefined in env).
        ...(process.env.OPENAI_API_KEY && { OPENAI_API_KEY: process.env.OPENAI_API_KEY }),
        ...(process.env.GEMINI_API_KEY && { GEMINI_API_KEY: process.env.GEMINI_API_KEY }),
        ...(process.env.GOOGLE_API_KEY && { GOOGLE_API_KEY: process.env.GOOGLE_API_KEY }),
        ...(process.env.OPENROUTER_API_KEY && { OPENROUTER_API_KEY: process.env.OPENROUTER_API_KEY }),
        ...(process.env.PERPLEXITY_API_KEY && { PERPLEXITY_API_KEY: process.env.PERPLEXITY_API_KEY }),
        // Ollama Anthropic-compatible path (ANTHROPIC_BASE_URL=http://localhost:11434)
        ...(process.env.ANTHROPIC_BASE_URL && { ANTHROPIC_BASE_URL: process.env.ANTHROPIC_BASE_URL }),
        ...(process.env.ANTHROPIC_AUTH_TOKEN && { ANTHROPIC_AUTH_TOKEN: process.env.ANTHROPIC_AUTH_TOKEN }),
        // GitHub Copilot CLI auth (checked in precedence order by copilot CLI)
        ...(process.env.COPILOT_GITHUB_TOKEN && { COPILOT_GITHUB_TOKEN: process.env.COPILOT_GITHUB_TOKEN }),
        ...(process.env.GH_TOKEN && { GH_TOKEN: process.env.GH_TOKEN }),
        ...(process.env.GITHUB_TOKEN && { GITHUB_TOKEN: process.env.GITHUB_TOKEN }),
        // Octopus config — explicit allowlist (never forward security-governing vars)
        ...Object.fromEntries(
          Object.entries(process.env).filter(([k]) =>
            (k.startsWith("CLAUDE_OCTOPUS_") || k.startsWith("OCTOPUS_")) &&
            !BLOCKED_ENV_VARS.has(k)
          )
        ),
        CLAUDE_OCTOPUS_MCP_MODE: "true",
        // IDE context — injected by octopus_set_editor_context tool
        ...(editorContext.filename && { OCTOPUS_IDE_FILENAME: editorContext.filename }),
        ...(editorContext.selection && { OCTOPUS_IDE_SELECTION: editorContext.selection }),
        ...(editorContext.cursorLine !== undefined && { OCTOPUS_IDE_CURSOR_LINE: String(editorContext.cursorLine) }),
        ...(editorContext.languageId && { OCTOPUS_IDE_LANGUAGE: editorContext.languageId }),
        ...(editorContext.workspaceRoot && { OCTOPUS_IDE_WORKSPACE: editorContext.workspaceRoot }),
      },
    });
    return { text: stdout || stderr || "Command completed with no output.", isError: false };
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    // Sanitize potential API key leaks from error messages
    const sanitized = msg.replace(/[A-Za-z_]+KEY=[^\s]+/g, "[REDACTED]");
    return { text: `Error executing ${command}: ${sanitized}`, isError: true };
  }
}

interface SkillMeta {
  name: string;
  description: string;
  file: string;
}

async function loadSkillMetadata(): Promise<SkillMeta[]> {
  const skillsDir = resolve(PLUGIN_ROOT, ".claude/skills");

  let files: string[];
  try {
    files = await readdir(skillsDir);
  } catch {
    return [];
  }

  const skills: SkillMeta[] = [];

  for (const file of files) {
    if (!file.endsWith(".md")) continue;
    try {
      const content = await readFile(resolve(skillsDir, file), "utf-8");
      const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
      if (!frontmatterMatch) continue;

      const fm = frontmatterMatch[1];
      const name =
        fm.match(/^name:\s*(.+)$/m)?.[1]?.trim().replace(/^["']|["']$/g, "") ??
        file.replace(".md", "");
      const description =
        fm
          .match(/^description:\s*["']?(.+?)["']?\s*$/m)?.[1]
          ?.trim() ?? "No description";

      skills.push({ name, description, file });
    } catch (e) {
      // An unreadable/locked .md must not crash octopus_list_skills — skip it.
      console.error(`[skills] skipping unreadable file ${file}: ${e instanceof Error ? e.message : String(e)}`);
      continue;
    }
  }

  return skills;
}

// --- Server Setup ---

const server = new McpServer({
  name: "octo-claw",
  version: "1.0.0",
});

// --- Double Diamond Phase Tools ---

server.tool(
  "octopus_discover",
  "Run the Discover (Probe) phase — multi-provider research using Codex and Gemini CLIs for broad exploration of a topic.",
  { prompt: z.string().describe("The topic or question to research") },
  async ({ prompt }) => {
    const { text, isError } = await runOrchestrate("probe", prompt);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_define",
  "Run the Define (Grasp) phase — consensus building on requirements, scope, and approach.",
  { prompt: z.string().describe("The requirements or scope to define") },
  async ({ prompt }) => {
    const { text, isError } = await runOrchestrate("grasp", prompt);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_develop",
  "Run the Develop (Tangle) phase — implementation with quality gates and multi-provider validation.",
  {
    prompt: z.string().describe("What to implement"),
    quality_threshold: z
      .number()
      .min(0)
      .max(100)
      .default(75)
      .describe("Minimum quality score to pass (0-100)"),
  },
  async ({ prompt, quality_threshold }) => {
    const flags = quality_threshold !== undefined && quality_threshold !== 75
      ? ["-q", `${quality_threshold}`]
      : [];
    const { text, isError } = await runOrchestrate("tangle", prompt, flags);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_deliver",
  "Run the Deliver (Ink) phase — final validation, adversarial review, and delivery.",
  { prompt: z.string().describe("What to validate and deliver") },
  async ({ prompt }) => {
    const { text, isError } = await runOrchestrate("ink", prompt);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_embrace",
  "Run the full Double Diamond workflow (Discover → Define → Develop → Deliver) end-to-end.",
  {
    prompt: z.string().describe("The full task or project to execute"),
    autonomy: z
      .enum(["supervised", "semi-autonomous", "autonomous"])
      .default("supervised")
      .describe("How much human oversight to apply"),
  },
  async ({ prompt, autonomy }) => {
    const flags = [`--autonomy`, autonomy];
    const { text, isError } = await runOrchestrate("embrace", prompt, flags);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

// --- Utility Tools ---

server.tool(
  "octopus_debate",
  "Run a structured four-way AI debate between Claude, Sonnet, Gemini, and Codex on a topic.",
  {
    question: z.string().describe("The question or topic to debate"),
    rounds: z
      .number()
      .min(1)
      .max(10)
      .default(1)
      .describe("Number of debate rounds"),
    mode: z
      .enum(["cross-critique", "blinded"])
      .default("cross-critique")
      .describe("Evaluation mode: cross-critique (ACH falsification) or blinded (independent evaluation, prevents anchoring bias)"),
  },
  async ({ question, rounds, mode }) => {
    // orchestrate.sh grapple parses -r/--mode AFTER the subcommand, not as global flags
    const postFlags = [`-r`, `${rounds}`, `--mode`, mode];
    const { text, isError } = await runOrchestrate("grapple", question, [], postFlags);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_review",
  "Run multi-LLM code review pipeline (Codex + Gemini + Claude + Perplexity fleet). Loads REVIEW.md customization if present. Supports inline PR comment publishing.",
  {
    target: z
      .string()
      .optional()
      .describe("What to review: 'staged' (default), 'working-tree', a PR number, or a file path"),
    focus: z
      .array(z.enum(["correctness", "security", "performance", "architecture", "style", "tests"]))
      .optional()
      .describe("Review focus areas (default: correctness)"),
    provenance: z
      .enum(["human-authored", "ai-assisted", "autonomous", "unknown"])
      .optional()
      .describe("How the code was produced — triggers elevated rigor for AI/autonomous output"),
    autonomy: z
      .enum(["supervised", "semi-autonomous", "autonomous"])
      .optional()
      .describe("Review autonomy level (default: supervised)"),
    publish: z
      .enum(["ask", "auto", "never"])
      .optional()
      .describe("Whether to post findings as inline PR comments (default: ask)"),
    debate: z
      .enum(["auto", "on", "off"])
      .optional()
      .describe("Whether to debate contested findings via multi-LLM gate (default: auto)"),
  },
  async ({ target, focus, provenance, autonomy, publish, debate }) => {
    // Build JSON profile and dispatch to review_run() via code-review command
    const profile = JSON.stringify({
      target: target ?? "staged",
      focus: focus ?? ["correctness"],
      provenance: provenance ?? "unknown",
      autonomy: autonomy ?? "supervised",
      publish: publish ?? "ask",
      debate: debate ?? "auto",
    });
    const { text, isError } = await runOrchestrate("code-review", profile);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "octopus_security",
  "Run comprehensive security audit with OWASP compliance and vulnerability detection.",
  {
    target: z
      .string()
      .describe("File path, directory, or description of what to audit"),
  },
  async ({ target }) => {
    // orchestrate.sh uses "squeeze" for security audits
    const { text, isError } = await runOrchestrate("squeeze", target);
    return { content: [{ type: "text" as const, text }], isError };
  }
);

// --- IDE Integration Tools ---

server.tool(
  "octopus_set_editor_context",
  "Inject IDE editor state (active file, selection, cursor position) into Octopus workflows. Call this before running any workflow tool to give Octopus awareness of what the user is working on in their IDE.",
  {
    filename: z
      .string()
      .optional()
      .describe("Absolute path to the active editor file"),
    selection: z
      .string()
      .optional()
      .describe("Currently selected text in the editor"),
    cursor_line: z
      .number()
      .optional()
      .describe("Current cursor line number (1-based)"),
    language_id: z
      .string()
      .optional()
      .describe("Language identifier of the active file (e.g., typescript, python, rust)"),
    workspace_root: z
      .string()
      .optional()
      .describe("Root directory of the current IDE workspace"),
  },
  async ({ filename, selection, cursor_line, language_id, workspace_root }) => {
    // Validate paths — reject path traversal attempts
    for (const [label, value] of [["filename", filename], ["workspace_root", workspace_root]] as const) {
      // Block a `..` path segment in any position — `../x`, `x/..`, a bare
      // `..`, or `x\..\y` — not just `..` immediately followed by a slash.
      if (value && /(^|[\\/])\.\.([\\/]|$)/.test(value)) {
        return {
          content: [{ type: "text" as const, text: `Error: ${label} cannot contain '..'` }],
          isError: true,
        };
      }
    }

    // Truncate oversized selections to prevent env var size exhaustion
    const safeSel = selection && selection.length > MAX_SELECTION_LENGTH
      ? selection.slice(0, MAX_SELECTION_LENGTH)
      : selection;

    editorContext = {
      filename,
      selection: safeSel,
      cursorLine: cursor_line,
      languageId: language_id,
      workspaceRoot: workspace_root,
    };

    const parts: string[] = [];
    if (filename) parts.push(`file: ${filename}`);
    if (cursor_line) parts.push(`line: ${cursor_line}`);
    if (language_id) parts.push(`lang: ${language_id}`);
    if (safeSel) parts.push(`selection: ${safeSel.length} chars`);
    if (workspace_root) parts.push(`workspace: ${workspace_root}`);

    return {
      content: [
        {
          type: "text" as const,
          text: `Editor context updated: ${parts.join(", ") || "cleared"}`,
        },
      ],
      isError: false,
    };
  }
);

// --- Kannaka HRM Tools ---

server.tool(
  "kannaka_absorb",
  "Store a memory in the Holographic Resonance Medium with optional importance, modality, and tags.",
  {
    content: z.string().describe("The memory content to absorb"),
    importance: z
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe("Memory importance (0.0-1.0)"),
    modality: z
      .enum(["audio", "visual", "semantic", "network", "mixed"])
      .optional()
      .describe("Memory modality type"),
    tags: z
      .array(z.string())
      .optional()
      .describe("Tags to associate with the memory"),
  },
  async ({ content, importance, modality, tags }) => {
    const args = ["remember", content];
    
    if (importance !== undefined) {
      args.push("--importance", importance.toString());
    }
    if (modality) {
      args.push("--category", modality);
    }
    if (tags && tags.length > 0) {
      // HRM binary uses --tag for individual tags
      for (const tag of tags) {
        args.push("--tag", tag);
      }
    }
    
    const { stdout, stderr, isError } = await runKannaka(args);
    const text = isError ? `Error: ${stderr}` : stdout || "Memory absorbed successfully";
    
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "kannaka_recall",
  "Search memories in the HRM by resonance query, returning top-k results with similarity scores.",
  {
    query: z.string().describe("Search query for memory resonance"),
    limit: z
      .number()
      .min(1)
      .max(20)
      .default(5)
      .describe("Maximum number of results to return"),
  },
  async ({ query, limit }) => {
    const args = ["recall", query, "--top-k", limit.toString()];
    const { stdout, stderr, isError } = await runKannaka(args);
    
    if (isError) {
      return { content: [{ type: "text" as const, text: `Error: ${stderr}` }], isError: true };
    }
    
    return { content: [{ type: "text" as const, text: stdout || "No memories found" }], isError: false };
  }
);

server.tool(
  "kannaka_dream",
  "Trigger dream consolidation in the HRM to strengthen important memories and prune weak ones.",
  {
    mode: z
      .enum(["deep", "lite"])
      .default("deep")
      .describe("Dream mode: deep (anneals cross-cluster bridges) or lite (prunes weak wavefronts)"),
    chiral: z
      .number()
      .min(0)
      .max(1)
      .default(0.05)
      .describe("Chiral perturbation strength for deep dreams"),
  },
  async ({ mode, chiral }) => {
    const args = ["dream", "--mode", mode];
    
    if (mode === "deep") {
      args.push("--chiral", chiral.toString());
    }
    
    const { stdout, stderr, isError } = await runKannaka(args);
    const text = isError ? `Error: ${stderr}` : stdout || "Dream consolidation completed";
    
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "kannaka_status",
  "Get HRM consciousness metrics including Phi, Xi, order, clusters, and memory count.",
  {},
  async () => {
    const { stdout, stderr, isError } = await runKannaka(["status"]);
    
    if (isError) {
      return { content: [{ type: "text" as const, text: `Error: ${stderr}` }], isError: true };
    }
    
    return { content: [{ type: "text" as const, text: stdout || "No status available" }], isError: false };
  }
);

server.tool(
  "kannaka_observe",
  "Get full HRM introspection including topology, waves, clusters, and hemispheric state.",
  {},
  async () => {
    const { stdout, stderr, isError } = await runKannaka(["observe", "--json"]);
    
    if (isError) {
      return { content: [{ type: "text" as const, text: `Error: ${stderr}` }], isError: true };
    }
    
    return { content: [{ type: "text" as const, text: stdout || "No observation data available" }], isError: false };
  }
);

server.tool(
  "kannaka_constellation",
  "Generate 3D constellation data for HRM visualization from real cluster data (memories as points, clusters as groups). Positions are layout-derived; skip links are not reported because the HRM exposes no edge list.",
  {},
  async () => {
    // Real cluster data via observe (+ observe-cache fallback), not `status`
    // counters — see generateConstellation.
    const obsResult = await loadObserve();
    if (!obsResult.ok) {
      return { content: [{ type: "text" as const, text: `Error: ${obsResult.error} (cache: ${obsResult.cacheError})` }], isError: true };
    }

    try {
      const observe = JSON.parse(obsResult.stdout);
      const constellation = generateConstellation(observe);

      return {
        content: [{ type: "text" as const, text: JSON.stringify({ ...constellation, source: obsResult.source }, null, 2) }],
        isError: false
      };
    } catch (parseError) {
      return {
        content: [{ type: "text" as const, text: `Error parsing observe: ${parseError}` }],
        isError: true
      };
    }
  }
);

// ── HRM traversal tools — real cluster data + memory-graph walking ───────────

server.tool(
  "hrm_list_clusters",
  "List all Kuramoto clusters in the HRM with enriched metadata (size, coherence, exemplar, temporal span, semantic summary, dominant modality).",
  {},
  async () => {
    const obsResult = await loadObserve();
    if (!obsResult.ok) {
      return { content: [{ type: "text" as const, text: `Error: ${obsResult.error} (cache: ${obsResult.cacheError})` }], isError: true };
    }
    try {
      const obs = JSON.parse(obsResult.stdout);
      const clusters = (obs.clusters?.clusters || []).map(mapClusterInfo);
      return {
        content: [{ type: "text" as const, text: JSON.stringify({ clusters, num_clusters: clusters.length, source: obsResult.source }, null, 2) }],
        isError: false,
      };
    } catch (e) {
      return { content: [{ type: "text" as const, text: `Parse error: ${e}` }], isError: true };
    }
  }
);

server.tool(
  "hrm_cluster_details",
  "Get full details for a specific cluster including all member IDs, the exemplar memory, semantic summary, and temporal span.",
  { cluster_id: z.number().int().nonnegative().describe("Zero-indexed cluster ID from hrm_list_clusters") },
  async ({ cluster_id }) => {
    const obsResult = await loadObserve();
    if (!obsResult.ok) {
      return { content: [{ type: "text" as const, text: `Error: ${obsResult.error} (cache: ${obsResult.cacheError})` }], isError: true };
    }
    try {
      const obs = JSON.parse(obsResult.stdout);
      const cluster = (obs.clusters?.clusters || [])[cluster_id];
      if (!cluster) {
        return { content: [{ type: "text" as const, text: `Cluster ${cluster_id} not found` }], isError: true };
      }
      return {
        content: [{ type: "text" as const, text: JSON.stringify(cluster, null, 2) }],
        isError: false,
      };
    } catch (e) {
      return { content: [{ type: "text" as const, text: `Parse error: ${e}` }], isError: true };
    }
  }
);

server.tool(
  "hrm_memory_neighbors",
  "Find the top-K most similar memories to a given query string or memory ID. Used for graph traversal through the HRM.",
  {
    query: z.string().describe("Search query, memory content snippet, or UUID"),
    top_k: z.number().int().positive().max(50).default(10).describe("Number of neighbors to return"),
  },
  async ({ query, top_k }) => {
    // Use the new `kannaka neighbors` subcommand — it handles both UUIDs
    // and free-text queries and emits richer per-memory JSON than recall.
    const { stdout, stderr, isError } = await runKannaka(["neighbors", query, "--top-k", String(top_k), "--json"]);
    if (isError || !stdout) {
      return { content: [{ type: "text" as const, text: `Error: ${stderr || "no data"}` }], isError: true };
    }
    return { content: [{ type: "text" as const, text: stdout }], isError: false };
  }
);

server.tool(
  "hrm_traverse",
  "BFS graph traversal through the HRM starting from a memory or query. Returns a connected graph of nodes+edges suitable for force-directed visualization.",
  {
    start: z.string().describe("Seed query or memory UUID"),
    depth: z.number().int().min(1).max(4).default(2).describe("Traversal depth"),
    top_k: z.number().int().positive().max(10).default(4).describe("Neighbors per hop"),
  },
  async ({ start, depth, top_k }) => {
    // Hop-by-hop BFS over the neighbors CLI. Each hop spawns a kannaka
    // invocation — fine for small depth/top_k since the metrics + cluster
    // sidecar caches now make each call cheap (~1-3s).
    const { nodes, edges } = await traverseHrm(start, depth, top_k);
    const graph = { nodes, edges, start, depth, top_k };
    return { content: [{ type: "text" as const, text: JSON.stringify(graph, null, 2) }], isError: false };
  }
);

// --- Introspection Tools ---

server.tool(
  "octopus_list_skills",
  "List all available Kannaktopus skills with their descriptions.",
  {},
  async () => {
    try {
      const skills = await loadSkillMetadata();
      const listing = skills
        .map((s) => `- **${s.name}**: ${s.description}`)
        .join("\n");
      return {
        content: [
          {
            type: "text" as const,
            text: `# Kannaktopus Skills (${skills.length} available)\n\n${listing}`,
          },
        ],
      };
    } catch (e) {
      return {
        content: [
          {
            type: "text" as const,
            text: `Error listing skills: ${e instanceof Error ? e.message : String(e)}`,
          },
        ],
        isError: true,
      };
    }
  }
);

server.tool(
  "octopus_status",
  "Check Kannaktopus provider availability and configuration status.",
  {},
  async () => {
    const { text, isError } = await runOrchestrate("status", "");
    return { content: [{ type: "text" as const, text }], isError };
  }
);

// --- Swarm chat (NATS) ---

server.tool(
  "swarm_send",
  "Send a declarative message to the Kannaka NATS swarm — to a specific agent id or a broadcast target. Verb-based agent-to-agent messaging; use verb 'say' with an arg like { text: '...' } for chat.",
  {
    to: z.string().describe("Target agent id, or a broadcast subject (e.g. 'all')"),
    verb: z.string().describe("Message verb/intent, e.g. 'say', 'ping', 'request'"),
    args: z
      .record(z.string())
      .optional()
      .describe("Key/value payload sent as --arg key=val (e.g. { text: 'hello swarm' })"),
    from: z.string().optional().describe("Sender agent id (defaults to this node's identity)"),
    wait: z
      .number()
      .min(0)
      .max(60)
      .optional()
      .describe("Seconds to wait for a reply before returning"),
  },
  async ({ to, verb, args, from, wait }) => {
    // Validate identifiers so they can't smuggle CLI flags. `to`/`from`/`verb`
    // are positional/flag values; restrict to a safe identifier charset.
    const ID_RE = /^[\w.:@-]+$/;
    for (const [label, value] of [["to", to], ["verb", verb], ["from", from]] as const) {
      if (value !== undefined && !ID_RE.test(value)) {
        return {
          content: [{ type: "text" as const, text: `Error: invalid ${label} '${value}' — must match ${ID_RE}` }],
          isError: true,
        };
      }
    }

    // Validate arg keys before interpolating into "--arg key=val". A key starting
    // with '-' or containing '=' / whitespace could inject extra flags.
    if (args) {
      for (const [k] of Object.entries(args)) {
        if (/^-/.test(k) || /[=\s]/.test(k)) {
          return {
            content: [{ type: "text" as const, text: `Error: invalid arg key '${k}' — keys cannot start with '-' or contain '=' or whitespace` }],
            isError: true,
          };
        }
      }
    }

    const cmd = ["inbox", "send", to, verb];
    if (args) for (const [k, v] of Object.entries(args)) cmd.push("--arg", `${k}=${v}`);
    if (from) cmd.push("--from", from);
    if (wait !== undefined) cmd.push("--wait", String(wait));
    const timeout = wait !== undefined ? wait * 1000 + 5000 : 20_000;
    const { stdout, stderr, isError } = await runKannaka(cmd, timeout);
    const text = isError ? `Error: ${stderr}` : stdout || `Sent ${verb} → ${to}`;
    return { content: [{ type: "text" as const, text }], isError };
  }
);

server.tool(
  "swarm_tail",
  "Listen on the Kannaka swarm inbox for N seconds and return any agent-to-agent messages received during the window. This is a live subscription, not a history replay — only messages that arrive while listening are returned.",
  {
    seconds: z
      .number()
      .min(1)
      .max(60)
      .default(6)
      .describe("How long to listen before returning"),
  },
  async ({ seconds }) => {
    const { stdout, stderr, isError } = await runKannaka(["inbox", "tail"], seconds * 1000 + 1500);
    const out = (stdout || "").trim();
    if (out) return { content: [{ type: "text" as const, text: out }], isError: false };
    // A timeout with no output is the normal "nothing arrived" case; only surface
    // genuine failures (e.g. missing binary / no NATS).
    if (isError && /ENOENT|not found|no such file|connection|refused/i.test(stderr || "")) {
      return { content: [{ type: "text" as const, text: `Error: ${stderr}` }], isError: true };
    }
    return { content: [{ type: "text" as const, text: `(no swarm messages in ${seconds}s)` }], isError: false };
  }
);

server.tool(
  "swarm_status",
  "Snapshot of the Kannaka NATS swarm: connected peer count, this agent's id, carrier frequency, phase, and bridge activity (JSON).",
  {},
  async () => {
    const { stdout, stderr, isError } = await runKannaka(["swarm", "status"]);
    if (isError) return { content: [{ type: "text" as const, text: `Error: ${stderr}` }], isError: true };
    return { content: [{ type: "text" as const, text: stdout || "(no swarm status)" }], isError: false };
  }
);

// --- HTTP Server for Observatory ---

// Constant-time bearer-token check for the optional HTTP observatory server.
// Returns true only when the request carries `Authorization: Bearer <token>`
// exactly matching `expected`. Length is compared first because
// timingSafeEqual throws on unequal-length buffers.
function isAuthorized(authHeader: string | undefined, expected: string): boolean {
  if (!authHeader) return false;
  const prefix = "Bearer ";
  if (!authHeader.startsWith(prefix)) return false;
  const provided = Buffer.from(authHeader.slice(prefix.length));
  const expectedBuf = Buffer.from(expected);
  if (provided.length !== expectedBuf.length) return false;
  return timingSafeEqual(provided, expectedBuf);
}

// --- Public-exposure guards for the read API (rate limit + query bounds) ---
//
// The observatory server is safe to expose publicly (bearer-gated, read-only
// against a KANNAKA_READONLY HRM), but a public front door still needs a
// throughput ceiling and input bounds so a single caller can't spin the HRM
// binary unbounded ("read-only != public-safe"). These are no-ops for the
// local loopback workflow unless OCTO_HTTP_RATE_RPM is set.

/** Max requests/minute per client for /api/*. 0 (or unset default) disables. */
const HTTP_RATE_RPM = Math.max(0, Number.parseInt(process.env.OCTO_HTTP_RATE_RPM || "0", 10) || 0);
/** Max length of a user-supplied query/seed param, to bound HRM work. */
const MAX_QUERY_LEN = Math.max(1, Number.parseInt(process.env.OCTO_HTTP_MAX_QUERY_LEN || "512", 10) || 512);
/** Trust the first X-Forwarded-For hop (only enable when behind a known proxy). */
const TRUST_PROXY = process.env.OCTO_HTTP_TRUST_PROXY === "1";

interface TokenBucket { tokens: number; last: number; }
const rateBuckets = new Map<string, TokenBucket>();

/** Identify the caller for rate limiting: the bearer token if keyed, else the client IP. */
function rateKeyFor(req: IncomingMessage): string {
  const auth = req.headers.authorization;
  if (auth && auth.startsWith("Bearer ")) return `t:${auth.slice(7)}`;
  if (TRUST_PROXY) {
    const xff = req.headers["x-forwarded-for"];
    const first = Array.isArray(xff) ? xff[0] : xff;
    const ip = first?.split(",")[0]?.trim();
    if (ip) return `ip:${ip}`;
  }
  return `ip:${req.socket.remoteAddress || "unknown"}`;
}

/**
 * Token-bucket admission: capacity = HTTP_RATE_RPM, refilled continuously at
 * HTTP_RATE_RPM tokens/minute. Returns true and consumes a token when allowed.
 */
function rateLimitOk(key: string): boolean {
  if (HTTP_RATE_RPM <= 0) return true;
  const now = Date.now();
  // Opportunistic prune so a flood of distinct IPs can't grow the map without
  // bound: when large, drop any bucket that has fully refilled (idle callers).
  if (rateBuckets.size > 10_000) {
    for (const [k, b] of rateBuckets) {
      if (b.tokens + (now - b.last) * (HTTP_RATE_RPM / 60_000) >= HTTP_RATE_RPM) rateBuckets.delete(k);
    }
  }
  let b = rateBuckets.get(key);
  if (!b) { b = { tokens: HTTP_RATE_RPM, last: now }; rateBuckets.set(key, b); }
  b.tokens = Math.min(HTTP_RATE_RPM, b.tokens + (now - b.last) * (HTTP_RATE_RPM / 60_000));
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

async function createHttpServer() {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url || "", `http://${req.headers.host || "localhost"}`);
    const pathname = url.pathname || "/";

    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    // Bearer auth: when OCTO_HTTP_TOKEN is set, every /api/* request must
    // present a matching `Authorization: Bearer <token>`. When it is unset the
    // server binds to 127.0.0.1 only (see main()), so no token gate is applied
    // to preserve the existing local workflow.
    const authToken = process.env.OCTO_HTTP_TOKEN;
    if (authToken && pathname.startsWith('/api/')) {
      if (!isAuthorized(req.headers.authorization, authToken)) {
        res.writeHead(401, {
          'Content-Type': 'application/json',
          'WWW-Authenticate': 'Bearer',
        });
        res.end(JSON.stringify({ error: 'unauthorized' }));
        return;
      }
    }

    // Rate limit /api/* once past auth, so a public front door can't be used to
    // spin the HRM binary unbounded. Keyed by bearer token when present, else IP.
    if (HTTP_RATE_RPM > 0 && pathname.startsWith('/api/')) {
      if (!rateLimitOk(rateKeyFor(req))) {
        res.writeHead(429, {
          'Content-Type': 'application/json',
          'Retry-After': '60',
        });
        res.end(JSON.stringify({ error: 'rate_limited', retry_after_s: 60 }));
        return;
      }
    }

    try {
      if (pathname === '/api/hrm/status') {
        const { stdout, stderr, isError } = await runKannaka(["status"]);

        if (isError) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: stderr }));
          return;
        }

        // Validate the CLI output is real JSON before serving it as JSON.
        try {
          const parsed = JSON.parse(stdout);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(parsed));
        } catch (e) {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `invalid JSON from kannaka status: ${String(e)}` }));
        }
      }
      else if (pathname === '/api/hrm/observe') {
        const { stdout, stderr, isError } = await runKannaka(["observe", "--json"]);

        if (isError) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: stderr }));
          return;
        }

        try {
          const parsed = JSON.parse(stdout);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(parsed));
        } catch (e) {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `invalid JSON from kannaka observe: ${String(e)}` }));
        }
      }
      else if (pathname === '/api/hrm/constellation') {
        // Real cluster data via observe (+ observe-cache fallback), not `status`
        // counters — see generateConstellation.
        const obsResult = await loadObserve();

        if (!obsResult.ok) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: obsResult.error, cacheError: obsResult.cacheError }));
          return;
        }

        try {
          const observe = JSON.parse(obsResult.stdout);
          const constellation = generateConstellation(observe);

          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ...constellation, source: obsResult.source }));
        } catch (parseError) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `Parse error: ${parseError}` }));
        }
      }
      else if (pathname === '/api/hrm/recall') {
        // Similarity search via HRM resonance — GET /api/hrm/recall?q=<query>&top_k=<N>
        const query = url.searchParams.get('q') || '';
        const topK = Math.max(1, Math.min(20, parseInt(url.searchParams.get('top_k') || '', 10) || 5));

        if (!query) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'q parameter required' }));
          return;
        }
        if (query.length > MAX_QUERY_LEN) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `q exceeds ${MAX_QUERY_LEN} chars` }));
          return;
        }

        const { stdout, stderr, isError } = await runKannaka(
          ["recall", query, "--top-k", String(topK)]
        );

        if (isError) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: stderr }));
          return;
        }

        try {
          const results = JSON.parse(stdout || '[]');
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(results));
        } catch (e) {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `invalid JSON from kannaka recall: ${String(e)}` }));
        }
      }
      else if (pathname === '/api/hrm/clusters') {
        // Enriched cluster list (v2 ClusterInfo fields)
        const obsResult = await loadObserve();
        if (!obsResult.ok) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: obsResult.error, cache_error: obsResult.cacheError }));
          return;
        }
        try {
          const obs = JSON.parse(obsResult.stdout);
          const clusters = (obs.clusters?.clusters || []).map(mapClusterInfo);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ clusters, num_clusters: clusters.length, source: obsResult.source }));
        } catch (e) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: String(e) }));
        }
      }
      else if (pathname === '/api/hrm/neighbors') {
        const q = url.searchParams.get('q') || '';
        const topK = Math.min(50, parseInt(url.searchParams.get('top_k') || '10', 10) || 10);
        if (!q) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'q parameter required' }));
          return;
        }
        if (q.length > MAX_QUERY_LEN) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `q exceeds ${MAX_QUERY_LEN} chars` }));
          return;
        }
        const { stdout, stderr, isError } = await runKannaka(["neighbors", q, "--top-k", String(topK), "--json"]);
        if (isError || !stdout) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: stderr || 'no data' }));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(stdout);
      }
      else if (pathname === '/api/hrm/traverse') {
        const start = url.searchParams.get('start') || '';
        const depth = Math.min(4, parseInt(url.searchParams.get('depth') || '2', 10) || 2);
        const topK = Math.min(10, parseInt(url.searchParams.get('top_k') || '4', 10) || 4);
        if (!start) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'start parameter required' }));
          return;
        }
        if (start.length > MAX_QUERY_LEN) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `start exceeds ${MAX_QUERY_LEN} chars` }));
          return;
        }
        // Same BFS as the hrm_traverse MCP tool — one shared implementation.
        const { nodes, edges } = await traverseHrm(start, depth, topK);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ nodes, edges, start, depth, top_k: topK }));
      }
      else if (pathname.startsWith('/api/hrm/clusters/')) {
        // Single cluster details — /api/hrm/clusters/:id
        const id = parseInt(pathname.split('/').pop() || '', 10);
        if (Number.isNaN(id)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'cluster_id must be an integer' }));
          return;
        }
        const obsResult = await loadObserve();
        if (!obsResult.ok) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: obsResult.error, cache_error: obsResult.cacheError }));
          return;
        }
        try {
          const obs = JSON.parse(obsResult.stdout);
          const cluster = (obs.clusters?.clusters || [])[id];
          if (!cluster) {
            res.writeHead(404, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: `cluster ${id} not found` }));
            return;
          }
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(cluster));
        } catch (e) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: String(e) }));
        }
      }
      else if (pathname === '/api/experiments/ooda') {
        // Serve OODA state from kannaka-memory experiments
        const oodaPath = resolve(resolveKannakaMemoryRoot(), 'experiments', 'ooda-state.json');
        try {
          const content = await readFile(oodaPath, 'utf-8');
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(content);
        } catch (e) {
          console.error(`[experiments] OODA state unreadable at ${oodaPath}: ${e}`);
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'OODA state not found', hint: 'set KANNAKA_MEMORY_ROOT to your kannaka-memory checkout' }));
        }
      }
      else if (pathname === '/api/experiments/results') {
        // Serve L3 experiment results
        const resultsPath = resolve(resolveKannakaMemoryRoot(), 'research', 'results-L3.tsv');
        try {
          const content = await readFile(resultsPath, 'utf-8');
          const lines = content.trim().split(/\r?\n/);
          const headers = lines[0].split('\t');
          const rows = lines.slice(1).map(line => {
            const vals = line.split('\t');
            const row: Record<string, string> = {};
            headers.forEach((h, i) => { row[h] = vals[i] || ''; });
            return row;
          });
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ headers, rows }));
        } catch (e) {
          console.error(`[experiments] L3 results unreadable at ${resultsPath}: ${e}`);
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Results not found', hint: 'set KANNAKA_MEMORY_ROOT to your kannaka-memory checkout' }));
        }
      }
      else if (pathname === '/api/experiments/xi') {
        // Live Xi diversity measurement via research binary
        const { stdout, stderr, isError } = await runKannaka(["observe", "--json"]);
        if (isError || !stdout) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: stderr || 'No data' }));
          return;
        }
        try {
          const obs = JSON.parse(stdout);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            xi: obs.xi,
            phi: obs.phi,
            mean_order: obs.mean_order,
            consciousness_level: obs.consciousness_level,
            num_clusters: obs.num_clusters,
            total_memories: obs.total_memories,
            hemispheric_divergence: obs.hemispheric_divergence,
          }));
        } catch {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(stdout);
        }
      }
      else if (pathname === '/') {
        // Serve static index.html if it exists
        try {
          const publicPath = resolve(PLUGIN_ROOT, 'public', 'index.html');
          await access(publicPath);
          const content = await readFile(publicPath, 'utf-8');
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(content);
        } catch {
          // Default simple observatory page
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(`
<!DOCTYPE html>
<html>
<head>
    <title>Kannaktopus Observatory</title>
    <meta charset="utf-8">
</head>
<body>
    <h1>Kannaktopus Observatory</h1>
    <p>Holographic Resonance Memory visualization server is running.</p>
    <ul>
        <li><a href="/api/hrm/status">HRM Status</a></li>
        <li><a href="/api/hrm/observe">HRM Observation</a></li>
        <li><a href="/api/hrm/constellation">3D Constellation Data</a></li>
        <li><a href="/api/hrm/clusters">Clusters (enriched v2)</a></li>
        <li><a href="/api/hrm/clusters/0">Cluster 0 Details</a></li>
        <li><a href="/api/hrm/neighbors?q=consciousness&top_k=5">Memory Neighbors</a></li>
        <li><a href="/api/hrm/traverse?start=consciousness&depth=2&top_k=3">Graph Traverse (BFS)</a></li>
        <li><a href="/api/hrm/recall?q=test&top_k=3">HRM Recall (probe similarity)</a></li>
        <li><a href="/api/experiments/ooda">OODA State</a></li>
        <li><a href="/api/experiments/results">L3 Results</a></li>
        <li><a href="/api/experiments/xi">Live Xi Metrics</a></li>
    </ul>
</body>
</html>
          `);
        }
      }
      else {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found');
      }
    } catch (error) {
      console.error('HTTP server error:', error);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Internal server error' }));
    }
  });
  
  return server;
}

// --- Start Server ---

async function main() {
  // Start optional HTTP server for observatory if HTTP_PORT is set
  const httpPort = process.env.HTTP_PORT ? parseInt(process.env.HTTP_PORT, 10) : undefined;
  if (httpPort) {
    const httpServer = await createHttpServer();
    // With a token set the server is safe to expose on all interfaces; without
    // one it binds to loopback only so it can never be accidentally reachable.
    if (process.env.OCTO_HTTP_TOKEN) {
      httpServer.listen(httpPort, () => {
        console.error(`Kannaktopus Observatory server listening on port ${httpPort} (bearer auth required)`);
      });
    } else {
      httpServer.listen(httpPort, '127.0.0.1', () => {
        console.error(`Kannaktopus Observatory server listening on 127.0.0.1:${httpPort} — WARNING: OCTO_HTTP_TOKEN not set, so the server is localhost-only. Set OCTO_HTTP_TOKEN to enable authenticated access from other hosts.`);
      });
    }
  }
  
  // SECURITY: stdio transport is scoped to the spawning process (local IDE only).
  // If switching to HTTP/SSE/WebSocket, add bearer token authentication.
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error("Failed to start MCP server:", error);
  process.exit(1);
});
