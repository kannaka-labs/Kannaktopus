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
export declare const KANNAKA_MODALITIES: readonly ["audio", "visual", "semantic", "network", "mixed"];
export type KannakaModality = (typeof KANNAKA_MODALITIES)[number];
export interface RememberInput {
    content: string;
    importance?: number;
    modality?: KannakaModality;
    tags?: string[];
}
/** argv (after the binary) for `kannaka remember`. */
export declare function buildRememberArgs({ content, importance, modality, tags }: RememberInput): string[];
export type XiMetricsResult = {
    status: 200 | 502;
    body: Record<string, unknown>;
};
/**
 * Turn raw `observe --json` text into the /api/experiments/xi response.
 *
 * - Unparseable output, or no finite `xi`/`phi`: 502 with the `missing` list.
 *   A 200 here is what let the old route answer `{}` for every request.
 * - Otherwise 200; any other absent field is an explicit `null` and is named
 *   in `missing`, so a partial answer can never be mistaken for a full one.
 */
export declare function extractXiMetrics(raw: string): XiMetricsResult;
