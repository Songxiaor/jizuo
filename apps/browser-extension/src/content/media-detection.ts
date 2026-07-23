import type {
  MediaDescriptor,
  MediaFailureReason,
  MediaKind,
  TranscriptionCapability,
} from "../contract";

export type MediaCandidate = {
  sourceURL?: string;
  mimeType?: string;
  playing: boolean;
  recentlyInteracted: boolean;
  visibleArea: number;
  viewportCenterDistance: number;
  playbackState: NonNullable<MediaDescriptor["playbackState"]>;
};

export type ClassifiedMedia = {
  kind: MediaKind;
  transcriptionCapability: TranscriptionCapability;
  failureReason?: MediaFailureReason;
  ephemeralPlaybackURL?: string;
};

export type MediaSelection =
  | { index: number; selectionReason: NonNullable<MediaDescriptor["selectionReason"]> }
  | { failureReason: "multiple_candidates"; selectionReason: "ambiguous" };

export const MAX_MEDIA_CANDIDATES = 1000;

export function classifyMediaSource(
  sourceURL: string | undefined,
  mimeType: string | undefined,
  state: { readyState?: number; encrypted?: boolean } = {},
): ClassifiedMedia {
  if (state.encrypted) {
    return { kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "drm_or_encrypted" };
  }
  const source = sourceURL?.trim();
  if (source?.startsWith("blob:") || source?.startsWith("mediasource:") || source?.startsWith("data:")) {
    return { kind: "browserSessionOnly", transcriptionCapability: "unavailable", failureReason: "blob_or_mse" };
  }
  if (!source) {
    return {
      kind: "browserSessionOnly",
      transcriptionCapability: "unavailable",
      failureReason: (state.readyState ?? 0) === 0 ? "video_not_loaded" : "no_transferable_source",
    };
  }
  let url: URL;
  try { url = new URL(source); } catch {
    return { kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "unknown" };
  }
  if (url.protocol !== "https:") {
    return { kind: "browserSessionOnly", transcriptionCapability: "unavailable", failureReason: "browser_session_required" };
  }
  const type = (mimeType ?? "").toLowerCase().split(";", 1)[0]?.trim() ?? "";
  const path = url.pathname.toLowerCase();
  const hostname = url.hostname.toLowerCase();
  const isDouyinVODHost = hostname === "douyinvod.com" || hostname.endsWith(".douyinvod.com");
  const isDouyinPlayPath = /^\/aweme\/v1\/(?:web\/)?play(?:\/|$)/u.test(path);
  if (path.endsWith(".m3u8") || type === "application/vnd.apple.mpegurl" || type === "application/x-mpegurl") {
    return { kind: "hls", transcriptionCapability: "conditional", ephemeralPlaybackURL: url.toString() };
  }
  if (path.endsWith(".mp4") || path.endsWith(".mov") || type === "video/mp4" || type === "video/quicktime" || isDouyinVODHost || isDouyinPlayPath) {
    return { kind: "directFile", transcriptionCapability: "supported", ephemeralPlaybackURL: url.toString() };
  }
  return { kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "unsupported_media_type" };
}

export function selectMediaCandidate(candidates: MediaCandidate[]): MediaSelection {
  if (candidates.length === 1) return { index: 0, selectionReason: "singleCandidate" };
  let pool = candidates.map((_, index) => index);

  const playing = pool.filter((index) => candidates[index]?.playing);
  if (playing.length === 1) return { index: playing[0]!, selectionReason: "playing" };
  if (playing.length > 1) pool = playing;

  const interacted = pool.filter((index) => candidates[index]?.recentlyInteracted);
  if (interacted.length === 1) return { index: interacted[0]!, selectionReason: "recentInteraction" };
  if (interacted.length > 1) pool = interacted;

  let maxArea = Number.NEGATIVE_INFINITY;
  for (const index of pool) maxArea = Math.max(maxArea, candidates[index]?.visibleArea ?? 0);
  const largest = pool.filter((index) => candidates[index]?.visibleArea === maxArea);
  if (largest.length === 1) return { index: largest[0]!, selectionReason: "largestVisibleArea" };
  pool = largest;

  let minDistance = Number.POSITIVE_INFINITY;
  for (const index of pool) minDistance = Math.min(minDistance, candidates[index]?.viewportCenterDistance ?? Number.POSITIVE_INFINITY);
  const nearest = pool.filter((index) => candidates[index]?.viewportCenterDistance === minDistance);
  if (nearest.length === 1) return { index: nearest[0]!, selectionReason: "nearestViewportCenter" };
  return { failureReason: "multiple_candidates", selectionReason: "ambiguous" };
}

/**
 * Self-contained current-page detector for `browser.scripting.executeScript`.
 * It reads only the active DOM and public video/source attributes. No network,
 * Cookie, credential, Profile, private endpoint, or persistent event listener.
 */
export function detectMediaInPage(documentLike: Document = document): MediaDescriptor | undefined {
  const pageURL = documentLike.location.href;

  const platformFor = (rawURL: string): MediaDescriptor["platform"] => {
    try {
      const host = new URL(rawURL).hostname.toLowerCase();
      if (host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")) return "x";
      if (host === "youtube.com" || host.endsWith(".youtube.com") || host === "youtu.be") return "youtube";
      if (host === "mp.weixin.qq.com") return "wechat";
      if (host === "xiaohongshu.com" || host.endsWith(".xiaohongshu.com")) return "xiaohongshu";
      if (host === "douyin.com" || host.endsWith(".douyin.com") || host === "iesdouyin.com" || host.endsWith(".iesdouyin.com")) return "douyin";
      if (host === "bilibili.com" || host.endsWith(".bilibili.com")) return "bilibili";
      if (host === "github.com" || host.endsWith(".github.com")) return "github";
    } catch { /* generic */ }
    return "generic";
  };

  const canonicalCandidate = documentLike.querySelector("link[rel='canonical']")?.getAttribute("href")?.trim();
  let canonicalURL = pageURL;
  if (canonicalCandidate) {
    try {
      const resolved = new URL(canonicalCandidate, pageURL);
      if (resolved.protocol === "http:" || resolved.protocol === "https:") canonicalURL = resolved.toString();
    } catch { /* retain page URL */ }
  }

  const videoNodes = documentLike.querySelectorAll("video");
  if (videoNodes.length === 0) return undefined;
  // Keep the limit local because this function is serialized into the page by
  // browser.scripting.executeScript and cannot close over module constants.
  const maximumMediaCandidates = 1000;
  if (videoNodes.length > maximumMediaCandidates) {
    return {
      kind: "unsupported",
      pageURL,
      canonicalURL,
      platform: platformFor(pageURL),
      transcriptionCapability: "unavailable",
      failureReason: "multiple_candidates",
      selectionReason: "ambiguous",
      playbackState: "unknown",
    };
  }
  const videos = Array.from(videoNodes) as HTMLVideoElement[];
  const viewportWidth = documentLike.defaultView?.innerWidth ?? 0;
  const viewportHeight = documentLike.defaultView?.innerHeight ?? 0;
  const activeElement = documentLike.activeElement;

  const candidates = videos.map((video) => {
    const sourceNode = video.querySelector("source");
    const sourceURL = video.currentSrc || video.src || video.getAttribute("src") || sourceNode?.getAttribute("src") || undefined;
    const mimeType = video.getAttribute("type") || sourceNode?.getAttribute("type") || undefined;
    const rect = video.getBoundingClientRect();
    const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
    const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
    const centerX = (rect.left + rect.right) / 2;
    const centerY = (rect.top + rect.bottom) / 2;
    const distance = Math.hypot(centerX - viewportWidth / 2, centerY - viewportHeight / 2);
    const playbackState: NonNullable<MediaDescriptor["playbackState"]> = video.ended
      ? "ended"
      : video.readyState === 0
        ? "notLoaded"
        : video.paused
          ? "paused"
          : "playing";
    return {
      sourceURL,
      mimeType,
      playing: !video.paused && !video.ended && video.readyState > 0,
      recentlyInteracted: activeElement === video || (activeElement != null && video.contains(activeElement)),
      visibleArea: visibleWidth * visibleHeight,
      viewportCenterDistance: distance,
      playbackState,
      video,
    };
  });

  let pool = candidates.map((_, index) => index);
  let selectedIndex: number | undefined;
  let selectionReason: NonNullable<MediaDescriptor["selectionReason"]> = "ambiguous";
  if (pool.length === 1) {
    selectedIndex = 0;
    selectionReason = "singleCandidate";
  } else {
    const playing = pool.filter((index) => candidates[index]!.playing);
    if (playing.length === 1) { selectedIndex = playing[0]; selectionReason = "playing"; }
    else {
      if (playing.length > 1) pool = playing;
      const interacted = pool.filter((index) => candidates[index]!.recentlyInteracted);
      if (interacted.length === 1) { selectedIndex = interacted[0]; selectionReason = "recentInteraction"; }
      else {
        if (interacted.length > 1) pool = interacted;
        let maxArea = Number.NEGATIVE_INFINITY;
        for (const index of pool) maxArea = Math.max(maxArea, candidates[index]!.visibleArea);
        const largest = pool.filter((index) => candidates[index]!.visibleArea === maxArea);
        if (largest.length === 1) { selectedIndex = largest[0]; selectionReason = "largestVisibleArea"; }
        else {
          pool = largest;
          let minDistance = Number.POSITIVE_INFINITY;
          for (const index of pool) minDistance = Math.min(minDistance, candidates[index]!.viewportCenterDistance);
          const nearest = pool.filter((index) => candidates[index]!.viewportCenterDistance === minDistance);
          if (nearest.length === 1) { selectedIndex = nearest[0]; selectionReason = "nearestViewportCenter"; }
        }
      }
    }
  }

  const platform = platformFor(pageURL);
  if (selectedIndex === undefined) {
    return {
      kind: "unsupported",
      pageURL,
      canonicalURL,
      platform,
      transcriptionCapability: "unavailable",
      failureReason: "multiple_candidates",
      candidateCount: candidates.length,
      selectionReason: "ambiguous",
      playbackState: "unknown",
    };
  }

  const selected = candidates[selectedIndex]!;
  const source = selected.sourceURL?.trim();
  const type = (selected.mimeType ?? "").toLowerCase().split(";", 1)[0]?.trim() ?? "";
  let kind: MediaKind;
  let transcriptionCapability: TranscriptionCapability;
  let failureReason: MediaFailureReason | undefined;
  let ephemeralPlaybackURL: string | undefined;
  const encrypted = selected.video.mediaKeys != null;
  if (encrypted) {
    kind = "unsupported"; transcriptionCapability = "unavailable"; failureReason = "drm_or_encrypted";
  } else if (source?.startsWith("blob:") || source?.startsWith("mediasource:") || source?.startsWith("data:")) {
    kind = "browserSessionOnly"; transcriptionCapability = "unavailable"; failureReason = "blob_or_mse";
  } else if (!source) {
    kind = "browserSessionOnly"; transcriptionCapability = "unavailable";
    failureReason = selected.video.readyState === 0 ? "video_not_loaded" : "no_transferable_source";
  } else {
    let parsed: URL | undefined;
    try { parsed = new URL(source); } catch { parsed = undefined; }
    if (!parsed) {
      kind = "unsupported"; transcriptionCapability = "unavailable"; failureReason = "unknown";
    } else if (parsed.protocol !== "https:") {
      kind = "browserSessionOnly"; transcriptionCapability = "unavailable"; failureReason = "browser_session_required";
    } else if (parsed.pathname.toLowerCase().endsWith(".m3u8") || type === "application/vnd.apple.mpegurl" || type === "application/x-mpegurl") {
      kind = "hls"; transcriptionCapability = "conditional"; ephemeralPlaybackURL = parsed.toString();
    } else {
      const path = parsed.pathname.toLowerCase();
      const hostname = parsed.hostname.toLowerCase();
      const isDouyinVODHost = hostname === "douyinvod.com" || hostname.endsWith(".douyinvod.com");
      const isDouyinPlayPath = /^\/aweme\/v1\/(?:web\/)?play(?:\/|$)/u.test(path);
      if (path.endsWith(".mp4") || path.endsWith(".mov") || type === "video/mp4" || type === "video/quicktime" || isDouyinVODHost || isDouyinPlayPath) {
        kind = "directFile"; transcriptionCapability = "supported"; ephemeralPlaybackURL = parsed.toString();
      } else {
        kind = "unsupported"; transcriptionCapability = "unavailable"; failureReason = "unsupported_media_type";
      }
    }
  }

  const posterRaw = selected.video.poster || selected.video.getAttribute("poster") || undefined;
  let posterURL: string | undefined;
  if (posterRaw) {
    try {
      const parsed = new URL(posterRaw, pageURL);
      if (parsed.protocol === "https:") posterURL = parsed.toString();
    } catch { /* omit */ }
  }
  const durationSeconds = Number.isFinite(selected.video.duration) && selected.video.duration > 0
    ? selected.video.duration
    : undefined;
  const author = documentLike.querySelector("meta[name='author']")?.getAttribute("content")?.trim()
    || documentLike.querySelector("meta[property='article:author']")?.getAttribute("content")?.trim()
    || undefined;

  return {
    kind,
    pageURL,
    canonicalURL,
    platform,
    ...(ephemeralPlaybackURL ? { ephemeralPlaybackURL } : {}),
    ...(selected.mimeType ? { mimeType: selected.mimeType } : {}),
    ...(posterURL ? { posterURL } : {}),
    ...(durationSeconds ? { durationSeconds } : {}),
    ...(author ? { author } : {}),
    transcriptionCapability,
    ...(failureReason ? { failureReason } : {}),
    candidateCount: candidates.length,
    selectionReason,
    playbackState: selected.playbackState,
  };
}
