/**
 * Popup-only, deliberately lossy observability for missing Douyin metadata.
 * This module must never grow strings from the page: its complete vocabulary is
 * fixed below, and the sanitizer rebuilds every accepted field from scratch.
 */
export const DOUYIN_METADATA_ROUTE_REJECT_CODES = [
  "none", "invalid_url", "missing_aweme_id", "non_canonical_route", "query_item_id",
] as const;
export const DOUYIN_METADATA_VIDEO_REJECT_CODES = [
  "none", "video_node_limit", "no_visible_video", "not_uniquely_dominant",
] as const;
export const DOUYIN_METADATA_SCOPE_REJECT_CODES = [
  "none", "dominant_video_proof", "identity_limit", "identity_conflict", "identity_conflict_stopped", "scope_limit", "not_dedicated",
] as const;
export const DOUYIN_METADATA_SSR_REJECT_CODES = [
  "none", "invalid_aweme_id", "no_roots", "no_exact_item", "main_injection_failed",
] as const;
export const DOUYIN_METADATA_SSR_LIMIT_CODES = [
  "none", "root_limit", "script_limit", "total_script_limit", "depth_limit", "node_limit", "child_limit",
] as const;

export type DouyinMetadataRouteRejectCode = typeof DOUYIN_METADATA_ROUTE_REJECT_CODES[number];
export type DouyinMetadataVideoRejectCode = typeof DOUYIN_METADATA_VIDEO_REJECT_CODES[number];
export type DouyinMetadataScopeRejectCode = typeof DOUYIN_METADATA_SCOPE_REJECT_CODES[number];
export type DouyinMetadataSSRRejectCode = typeof DOUYIN_METADATA_SSR_REJECT_CODES[number];
export type DouyinMetadataSSRLimitCode = typeof DOUYIN_METADATA_SSR_LIMIT_CODES[number];

export type DouyinMetadataDOMDiagnostic = {
  route: { eligible: boolean; rejectCode: DouyinMetadataRouteRejectCode };
  video: { positiveVisibleCount: number; dominantVideoCount: number; rejectCode: DouyinMetadataVideoRejectCode };
  scopes: { safeCount: number; dedicatedCount: number; rejectCode: DouyinMetadataScopeRejectCode };
  dom: { publishedSelectorHit: boolean; statSelectorHitMask: number; statAcceptedCount: number };
};

export type DouyinMetadataSSRDiagnostic = {
  fixedRootPresent: number;
  fixedRootParseable: number;
  exactHit: boolean;
  rejectCode: DouyinMetadataSSRRejectCode;
  limitCode: DouyinMetadataSSRLimitCode;
};

export type DouyinMetadataDiagnostic = {
  missingPublished: boolean;
  missingStatsMask: number;
  dom: DouyinMetadataDOMDiagnostic;
  ssr: DouyinMetadataSSRDiagnostic;
};

const includes = <T extends readonly string[]>(values: T, value: unknown): value is T[number] =>
  typeof value === "string" && (values as readonly string[]).includes(value);
const integer = (value: unknown, maximum: number): number | undefined =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= maximum ? value : undefined;

/**
 * Reject unknown keys, values, and shapes. It intentionally does not spread an
 * input object, so accidental DOM text, selectors, raw JSON, URLs, or storage
 * values cannot become popup data.
 */
export function sanitizeDouyinMetadataDiagnostic(value: unknown): DouyinMetadataDiagnostic | undefined {
  if (!value || typeof value !== "object") return undefined;
  const source = value as Record<string, unknown>;
  const domSource = source.dom;
  const ssrSource = source.ssr;
  if (!domSource || typeof domSource !== "object" || !ssrSource || typeof ssrSource !== "object") return undefined;
  const dom = domSource as Record<string, unknown>;
  const route = dom.route as Record<string, unknown> | undefined;
  const video = dom.video as Record<string, unknown> | undefined;
  const scopes = dom.scopes as Record<string, unknown> | undefined;
  const fields = dom.dom as Record<string, unknown> | undefined;
  const ssr = ssrSource as Record<string, unknown>;
  const missingStatsMask = integer(source.missingStatsMask, 15);
  const positiveVisibleCount = integer(video?.positiveVisibleCount, 1000);
  const dominantVideoCount = integer(video?.dominantVideoCount, 1);
  const safeCount = integer(scopes?.safeCount, 6);
  const dedicatedCount = integer(scopes?.dedicatedCount, 6);
  const statSelectorHitMask = integer(fields?.statSelectorHitMask, 15);
  const statAcceptedCount = integer(fields?.statAcceptedCount, 4);
  const fixedRootPresent = integer(ssr.fixedRootPresent, 8);
  const fixedRootParseable = integer(ssr.fixedRootParseable, 8);
  if (typeof source.missingPublished !== "boolean" || missingStatsMask === undefined
      || !route || typeof route.eligible !== "boolean" || !includes(DOUYIN_METADATA_ROUTE_REJECT_CODES, route.rejectCode)
      || positiveVisibleCount === undefined || dominantVideoCount === undefined || !includes(DOUYIN_METADATA_VIDEO_REJECT_CODES, video?.rejectCode)
      || safeCount === undefined || dedicatedCount === undefined || !includes(DOUYIN_METADATA_SCOPE_REJECT_CODES, scopes?.rejectCode)
      || !fields || typeof fields.publishedSelectorHit !== "boolean" || statSelectorHitMask === undefined || statAcceptedCount === undefined
      || fixedRootPresent === undefined || fixedRootParseable === undefined || typeof ssr.exactHit !== "boolean"
      || !includes(DOUYIN_METADATA_SSR_REJECT_CODES, ssr.rejectCode) || !includes(DOUYIN_METADATA_SSR_LIMIT_CODES, ssr.limitCode)) return undefined;
  return {
    missingPublished: source.missingPublished,
    missingStatsMask,
    dom: {
      route: { eligible: route.eligible, rejectCode: route.rejectCode },
      video: { positiveVisibleCount, dominantVideoCount, rejectCode: video.rejectCode },
      scopes: { safeCount, dedicatedCount, rejectCode: scopes.rejectCode },
      dom: { publishedSelectorHit: fields.publishedSelectorHit, statSelectorHitMask, statAcceptedCount },
    },
    ssr: { fixedRootPresent, fixedRootParseable, exactHit: ssr.exactHit, rejectCode: ssr.rejectCode, limitCode: ssr.limitCode },
  };
}
