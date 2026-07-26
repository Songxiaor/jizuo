/**
 * Xiaohongshu (RED) note recognition. C-class login-wall SPA: the only robust,
 * policy-safe path is to read the note the user is already viewing in their own
 * logged-in session (DOM + og:meta) — never replay the signed `x-s`/`x-t` API.
 * v1 captures the note's public title / author / body as a text record.
 */

/** Host-level recognition, incl. the `xhslink.com` short-link domain. */
export function isXiaohongshuHost(rawURL: string): boolean {
  try {
    const host = new URL(rawURL).hostname.toLowerCase();
    return (
      host === "xiaohongshu.com" ||
      host.endsWith(".xiaohongshu.com") ||
      host === "xhslink.com"
    );
  } catch {
    return false;
  }
}

/** Extract a note id from an explore/discovery URL, when present. */
export function xiaohongshuNoteID(rawURL: string): string | undefined {
  try {
    const url = new URL(rawURL);
    if (!isXiaohongshuHost(rawURL)) return undefined;
    // `/explore/{id}` or `/discovery/item/{id}` — a 24-hex ObjectId.
    const match = url.pathname.match(/\/(?:explore|discovery\/item)\/([0-9a-fA-F]{16,32})/u);
    return match ? match[1] : undefined;
  } catch {
    return undefined;
  }
}

/** True only for a concrete note surface (not the home feed or a user profile). */
export function isXiaohongshuNoteURL(rawURL: string): boolean {
  return xiaohongshuNoteID(rawURL) !== undefined;
}

/** Stable public note page for storage / History (falls back to the raw URL). */
export function xiaohongshuCanonicalURL(rawURL: string): string {
  const id = xiaohongshuNoteID(rawURL);
  return id ? `https://www.xiaohongshu.com/explore/${id}` : rawURL;
}

/**
 * 视频笔记的播放地址：页面上的 `<video>` 走 MSE，`src` 是 blob，扩展拿不到真实
 * 流。小红书把整段 mp4 的地址放在 MAIN world 的 `window.__INITIAL_STATE__` 里，
 * 那是页面自己已经水合好的公开数据——读它不需要 cookie、不调签名接口。
 */
export type XiaohongshuVideoStream = {
  url: string;
  /** 官方给的备份地址，主地址失败时按序回退。 */
  backupURLs: string[];
  durationSeconds?: number;
  sizeBytes?: number;
  expiresAt?: string;
};

/**
 * 自包含（供 `browser.scripting.executeScript` 注入 MAIN world）。编解码优先
 * h264：AVFoundation 对它最稳，h265/av1 在旧机型上可能解不出来。
 */
export function readXiaohongshuVideoStreamInMainWorld(noteID: string): XiaohongshuVideoStream | null {
  try {
    const state = (window as unknown as { __INITIAL_STATE__?: Record<string, unknown> }).__INITIAL_STATE__;
    const noteMap = (state?.note as Record<string, unknown> | undefined)?.noteDetailMap as
      Record<string, { note?: Record<string, unknown> }> | undefined;
    const note = noteMap?.[noteID]?.note;
    if (!note || note.type !== "video") return null;
    const video = note.video as Record<string, unknown> | undefined;
    const stream = (video?.media as Record<string, unknown> | undefined)?.stream as
      Record<string, unknown> | undefined;
    if (!stream) return null;

    // SSR 给的是 http，同一资源换 https 可取（实测 206，无需 Referer / cookie）。
    const mediaURL = (raw: unknown): string => {
      if (typeof raw !== "string") return "";
      const trimmed = raw.trim();
      if (!trimmed || trimmed.length > 4096) return "";
      try {
        const url = new URL(trimmed);
        if (url.protocol === "http:") url.protocol = "https:";
        if (url.protocol !== "https:") return "";
        if (url.port !== "") return "";
        const host = url.hostname.toLowerCase();
        if (host !== "xhscdn.com" && !host.endsWith(".xhscdn.com")) return "";
        return url.href;
      } catch {
        return "";
      }
    };
    // 地址带限时签名，`t` 是十六进制的秒级 Unix 时间戳，过期后取不到。
    const expiryOf = (url: string): string | undefined => {
      try {
        const raw = new URL(url).searchParams.get("t");
        if (!raw || !/^[0-9a-f]{6,12}$/iu.test(raw)) return undefined;
        const seconds = Number.parseInt(raw, 16);
        if (!Number.isSafeInteger(seconds) || seconds < 1_600_000_000 || seconds > 4_102_444_800) return undefined;
        return new Date(seconds * 1_000).toISOString();
      } catch {
        return undefined;
      }
    };

    const capaDuration = Number(((video?.capa as Record<string, unknown> | undefined)?.duration) ?? NaN);
    for (const codec of ["h264", "h265", "av1"]) {
      const entries = stream[codec];
      if (!Array.isArray(entries)) continue;
      for (const raw of entries.slice(0, 4)) {
        const entry = raw as Record<string, unknown> | undefined;
        if (!entry || typeof entry !== "object") continue;
        const urls: string[] = [];
        const push = (value: unknown) => {
          const url = mediaURL(value);
          if (url && !urls.includes(url)) urls.push(url);
        };
        push(entry.masterUrl);
        if (Array.isArray(entry.backupUrls)) for (const backup of entry.backupUrls.slice(0, 8)) push(backup);
        if (urls.length === 0) continue;
        const entryDuration = Number(entry.duration);
        const durationSeconds = Number.isFinite(capaDuration) && capaDuration > 0
          ? capaDuration
          : Number.isFinite(entryDuration) && entryDuration > 0 ? entryDuration / 1_000 : undefined;
        const size = Number(entry.size);
        const expiresAt = expiryOf(urls[0]!);
        return {
          url: urls[0]!,
          backupURLs: urls.slice(1),
          ...(durationSeconds ? { durationSeconds } : {}),
          ...(Number.isSafeInteger(size) && size > 0 ? { sizeBytes: size } : {}),
          ...(expiresAt ? { expiresAt } : {}),
        };
      }
    }
    return null;
  } catch {
    return null;
  }
}
