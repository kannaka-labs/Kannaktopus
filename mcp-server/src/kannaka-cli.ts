/**
 * Pure helpers that translate between the MCP/HTTP surface and the `kannaka`
 * CLI. Kept out of index.ts — which starts the stdio server on import — so the
 * argument building and output parsing can be exercised by tests without a
 * kannaka binary or a live memory store.
 *
 * The flag names here are the ones kannaka-memory's `remember` handler
 * actually parses (src/bin/kannaka.rs): `--importance`, `--category`,
 * `--modality`, `--tags` (ONE comma-separated value). Any other `--flag` makes
 * the CLI print its usage and exit 2 without storing anything, so a wrong flag
 * name here is not a degraded write — it is no write at all.
 */

export const KANNAKA_MODALITIES = ["audio", "visual", "semantic", "network", "mixed"] as const;
export type KannakaModality = (typeof KANNAKA_MODALITIES)[number];

export interface RememberInput {
  content: string;
  importance?: number;
  modality?: KannakaModality;
  tags?: string[];
}

/** argv (after the binary) for `kannaka remember`. */
export function buildRememberArgs({ content, importance, modality, tags }: RememberInput): string[] {
  const args = ["remember", content];
  if (importance !== undefined) {
    args.push("--importance", importance.toString());
  }
  if (modality) {
    // --modality, not --category: --category is a free-form label and would
    // leave the wavefront's modality to content auto-detection.
    args.push("--modality", modality);
  }
  const cleanTags = (tags ?? []).map((t) => t.trim()).filter((t) => t.length > 0);
  if (cleanTags.length > 0) {
    // One comma-joined --tags. A repeated per-tag flag is not a CLI flag at
    // all and makes `remember` exit 2 with nothing stored.
    args.push("--tags", cleanTags.join(","));
  }
  return args;
}

/**
 * Where each /api/experiments/xi field lives in `kannaka observe --json`
 * (kannaka-memory src/observe.rs SystemReport). Every scalar is nested under
 * `consciousness`; none of them exist at the top level.
 *
 * `hemispheric_divergence` is not part of the observe report at all — only
 * `kannaka status` carries it — so it is always reported as missing here
 * rather than silently dropped from the response.
 */
const XI_FIELD_PATHS: Record<string, string[] | null> = {
  xi: ["consciousness", "xi"],
  phi: ["consciousness", "phi"],
  mean_order: ["consciousness", "mean_order"],
  consciousness_level: ["consciousness", "level"],
  num_clusters: ["consciousness", "num_clusters"],
  total_memories: ["consciousness", "total_memories"],
  hemispheric_divergence: null,
};

/** The route exists to report these; without them the response is a 502. */
const XI_REQUIRED_FIELDS = ["xi", "phi"];

export type XiMetricsResult = { status: 200 | 502; body: Record<string, unknown> };

function readPath(obj: unknown, path: string[]): unknown {
  let cur: unknown = obj;
  for (const key of path) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

/**
 * Turn raw `observe --json` text into the /api/experiments/xi response.
 *
 * - Unparseable output, or no finite `xi`/`phi`: 502 with the `missing` list.
 *   A 200 here is what let the old route answer `{}` for every request.
 * - Otherwise 200; any other absent field is an explicit `null` and is named
 *   in `missing`, so a partial answer can never be mistaken for a full one.
 */
export function extractXiMetrics(raw: string): XiMetricsResult {
  let obs: unknown;
  try {
    obs = JSON.parse(raw);
  } catch (e) {
    return {
      status: 502,
      body: { error: `invalid JSON from kannaka observe: ${String(e).slice(0, 200)}` },
    };
  }

  const fields: Record<string, unknown> = {};
  const missing: string[] = [];
  for (const [name, path] of Object.entries(XI_FIELD_PATHS)) {
    const value = path ? readPath(obs, path) : undefined;
    const present =
      name === "consciousness_level"
        ? typeof value === "string" && value.length > 0
        : typeof value === "number" && Number.isFinite(value);
    if (present) {
      fields[name] = value;
    } else {
      fields[name] = null;
      missing.push(name);
    }
  }

  const missingRequired = XI_REQUIRED_FIELDS.filter((f) => missing.includes(f));
  if (missingRequired.length > 0) {
    return {
      status: 502,
      body: {
        error: `kannaka observe output has no ${missingRequired.join("/")} under consciousness`,
        missing,
      },
    };
  }
  return { status: 200, body: { ...fields, missing } };
}
