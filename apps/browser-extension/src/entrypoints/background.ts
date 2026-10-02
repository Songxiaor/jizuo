import {
  attachDetectedMedia,
  cleanDouyinAuthorText,
  enrichXCaptureWithTitleFallback,
  extractDouyinSingleItemMetaInPage,
  type ExtractedPage,
} from "../content/extract";
import { captureSendBlockReason } from "../content/capture-send-gate";
import {
  clampCommentLimit,
  commentPlatformForURL,
  commentsMarkdown,
  COMMENT_LIMIT_DEFAULT,
  selectComments,
  stripEmbeddedCommentSection,
  type CapturedComment,
  type CommentCollection,
  type CommentPlatform,
} from "../content/comments";
import { detectMediaInPage } from "../content/media-detection";
import { isYouTubeWatchURL, youTubeVideoID } from "../content/youtube";
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
  bilibiliCanonicalURL,
  bilibiliVideoID,
  isBilibiliVideoURL,
  readBilibiliStreamInMainWorld,
} from "../content/bilibili";
import {
  isXiaohongshuNoteURL,
  readXiaohongshuVideoStreamInMainWorld,
  xiaohongshuCanonicalURL,
  xiaohongshuNoteID,
} from "../content/xiaohongshu";
import {
  makeAppError,
  MAX_CAPTURE_PAYLOAD_BYTES,
  normalizeNativeResponse,
  truncateToUtf8Bytes,
  utf8ByteLength,
  validateCapture,
  type CaptureEnvelope,
  type CapturePlatform,
  type CaptureRequestedAction,
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
  normalizeBookmarkItems,
  parseBookmarksAccepted,
  parseBookmarksLookup,
  type BookmarksSyncOutcome,
  type CollectResult,
} from "../content/x-bookmarks";
import {
  collectXProfileItemsInPage,
  canonicalXProfileURL,
  isPublicTwimgProfileImageURL,
  isXProfileURL,
  MAX_X_PROFILE_CANDIDATES,
  normalizeXProfileItems,
  parseProfileCandidatesPresented,
  profileHandleFromURL,
  resolvedXProfileDisplayName,
  X_PROFILE_CANDIDATES_KIND,
  type XProfileCollectResult,
  type XProfilePreviewItem,
} from "../content/x-profile";
import validateXProfileSchema from "../generated/x-profile-validator.mjs";

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

// ---------------------------------------------------------------------------
// 评论：条数来自 App 设置页，收集结果按标签页缓存，发送时只写勾选的那些。

const COMMENT_PLATFORMS: readonly CommentPlatform[] = [
  "reddit", "community", "x", "youtube", "bilibili", "zhihu", "douyin", "xiaohongshu",
];

/**
 * App 设置页「收集 · 汲 → 评论」里的抓取偏好。
 * - `commentLimit`：默认条数（10..100）。
 * - `commentLimits`：按平台覆盖；0 = 这个平台不抓评论，没写的平台跟随默认条数。
 * - `autoSaveComments`：true = 不弹勾选，保存时自动带上前 N 条。
 */
export type CapturePreferences = {
  commentLimit: number;
  commentLimits: Partial<Record<CommentPlatform, number>>;
  autoSaveComments: boolean;
  /** 新内容进来会自动做的工序；undefined = 旧版 App/Host 没告诉（2026-09-29 弹窗重构）。 */
  autoSteps?: ProcessStepKey[];
};

export const PROCESS_STEP_KEYS = ["record", "proof", "comments", "summary", "translation", "mindMap"] as const;
export type ProcessStepKey = (typeof PROCESS_STEP_KEYS)[number];

export const DEFAULT_CAPTURE_PREFERENCES: CapturePreferences = {
  commentLimit: COMMENT_LIMIT_DEFAULT,
  commentLimits: {},
  autoSaveComments: false,
};

/** 读 App 设置页的评论偏好。旧版 App/Host 不认识这条消息或没带新字段时退回默认值（今天的行为）。 */
export async function capturePreferences(): Promise<CapturePreferences> {
  const message = { kind: "getCapturePreferences", version: 1, requestId: requestId() };
  try {
    const response: unknown = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 4_000);
    return parseCapturePreferences(response, message.requestId) ?? DEFAULT_CAPTURE_PREFERENCES;
  } catch {
    return DEFAULT_CAPTURE_PREFERENCES;
  }
}

/** 读 App 设置页的「评论抓取数量」（默认条数）。 */
export async function commentLimitPreference(): Promise<number> {
  return (await capturePreferences()).commentLimit;
}

export function parseCapturePreferences(response: unknown, expectedRequestId: string): CapturePreferences | undefined {
  if (!response || typeof response !== "object") return undefined;
  const row = response as {
    kind?: unknown; version?: unknown; requestId?: unknown;
    commentLimit?: unknown; commentLimits?: unknown; autoSaveComments?: unknown; autoSteps?: unknown;
  };
  if (row.kind !== "capturePreferences" || row.version !== 1 || row.requestId !== expectedRequestId) return undefined;
  const commentLimit = typeof row.commentLimit === "number" && Number.isInteger(row.commentLimit)
    ? clampCommentLimit(row.commentLimit)
    : COMMENT_LIMIT_DEFAULT;
  const commentLimits: Partial<Record<CommentPlatform, number>> = {};
  if (row.commentLimits && typeof row.commentLimits === "object" && !Array.isArray(row.commentLimits)) {
    const raw = row.commentLimits as Record<string, unknown>;
    for (const platform of COMMENT_PLATFORMS) {
      if (!Object.prototype.hasOwnProperty.call(raw, platform)) continue;
      const value = raw[platform];
      if (typeof value !== "number" || !Number.isInteger(value)) continue;
      commentLimits[platform] = value <= 0 ? 0 : clampCommentLimit(value);
    }
  }
  const autoSteps = Array.isArray(row.autoSteps)
    ? PROCESS_STEP_KEYS.filter((key) => (row.autoSteps as unknown[]).includes(key))
    : undefined;
  return {
    commentLimit, commentLimits, autoSaveComments: row.autoSaveComments === true,
    ...(autoSteps ? { autoSteps } : {}),
  };
}

export function parseCapturePreferencesLimit(response: unknown, expectedRequestId: string): number | undefined {
  const preferences = parseCapturePreferences(response, expectedRequestId);
  return preferences ? preferences.commentLimit : undefined;
}

/** 这个平台实际用的条数：平台单独设过就用它，否则跟随默认条数。0 = 不抓。 */
export function effectiveCommentLimit(preferences: CapturePreferences, platform: CommentPlatform): number {
  return preferences.commentLimits[platform] ?? preferences.commentLimit;
}

/**
 * 弹窗转交给发送的评论处理方式（来自 collect-comments 的结果）：
 * - disabled：这个平台设为不抓，连提取器自带的评论段也去掉；
 * - auto：保存时现读前 `limit` 条，不经勾选。
 * 没有这个字段时保持原来的勾选流程。
 */
export type CommentSendMode = { kind: "disabled" } | { kind: "auto"; limit: number };

export function parseCommentSendMode(value: unknown): CommentSendMode | undefined {
  if (!value || typeof value !== "object") return undefined;
  const row = value as { kind?: unknown; limit?: unknown };
  if (row.kind === "disabled") return { kind: "disabled" };
  if (row.kind === "auto" && typeof row.limit === "number" && Number.isInteger(row.limit) && row.limit > 0) {
    return { kind: "auto", limit: clampCommentLimit(row.limit) };
  }
  return undefined;
}

type CachedComments = { url: string; collection: CommentCollection };

/**
 * 勾选期间 MV3 后台闲置 30 秒就会被浏览器回收，内存里的评论会丢。
 * 放进 `storage.session`：后台重启仍在，关浏览器才清空，不落盘。
 */
const commentCacheKey = (tabId: number) => `comments:${tabId}`;

async function readCommentCache(tabId: number): Promise<CachedComments | undefined> {
  try {
    const stored = await browser.storage.session.get(commentCacheKey(tabId));
    return stored[commentCacheKey(tabId)] as CachedComments | undefined;
  } catch {
    return undefined;
  }
}

async function writeCommentCache(tabId: number, value: CachedComments | undefined): Promise<void> {
  try {
    if (value) await browser.storage.session.set({ [commentCacheKey(tabId)]: value });
    else await browser.storage.session.remove(commentCacheKey(tabId));
  } catch {
    // 存不进去只影响勾选结果，发送时退回提取器自带的评论段。
  }
}

/** 只比「是不是同一条内容」：B 站等会在地址栏悄悄改 spm/vd_source 之类的跟踪参数。 */
export function sameContentURL(left: string, right: string): boolean {
  const key = (raw: string): string => {
    try {
      const url = new URL(raw);
      const kept = ["v", "id", "modal_id", "p", "item"]
        .filter((name) => url.searchParams.has(name))
        .map((name) => `${name}=${url.searchParams.get(name)}`);
      return `${url.origin}${url.pathname.replace(/\/+$/u, "")}?${kept.join("&")}`;
    } catch {
      return raw.split("#")[0] ?? raw;
    }
  };
  return key(left) === key(right);
}

async function collectCommentsInTab(tabId: number, limit: number): Promise<CommentCollection | undefined> {
  // `files` 注入带不了参数：先把条数写进同一隔离世界，再注入收集脚本。
  await browser.scripting.executeScript({
    target: { tabId },
    func: (value: number) => {
      (globalThis as { __linkdigestCommentLimit?: number }).__linkdigestCommentLimit = value;
    },
    args: [limit],
  });
  const results = await browser.scripting.executeScript({
    target: { tabId },
    files: ["/extract-comments.js"],
  });
  const collection = results[0]?.result as CommentCollection | null | undefined;
  return collection && Array.isArray(collection.comments) ? collection : undefined;
}

export type CommentPickerItem = {
  id: string;
  author: string;
  excerpt: string;
  depth: number;
  likes?: string;
};

export type CommentCollectResult =
  | { ok: true; platform: CommentPlatform; limit: number; expectedCount?: number; loginRequired?: boolean; items: CommentPickerItem[] }
  | { ok: false; code: "unsupported" | "empty" | "failed"; limit?: number }
  /** 这个平台在汲作设置里设为不抓评论：不注入收集脚本。 */
  | { ok: false; code: "disabled"; platform: CommentPlatform }
  /**
   * 自动保存前 N 条：弹窗不给勾选，只预览读到的前几条（2026-09-29 弹窗重构）。
   * 读到的这份写进缓存，保存时直接用，不再滚第二遍；没读到时 items 缺省，保存时再读。
   */
  | { ok: false; code: "auto"; platform: CommentPlatform; limit: number; expectedCount?: number; loginRequired?: boolean; items?: CommentPickerItem[] };

export function commentPickerItems(comments: CapturedComment[]): CommentPickerItem[] {
  return comments.map((comment) => ({
    id: comment.id,
    author: comment.author.replace(/^u\//u, ""),
    excerpt: comment.body.replace(/!\[[^\]]*\]\([^)]*\)/gu, "[图片]").replace(/\s+/gu, " ").trim().slice(0, 160),
    depth: comment.depth,
    ...(comment.likes ? { likes: comment.likes } : comment.score ? { likes: comment.score } : {}),
  }));
}

export async function collectCommentsForPicker(tabId: number): Promise<CommentCollectResult> {
  const tab = await browser.tabs.get(tabId).catch(() => undefined);
  const tabURL = tab?.url ?? "";
  const platform = commentPlatformForURL(tabURL);
  if (!platform) return { ok: false, code: "unsupported" };
  const preferences = await capturePreferences();
  const limit = effectiveCommentLimit(preferences, platform);
  if (limit === 0) {
    await writeCommentCache(tabId, undefined);
    return { ok: false, code: "disabled", platform };
  }
  if (preferences.autoSaveComments) {
    // 按当前条数现读一份给弹窗预览，并缓存给保存用；读失败不影响保存（保存时再读）。
    await writeCommentCache(tabId, undefined);
    try {
      const collection = await withTimeout(collectCommentsInTab(tabId, limit), 25_000);
      if (collection) {
        await writeCommentCache(tabId, { url: tabURL, collection });
        return {
          ok: false,
          code: "auto",
          platform,
          limit,
          ...(collection.expectedCount !== undefined ? { expectedCount: collection.expectedCount } : {}),
          ...(collection.loginRequired ? { loginRequired: true } : {}),
          items: commentPickerItems(collection.comments),
        };
      }
    } catch {
      // 落到下面：只告诉弹窗「自动存前 N 条」。
    }
    return { ok: false, code: "auto", platform, limit };
  }
  try {
    const collection = await withTimeout(collectCommentsInTab(tabId, limit), 25_000);
    if (!collection) return { ok: false, code: "failed", limit };
    await writeCommentCache(tabId, { url: tabURL, collection });
    if (!collection.comments.length) return { ok: false, code: "empty", limit };
    return {
      ok: true,
      platform: collection.platform,
      limit: collection.limit,
      ...(collection.expectedCount !== undefined ? { expectedCount: collection.expectedCount } : {}),
      ...(collection.loginRequired ? { loginRequired: true } : {}),
      items: commentPickerItems(collection.comments),
    };
  } catch {
    return { ok: false, code: "failed", limit };
  }
}

/**
 * 把评论写进正文末尾。`selectedIDs` 为 undefined 表示没经过弹窗勾选（直接发送），
 * 按设置条数取前 N；传空数组表示用户一条都不要。评论收集失败绝不阻断正文抓取。
 */
export function pageWithComments(
  page: ExtractedPage,
  collection: CommentCollection | undefined,
  selectedIDs: readonly string[] | undefined,
): ExtractedPage {
  if (!collection) return page;
  const chosen = selectComments(collection.comments, selectedIDs, collection.limit);
  // 收集器一条都没读到、用户也没表态时，保留提取器自带的评论段，不做减法。
  if (!collection.comments.length && selectedIDs === undefined) return page;
  const base = stripEmbeddedCommentSection(page.text);
  const section = commentsMarkdown(collection, chosen);
  const text = section ? `${base}\n\n${section}` : base;
  const replacedPartialRedditComments = collection.platform === "reddit" && page.completeness === "visible_only";
  return {
    ...page,
    text,
    characterCount: [...text].length,
    ...(replacedPartialRedditComments ? { completeness: "full_article" as const } : {}),
  };
}

/** 这个平台设为不抓评论：连提取器自带的评论段（Reddit/论坛）也去掉。 */
export function pageWithoutComments(page: ExtractedPage): ExtractedPage {
  const text = stripEmbeddedCommentSection(page.text);
  if (text === page.text) return page;
  return { ...page, text, characterCount: [...text].length };
}

/**
 * 勾选模式只用弹窗 collect-comments 读好的那份：发送不再临时滚页面补读，
 * 没经过弹窗（或读失败）的发送保持原样，由提取器自带的评论段兜底。
 * 自动保存模式在这里现读前 N 条；读失败只保存正文，绝不阻断。
 */
async function attachComments(
  tabId: number,
  tabURL: string,
  page: ExtractedPage,
  selectedIDs: readonly string[] | undefined,
  mode: CommentSendMode | undefined,
): Promise<ExtractedPage> {
  if (mode?.kind === "disabled") return pageWithoutComments(page);
  if (mode?.kind === "auto") {
    const cached = await readCommentCache(tabId);
    if (cached && sameContentURL(cached.url, tabURL) && cached.collection.limit === mode.limit) {
      return pageWithComments(page, cached.collection, undefined);
    }
    try {
      const collection = await withTimeout(collectCommentsInTab(tabId, mode.limit), 25_000);
      return pageWithComments(page, collection, undefined);
    } catch {
      return page;
    }
  }
  const cached = await readCommentCache(tabId);
  if (!cached || !sameContentURL(cached.url, tabURL)) return page;
  return pageWithComments(page, cached.collection, selectedIDs);
}

export type DouyinMediaHit = MediaDescriptor;
export type SafeCapturePreview = {
  title: string;
  characterCount: number;
  /** 英文等拉丁文字为主的正文：按词数显示。 */
  wordCount?: number;
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
  /** 正文开头一小段（最多 120 字，压成一行），让用户确认读对了内容。不带全文。 */
  excerpt?: string;
  /** 页面域名，只有主机名。 */
  host?: string;
  /** 这次抓取认定的页面地址（抖音弹层会换成视频详情页）；弹窗拿它问 App 存过没有。 */
  pageURL?: string;
  /** 读取时用了浏览器里的登录状态。 */
  usedCookie?: boolean;
  /** 视频时长与作者：页面上本来就看得见的元数据；播放和封面地址仍然不出后台。 */
  mediaDurationSeconds?: number;
  mediaAuthor?: string;
  /** 页面正被这个翻译插件显示成译文：存下的会是译文，弹窗提醒用户。 */
  pageTranslatedBy?: string;
  /** 抓取头部元数据（`---` 块）里的作者、发布时间和互动数，原样的短字符串。 */
  sourceAuthor?: string;
  published?: string;
  engagement?: PreviewEngagement;
};

export type PreviewEngagement = Partial<Record<"likes" | "comments" | "shares" | "collects" | "views", string>>;

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

const EXCERPT_LIMIT = 120;
const FRONTMATTER_KEYS = ["author", "published", "likes", "comments", "shares", "collects", "views"] as const;

/**
 * 抓取正文开头的 `---` 元数据块（extract.ts buildCaptureFrontmatter 写的，值是 JSON 字符串）。
 * 只认那几项已知字段，其余忽略；块不完整时当作没有。
 */
export function splitCaptureFrontmatter(text: string): { fields: Partial<Record<(typeof FRONTMATTER_KEYS)[number], string>>; body: string } {
  const match = /^---\n([\s\S]*?)\n---\n?/u.exec(text.replace(/^\uFEFF/u, ""));
  if (!match) return { fields: {}, body: text };
  const fields: Partial<Record<(typeof FRONTMATTER_KEYS)[number], string>> = {};
  for (const line of (match[1] ?? "").split("\n")) {
    const pair = /^([a-z_]+):\s*(.+)$/u.exec(line.trim());
    if (!pair) continue;
    const key = pair[1] as (typeof FRONTMATTER_KEYS)[number];
    if (!FRONTMATTER_KEYS.includes(key)) continue;
    let value = pair[2] ?? "";
    try {
      const parsed: unknown = JSON.parse(value);
      value = typeof parsed === "string" || typeof parsed === "number" ? String(parsed) : "";
    } catch {
      value = value.replace(/^["']|["']$/gu, "");
    }
    value = value.replace(/\s+/gu, " ").trim();
    if (value) fields[key] = [...value].slice(0, key === "author" ? 60 : 32).join("");
  }
  return { fields, body: text.slice(match[0].length) };
}

/**
 * 弹窗里的正文开头：去掉 Markdown 标记、与标题重复的首行和评论段，压成一行，最多 120 字。
 * 只有这一小段离开后台；全文仍然只随保存发给 App。
 */
function readableBodyLines(text: string, options: { skipHeadings?: boolean } = {}): string[] {
  return stripEmbeddedCommentSection(splitCaptureFrontmatter(text).body)
    .split("\n")
    // 开头摘录不要「## 字幕」「## 简介」这类小节名，读起来像正文第一个词。
    .filter((line) => !options.skipHeadings || !/^\s{0,3}#{2,6}\s/u.test(line))
    .map((line) => line
      // 正文里给视频占位的 `<!--LDVIDEO …-->` 是内部记号：头条弹窗摘要曾原样露出来（2026-10-02）。
      .replace(/<!--[\s\S]*?-->/gu, "")
      // 地址里可以带一层括号（维基百科的 Seal_(East_Asia)）：按一层嵌套配平，不然会留下「&redirect=no))」。
      .replace(/!\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+"[^"]*")?\)/gu, "")
      .replace(/\[([^\]]*)\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+"[^"]*")?\)/gu, "$1")
      .replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+/u, "")
      .replace(/[*_`~]+/gu, "")
      .replace(/\s+/gu, " ")
      .trim())
    .filter((line) => line.length > 0 && !/^\[?\d{1,2}:\d{2}(:\d{2})?\]?$/u.test(line));
}

/**
 * 弹窗「字 / 读完」按读者真能读到的字算：不数开头的元数据块、图片链接、Markdown 记号和空白。
 * 抓取信封里的 characterCount 是整份文本的长度（含图片地址），给不配文字的图文算出「1.2k 字」。
 */
export function readableCharacterCount(text: string): number {
  return readableBodyLines(text).reduce((sum, line) => sum + [...line.replace(/\s+/gu, "")].length, 0);
}

/**
 * 以拉丁字母为主的正文按词算（「48k 字 · 119 分钟」对英文没有意义）。中文、日文等返回 undefined，
 * 仍按字算。
 */
export function readableLatinWordCount(text: string): number | undefined {
  const body = readableBodyLines(text).join(" ");
  const latin = body.match(/[A-Za-z]/gu)?.length ?? 0;
  const han = body.match(/[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/gu)?.length ?? 0;
  if (latin < 200 || han * 10 > latin) return undefined;
  return body.match(/[A-Za-z0-9][A-Za-z0-9'’-]*/gu)?.length;
}

export function previewExcerpt(text: string, title: string | null | undefined): string | undefined {
  const normalizedTitle = (title ?? "").replace(/\s+/gu, " ").trim();
  const body = readableBodyLines(text, { skipHeadings: true });
  if (body[0] && normalizedTitle && body[0] === normalizedTitle) body.shift();
  let joined = body.join(" ").trim();
  // X 这类没有标题的帖子，标题就是正文第一句：开头再出现一遍就去掉。
  const titleStem = normalizedTitle.replace(/[。．.！!？?…]+$/u, "");
  if (titleStem.length >= 4 && joined.startsWith(titleStem)) {
    joined = joined.slice(titleStem.length).replace(/^[。．.！!？?…，,：:;；\s]+/u, "");
  }
  if (!joined) return undefined;
  const chars = [...joined];
  return chars.length > EXCERPT_LIMIT ? `${chars.slice(0, EXCERPT_LIMIT).join("")}…` : joined;
}

/**
 * Popup preview is deliberately an allowlist. In particular, process-only
 * playback/poster URLs and the full captured text never cross this message
 * boundary; only a bounded excerpt does (see `previewExcerpt`).
 */
export function safePreviewForCapture(
  envelope: CaptureEnvelope,
  mediaDiagnostic?: DouyinSessionDiagnostic,
  metadataDiagnostic?: DouyinMetadataDiagnostic,
  imageCount?: number,
): SafeCapturePreview {
  const preview: SafeCapturePreview = {
    title: envelope.source.title || "当前页面",
    // 只用于弹窗显示，见 `readableCharacterCount`。
    characterCount: envelope.capture.completeness === "selection_only"
      ? envelope.capture.characterCount
      : readableCharacterCount(envelope.capture.text),
    version: envelope.version,
    platform: envelope.source.platform,
    completeness: envelope.capture.completeness,
    ...(typeof imageCount === "number" && imageCount > 0 ? { imageCount } : {}),
  };
  const excerpt = previewExcerpt(envelope.capture.text, envelope.source.title);
  if (excerpt) preview.excerpt = excerpt;
  if (envelope.capture.completeness !== "selection_only") {
    const words = readableLatinWordCount(envelope.capture.text);
    if (words) preview.wordCount = words;
  }
  const host = safeBlockedHostFromURL(envelope.source.url);
  if (host) preview.host = host.replace(/^www\./u, "");
  if (/^https?:\/\//u.test(envelope.source.url)) preview.pageURL = envelope.source.url;
  if (envelope.evidence.usedCookie) preview.usedCookie = true;
  const { fields } = splitCaptureFrontmatter(envelope.capture.text);
  if (fields.author) preview.sourceAuthor = fields.author;
  if (fields.published) preview.published = fields.published;
  const engagement: PreviewEngagement = {};
  for (const key of ["likes", "comments", "shares", "collects", "views"] as const) {
    if (fields[key]) engagement[key] = fields[key];
  }
  if (Object.keys(engagement).length > 0) preview.engagement = engagement;
  if (envelope.version === 2) {
    const duration = envelope.media.durationSeconds;
    if (typeof duration === "number" && Number.isFinite(duration) && duration > 0) {
      preview.mediaDurationSeconds = Math.round(duration);
    }
    const author = envelope.media.author?.replace(/\s+/gu, " ").trim().slice(0, 60);
    if (author) preview.mediaAuthor = author;
  }
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
    ...(value.requestedAction ? { requestedAction: value.requestedAction } : {}),
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
      platform: page.platform ?? detectCapturePlatform(sourceURL),
      ...(page.faviconURL ? { faviconURL: page.faviconURL } : {}),
    },
    capture: {
      method: page.method,
      text: page.text,
      characterCount: page.characterCount,
      completeness: page.completeness
        ?? (page.method === "selection" ? "selection_only" as const : "full_article" as const),
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

/**
 * DOM video selection can fail (multi-player feeds, not loaded yet) while the
 * tab URL already locks a single aweme. Playback recovery from page state /
 * same-origin detail is safe for these misses; DRM and unknown formats are not.
 */
const recoverableDouyinMediaFailures = new Set<NonNullable<MediaDescriptor["failureReason"]>>([
  "blob_or_mse",
  "multiple_candidates",
  "video_not_loaded",
  "no_transferable_source",
  "browser_session_required",
]);

export function needsDouyinPlaybackRecovery(
  descriptor: DouyinMediaHit | undefined,
): boolean {
  if (!descriptor) return true;
  if (
    (descriptor.kind === "directFile" || descriptor.kind === "hls")
    && typeof descriptor.ephemeralPlaybackURL === "string"
    && descriptor.ephemeralPlaybackURL.length > 0
    && !descriptor.failureReason
  ) {
    return false;
  }
  return descriptor.failureReason != null
    && recoverableDouyinMediaFailures.has(descriptor.failureReason);
}

export function buildDouyinPlaybackUpgrade(
  lockedAwemeId: string,
  lockedDescriptor: DouyinMediaHit | undefined,
  playbackURL: string,
  candidateCount: number,
): DouyinMediaHit {
  const canonicalURL = lockedDescriptor?.canonicalURL
    ?? `https://www.douyin.com/video/${lockedAwemeId}`;
  const pageURL = lockedDescriptor?.pageURL ?? canonicalURL;
  const persistentDescriptor = lockedDescriptor
    ? { ...lockedDescriptor }
    : {
        kind: "unsupported" as const,
        pageURL,
        canonicalURL,
        platform: "douyin" as const,
        transcriptionCapability: "unavailable" as const,
      };
  delete persistentDescriptor.failureReason;
  return {
    ...persistentDescriptor,
    kind: "directFile",
    pageURL,
    canonicalURL,
    platform: "douyin",
    ephemeralPlaybackURL: playbackURL,
    mimeType: "video/mp4",
    transcriptionCapability: "supported",
    candidateCount,
  };
}

export function upgradedDouyinSessionDescriptor(
  lockedAwemeId: string,
  lockedDescriptor: DouyinMediaHit | undefined,
  result: DouyinSessionDetailSuccess | undefined,
): DouyinMediaHit | undefined {
  if (!needsDouyinPlaybackRecovery(lockedDescriptor)
      || result?.ok !== true
      || !Number.isInteger(result.candidateCount)
      || result.candidateCount < 1
      || result.candidateCount > 256
      || !isAllowedDouyinPlaybackURL(result.playbackURL)) {
    return undefined;
  }
  return buildDouyinPlaybackUpgrade(
    lockedAwemeId,
    lockedDescriptor,
    result.playbackURL,
    result.candidateCount,
  );
}

async function tryDouyinSessionDetail(
  tabId: number,
  lockedAwemeId: string,
  lockedDescriptor: DouyinMediaHit | undefined,
): Promise<{ media?: DouyinMediaHit; diagnostic?: DouyinSessionDiagnostic }> {
  if (!needsDouyinPlaybackRecovery(lockedDescriptor)) return {};
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
    const media = upgradedDouyinSessionDescriptor(lockedAwemeId, lockedDescriptor, result);
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
  if (!needsDouyinPlaybackRecovery(lockedDescriptor)) return {};
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
    return {
      media: buildDouyinPlaybackUpgrade(
        lockedAwemeId,
        lockedDescriptor,
        result.playbackURL,
        result.candidateCount,
      ),
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
    // 抛错，不要把这句提示当正文返回。
    //
    // 原来返回的是一个 text 为「未识别到单条抖音视频…」的 page：它非空，于是
    // schema 校验全过、sendCapture 正常送出、popup 显示「✓ 已发送到 App」，
    // 桌面按 source.url 建一条记录，正文就是这句提示。用户在抖音个人主页、搜索页、
    // 无 modal_id 的精选页点发送，都会安静地攒出这种记录。
    // 抓取失败必须走错误通道——popup 已经会把 CAPTURE_DOUYIN_NO_SINGLE_ITEM
    // 翻成人话显示。
    throw new Error("CAPTURE_DOUYIN_NO_SINGLE_ITEM");
  }

  const notePath = (() => {
    try {
      return /\/(?:share\/)?note\//u.test(new URL(tabURL).pathname);
    } catch {
      return false;
    }
  })();
  let canonicalURL = `https://www.douyin.com/${notePath ? "note" : "video"}/${awemeId}`;
  const title = meta?.title || (notePath ? "抖音图文" : "抖音视频");
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
  // 换成 SSR / 接口拿到的播放信息后，页面上已读到的时长不能丢（2026-09-29 弹窗实测：
  // 抖音视频卡片没有时长）。
  const domDuration = meta?.mediaDescriptor?.durationSeconds;
  if (mediaHit && !mediaHit.durationSeconds && typeof domDuration === "number" && domDuration > 0) {
    mediaHit = { ...mediaHit, durationSeconds: domDuration };
  }

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
    // 空字符串不算「有」：SSR 缺作者时回空串，曾把 DOM 读到的作者盖成空白，弹窗与存档都没了作者。
    if (typeof ssr?.author === "string" && ssr.author.trim()) author = ssr.author;
    if (typeof ssr?.publishedAt === "string" && ssr.publishedAt.trim()) publishedAt = ssr.publishedAt;
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
  if (imageURLs.length > 0) {
    canonicalURL = `https://www.douyin.com/note/${awemeId}`;
  }
  const gallery = imageURLs.map((url) => `![](${url})`).join("\n\n");
  // 抖音把「展开」按钮的文字渲染在文案节点里，标题已剥掉它，描述也要剥；
  // 剥完与标题相同时就是同一句文案，不再重复成一段正文。标题会去掉末尾话题，
  // 此时正文只补回话题，不把整句配文重复展示两遍。
  const trimmedDescription = description.replace(/(?:…|\.{3})?\s*展开$/u, "").trim();
  const descriptionSuffix = trimmedDescription.startsWith(title)
    ? trimmedDescription.slice(title.length).trim()
    : "";
  const bodyDescription = trimmedDescription === title
    ? ""
    : descriptionSuffix && /^(?:#[^\s#]+\s*)+$/u.test(descriptionSuffix)
      ? descriptionSuffix
      : trimmedDescription;
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
    const mediaAuthor = cleanDouyinAuthorText(author || mediaHit.author);
    page.mediaDescriptor = {
      ...mediaHit,
      canonicalURL,
      platform: "douyin",
      ...(mediaAuthor ? { author: mediaAuthor } : {}),
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
  if (!youTubeVideoID(tabURL)) throw new Error("CAPTURE_CONTENT_EMPTY");
  // 整个流程在页面主世界里一次跑完；App「添加链接」执行的是同一个打包文件。
  const results = await browser.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    files: ["/extract-youtube.js"],
  }).catch(() => undefined);
  const page = results?.[0]?.result as ExtractedPage | undefined;
  if (!page?.text) throw new Error("CAPTURE_CONTENT_EMPTY");
  return page;
}

/**
 * 小红书视频笔记与 B 站视频的 `<video>` 都是 MSE，`src` 是 blob，DOM 探测只能
 * 判成「只能在原浏览器会话观看」。两家都把本次播放的真实地址放在页面自己的 JS
 * 全局里（`__INITIAL_STATE__` / `__playinfo__`），MAIN world 读一下就能把这条
 * 抓取从「不可下载」升级成「可下载、可转写」。只读页面已有数据：不带 cookie、
 * 不调私有接口、不做签名，`usedCookie` 保持 false。
 *
 * 只在 DOM 探测确实卡在 blob/MSE 时才走这一步——已经拿到直链的页面不必再注入。
 */
async function upgradeBrowserSessionMedia(
  tabId: number,
  tabURL: string,
  page: ExtractedPage,
): Promise<ExtractedPage> {
  const detected = page.mediaDescriptor;
  if (detected && detected.kind !== "browserSessionOnly") return page;
  const base = {
    pageURL: tabURL,
    ...(detected?.posterURL ? { posterURL: detected.posterURL } : {}),
    candidateCount: detected?.candidateCount ?? 1,
    selectionReason: detected?.selectionReason ?? "singleCandidate",
    playbackState: detected?.playbackState ?? "unknown",
    transcriptionCapability: "supported",
    kind: "directFile",
  } as const;

  try {
    const noteID = xiaohongshuNoteID(tabURL);
    if (noteID && isXiaohongshuNoteURL(tabURL)) {
      const results = await browser.scripting.executeScript({
        target: { tabId, frameIds: [0] },
        world: "MAIN",
        func: readXiaohongshuVideoStreamInMainWorld,
        args: [noteID],
      });
      const stream = results[0]?.result as
        | ReturnType<typeof readXiaohongshuVideoStreamInMainWorld>
        | undefined;
      if (!stream?.url) return page;
      return {
        ...page,
        mediaDescriptor: {
          ...base,
          canonicalURL: xiaohongshuCanonicalURL(tabURL),
          platform: "xiaohongshu",
          ephemeralPlaybackURL: stream.url,
          mimeType: "video/mp4",
          ...(stream.durationSeconds ? { durationSeconds: stream.durationSeconds } : {}),
          ...(stream.expiresAt ? { expiresAt: stream.expiresAt } : {}),
        },
      };
    }

    const videoID = bilibiliVideoID(tabURL);
    if (videoID && isBilibiliVideoURL(tabURL)) {
      const results = await browser.scripting.executeScript({
        target: { tabId, frameIds: [0] },
        world: "MAIN",
        func: readBilibiliStreamInMainWorld,
      });
      const stream = results[0]?.result as
        | ReturnType<typeof readBilibiliStreamInMainWorld>
        | undefined;
      if (!stream?.url) return page;
      return {
        ...page,
        mediaDescriptor: {
          ...base,
          canonicalURL: bilibiliCanonicalURL(videoID),
          platform: "bilibili",
          ephemeralPlaybackURL: stream.url,
          // DASH 的画面与声音是两条流：把音轨一并带上，App 下载后在本机合成。
          ...(stream.companionAudioURL ? { companionAudioURL: stream.companionAudioURL } : {}),
          mimeType: stream.mimeType,
          ...(stream.durationSeconds ? { durationSeconds: stream.durationSeconds } : {}),
          ...(stream.expiresAt ? { expiresAt: stream.expiresAt } : {}),
        },
      };
    }
  } catch {
    // MAIN world 注入在受限页面会失败——保留 DOM 探测的结论即可，不影响正文。
  }
  return page;
}

type CaptureCommentOptions =
  | { include: false }
  | { include: true; selectedIDs?: readonly string[] | undefined; mode?: CommentSendMode | undefined };

async function captureAttemptFromTab(
  tabId: number,
  commentOptions: CaptureCommentOptions = { include: true },
): Promise<{
  envelope: CaptureEnvelope;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  imageCount?: number;
  pageTranslatedBy?: string;
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
    // 注入打包好的文件而不是序列化一个函数。
    //
    // `func:` 会把函数体 toString 后注入，够不着模块作用域——那正是过去必须维护
    // 一份自包含拷贝的原因，也是「改动只落在其中一份、测试全绿、生产没变」这类
    // 失败的来源。`files:` 注入的是构建产物，模块导入照常工作，于是抽取逻辑
    // 只剩 `extractCurrentPage` 一份实现。
    const result = await browser.scripting.executeScript({
      target: { tabId },
      files: ["/extract-page.js"],
    });
    page = result[0]?.result as ExtractedPage;
    if (!page) throw new Error("CAPTURE_CONTENT_EMPTY");
    // Soft-gate: selection / substantial body can still send on login-wall /
    // SPA shells so a logged-in current tab remains usable. Hard failures still throw.
    const blockReason = captureSendBlockReason(page);
    if (blockReason) throw new Error(blockReason);
    if (page.captureIssue) {
      const rest = { ...page };
      delete rest.captureIssue;
      page = {
        ...rest,
        completeness: page.completeness ?? "visible_only",
      };
    }
    page = enrichXCaptureWithTitleFallback(page, tab?.title ?? null);
    const mediaResults = await browser.scripting.executeScript({
      target: { tabId },
      func: detectMediaInPage,
    });
    const mediaDescriptor = mediaResults[0]?.result as MediaDescriptor | undefined;
    page = attachDetectedMedia(page, mediaDescriptor);
    page = await upgradeBrowserSessionMedia(tabId, tabURL, page);
  }

  if (!page?.text) throw new Error("CAPTURE_CONTENT_EMPTY");
  if (commentOptions.include) {
    page = await attachComments(tabId, tabURL, page, commentOptions.selectedIDs, commentOptions.mode);
  }

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
    ...(page.pageTranslatedBy ? { pageTranslatedBy: page.pageTranslatedBy } : {}),
  };
}

export async function captureFromTab(tabId: number): Promise<CaptureEnvelope> {
  return (await captureAttemptFromTab(tabId)).envelope;
}

export async function sendCapture(
  tabId: number,
  requestedAction: CaptureRequestedAction = "save",
  selectedCommentIDs?: readonly string[],
  commentMode?: CommentSendMode,
): Promise<ExtensionSendResult> {
  const attempt = await captureAttemptFromTab(tabId, { include: true, selectedIDs: selectedCommentIDs, mode: commentMode });
  const { envelope, mediaDiagnostic, metadataDiagnostic } = attempt;
  // V2-first strategy: validate the V2 envelope (which carries the media
  // descriptor). Only if V2 validation actually fails do we downgrade to V1.
  // This preserves the video player URL and media metadata for the App.
  let wireEnvelope: CaptureEnvelope = { ...envelope, requestedAction };
  let invalid = validateCapture(wireEnvelope);
  if (invalid && envelope.version === 2) {
    // V2 validation failed — downgrade to V1 (drops media, keeps text).
    // Better to deliver text-only than to fail the entire capture.
    wireEnvelope = downgradeToV1(envelope);
  }

  // Payload size guard: Native Messaging has a 4 MiB hard limit.
  // 按 UTF-8 字节算，不用 JS 字符串长度（中文 1 字 3 字节）。
  let serialized = JSON.stringify(wireEnvelope);
  if (utf8ByteLength(serialized) > MAX_CAPTURE_PAYLOAD_BYTES) {
    const envelopeCopy = { ...wireEnvelope };
    const captureCopy = { ...envelopeCopy.capture };
    const textBytes = utf8ByteLength(captureCopy.text ?? "");
    const overhead = Math.max(0, utf8ByteLength(serialized) - textBytes);
    const maxTextBytes = Math.max(10_000, MAX_CAPTURE_PAYLOAD_BYTES - overhead - 2_000);
    if (captureCopy.text && textBytes > maxTextBytes) {
      captureCopy.text = truncateToUtf8Bytes(captureCopy.text, maxTextBytes);
      const cutAt = captureCopy.text.lastIndexOf("\n\n");
      if (cutAt > captureCopy.text.length * 0.3) {
        captureCopy.text = captureCopy.text.slice(0, cutAt);
      }
      captureCopy.text += "\n\n…（内容过长，已截断）";
      captureCopy.characterCount = [...captureCopy.text].length;
      captureCopy.completeness = "selection_only";
    }
    envelopeCopy.capture = captureCopy;
    wireEnvelope = envelopeCopy;
    serialized = JSON.stringify(wireEnvelope);
    if (utf8ByteLength(serialized) > MAX_CAPTURE_PAYLOAD_BYTES && "media" in wireEnvelope) {
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
  // 预览要快：评论另走 collect-comments，边显示预览边往下翻评论区。
  await writeCommentCache(tabId, undefined);
  const attempt = await captureAttemptFromTab(tabId, { include: false });
  const preview = safePreviewForCapture(
    attempt.envelope,
    attempt.mediaDiagnostic,
    attempt.metadataDiagnostic,
    attempt.imageCount,
  );
  return attempt.pageTranslatedBy ? { ...preview, pageTranslatedBy: attempt.pageTranslatedBy } : preview;
}

/** 记住上次同步到的最新收藏 id，供下次增量同步判断「追上了」/标「已在库」。 */
const BOOKMARKS_CURSOR_KEY = "x-bookmarks-last-synced-id";

export type BookmarksCollectResult =
  | {
      ok: true;
      items: import("../content/x-bookmarks").BookmarkPreviewItem[];
      reachedKnown: boolean;
      /** App 历史查重是否成功；失败时 alreadySynced 仅来自本地游标粗标。 */
      libraryLookup: "ok" | "unavailable";
    }
  | { ok: false; code: "not_bookmarks" | "empty" | "injection_failed" };

export type BookmarksSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome; collected: number; reachedKnown: boolean }
  | { ok: false; code: "not_bookmarks" | "empty" | "injection_failed" | "upgrade_app" }
  | NativeErrorResult;

/**
 * 连不上汲作。transient = 浏览器那一层很快就断了（不是超时、不是 Host 冷启动等满），
 * 弹窗据此自动重试；其余直接给「打开汲作并重试」（2026-10-01）。
 */
export type NativeErrorResult = { ok: false; code: "native_error"; transient?: true };

function nativeTransportFailure(error: unknown): NativeErrorResult {
  return mapNativeFailure(error, "popup").code === "NATIVE_MESSAGE_FAILED"
    ? { ok: false, code: "native_error", transient: true }
    : { ok: false, code: "native_error" };
}

async function loadBookmarksCursor(): Promise<string[]> {
  // 游标必须存**一批** id，不能只存一条。
  //
  // 采集器要求「连续遇到 stopAfterKnownStreak(=3) 条已知」才判定追上，而它内部用
  // `seen` 保证同一 id 只计一次——已知集合里只有 1 个 id 时 knownStreak 最大到 1，
  // 永远够不到 3。后果有两个：早停从不生效，每次同步都滚满 400 轮（约 140s），
  // 「已同步到上次的位置」这句提示永远不出现；更糟的是收藏超过 300 条待同步时，
  // 每次都只重复采集最上面同一批 300 条，更早的收藏永远同步不到。
  const stored = await browser.storage.local.get(BOOKMARKS_CURSOR_KEY);
  const rawCursor = stored[BOOKMARKS_CURSOR_KEY];
  return (Array.isArray(rawCursor) ? rawCursor : [rawCursor])
    .filter((id): id is string => isValidTweetID(id));
}

async function rememberBookmarksCursor(ids: string[]): Promise<void> {
  // 收藏夹按加入时间倒序。存最新的一小批而不是一条：连续命中 3 条才算追上，
  // 只存一条的话那个判据永远不成立。存 8 条留出余量——用户在两次同步之间
  // 取消收藏了其中几条时，剩下的仍足以凑够连续 3 条。
  const nextCursor = ids.filter(isValidTweetID).slice(0, 8);
  if (nextCursor.length > 0) {
    await browser.storage.local.set({ [BOOKMARKS_CURSOR_KEY]: nextCursor });
  }
}

/** 只滚动收集，不立刻交给 App——弹窗勾选后再 sync。 */
export async function collectXBookmarks(tabId: number): Promise<BookmarksCollectResult> {
  const tab = await browser.tabs.get(tabId).catch(() => undefined);
  if (!isXBookmarksURL(tab?.url)) return { ok: false, code: "not_bookmarks" };

  const knownIDs = await loadBookmarksCursor();
  let collected: CollectResult;
  try {
    const results = await browser.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: collectXBookmarkIDsInPage,
      // 勾选模式：不因追上已知而早停（streak=0），尽量把列表滚全再让用户挑。
      args: [knownIDs, MAX_BOOKMARK_IDS, 0],
    });
    const raw = results[0]?.result as CollectResult | undefined;
    const items = normalizeBookmarkItems(
      raw?.items
      ?? raw?.ids?.map((id) => ({
        id,
        author: "",
        text: "",
        alreadySynced: knownIDs.includes(id),
      })),
    );
    collected = {
      items,
      ids: items.map((item) => item.id),
      reachedKnown: raw?.reachedKnown === true,
    };
  } catch {
    return { ok: false, code: "injection_failed" };
  }

  if (collected.items.length === 0) return { ok: false, code: "empty" };

  // 以 App 本地历史为准标「已在库」；App 不可达时保留游标粗标。
  const existing = await lookupExistingBookmarkIDs(collected.ids);
  if (existing) {
    const inLibrary = new Set(existing);
    return {
      ok: true,
      items: collected.items.map((item) => ({
        ...item,
        alreadySynced: inLibrary.has(item.id),
      })),
      reachedKnown: collected.reachedKnown,
      libraryLookup: "ok",
    };
  }

  return {
    ok: true,
    items: collected.items,
    reachedKnown: collected.reachedKnown,
    libraryLookup: "unavailable",
  };
}

/** 问 App：这批 id 里哪些已在本地历史。失败返回 null（调用方降级）。 */
async function lookupExistingBookmarkIDs(tweetIDs: string[]): Promise<string[] | null> {
  const ids = tweetIDs.filter(isValidTweetID).slice(0, MAX_BOOKMARK_IDS);
  const message = {
    kind: "xBookmarksLookup",
    version: 1,
    requestId: requestId(),
    tweetIDs: ids,
  };
  try {
    const response: unknown = await withTimeout(
      browser.runtime.sendNativeMessage(HOST_NAME, message),
      15_000,
    );
    return parseBookmarksLookup(response);
  } catch {
    return null;
  }
}

/** 把用户勾选的 id 交给 App；不再二次滚动。 */
export async function enqueueXBookmarkIDs(tweetIDs: unknown): Promise<BookmarksSyncResult> {
  const ids = (Array.isArray(tweetIDs) ? tweetIDs : [])
    .filter(isValidTweetID)
    .slice(0, MAX_BOOKMARK_IDS);
  if (ids.length === 0) return { ok: false, code: "empty" };

  const syncRequestId = requestId();
  const message = { kind: "xBookmarks", version: 1, requestId: syncRequestId, tweetIDs: ids };
  let response: unknown;
  try {
    response = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 30_000);
  } catch (error) {
    return nativeTransportFailure(error);
  }
  const outcome = parseBookmarksAccepted(response);
  if (!outcome) return { ok: false, code: nativeFailureCode(response) };

  await rememberBookmarksCursor(ids);
  return { ok: true, outcome, collected: ids.length, reachedKnown: false };
}

/** 兼容旧入口：收集后立刻全量同步（测试与外部仍可调用）。 */
export async function syncXBookmarks(tabId: number): Promise<BookmarksSyncResult> {
  const collected = await collectXBookmarks(tabId);
  if (!collected.ok) return collected;
  const synced = await enqueueXBookmarkIDs(collected.items.map((item) => item.id));
  if (!synced.ok) return synced;
  return { ...synced, reachedKnown: collected.reachedKnown };
}

export type SingleTweetSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome }
  | { ok: false; code: "invalid_id" | "native_error" | "upgrade_app" };

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
  if (!outcome) return { ok: false, code: nativeFailureCode(response) };
  return { ok: true, outcome };
}

export type ProfileCollectResult =
  | { ok: true; authorID: string; profileURL: string; profileName: string; profileAvatarURL?: string; items: XProfilePreviewItem[] }
  | { ok: false; code: "not_profile" | "empty" | "login" | "injection_failed" };

export type ProfilePresentResult =
  | { ok: true; acceptedCount: number }
  | { ok: false; code: "not_profile" | "empty" | "login" | "injection_failed" | "upgrade_app" }
  | NativeErrorResult;

export async function collectXProfile(tabId: number): Promise<ProfileCollectResult> {
  const tab = await browser.tabs.get(tabId).catch(() => undefined);
  const handle = profileHandleFromURL(tab?.url);
  if (!isXProfileURL(tab?.url) || !handle) return { ok: false, code: "not_profile" };

  let collected: XProfileCollectResult;
  try {
    const results = await browser.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: collectXProfileItemsInPage,
      args: [handle, MAX_X_PROFILE_CANDIDATES],
    });
    collected = results[0]?.result as XProfileCollectResult;
  } catch {
    return { ok: false, code: "injection_failed" };
  }

  if (collected?.loginRequired) return { ok: false, code: "login" };
  const items = normalizeXProfileItems(collected?.items, handle);
  if (items.length === 0) return { ok: false, code: "empty" };
  const rawName = typeof collected?.profileName === "string" ? collected.profileName : "";
  const profileName = resolvedXProfileDisplayName(rawName, handle) ?? "";
  const rawAvatar = typeof collected?.profileAvatarURL === "string" ? collected.profileAvatarURL : "";
  const profileAvatarURL = isPublicTwimgProfileImageURL(rawAvatar) ? rawAvatar.slice(0, 2048) : undefined;
  return {
    ok: true,
    authorID: handle,
    profileURL: canonicalXProfileURL(handle),
    profileName,
    ...(profileAvatarURL ? { profileAvatarURL } : {}),
    items,
  };
}

export async function presentXProfileCandidates(tabId: number): Promise<ProfilePresentResult> {
  const collected = await collectXProfile(tabId);
  if (!collected.ok) return collected;

  const message = {
    kind: X_PROFILE_CANDIDATES_KIND,
    version: 1 as const,
    requestId: requestId(),
    profileURL: collected.profileURL,
    authorID: collected.authorID,
    ...(collected.profileName ? { profileName: collected.profileName } : {}),
    ...(collected.profileAvatarURL ? { profileAvatarURL: collected.profileAvatarURL } : {}),
    items: collected.items,
  };
  if (!validateXProfileSchema(message)) return { ok: false, code: "empty" };

  let response: unknown;
  try {
    response = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 30_000);
  } catch (error) {
    return nativeTransportFailure(error);
  }
  if (response && typeof response === "object") {
    const row = response as { kind?: string; error?: { code?: string; action?: string } };
    if (row.kind === "bookmarksAccepted" || row.kind === "taskAccepted" || row.kind === "bookmarksLookup") {
      return { ok: false, code: "upgrade_app" };
    }
    if (row.kind === "error") {
      return { ok: false, code: nativeFailureCode(response) };
    }
  }
  const presented = parseProfileCandidatesPresented(response);
  if (!validateXProfileSchema(response) || !presented || presented.requestId !== message.requestId
      || presented.acceptedCount > message.items.length) return { ok: false, code: "upgrade_app" };
  return { ok: true, acceptedCount: presented.acceptedCount };
}

function nativeFailureCode(response: unknown): "upgrade_app" | "native_error" {
  if (response && typeof response === "object") {
    const row = response as { kind?: string; error?: { code?: string; action?: string } };
    if (row.kind === "error") {
      if (row.error?.action === "upgrade_app" || row.error?.code === "PROTOCOL_VERSION_UNSUPPORTED") {
        return "upgrade_app";
      }
    }
  }
  return "native_error";
}

export type PageStepState = { step: ProcessStepKey; state: "done" | "running" | "failed" | "notNeeded"; detail?: string };
export type PageStatusResult =
  | { kind: "found"; taskID: string; savedAt?: number; steps: PageStepState[] }
  | { kind: "notFound" }
  /** App 没开、旧版本或读失败：弹窗不显示查重，按平常保存。 */
  | { kind: "unavailable" };

const TASK_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

export function parsePageStatus(response: unknown, expectedRequestId: string): PageStatusResult {
  if (!response || typeof response !== "object") return { kind: "unavailable" };
  const row = response as { kind?: unknown; version?: unknown; requestId?: unknown; status?: unknown };
  if (row.kind !== "pageStatus" || row.version !== 1 || row.requestId !== expectedRequestId) return { kind: "unavailable" };
  const status = row.status as { found?: unknown; taskID?: unknown; savedAtMilliseconds?: unknown; steps?: unknown } | undefined;
  if (!status || typeof status !== "object") return { kind: "unavailable" };
  if (status.found !== true) return { kind: "notFound" };
  if (typeof status.taskID !== "string" || !TASK_ID_PATTERN.test(status.taskID)) return { kind: "unavailable" };
  const steps: PageStepState[] = [];
  for (const raw of Array.isArray(status.steps) ? status.steps : []) {
    const item = raw as { step?: unknown; state?: unknown; detail?: unknown };
    if (!PROCESS_STEP_KEYS.includes(item.step as ProcessStepKey)) continue;
    if (item.state !== "done" && item.state !== "running" && item.state !== "failed" && item.state !== "notNeeded") continue;
    steps.push({
      step: item.step as ProcessStepKey,
      state: item.state,
      ...(typeof item.detail === "string" && item.detail.trim() ? { detail: [...item.detail.trim()].slice(0, 40).join("") } : {}),
    });
  }
  return {
    kind: "found",
    taskID: status.taskID,
    ...(typeof status.savedAtMilliseconds === "number" ? { savedAt: status.savedAtMilliseconds } : {}),
    steps,
  };
}

/** 问 App「这一页存过没有、做到哪了」。Host 只找正在运行的 App，不会把它拉起来。 */
export async function lookupPageStatus(url: unknown): Promise<PageStatusResult> {
  if (typeof url !== "string" || !/^https?:\/\//u.test(url) || url.length > 4_096) return { kind: "unavailable" };
  const message = { kind: "pageStatus", version: 1, requestId: requestId(), url };
  try {
    const response: unknown = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, message), 5_000);
    return parsePageStatus(response, message.requestId);
  } catch {
    return { kind: "unavailable" };
  }
}

export async function openPeerApp(taskID?: unknown): Promise<{ ok: true } | { ok: false; code: "native_error" | "upgrade_app" }> {
  const message = {
    kind: "openApp", version: 1, requestId: requestId(),
    ...(typeof taskID === "string" && TASK_ID_PATTERN.test(taskID) ? { taskID } : {}),
  };
  try {
    const response: unknown = await withTimeout(
      browser.runtime.sendNativeMessage(HOST_NAME, message),
      10_000,
    );
    const normalized = normalizeNativeResponse(response, message.requestId);
    if (normalized.kind === "error") {
      return { ok: false, code: nativeFailureCode(normalized) };
    }
    if (normalized.kind === "openAppAccepted") {
      if (!normalized.supportedVersions.includes(1)) return { ok: false, code: "upgrade_app" };
      return { ok: true };
    }
    if (normalized.kind === "taskAccepted") return { ok: true };
    return { ok: false, code: "native_error" };
  } catch {
    return { ok: false, code: "native_error" };
  }
}

export default defineBackground(() => {
  browser.runtime.onMessage.addListener(async (
    message: {
      type?: string;
      tabId?: number;
      tweetID?: string;
      tweetIDs?: string[];
      requestedAction?: CaptureRequestedAction;
      selectedCommentIDs?: string[];
      commentMode?: unknown;
      taskID?: unknown;
      url?: unknown;
    },
  ) => {
    // 时间线注入按钮发来的单条同步：只需要 tweetID，不涉及 tabId。
    if (message.type === "sync-single-tweet") return syncSingleTweet(message.tweetID);
    if (message.type === "open-app") return openPeerApp(message.taskID);
    if (message.type === "page-status") return lookupPageStatus(message.url);
    if (message.type === "pipeline-preferences") return capturePreferences();
    // 勾选后提交：只交 id 列表，不再依赖当前 tab 滚动。
    if (message.type === "enqueue-x-bookmarks") return enqueueXBookmarkIDs(message.tweetIDs);
    if (typeof message.tabId !== "number") return undefined;
    if (message.type === "preview-current-page") return previewCurrentPage(message.tabId);
    if (message.type === "collect-comments") return collectCommentsForPicker(message.tabId);
    if (message.type === "send-current-page") {
      const action = message.requestedAction;
      const selected = Array.isArray(message.selectedCommentIDs)
        ? message.selectedCommentIDs.filter((id): id is string => typeof id === "string")
        : undefined;
      return sendCapture(
        message.tabId,
        action === "summarize" || action === "translate" ? action : "save",
        selected,
        parseCommentSendMode(message.commentMode),
      );
    }
    if (message.type === "collect-x-bookmarks") return collectXBookmarks(message.tabId);
    if (message.type === "collect-x-profile") return collectXProfile(message.tabId);
    if (message.type === "present-x-profile-candidates") return presentXProfileCandidates(message.tabId);
    // 旧入口仍保留：一键收集并全量同步。
    if (message.type === "sync-x-bookmarks") return syncXBookmarks(message.tabId);
    return undefined;
  });
});
