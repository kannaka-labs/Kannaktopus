/**
 * Kannaktopus — OpenClaw Extension
 *
 * Registers Kannaktopus workflows as native OpenClaw tools.
 * Delegates execution to orchestrate.sh (via Claude CLI or MCP server)
 * to preserve exact behavioral parity with the Claude Code plugin.
 *
 * Architecture:
 *   OpenClaw Gateway → This extension → orchestrate.sh → Multi-provider execution
 *
 * This module is the entry point declared in openclaw.extensions.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "@sinclair/typebox";
import { loadSkills } from "./skill-loader.js";
const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, "../..");
// Security: these env vars must never be overridden via the OpenClaw client
// environment. They control security hardening, sandbox modes, and autonomy
// levels. Mirrors mcp-server/src/index.ts BLOCKED_ENV_VARS.
const BLOCKED_ENV_VARS = new Set([
    "OCTOPUS_SECURITY_V870",
    "OCTOPUS_GEMINI_SANDBOX",
    "OCTOPUS_CODEX_SANDBOX",
    "CLAUDE_OCTOPUS_AUTONOMY",
]);
// --- Helpers ---
function textResult(text) {
    return { content: [{ type: "text", text }], details: {} };
}
// --- Configuration ---
// Allowed autonomy values for runtime validation
const VALID_AUTONOMY = new Set(["supervised", "semi-autonomous", "autonomous"]);
const FALLBACK_AUTONOMY = "supervised";
// Default workflow set when the host supplies no `enabledWorkflows`.
// MUST stay identical to openclaw.plugin.json →
// configSchema.properties.enabledWorkflows.default; the manifest is the
// declared contract and tests/unit/test-openclaw-compat.sh asserts the two
// lists match so they cannot drift apart again.
const DEFAULT_ENABLED_WORKFLOWS = ["discover", "define", "develop", "deliver", "embrace", "debate", "review"];
// --- Execution ---
async function executeOrchestrate(config, command, prompt, flags = [], postFlags = []) {
    const orchestrateSh = config.orchestrateShPath;
    // Global flags MUST come before the command; subcommand flags go after
    const args = [...flags, command, ...postFlags, prompt];
    try {
        const { stdout, stderr } = await execFileAsync(orchestrateSh, args, {
            cwd: PLUGIN_ROOT,
            timeout: 300_000,
            env: {
                // Security: only forward required env vars, not the full process.env
                PATH: process.env.PATH,
                HOME: process.env.HOME,
                TMPDIR: process.env.TMPDIR,
                SHELL: process.env.SHELL,
                USER: process.env.USER,
                // AI provider keys — only forward keys that are set (avoid injecting
                // `undefined` into the child env), mirroring mcp-server/src/index.ts.
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
                ...Object.fromEntries(Object.entries(process.env).filter(([k]) => (k.startsWith("CLAUDE_OCTOPUS_") || k.startsWith("OCTOPUS_")) &&
                    !BLOCKED_ENV_VARS.has(k))),
                CLAUDE_OCTOPUS_MCP_MODE: "true",
                CLAUDE_OCTOPUS_OPENCLAW: "true",
            },
        });
        return stdout || stderr || "Command completed with no output.";
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        // Sanitize potential API key leaks from error messages
        const sanitized = msg.replace(/[A-Za-z_]+KEY=[^\s]+/g, "[REDACTED]");
        return `Error: ${sanitized}`;
    }
}
const WORKFLOW_DEFS = [
    {
        name: "octopus_discover",
        label: "Octopus Discover",
        description: "Run multi-provider research using Codex and Gemini CLIs for broad exploration.",
        parameters: Type.Object({
            prompt: Type.String({ description: "Topic to research" }),
        }),
        run: async (params, config) => executeOrchestrate(config, "probe", params.prompt),
    },
    {
        name: "octopus_define",
        label: "Octopus Define",
        description: "Build consensus on requirements, scope, and approach using multi-AI synthesis.",
        parameters: Type.Object({
            prompt: Type.String({ description: "Requirements or scope to define" }),
        }),
        run: async (params, config) => executeOrchestrate(config, "grasp", params.prompt),
    },
    {
        name: "octopus_develop",
        label: "Octopus Develop",
        description: "Implement with quality gates and multi-provider validation.",
        parameters: Type.Object({
            prompt: Type.String({ description: "What to implement" }),
            quality_threshold: Type.Optional(Type.Number({ description: "Minimum quality score (0-100)", default: 75 })),
        }),
        run: async (params, config) => {
            const qt = params.quality_threshold;
            const flags = qt !== undefined && qt !== 75 ? ["-q", `${qt}`] : [];
            return executeOrchestrate(config, "tangle", params.prompt, flags);
        },
    },
    {
        name: "octopus_deliver",
        label: "Octopus Deliver",
        description: "Final validation, adversarial review, and delivery of completed work.",
        parameters: Type.Object({
            prompt: Type.String({ description: "What to validate and deliver" }),
        }),
        run: async (params, config) => executeOrchestrate(config, "ink", params.prompt),
    },
    {
        name: "octopus_embrace",
        label: "Octopus Embrace",
        description: "Full Double Diamond workflow: Discover → Define → Develop → Deliver.",
        parameters: Type.Object({
            prompt: Type.String({ description: "Full task or project" }),
            autonomy: Type.Optional(Type.Union([
                Type.Literal("supervised"),
                Type.Literal("semi-autonomous"),
                Type.Literal("autonomous"),
            ], { default: "supervised" })),
        }),
        run: async (params, config) => {
            const autonomy = params.autonomy ?? config.defaultAutonomy;
            if (!VALID_AUTONOMY.has(autonomy)) {
                return `Error: invalid autonomy value '${autonomy}'. Allowed: supervised, semi-autonomous, autonomous`;
            }
            return executeOrchestrate(config, "embrace", params.prompt, [
                `--autonomy`, autonomy,
            ]);
        },
    },
    {
        name: "octopus_debate",
        label: "Octopus Debate",
        description: "Four-way AI debate between Claude, Sonnet, Gemini, and Codex on any topic.",
        parameters: Type.Object({
            question: Type.String({ description: "Question to debate" }),
            rounds: Type.Optional(Type.Number({ default: 1, description: "Debate rounds" })),
            mode: Type.Optional(Type.Union([
                Type.Literal("cross-critique"),
                Type.Literal("blinded"),
            ], { default: "cross-critique", description: "Evaluation mode: cross-critique (ACH falsification) or blinded (independent)" })),
        }),
        // orchestrate.sh grapple parses -r/--mode AFTER the subcommand, not as global flags
        run: async (params, config) => executeOrchestrate(config, "grapple", params.question, [], [
            "-r",
            `${params.rounds ?? 1}`,
            "--mode",
            params.mode ?? "cross-critique",
        ]),
    },
    {
        name: "octopus_review",
        label: "Octopus Review",
        description: "Multi-LLM code review pipeline (Codex + Gemini + Claude + Perplexity fleet). Loads REVIEW.md customization, supports inline PR comment publishing.",
        parameters: Type.Object({
            target: Type.Optional(Type.String({ description: "What to review: 'staged' (default), 'working-tree', PR number, or file path" })),
            focus: Type.Optional(Type.Array(Type.Union([
                Type.Literal("correctness"),
                Type.Literal("security"),
                Type.Literal("performance"),
                Type.Literal("architecture"),
                Type.Literal("style"),
                Type.Literal("tests"),
            ]), { description: "Review focus areas (default: correctness)" })),
            provenance: Type.Optional(Type.Union([
                Type.Literal("human-authored"),
                Type.Literal("ai-assisted"),
                Type.Literal("autonomous"),
                Type.Literal("unknown"),
            ], { description: "Code provenance — triggers elevated rigor for AI/autonomous output" })),
            autonomy: Type.Optional(Type.Union([
                Type.Literal("supervised"),
                Type.Literal("semi-autonomous"),
                Type.Literal("autonomous"),
            ], { description: "Review autonomy level (default: supervised)" })),
            publish: Type.Optional(Type.Union([
                Type.Literal("ask"),
                Type.Literal("auto"),
                Type.Literal("never"),
            ], { description: "Whether to post findings as inline PR comments (default: ask)" })),
            debate: Type.Optional(Type.Union([
                Type.Literal("auto"),
                Type.Literal("on"),
                Type.Literal("off"),
            ], { description: "Whether to debate contested findings via multi-LLM gate (default: auto)" })),
        }),
        run: async (params, config) => {
            const profile = JSON.stringify({
                target: params.target ?? "staged",
                focus: params.focus ?? ["correctness"],
                provenance: params.provenance ?? "unknown",
                autonomy: params.autonomy ?? config.defaultAutonomy,
                publish: params.publish ?? "ask",
                debate: params.debate ?? "auto",
            });
            return executeOrchestrate(config, "code-review", profile);
        },
    },
    {
        name: "octopus_security",
        label: "Octopus Security",
        description: "Comprehensive security audit with OWASP compliance and vulnerability detection.",
        parameters: Type.Object({
            target: Type.String({ description: "File or directory to audit" }),
        }),
        run: async (params, config) => executeOrchestrate(config, "squeeze", params.target),
    },
];
// --- Extension Entry Point ---
export default function register(api) {
    const pluginConfig = api.pluginConfig ?? {};
    // `defaultAutonomy` — validated against the same set the tools enforce, so a
    // bad host config degrades to "supervised" instead of failing every call.
    const configuredAutonomy = pluginConfig.defaultAutonomy;
    let defaultAutonomy = FALLBACK_AUTONOMY;
    if (typeof configuredAutonomy === "string" && configuredAutonomy !== "") {
        if (VALID_AUTONOMY.has(configuredAutonomy)) {
            defaultAutonomy = configuredAutonomy;
        }
        else {
            api.logger.warn(`Ignoring invalid defaultAutonomy '${configuredAutonomy}' — using '${FALLBACK_AUTONOMY}'. Allowed: ${[...VALID_AUTONOMY].join(", ")}`);
        }
    }
    // `orchestrateShPath` — relative paths resolve against the plugin root so the
    // documented default ("auto-detected from plugin installation") still holds.
    const configuredPath = pluginConfig.orchestrateShPath;
    const orchestrateShPath = typeof configuredPath === "string" && configuredPath.trim() !== ""
        ? resolve(PLUGIN_ROOT, configuredPath.trim())
        : resolve(PLUGIN_ROOT, "scripts/orchestrate.sh");
    // `enabledWorkflows` — an empty array is treated as "unset" rather than
    // "enable nothing": `??` alone only catches `undefined`, so a host that
    // materializes the key as `[]` would otherwise register zero workflows.
    const configuredWorkflows = pluginConfig.enabledWorkflows;
    const enabledWorkflows = Array.isArray(configuredWorkflows) && configuredWorkflows.length > 0
        ? configuredWorkflows
        : DEFAULT_ENABLED_WORKFLOWS;
    const config = { orchestrateShPath, defaultAutonomy };
    api.logger.info(`Kannaktopus OpenClaw extension loading...`);
    api.logger.info(`Plugin root: ${PLUGIN_ROOT}`);
    api.logger.info(`orchestrate.sh: ${orchestrateShPath}`);
    api.logger.info(`Default autonomy: ${defaultAutonomy}`);
    // Register workflow tools
    let registered = 0;
    for (const def of WORKFLOW_DEFS) {
        const workflowName = def.name.replace("octopus_", "");
        if (enabledWorkflows.includes(workflowName)) {
            const tool = {
                name: def.name,
                label: def.label,
                description: def.description,
                parameters: def.parameters,
                execute: async (_toolCallId, params) => textResult(await def.run(params, config)),
            };
            api.registerTool(tool);
            api.logger.info(`Registered tool: ${def.name}`);
            registered++;
        }
    }
    // Register introspection tool
    api.registerTool({
        name: "octopus_list_skills",
        label: "Octopus List Skills",
        description: "List all available Kannaktopus skills.",
        parameters: Type.Object({}),
        execute: async () => {
            const skills = await loadSkills(PLUGIN_ROOT);
            const text = skills
                .map((s) => `- ${s.name}: ${s.description}`)
                .join("\n");
            return textResult(text);
        },
    });
    // Register status tool — parity with mcp-server/src/index.ts octopus_status
    api.registerTool({
        name: "octopus_status",
        label: "Octopus Status",
        description: "Check Kannaktopus provider availability and configuration status.",
        parameters: Type.Object({}),
        execute: async () => textResult(await executeOrchestrate(config, "status", "")),
    });
    api.logger.info(`Kannaktopus extension loaded: ${registered} workflows registered.`);
}
//# sourceMappingURL=index.js.map