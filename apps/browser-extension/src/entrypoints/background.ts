import {
  attachDetectedMedia,
  enrichXCaptureWithTitleFallback,
  extractDouyinSingleItemMetaInPage,
  extractPageInIsolatedWorld,
  type ExtractedPage,
} from "../content/extract";
import { detectMediaInPage } from "../content/media-detection";
import {
  buildYouTubeMarkdown,
  extractYouTubeWatchDOMFallbackInPage,
  collectYouTubeTranscriptFromPanelInPage,
  fetchYouTubeTranscriptPayloadInPage,
  restoreYouTubeCaptionTrackInMainWorld,
  setYouTubeCaptionTrackInMainWorld,
  transcriptFromPanelSegments,
  transcriptFromTimedTextXML,
  type YouTubePanelSegment,
  isYouTubeWatchURL,
  pickCaptionTrack,
  readYouTubePlayerSnapshotInMainWorld,
  transcriptFromJSON3,
  youTubeCanonicalURL,
  youTubeVideoID,
} from "../content/youtube";
import {
  detectDouyinAwemeIdFromURL,
  isDouyinHost,
} from "../content/douyin-detect";
import {
  fetchDouyinSessionDetailInMainWorld,
  isAllowedDouyinPlaybackURL,
  type DouyinSessionDiagnostic,
  type DouyinSessionDiagnosticCode,
  type DouyinSessionDetailResult,
  type DouyinSessionDetailSuccess,
} from "../content/douyin-session-detail";
import {
  sanitizeDouyinMetadataDiagnostic,
  type DouyinMetadataDiagnostic,
  type DouyinMetadataDOMDiagnostic,
  type DouyinMetadataSSRDiagnostic,
} from "../content/douyin-metadata-diagnostic";
import {
  makeAppError,
  normalizeNativeResponse,
  validateCapture,
  type CaptureEnvelope,
  type CapturePlatform,
  type MediaDescriptor,
  type NativeResponse,
} from "../contract";
import { mapNativeFailure, withTimeout } from "../native-client";
import { detectCapturePlatform, isDouyinVideoURL } from "../platform";
import {
  collectXBookmarkIDsInPage,
  isValidTweetID,
  isXBookmarksURL,
  MAX_BOOKMARK_IDS,
  parseBookmarksAccepted,
  type BookmarksSyncOutcome,
  type CollectResult,
} from "../content/x-bookmarks";

type DouyinEngagementStats = {
  likes?: string;
  comments?: string;
  shares?: string;
  collects?: string;
};

type DouyinInitialStateMetadata = {
  author?: string;
  publishedAt?: string;
  stats?: DouyinEngagementStats;
  /** 图文帖（aweme_type 68）的图片 CDN 地址，视频帖为空。 */
  imageURLs?: string[];
};

type DouyinInitialStateMetadataAttempt = {
  metadata: DouyinInitialStateMetadata | null;
  diagnostic: DouyinMetadataSSRDiagnostic;
};

export type DouyinCaptureAttempt = {
  page: ExtractedPage;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
};

export function mergeDefinedDouyinStats(
  base: DouyinEngagementStats | undefined,
  override: DouyinEngagementStats | null | undefined,
): DouyinEngagementStats | undefined {
  const result: DouyinEngagementStats = { ...(base ?? {}) };
  if (override?.likes !== undefined) result.likes = override.likes;
  if (override?.comments !== undefined) result.comments = override.comments;
  if (override?.shares !== undefined) result.shares = override.shares;
  if (override?.collects !== undefined) result.collects = override.collects;
  return Object.keys(result).length > 0 ? result : undefined;
}

const HOST_NAME = "com.syc.linkdigest.v01";
const requestId = () => crypto.randomUUID();

export type DouyinMediaHit = MediaDescriptor;
export type SafeCapturePreview = {
  title: string;
  characterCount: number;
  version: 1 | 2;
  platform: CapturePlatform;
  completeness: "full_article" | "visible_only" | "selection_only" | "unknown";
  media?: Pick<
    MediaDescriptor,
    "kind" | "failureReason" | "selectionReason" | "playbackState" | "candidateCount"
  >;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  /** 抖音图文帖的图片张数；非图文帖不带。 */
  imageCount?: number;
};

export type ExtensionSendErrorStage = "extension_validation" | "native_response" | "native_transport";
export type ExtensionSendResult = {
  response: NativeResponse;
  errorStage?: ExtensionSendErrorStage;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
};

const diagnosticCodes = new Set<DouyinSessionDiagnosticCode>([
  "invalid_context", "id_before_after", "main_fetch_timeout", "main_fetch_network",
  "main_injection_failed", "http_403", "http_429", "http_other", "body_too_large",
  "body_unavailable", "json_invalid", "api_status", "detail_missing",
  "aweme_id_missing_or_nonstring", "aweme_id_mismatch", "video_missing", "no_candidates",
  "candidate_limit", "no_allowed_host",
]);

function safeBlockedHostFromURL(rawURL: string): string | undefined {
  try {
    const url = new URL(rawURL);
    if (url.username || url.password) return undefined;
    const host = url.hostname.toLowerCase();
    return host.length > 0 && host.length <= 253 && /^[a-z0-9.-]+$/u.test(host)
      ? host
      : undefined;
  } catch {
    return undefined;
  }
}

export function safeDouyinSessionDiagnostic(value: unknown): DouyinSessionDiagnostic | undefined {
  if (!value || typeof value !== "object") return undefined;
  const candidate = value as Record<string, unknown>;
  if (candidate.ok !== false
      || typeof candidate.code !== "string"
      || !diagnosticCodes.has(candidate.code as DouyinSessionDiagnosticCode)) return undefined;
  const code = candidate.code as DouyinSessionDiagnosticCode;
  if (code !== "no_allowed_host") return { code };
  const blockedHost = typeof candidate.blockedHost === "string"
    && candidate.blockedHost === candidate.blockedHost.toLowerCase()
    && candidate.blockedHost.length <= 253
    && /^[a-z0-9.-]+$/u.test(candidate.blockedHost)
    ? candidate.blockedHost
    : undefined;
  return { code, ...(blockedHost ? { blockedHost } : {}) };
}

function metadataMissingStatsMask(stats: DouyinEngagementStats | undefined): number {
  return (stats?.likes === undefined ? 1 : 0)
    | (stats?.comments === undefined ? 2 : 0)
    | (stats?.shares === undefined ? 4 : 0)
    | (stats?.collects === undefined ? 8 : 0);
}

function makePopupOnlyMetadataDiagnostic(
  dom: DouyinMetadataDOMDiagnostic | undefined,
  ssr: DouyinMetadataSSRDiagnostic,
  publishedAt: string | undefined,
  stats: DouyinEngagementStats | undefined,
): DouyinMetadataDiagnostic | undefined {
  const missingStatsMask = metadataMissingStatsMask(stats);
  if (publishedAt !== undefined && missingStatsMask === 0) return undefined;
  return sanitizeDouyinMetadataDiagnostic({
    missingPublished: publishedAt === undefined,
    missingStatsMask,
    dom,
    ssr,
  });
}

function safeSSRMetadataDiagnostic(value: unknown): DouyinMetadataSSRDiagnostic | undefined {
  const sanitized = sanitizeDouyinMetadataDiagnostic({
    missingPublished: true,
    missingStatsMask: 15,
    dom: {
      route: { eligible: false, rejectCode: "non_canonical_route" },
      video: { positiveVisibleCount: 0, dominantVideoCount: 0, rejectCode: "no_visible_video" },
      scopes: { safeCount: 0, dedicatedCount: 0, rejectCode: "not_dedicated" },
      dom: { publishedSelectorHit: false, statSelectorHitMask: 0, statAcceptedCount: 0 },
    },
    ssr: value,
  });
  return sanitized?.ssr;
}

function safeDiagnosticCopy(value: unknown): DouyinSessionDiagnostic | undefined {
  if (!value || typeof value !== "object") return undefined;
  return safeDouyinSessionDiagnostic({ ...(value as Record<string, unknown>), ok: false });
}

/**
 * Popup preview is deliberately an allowlist. In particular, process-only
 * playback/poster URLs and captured text never cross this message boundary.
 */
export function safePreviewForCapture(
  envelope: CaptureEnvelope,
  mediaDiagnostic?: DouyinSessionDiagnostic,
  metadataDiagnostic?: DouyinMetadataDiagnostic,
  imageCount?: number,
): SafeCapturePreview {
  const preview: SafeCapturePreview = {
    title: envelope.source.title || "当前页面",
    characterCount: envelope.capture.characterCount,
    version: envelope.version,
    platform: envelope.source.platform,
    completeness: envelope.capture.completeness,
    ...(typeof imageCount === "number" && imageCount > 0 ? { imageCount } : {}),
  };
  if (envelope.version === 2) {
    preview.media = {
      kind: envelope.media.kind,
      ...(envelope.media.failureReason ? { failureReason: envelope.media.failureReason } : {}),
      ...(envelope.media.selectionReason ? { selectionReason: envelope.media.selectionReason } : {}),
      ...(envelope.media.playbackState ? { playbackState: envelope.media.playbackState } : {}),
      ...(envelope.media.candidateCount !== undefined ? { candidateCount: envelope.media.candidateCount } : {}),
    };
  }
  const safeDiagnostic = safeDiagnosticCopy(mediaDiagnostic);
  if (safeDiagnostic) preview.mediaDiagnostic = safeDiagnostic;
  const safeMetadataDiagnostic = sanitizeDouyinMetadataDiagnostic(metadataDiagnostic);
  if (safeMetadataDiagnostic) preview.metadataDiagnostic = safeMetadataDiagnostic;
  return preview;
}

/**
 * If `value` is a V2 envelope whose V2 contract cannot be sent successfully
 * (e.g. the desktop V2 validator rejects the media block, or the wire byte
 * stream is treated as V1 only), rebuild it as a V1 envelope. V1 envelopes
 * carry only source/capture/evidence, so any malformed media is silently
 * dropped. Returns `null` for envelopes that are already V1 or that are
 * already valid V2.
 */
function downgradeToV1(value: CaptureEnvelope): CaptureEnvelope {
  if (value.version !== 2) return value;
  return {
    version: 1,
    requestId: value.requestId,
    createdAt: value.createdAt,
    ...(value.idempotencyKey ? { idempotencyKey: value.idempotencyKey } : {}),
    source: value.source,
    capture: value.capture,
    evidence: { sourceLabel: "Current page DOM", usedCookie: false },
  };
}

export function captureEnvelopeForPage(
  page: ExtractedPage,
  tabURL: string,
  tabTitle: string | null,
  now: string,
  captureRequestID: string,
): CaptureEnvelope {
  const sourceURL = page.url || tabURL;
  const common = {
    requestId: captureRequestID,
    createdAt: now,
    source: {
      kind: "browser_capture" as const,
      url: sourceURL,
      title: page.title || tabTitle || null,
      platform: detectCapturePlatform(sourceURL),
    },
    capture: {
      method: page.method,
      text: page.text,
      characterCount: page.characterCount,
      completeness: page.method === "selection" ? "selection_only" as const : "full_article" as const,
      capturedAt: now,
    },
  };
  return page.mediaDescriptor
    ? {
        ...common,
        version: 2,
        evidence: {
          sourceLabel: page.usedCookie
            ? "Current page DOM + same-origin session detail"
            : "Current page DOM",
          usedCookie: page.usedCookie === true,
        },
        media: page.mediaDescriptor,
      }
    : {
        ...common,
        version: 1,
        evidence: { sourceLabel: "Current page DOM", usedCookie: false as const },
      };
}

/**
 * Accept media metadata only when every identity in the atomic page snapshot
 * names the same video as its text/canonical metadata.
 */
export function mediaHitForLockedDouyinItem(
  lockedAwemeId: string,
  mediaHit: DouyinMediaHit | undefined,
): DouyinMediaHit | undefined {
  if (!mediaHit || !lockedAwemeId) return undefined;
  const returnedIds = [
    detectDouyinAwemeIdFromURL(mediaHit.pageURL)?.awemeId,
    detectDouyinAwemeIdFromURL(mediaHit.canonicalURL)?.awemeId,
  ].filter((value): value is string => Boolean(value));
  if (returnedIds.length === 0) return undefined;
  return returnedIds.every((value) => value === lockedAwemeId)
    ? mediaHit
    : undefined;
}

export function upgradedDouyinSessionDescriptor(
  lockedDescriptor: DouyinMediaHit | undefined,
  result: DouyinSessionDetailSuccess | undefined,
): DouyinMediaHit | undefined {
  if (lockedDescriptor?.kind !== "browserSessionOnly"
      || lockedDescriptor.failureReason !== "blob_or_mse"
      || result?.ok !== true
      || !Number.isInteger(result.candidateCount)
      || result.candidateCount < 1
      || result.candidateCount > 256
      || !isAllowedDouyinPlaybackURL(result.playbackURL)) {
    return undefined;
  }
  const persistentDescriptor = { ...lockedDescriptor };
  delete persistentDescriptor.failureReason;
  return {
    ...persistentDescriptor,
    kind: "directFile",
    ephemeralPlaybackURL: result.playbackURL,
    mimeType: "video/mp4",
    transcriptionCapability: "supported",
    candidateCount: result.candidateCount,
  };
}

async function tryDouyinSessionDetail(
  tabId: number,
  lockedAwemeId: string,
  lockedDescriptor: DouyinMediaHit | undefined,
): Promise<{ media?: DouyinMediaHit; diagnostic?: DouyinSessionDiagnostic }> {
  if (lockedDescriptor?.kind !== "browserSessionOnly"
      || lockedDescriptor.failureReason !== "blob_or_mse") return {};
  try {
    const results = await browser.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      world: "MAIN",
      func: fetchDouyinSessionDetailInMainWorld,
      args: [lockedAwemeId],
    });
    const result = results[0]?.result as DouyinSessionDetailResult | undefined;
    const diagnostic = safeDouyinSessionDiagnostic(result);
    if (diagnostic) return { diagnostic };
    if (result?.ok !== true) return { diagnostic: { code: "body_unavailable" } };
    const media = upgradedDouyinSessionDescriptor(lockedDescriptor, result);
    if (media) return { media };
    const blockedHost = safeBlockedHostFromURL(result.playbackURL);
    return {
      diagnostic: {
        code: "no_allowed_host",
        ...(blockedHost ? { blockedHost } : {}),
      },
    };
  } catch {
    return { diagnostic: { code: "main_injection_failed" } };
  }
}

/**
 * MAIN-world extraction of Douyin playback URL from page-embedded state.
 * Douyin SSR hydrates `window.__INITIAL_STATE__` with the full aweme detail
 * (including play_addr.url_list) before the blob/MSE player takes over.
 * This is more reliable than the detail API because the data is already
 * in the page — no extra network request, no anti-bot signature needed.
 *
 * Must be fully self-contained: Chrome serializes only the function body.
 */
export function extractDouyinPlaybackFromInitialStateInMainWorld(
  lockedAwemeId: string,
): { ok: true; playbackURL: string; candidateCount: number } | { ok: false } {
  const validID = (value: unknown): value is string =>
    typeof value === "string" && /^\d{8,25}$/u.test(value);
  if (!validID(lockedAwemeId)) return { ok: false };

  type PlayAddr = { url_list?: unknown };
  type BitRate = { bit_rate?: number; play_addr?: PlayAddr };
  type Video = { play_addr?: PlayAddr; bit_rate?: BitRate[] };
  type Aweme = { aweme_id?: string; video?: Video };

  const isAllowedHost = (rawURL: string): boolean => {
    try {
      const url = new URL(rawURL);
      if (url.protocol !== "https:") return false;
      if (url.port && url.port !== "443") return false;
      const host = url.hostname.toLowerCase();
      if (host === "douyinvod.com" || host.endsWith(".douyinvod.com")) return true;
      if (host === "douyincdn.com" || host.endsWith(".douyincdn.com")) return true;
      return (host === "douyin.com" || host === "www.douyin.com")
        && /^\/aweme\/v1\/(?:web\/)?play\/$/u.test(url.pathname);
    } catch {
      return false;
    }
  };

  const extractURLs = (aweme: Record<string, unknown>): string[] => {
    const video = aweme.video as Video | undefined;
    if (!video || typeof video !== "object") return [];
    const ranked: Array<{ bitrate: number; order: number; urls: string[] }> = [];
    let order = 0;
    if (Array.isArray(video.bit_rate)) {
      for (const entry of video.bit_rate) {
        if (!entry || typeof entry !== "object") continue;
        const item = entry as BitRate;
        const urls = item.play_addr?.url_list;
        if (!Array.isArray(urls)) continue;
        ranked.push({
          bitrate: typeof item.bit_rate === "number" && Number.isFinite(item.bit_rate) ? item.bit_rate : 0,
          order: order++,
          urls: urls.filter((value): value is string => typeof value === "string"),
        });
      }
    }
    const fallbackURLs = video.play_addr?.url_list;
    if (Array.isArray(fallbackURLs)) {
      ranked.push({
        bitrate: -1,
        order,
        urls: fallbackURLs.filter((value): value is string => typeof value === "string"),
      });
    }
    ranked.sort((left, right) => right.bitrate - left.bitrate || left.order - right.order);
    return ranked.flatMap((entry) => entry.urls);
  };

  // Try window.__INITIAL_STATE__ (Douyin SSR hydration data)
  const state = (globalThis as Record<string, unknown>).__INITIAL_STATE__;
  if (!state || typeof state !== "object") return { ok: false };
  const root = state as Record<string, unknown>;

  // Navigate common shapes: itemList[].aweme, awemeDetail, videoDetailPage
  const candidates: Aweme[] = [];

  // Shape 1: root.itemList
  if (Array.isArray(root.itemList)) {
    for (const item of root.itemList) {
      if (item && typeof item === "object") {
        const aweme = (item as Record<string, unknown>).aweme;
        if (aweme && typeof aweme === "object") candidates.push(aweme as Aweme);
      }
    }
  }

  // Shape 2: root.awemeDetail or root.videoDetailPage.video
  if (root.awemeDetail && typeof root.awemeDetail === "object") {
    candidates.push(root.awemeDetail as Aweme);
  }
  if (root.videoDetailPage && typeof root.videoDetailPage === "object") {
    const inner = (root.videoDetailPage as Record<string, unknown>).video;
    if (inner && typeof inner === "object") candidates.push(inner as Aweme);
  }

  // Shape 3: root.video.detail
  if (root.video && typeof root.video === "object") {
    const detail = (root.video as Record<string, unknown>).detail;
    if (detail && typeof detail === "object") candidates.push(detail as Aweme);
  }

  for (const candidate of candidates) {
    if (!candidate || typeof candidate !== "object") continue;
    if (candidate.aweme_id !== lockedAwemeId) continue;
    const rawURLs = extractURLs(candidate as Record<string, unknown>);
    const allowed = [...new Set(rawURLs)].filter(isAllowedHost);
    if (allowed.length > 0) {
      return { ok: true, playbackURL: allowed[0]!, candidateCount: allowed.length };
    }
  }

  return { ok: false };
}

/**
 * MAIN-world extraction of Douyin video statistics from __INITIAL_STATE__.
 * Runs independently of playback URL extraction — stats should always be
 * captured even if the video player URL can't be resolved.
 */
export function extractDouyinStatsFromInitialStateInMainWorld(
  lockedAwemeId: string,
): DouyinEngagementStats | null {
  return extractDouyinMetadataFromInitialStateInMainWorld(lockedAwemeId)?.stats ?? null;
}

/**
 * Reads only the exact locked aweme from a small allowlist of page-hydrated
 * roots. This is intentionally not an inline-script scan: we read three named
 * globals and five exact script IDs, then share one bounded walk across them.
 */
export function extractDouyinMetadataWithDiagnosticInMainWorld(
  lockedAwemeId: string,
): DouyinInitialStateMetadataAttempt {
  const validID = (value: unknown): value is string =>
    typeof value === "string" && /^\d{8,25}$/u.test(value);
  const diagnostic: DouyinMetadataSSRDiagnostic = {
    fixedRootPresent: 0, fixedRootParseable: 0, exactHit: false,
    rejectCode: "none", limitCode: "none",
  };
  if (!validID(lockedAwemeId)) {
    diagnostic.rejectCode = "invalid_aweme_id";
    return { metadata: null, diagnostic };
  }

  // Douyin ships two hydrated shapes for the same aweme: the API-flavoured
  // snake_case object (`statistics.digg_count`, `author.nickname`) and the
  // client store's camelCase normalization (`stats.diggCount`,
  // `authorInfo.nickname`). Reading only the first is what produced an exact
  // ID hit with empty engagement fields.
  type Statistics = Record<string, unknown>;

  const maxRootCount = 8;
  const maxScriptBytes = 2 * 1024 * 1024;
  const maxTotalScriptBytes = 4 * 1024 * 1024;
  const roots: object[] = [];
  const addRoot = (value: unknown, parseable: boolean) => {
    if (value === null || typeof value !== "object") return;
    diagnostic.fixedRootPresent = Math.min(maxRootCount, diagnostic.fixedRootPresent + 1);
    if (parseable) diagnostic.fixedRootParseable = Math.min(maxRootCount, diagnostic.fixedRootParseable + 1);
    if (roots.length < maxRootCount) roots.push(value);
    else if (diagnostic.limitCode === "none") diagnostic.limitCode = "root_limit";
  };
  const globals = globalThis as Record<string, unknown>;
  for (const name of ["__INITIAL_STATE__", "_ROUTER_DATA", "_SSR_HYDRATED_DATA"]) addRoot(globals[name], true);

  let scriptBytes = 0;
  const pageDocument = typeof document === "undefined" ? undefined : document;
  const utf8Bytes = (value: string) => new TextEncoder().encode(value).byteLength;
  const parseScript = (id: string, decodeAtMostTwice: boolean) => {
    const script = pageDocument?.getElementById(id);
    if (script?.tagName !== "SCRIPT") return;
    diagnostic.fixedRootPresent = Math.min(maxRootCount, diagnostic.fixedRootPresent + 1);
    const raw = script?.textContent ?? "";
    if (!raw || utf8Bytes(raw) > maxScriptBytes) {
      if (diagnostic.limitCode === "none") diagnostic.limitCode = "script_limit";
      return;
    }
    const values = [raw];
    if (decodeAtMostTwice) {
      try { values.push(decodeURIComponent(raw)); } catch { /* malformed encoding is one bad root */ }
      if (values.length > 1) {
        try { values.push(decodeURIComponent(values[1]!)); } catch { /* one decode is still usable */ }
      }
    }
    for (const value of values) {
      const bytes = utf8Bytes(value);
      if (bytes > maxScriptBytes) {
        if (diagnostic.limitCode === "none") diagnostic.limitCode = "script_limit";
        return;
      }
      if (scriptBytes + bytes > maxTotalScriptBytes) {
        if (diagnostic.limitCode === "none") diagnostic.limitCode = "total_script_limit";
        return;
      }
      scriptBytes += bytes;
      try {
        const parsed: unknown = JSON.parse(value);
        diagnostic.fixedRootParseable = Math.min(maxRootCount, diagnostic.fixedRootParseable + 1);
        if (parsed !== null && typeof parsed === "object") {
          if (roots.length < maxRootCount) roots.push(parsed);
          else if (diagnostic.limitCode === "none") diagnostic.limitCode = "root_limit";
        }
        return;
      } catch {
        // Try the next allowed decoding only; never inspect unrelated scripts.
      }
    }
  };
  parseScript("RENDER_DATA", true);
  parseScript("__NEXT_DATA__", false);
  // Some deployments expose the named global as an exact-ID JSON script rather
  // than as window data. Supporting those IDs does not widen the source set.
  parseScript("__INITIAL_STATE__", false);
  parseScript("_ROUTER_DATA", false);
  parseScript("_SSR_HYDRATED_DATA", false);
  if (roots.length === 0) {
    diagnostic.rejectCode = "no_roots";
    return { metadata: null, diagnostic };
  }

  const seen = new WeakSet<object>();
  const queue: Array<{ value: object; depth: number }> = roots.map((value) => ({ value, depth: 0 }));
  // Keep the walk bounded, but make the bound fit Douyin's current hydrated
  // state. The separate child budget protects against a primitive-property
  // flood even when very few values are enqueued.
  const maxDepth = 16;
  const maxNodes = 20_000;
  const maxExaminedChildren = 20_000;
  let head = 0;
  let enqueued = queue.length;
  let dequeued = 0;
  let visited = 0;
  let examinedChildren = 0;
  const result: DouyinInitialStateMetadata = {};
  while (head < queue.length && dequeued < maxNodes && visited < maxNodes) {
    const entry = queue[head++]!;
    dequeued += 1;
    if (seen.has(entry.value)) continue;
    seen.add(entry.value); visited += 1;
    const candidate = entry.value as Record<string, unknown>;
    const ownIdentityKeys = ["aweme_id", "awemeId"].filter((key) =>
      Object.prototype.hasOwnProperty.call(candidate, key),
    );
    const candidateMatches = ownIdentityKeys.length > 0
      && ownIdentityKeys.every((key) => typeof candidate[key] === "string" && candidate[key] === lockedAwemeId);
    if (candidateMatches) {
      diagnostic.exactHit = true;
      const fmt = (value: unknown): string | undefined => {
        if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return String(value);
        if (typeof value === "string" && /^\d{1,20}$/u.test(value)) return value;
        return undefined;
      };
      const firstDefined = (source: Record<string, unknown> | undefined, keys: string[]): unknown => {
        if (!source) return undefined;
        for (const key of keys) {
          if (Object.prototype.hasOwnProperty.call(source, key) && source[key] !== undefined) return source[key];
        }
        return undefined;
      };
      const objectAt = (keys: string[]): Record<string, unknown> | undefined => {
        const value = firstDefined(candidate, keys);
        return value && typeof value === "object" ? value as Record<string, unknown> : undefined;
      };
      const stats = objectAt(["statistics", "stats"]) as Statistics | undefined;
      const nickname = firstDefined(
        objectAt(["author", "authorInfo", "authorUserInfo"]),
        ["nickname", "nickName"],
      );
      if (result.author === undefined && typeof nickname === "string" && nickname.trim()) result.author = nickname.trim();
      const createTime = firstDefined(candidate, ["create_time", "createTime"]);
      const unixSeconds = typeof createTime === "number"
        ? createTime
        : typeof createTime === "string" && /^\d{1,20}$/u.test(createTime) ? Number(createTime) : NaN;
      if (Number.isSafeInteger(unixSeconds) && unixSeconds >= 0 && unixSeconds <= 253_402_300_799) {
        if (result.publishedAt === undefined) result.publishedAt = new Date(unixSeconds * 1_000).toISOString();
      }
      if (stats && typeof stats === "object") {
        const parsed: DouyinEngagementStats = { ...(result.stats ?? {}) };
        const likes = fmt(firstDefined(stats, ["digg_count", "diggCount"]));
        const comments = fmt(firstDefined(stats, ["comment_count", "commentCount"]));
        const shares = fmt(firstDefined(stats, ["share_count", "shareCount"]));
        const collects = fmt(firstDefined(stats, ["collect_count", "collectCount"]));
        if (parsed.likes === undefined && likes !== undefined) parsed.likes = likes;
        if (parsed.comments === undefined && comments !== undefined) parsed.comments = comments;
        if (parsed.shares === undefined && shares !== undefined) parsed.shares = shares;
        if (parsed.collects === undefined && collects !== undefined) parsed.collects = collects;
        if (Object.keys(parsed).length > 0) result.stats = parsed;
      }
      // 图文帖（aweme_type 68）的图片：抖音有两种水合形态——顶层 `images`
      // 或 `image_post_info.images` / `imagePostInfo.images`；每张图的地址是
      // `url_list` / `urlList`（带签名的 douyinpic CDN）。仅在首次命中时读取。
      if (result.imageURLs === undefined) {
        const postInfo = objectAt(["image_post_info", "imagePostInfo"]);
        const rawImages = firstDefined(candidate, ["images"]) ?? firstDefined(postInfo, ["images"]);
        if (Array.isArray(rawImages)) {
          const urls: string[] = [];
          for (const image of rawImages.slice(0, 30)) {
            if (!image || typeof image !== "object") continue;
            const list = firstDefined(image as Record<string, unknown>, ["url_list", "urlList"]);
            const first = Array.isArray(list)
              ? list.find((u): u is string => typeof u === "string" && /^https:\/\/[\w.-]*douyinpic\.com\//u.test(u))
              : undefined;
            if (first) urls.push(first);
          }
          if (urls.length > 0) result.imageURLs = urls;
        }
      }
      // A complete exact item is the only useful result from this traversal.
      // Stop before walking unrelated state so the larger safety budget does
      // not add work on the common successful path. Images are read in this same
      // hit above, so they need not gate the break (video posts never have them).
      if (result.author !== undefined && result.stats !== undefined && result.publishedAt !== undefined) break;
    }
    if (entry.depth >= maxDepth) {
      if (diagnostic.limitCode === "none") diagnostic.limitCode = "depth_limit";
      continue;
    }
    if (examinedChildren >= maxExaminedChildren) {
      if (diagnostic.limitCode === "none") diagnostic.limitCode = "child_limit";
      continue;
    }
    if (enqueued >= maxNodes) {
      if (diagnostic.limitCode === "none") diagnostic.limitCode = "node_limit";
      continue;
    }
    // `for…in` avoids materializing a giant primitive array. The separate
    // child-examination limit keeps the walk bounded even when no child is an
    // object and therefore nothing is enqueued.
    for (const key in candidate) {
      if (!Object.prototype.hasOwnProperty.call(candidate, key)) continue;
      if (examinedChildren >= maxExaminedChildren) {
        if (diagnostic.limitCode === "none") diagnostic.limitCode = "child_limit";
        break;
      }
      if (enqueued >= maxNodes) {
        if (diagnostic.limitCode === "none") diagnostic.limitCode = "node_limit";
        break;
      }
      examinedChildren += 1;
      const child = candidate[key];
      if (child && typeof child === "object") {
        queue.push({ value: child, depth: entry.depth + 1 });
        enqueued += 1;
      }
    }
  }
  if (!diagnostic.exactHit) diagnostic.rejectCode = "no_exact_item";
  return { metadata: Object.keys(result).length > 0 ? result : null, diagnostic };
}

/** Compatibility projection for existing callers that need metadata only. */
export function extractDouyinMetadataFromInitialStateInMainWorld(
  lockedAwemeId: string,
): DouyinInitialStateMetadata | null {
  return extractDouyinMetadataWithDiagnosticInMainWorld(lockedAwemeId).metadata;
}
async function tryDouyinInitialState(
  tabId: number,
  lockedAwemeId: string,
  lockedDescriptor: DouyinMediaHit | undefined,
): Promise<{ media?: DouyinMediaHit }> {
  if (lockedDescriptor?.kind !== "browserSessionOnly"
      || lockedDescriptor.failureReason !== "blob_or_mse") return {};
  try {
    const results = await browser.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      world: "MAIN",
      func: extractDouyinPlaybackFromInitialStateInMainWorld,
      args: [lockedAwemeId],
    });
    const result = results[0]?.result as { ok: true; playbackURL: string; candidateCount: number } | { ok: false } | undefined;
    if (!result?.ok) return {};
    if (!isAllowedDouyinPlaybackURL(result.playbackURL)) return {};
    const persistentDescriptor = { ...lockedDescriptor };
    delete persistentDescriptor.failureReason;
    return {
      media: {
        ...persistentDescriptor,
        kind: "directFile",
        ephemeralPlaybackURL: result.playbackURL,
        mimeType: "video/mp4",
        transcriptionCapability: "supported",
        candidateCount: result.candidateCount,
      },
    };
  } catch {
    return {};
  }
}

/**
 * Douyin must never use the generic full-page DOM scrape. Background rebuilds
 * one locked item and reads only its current DOM video/source capability.
 */
export async function captureDouyinSingleItemAttempt(tabId: number, tabURL: string): Promise<DouyinCaptureAttempt> {
  const metaResults = await browser.scripting.executeScript({
    target: { tabId },
    func: extractDouyinSingleItemMetaInPage,
  });
  const meta = metaResults[0]?.result as ReturnType<typeof extractDouyinSingleItemMetaInPage>;

  const fromTab = detectDouyinAwemeIdFromURL(tabURL);
  const awemeId = meta?.awemeId || fromTab?.awemeId || "";
  if (!awemeId) {
    const text =
      "未识别到单条抖音视频。请打开具体视频页，或在精选里点开弹层后再发送。";
    return { page: {
      title: "抖音",
      url: tabURL,
      text,
      characterCount: [...text].length,
      method: "rendered_dom",
    } };
  }

  const canonicalURL = `https://www.douyin.com/video/${awemeId}`;
  const title = meta?.title || "抖音视频";
  let author = meta?.author || null;
  let publishedAt = meta?.publishedAt;
  const description = meta?.description || "";

  let mediaHit = mediaHitForLockedDouyinItem(
    awemeId,
    meta?.mediaDescriptor,
  );

  // Strategy: try __INITIAL_STATE__ first (no network needed), then API fallback.
  // usedCookie is true only when the session-detail API (which sends same-origin
  // credentials) is the source of the playback URL. __INITIAL_STATE__ is SSR data
  // already in the page, so it does not count as cookie use.
  let diagnostic: DouyinSessionDiagnostic | undefined;
  let usedSessionDetail = false;
  const stateResult = await tryDouyinInitialState(tabId, awemeId, mediaHit);
  if (stateResult.media) {
    mediaHit = stateResult.media;
  } else {
    const sessionDetail = await tryDouyinSessionDetail(tabId, awemeId, mediaHit);
    if (sessionDetail.media) {
      mediaHit = sessionDetail.media;
      usedSessionDetail = true;
    }
    if (sessionDetail.diagnostic) diagnostic = sessionDetail.diagnostic;
  }

  const usedCookie = usedSessionDetail;

  if (mediaHit?.author) author = mediaHit.author;

  // Extract exact-item metadata from __INITIAL_STATE__ independently of media
  // state. Its defined fields override DOM; missing fields retain DOM values.
  let stats: DouyinEngagementStats | undefined =
    meta?.stats;
  let ssrDiagnostic: DouyinMetadataSSRDiagnostic = {
    fixedRootPresent: 0, fixedRootParseable: 0, exactHit: false,
    rejectCode: "main_injection_failed", limitCode: "none",
  };
  // DOM 优先：实测 SSR 精确命中在弹层页和详情页都失败，页面渲染出来的 <img>
  // 才是图集唯一可靠的来源。SSR 若命中则作为补充。
  const allowedImageURL = (value: unknown): value is string =>
    typeof value === "string" && /^https:\/\/[\w.-]*douyinpic\.com\//u.test(value);
  let imageURLs: string[] = (meta?.imageURLs ?? []).filter(allowedImageURL).slice(0, 30);
  try {
    const statsResults = await browser.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      world: "MAIN",
      func: extractDouyinMetadataWithDiagnosticInMainWorld,
      args: [awemeId],
    });
    const ssrAttempt = statsResults[0]?.result as DouyinInitialStateMetadataAttempt | undefined;
    const safeSSRDiagnostic = safeSSRMetadataDiagnostic(ssrAttempt?.diagnostic);
    if (safeSSRDiagnostic) ssrDiagnostic = safeSSRDiagnostic;
    const ssr = ssrAttempt?.metadata;
    if (ssr?.author !== undefined) author = ssr.author;
    if (ssr?.publishedAt !== undefined) publishedAt = ssr.publishedAt;
    stats = mergeDefinedDouyinStats(stats, ssr?.stats);
    // 只保留 https 的 douyinpic 图片；App 侧下载已带 douyin Referer。
    if (imageURLs.length === 0 && Array.isArray(ssr?.imageURLs)) {
      imageURLs = ssr.imageURLs.filter(allowedImageURL).slice(0, 30);
    }
  } catch {
    // MAIN world injection may fail on restricted pages — DOM stats are enough.
  }

  const lines = ["---"];
  if (author) lines.push(`author: ${JSON.stringify(author)}`);
  if (publishedAt) lines.push(`published: ${JSON.stringify(publishedAt)}`);
  lines.push(`aweme_id: ${JSON.stringify(awemeId)}`);
  if (stats?.likes !== undefined) lines.push(`likes: ${JSON.stringify(stats.likes)}`);
  if (stats?.comments !== undefined) lines.push(`comments: ${JSON.stringify(stats.comments)}`);
  if (stats?.shares !== undefined) lines.push(`shares: ${JSON.stringify(stats.shares)}`);
  if (stats?.collects !== undefined) lines.push(`collects: ${JSON.stringify(stats.collects)}`);
  const header = `${lines.join("\n")}\n---\n\n`;
  // Single-item body only — never site navigation chrome. Image posts (图文帖)
  // inline their gallery as Markdown images; the desktop app downloads them
  // with a Douyin Referer via the existing remote-image staging path.
  const gallery = imageURLs.map((url) => `![](${url})`).join("\n\n");
  // 抖音把「展开」按钮的文字渲染在文案节点里，标题已剥掉它，描述也要剥；
  // 剥完与标题相同时就是同一句文案，不再重复成一段正文。
  const trimmedDescription = description.replace(/(?:…|\.{3})?\s*展开$/u, "").trim();
  const bodyDescription = trimmedDescription === title ? "" : trimmedDescription;
  const body = [`# ${title}`, bodyDescription, gallery].filter(Boolean).join("\n\n");
  const text = `${header}${body}`.trim() || "抖音公开视频";

  const page: ExtractedPage = {
    title,
    url: canonicalURL,
    text,
    characterCount: [...text].length,
    method: "rendered_dom",
    ...(usedCookie ? { usedCookie: true } : {}),
    ...(diagnostic ? { mediaDiagnostic: diagnostic } : {}),
  };

  // 图文帖没有正片视频——页面上那个 <video> 只是背景音乐轨。带上它会让扩展
  // 与 App 都把这条当成"受限视频"，把图集正文挤到视频占位符后面。
  const isImagePost = imageURLs.length > 0;
  if (mediaHit && !isImagePost) {
    page.mediaDescriptor = {
      ...mediaHit,
      canonicalURL,
      platform: "douyin",
      author: mediaHit.author ?? author,
    };
  }
  if (isImagePost) page.imageCount = imageURLs.length;

  const metadataDiagnostic = makePopupOnlyMetadataDiagnostic(meta?.metadataDiagnostic, ssrDiagnostic, publishedAt, stats);
  return {
    page,
    ...(diagnostic ? { mediaDiagnostic: diagnostic } : {}),
    ...(metadataDiagnostic ? { metadataDiagnostic } : {}),
  };
}

/** Compatibility projection: existing callers that only need a page keep it. */
export async function captureDouyinSingleItem(tabId: number, tabURL: string): Promise<ExtractedPage> {
  return (await captureDouyinSingleItemAttempt(tabId, tabURL)).page;
}

/**
 * YouTube single-video capture: MAIN-world player snapshot → optional
 * caption fetch in the page's own origin → markdown page. Only the video
 * the user is watching; no private endpoints, no downloads.
 */
export async function captureYouTubeSingleVideo(tabId: number, tabURL: string): Promise<ExtractedPage> {
  const urlVideoID = youTubeVideoID(tabURL);
  if (!urlVideoID) throw new Error("CAPTURE_CONTENT_EMPTY");
  const canonical = youTubeCanonicalURL(urlVideoID);

  const snapshotResults = await browser.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    func: readYouTubePlayerSnapshotInMainWorld,
  }).catch(() => undefined);
  let snapshot = snapshotResults?.[0]?.result as ReturnType<typeof readYouTubePlayerSnapshotInMainWorld> | undefined;
  // The SPA keeps stale player responses across in-page navigation; only
  // trust a snapshot that matches the video actually in the address bar.
  if (snapshot?.videoId && snapshot.videoId !== urlVideoID) snapshot = undefined;

  if (!snapshot?.title) {
    // Watch-page DOM fallback: still the single video, never the feed.
    const domResults = await browser.scripting.executeScript({
      target: { tabId },
      func: extractYouTubeWatchDOMFallbackInPage,
    }).catch(() => undefined);
    const dom = domResults?.[0]?.result as ReturnType<typeof extractYouTubeWatchDOMFallbackInPage> | undefined;
    if (!dom?.title) throw new Error("CAPTURE_CONTENT_EMPTY");
    const fallbackText = buildYouTubeMarkdown({
      title: dom.title,
      ...(dom.author ? { author: dom.author } : {}),
      ...(dom.description ? { description: dom.description } : {}),
      canonicalURL: canonical,
    });
    return {
      title: dom.title,
      url: canonical,
      text: fallbackText,
      characterCount: [...fallbackText].length,
      method: "rendered_dom",
    };
  }

  let transcript = "";
  const track = pickCaptionTrack(snapshot.captionTracks ?? []);
  if (track) {
    const transcriptResults = await browser.scripting.executeScript({
      target: { tabId },
      func: fetchYouTubeTranscriptPayloadInPage,
      args: [track.baseUrl],
    }).catch(() => undefined);
    const payload = transcriptResults?.[0]?.result as
      | { format: "json3"; json: unknown }
      | { format: "xml"; text: string }
      | undefined;
    if (payload?.format === "json3") transcript = transcriptFromJSON3(payload.json);
    else if (payload?.format === "xml") transcript = transcriptFromTimedTextXML(payload.text);
  }
  if (!transcript && track) {
    // timedtext 被 pot 令牌拦截时（2025 起常态），走页面自己的文字记录面板。
    // 只抓视频原始语言：先把播放器字幕轨切到原始轨（翻译不在 captionTracks
    // 中），面板跟随；抓完恢复用户原状。
    const previousResults = await browser.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: setYouTubeCaptionTrackInMainWorld,
      args: [track.languageCode],
    }).catch(() => undefined);
    const previousState = previousResults?.[0]?.result as
      | { previousLanguage?: string; previousTranslation?: string; wasOff: boolean }
      | undefined;
    const panelResults = await browser.scripting.executeScript({
      target: { tabId },
      func: collectYouTubeTranscriptFromPanelInPage,
    }).catch(() => undefined);
    if (previousState) {
      await browser.scripting.executeScript({
        target: { tabId },
        world: "MAIN",
        func: restoreYouTubeCaptionTrackInMainWorld,
        args: [previousState],
      }).catch(() => undefined);
    }
    const segments = (panelResults?.[0]?.result ?? []) as YouTubePanelSegment[];
    transcript = transcriptFromPanelSegments(segments);
  }

  const canonicalURL = canonical;
  const text = buildYouTubeMarkdown({
    title: snapshot.title,
    ...(snapshot.author ? { author: snapshot.author } : {}),
    ...(snapshot.publishDate ? { published: snapshot.publishDate } : {}),
    ...(snapshot.likeCount ? { likes: snapshot.likeCount } : {}),
    ...(snapshot.viewCount ? { views: snapshot.viewCount } : {}),
    ...(snapshot.shortDescription ? { description: snapshot.shortDescription } : {}),
    ...(transcript ? { transcript } : {}),
    canonicalURL,
  });
  return {
    title: snapshot.title,
    url: canonicalURL,
    text,
    characterCount: [...text].length,
    method: "rendered_dom",
  };
}

async function captureAttemptFromTab(
  tabId: number,
): Promise<{
  envelope: CaptureEnvelope;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  imageCount?: number;
}> {
  const tab = await browser.tabs.get(tabId).catch(() => undefined);
  const tabURL = tab?.url || "";

  let page: ExtractedPage;

  // Hard fork: any Douyin host uses single-item capture, never generic page scrape.
  let douyinAttempt: DouyinCaptureAttempt | undefined;
  if (isDouyinHost(tabURL) || isDouyinVideoURL(tabURL)) {
    douyinAttempt = await captureDouyinSingleItemAttempt(tabId, tabURL);
    page = douyinAttempt.page;
  } else if (isYouTubeWatchURL(tabURL)) {
    // Hard fork: a watch URL never uses the generic scraper — that captures
    // the SPA shell (feed/sidebar) instead of the video.
    page = await captureYouTubeSingleVideo(tabId, tabURL);
  } else {
    const result = await browser.scripting.executeScript({
      target: { tabId },
      func: extractPageInIsolatedWorld,
    });
    page = result[0]?.result as ExtractedPage;
    if (!page) throw new Error("CAPTURE_CONTENT_EMPTY");
    page = enrichXCaptureWithTitleFallback(page, tab?.title ?? null);
    const mediaResults = await browser.scripting.executeScript({
      target: { tabId },
      func: detectMediaInPage,
    });
    const mediaDescriptor = mediaResults[0]?.result as MediaDescriptor | undefined;
    page = attachDetectedMedia(page, mediaDescriptor);
  }

  if (!page?.text) throw new Error("CAPTURE_CONTENT_EMPTY");

  return {
    envelope: captureEnvelopeForPage(
      page,
      tabURL,
      tab?.title ?? null,
      new Date().toISOString(),
      requestId(),
    ),
    ...(douyinAttempt?.mediaDiagnostic ?? page.mediaDiagnostic ? { mediaDiagnostic: douyinAttempt?.mediaDiagnostic ?? page.mediaDiagnostic } : {}),
    ...(douyinAttempt?.metadataDiagnostic ? { metadataDiagnostic: douyinAttempt.metadataDiagnostic } : {}),
    ...(page.imageCount !== undefined ? { imageCount: page.imageCount } : {}),
  };
}

export async function captureFromTab(tabId: number): Promise<CaptureEnvelope> {
  return (await captureAttemptFromTab(tabId)).envelope;
}

/**
 * 已声明枚举但尚无专属适配器的平台（小红书/B站）。它们是重客户端渲染的
 * SPA，通用抓取只会刮到信息流外壳垃圾（与 YouTube watch 页同类问题）；
 * 因此显式拦截并给人话降级，而不是产出乱码条目。
 */
function isUnimplementedPlatformHost(rawURL: string): "xiaohongshu" | "bilibili" | undefined {
  let host: string;
  try {
    host = new URL(rawURL).hostname.toLowerCase();
  } catch {
    return undefined;
  }
  host = host.replace(/^www\.|^m\./, "");
  if (host === "xiaohongshu.com" || host.endsWith(".xiaohongshu.com") || host === "xhslink.com") {
    return "xiaohongshu";
  }
  if (host === "bilibili.com" || host.endsWith(".bilibili.com") || host === "b23.tv") {
    return "bilibili";
  }
  return undefined;
}

export async function sendCapture(tabId: number): Promise<ExtensionSendResult> {
  const preTab = await browser.tabs.get(tabId).catch(() => undefined);
  if (isUnimplementedPlatformHost(preTab?.url || "")) {
    // 尚无适配器：明确降级，不落 SPA 外壳垃圾。
    return {
      response: { kind: "error", error: makeAppError(requestId(), "protocol", "PLATFORM_NOT_SUPPORTED", false, "open_in_browser") },
      errorStage: "extension_validation",
    };
  }
  const attempt = await captureAttemptFromTab(tabId);
  const { envelope, mediaDiagnostic, metadataDiagnostic } = attempt;
  // V2-first strategy: validate the V2 envelope (which carries the media
  // descriptor). Only if V2 validation actually fails do we downgrade to V1.
  // This preserves the video player URL and media metadata for the App.
  let wireEnvelope: CaptureEnvelope = envelope;
  let invalid = validateCapture(wireEnvelope);
  if (invalid && envelope.version === 2) {
    // V2 validation failed — downgrade to V1 (drops media, keeps text).
    // Better to deliver text-only than to fail the entire capture.
    wireEnvelope = downgradeToV1(envelope);
  }

  // Payload size guard: Native Messaging has a 4 MiB hard limit.
  // Text is already capped at 1 MB in the extraction layer — this is a
  // safety net for edge cases (e.g. media descriptor with many candidates).
  // Truncates at paragraph boundary (\n\n) to preserve readability.
  const MAX_PAYLOAD_BYTES = 3 * 1024 * 1024; // 3 MiB safety net
  let serialized = JSON.stringify(wireEnvelope);
  if (serialized.length > MAX_PAYLOAD_BYTES) {
    const envelopeCopy = { ...wireEnvelope };
    const captureCopy = { ...envelopeCopy.capture };
    const textLen = captureCopy.text?.length ?? 0;
    const overhead = serialized.length - textLen;
    const maxTextLen = Math.max(10_000, MAX_PAYLOAD_BYTES - overhead - 2_000);
    if (captureCopy.text && textLen > maxTextLen) {
      // Cut at last paragraph boundary within budget; fall back to hard cut
      const cutAt = captureCopy.text.lastIndexOf("\n\n", maxTextLen);
      const sliceEnd = cutAt > maxTextLen * 0.3 ? cutAt : maxTextLen;
      captureCopy.text = captureCopy.text.slice(0, sliceEnd) + "\n\n…（内容过长，已截断）";
      captureCopy.characterCount = [...captureCopy.text].length;
      captureCopy.completeness = "selection_only";
    }
    envelopeCopy.capture = captureCopy;
    wireEnvelope = envelopeCopy;
    serialized = JSON.stringify(wireEnvelope);
    // Last resort: strip media descriptor entirely
    if (serialized.length > MAX_PAYLOAD_BYTES && "media" in wireEnvelope) {
      const stripped = { ...wireEnvelope };
      delete (stripped as Record<string, unknown>).media;
      stripped.version = 1;
      stripped.evidence = { sourceLabel: "Current page DOM (truncated)", usedCookie: false };
      wireEnvelope = stripped as CaptureEnvelope;
    }
  }

  // Re-validate after payload size guard may have modified the envelope.
  invalid = validateCapture(wireEnvelope);
  if (invalid) {
    return {
      response: { kind: "error", error: makeAppError(wireEnvelope.requestId, "protocol", invalid, false, "retry") },
      errorStage: "extension_validation",
      ...(mediaDiagnostic ? { mediaDiagnostic } : {}),
      ...(metadataDiagnostic ? { metadataDiagnostic } : {}),
    };
  }
  try {
    // 30s covers cold-start: Native Host may open LinkDigest.app, wait for the
    // capture socket, then complete one local write. Hot path still finishes in ms.
    // Send wireEnvelope (which may have been downgraded to V1 and/or truncated).
    const response: unknown = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, wireEnvelope), 30_000);
    const normalized = normalizeNativeResponse(response, wireEnvelope.requestId);
    return {
      response: normalized,
      ...(normalized.kind === "error" ? { errorStage: "native_response" as const } : {}),
      ...(mediaDiagnostic ? { mediaDiagnostic } : {}),
      ...(metadataDiagnostic ? { metadataDiagnostic } : {}),
    };
  } catch (error) {
    return {
      response: { kind: "error", error: mapNativeFailure(error, wireEnvelope.requestId) },
      errorStage: "native_transport",
      ...(mediaDiagnostic ? { mediaDiagnostic } : {}),
      ...(metadataDiagnostic ? { metadataDiagnostic } : {}),
    };
  }
}

export async function previewCurrentPage(tabId: number): Promise<SafeCapturePreview> {
  const attempt = await captureAttemptFromTab(tabId);
  return safePreviewForCapture(
    attempt.envelope,
    attempt.mediaDiagnostic,
    attempt.metadataDiagnostic,
    attempt.imageCount,
  );
}

/** 记住上次同步到的最新收藏 id，供下次增量同步判断「追上了」。 */
const BOOKMARKS_CURSOR_KEY = "x-bookmarks-last-synced-id";

export type BookmarksSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome; collected: number; reachedKnown: boolean }
  | { ok: false; code: "not_bookmarks" | "empty" | "native_error" | "injection_failed" };

export async function syncXBookmarks(tabId: number): Promise<BookmarksSyncResult> {
  const tab = await browser.tabs.get(tabId).catch(() => undefined);
  if (!isXBookmarksURL(tab?.url)) return { ok: false, code: "not_bookmarks" };

  const stored = await browser.storage.local.get(BOOKMARKS_CURSOR_KEY);
  const lastSynced = stored[BOOKMARKS_CURSOR_KEY];
  const knownIDs = isValidTweetID(lastSynced) ? [lastSynced] : [];

  let collected: CollectResult;
  try {
    const results = await browser.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: collectXBookmarkIDsInPage,
      // 只把上次游标交给页面；连续遇到 3 条已知即判定追上。
      args: [knownIDs, MAX_BOOKMARK_IDS, 3],
    });
    const raw = results[0]?.result as CollectResult | undefined;
    collected = raw && Array.isArray(raw.ids)
      ? { ids: raw.ids.filter(isValidTweetID), reachedKnown: raw.reachedKnown === true }
      : { ids: [], reachedKnown: false };
  } catch {
    return { ok: false, code: "injection_failed" };
  }

  if (collected.ids.length === 0) {
    return { ok: false, code: "empty" };
  }

  const syncRequestId = requestId();
  const message = { kind: "xBookmarks", version: 1, requestId: syncRequestId, tweetIDs: collected.ids };
  let response: unknown;
  try {
    response = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 30_000);
  } catch {
    return { ok: false, code: "native_error" };
  }
  const outcome = parseBookmarksAccepted(response);
  if (!outcome) return { ok: false, code: "native_error" };

  // 收藏夹按加入时间倒序，第一条即最新——记为下次增量的游标。
  const newest = collected.ids[0];
  if (newest) await browser.storage.local.set({ [BOOKMARKS_CURSOR_KEY]: newest });

  return { ok: true, outcome, collected: collected.ids.length, reachedKnown: collected.reachedKnown };
}

export type SingleTweetSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome }
  | { ok: false; code: "invalid_id" | "native_error" };

/**
 * 时间线上就地同步一条推文。它就是「tweetIDs 只含一条的收藏夹同步」——App 侧
 * enqueueXBookmarks 已处理去重与逐条抓取，这里不需要额外通道。
 */
export async function syncSingleTweet(tweetID: unknown): Promise<SingleTweetSyncResult> {
  if (!isValidTweetID(tweetID)) return { ok: false, code: "invalid_id" };
  const message = { kind: "xBookmarks", version: 1, requestId: requestId(), tweetIDs: [tweetID] };
  let response: unknown;
  try {
    response = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 30_000);
  } catch {
    return { ok: false, code: "native_error" };
  }
  const outcome = parseBookmarksAccepted(response);
  if (!outcome) return { ok: false, code: "native_error" };
  return { ok: true, outcome };
}

export default defineBackground(() => {
  browser.runtime.onMessage.addListener(async (
    message: { type?: string; tabId?: number; tweetID?: string },
  ) => {
    // 时间线注入按钮发来的单条同步：只需要 tweetID，不涉及 tabId。
    if (message.type === "sync-single-tweet") return syncSingleTweet(message.tweetID);
    if (typeof message.tabId !== "number") return undefined;
    if (message.type === "preview-current-page") return previewCurrentPage(message.tabId);
    if (message.type === "send-current-page") return sendCapture(message.tabId);
    if (message.type === "sync-x-bookmarks") return syncXBookmarks(message.tabId);
    return undefined;
  });
});
