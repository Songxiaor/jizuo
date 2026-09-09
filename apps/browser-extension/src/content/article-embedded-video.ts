/**
 * 长文里穿插的视频：YouTube / B 站 / Vimeo / Mux / 直连文件。
 *
 * 产出写进正文的 `<!--LDVIDEO ... -->` 标记，阅读区按原位置渲染。
 * 不写入临时签名地址；页面主视频（YouTube 观看页、B 站投稿页）不重复占位。
 */

export type ArticleEmbeddedVideoKind =
  | "youtube"
  | "bilibili"
  | "vimeo"
  | "mux"
  | "direct"
  | "unknown";

export type ArticleEmbeddedVideo = {
  kind: ArticleEmbeddedVideoKind;
  platform: string;
  id?: string;
  url?: string;
  title?: string | undefined;
};

const YOUTUBE_ID = /^[A-Za-z0-9_-]{6,20}$/u;
const BILIBILI_ID = /^(?:BV[0-9A-Za-z]{10}|av\d+)$/u;
const VIMEO_ID = /^\d{6,12}$/u;
const MUX_ID = /^[A-Za-z0-9]{8,}$/u;

export function articleVideoMarkdown(el: Element, baseHref: string): string | null {
  const classified = classifyArticleVideo(el, baseHref);
  if (classified === null) return null;
  if (classified === "drop") return "";
  if (isPrimaryWatchSurface(baseHref, classified)) return "";
  return `\n\n${serializeArticleVideoMarker(classified)}\n\n`;
}

export function classifyArticleVideo(
  el: Element,
  baseHref: string,
): ArticleEmbeddedVideo | "drop" | null {
  const tag = el.tagName.toLowerCase();
  const title = videoTitle(el);

  if (tag === "lite-youtube") {
    const id = (el.getAttribute("videoid") ?? el.getAttribute("video-id") ?? "").trim();
    if (!YOUTUBE_ID.test(id)) return "drop";
    return {
      kind: "youtube",
      platform: "youtube",
      id,
      url: `https://www.youtube.com/watch?v=${id}`,
      title,
    };
  }

  if (tag === "iframe") {
    const raw = iframeSource(el);
    if (!raw) return "drop";
    const absolute = absoluteHTTPS(raw, baseHref);
    if (!absolute) return "drop";
    return classifyEmbedURL(absolute, title) ?? "drop";
  }

  if (tag === "video") {
    if (isTrivialVideo(el)) return "drop";
    const source = videoSource(el);
    const absolute = source ? absoluteHTTPS(source, baseHref) : undefined;
    if (absolute) {
      const embed = classifyEmbedURL(absolute, title);
      if (embed && embed.kind !== "direct") return embed;
      if (isPersistableMediaURL(absolute) && isDirectMediaURL(absolute)) {
        return { kind: "direct", platform: "generic", url: stripFragileQuery(absolute), title };
      }
    }
    return { kind: "unknown", platform: "generic", title };
  }

  return null;
}

export function serializeArticleVideoMarker(video: ArticleEmbeddedVideo): string {
  const parts = [`kind="${escapeAttr(video.kind)}"`, `platform="${escapeAttr(video.platform)}"`];
  if (video.id) parts.push(`id="${escapeAttr(video.id)}"`);
  if (video.url) parts.push(`url="${escapeAttr(video.url)}"`);
  if (video.title) parts.push(`title="${escapeAttr(video.title)}"`);
  return `<!--LDVIDEO ${parts.join(" ")} -->`;
}

export function isPersistableMediaURL(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") return false;
  if (url.username || url.password) return false;
  return !hasCredentialQuery(url);
}

function classifyEmbedURL(raw: string, title?: string): ArticleEmbeddedVideo | undefined {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:") return undefined;
  const host = url.hostname.toLowerCase().replace(/^www\./u, "");

  const youtubeID = youtubeVideoID(url);
  if (youtubeID) {
    return {
      kind: "youtube",
      platform: "youtube",
      id: youtubeID,
      url: `https://www.youtube.com/watch?v=${youtubeID}`,
      title,
    };
  }

  const bilibiliID = bilibiliEmbedID(url);
  if (bilibiliID) {
    return {
      kind: "bilibili",
      platform: "bilibili",
      id: bilibiliID,
      url: `https://www.bilibili.com/video/${bilibiliID}`,
      title,
    };
  }

  if (host === "player.vimeo.com" || host === "vimeo.com") {
    const id = url.pathname.split("/").filter(Boolean).at(-1) ?? "";
    if (VIMEO_ID.test(id)) {
      return {
        kind: "vimeo",
        platform: "vimeo",
        id,
        url: `https://vimeo.com/${id}`,
        title,
      };
    }
  }

  if (host === "player.mux.com" || host === "stream.mux.com") {
    const id = (url.pathname.split("/").filter(Boolean)[0] ?? "").replace(/\.(?:m3u8|mp4)$/iu, "");
    if (MUX_ID.test(id) && isPersistableMediaURL(url.toString())) {
      return {
        kind: "mux",
        platform: "generic",
        id,
        url: `https://player.mux.com/${id}`,
        title,
      };
    }
  }

  if (isPersistableMediaURL(url.toString()) && isDirectMediaURL(url.toString())) {
    return { kind: "direct", platform: "generic", url: stripFragileQuery(url.toString()), title };
  }
  return undefined;
}

function youtubeVideoID(url: URL): string | undefined {
  const host = url.hostname.toLowerCase().replace(/^www\.|^m\./u, "");
  if (host === "youtu.be") {
    const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
    return YOUTUBE_ID.test(id) ? id : undefined;
  }
  if (host !== "youtube.com" && !host.endsWith(".youtube.com") && host !== "youtube-nocookie.com") {
    return undefined;
  }
  if (url.pathname === "/watch") {
    const id = url.searchParams.get("v") ?? "";
    return YOUTUBE_ID.test(id) ? id : undefined;
  }
  const embed = url.pathname.match(/^\/(?:embed|shorts|live)\/([A-Za-z0-9_-]{6,20})(?:\/|$)/u);
  return embed && YOUTUBE_ID.test(embed[1]!) ? embed[1] : undefined;
}

function bilibiliEmbedID(url: URL): string | undefined {
  const host = url.hostname.toLowerCase().replace(/^www\.|^m\./u, "");
  if (host === "player.bilibili.com") {
    const bvid = url.searchParams.get("bvid") ?? "";
    if (BILIBILI_ID.test(bvid)) return bvid;
    const aid = url.searchParams.get("aid") ?? "";
    if (/^\d+$/u.test(aid)) return `av${aid}`;
    return undefined;
  }
  if (host !== "bilibili.com") return undefined;
  const match = url.pathname.match(/^\/video\/(BV[0-9A-Za-z]{10}|av\d+)/u);
  return match?.[1];
}

function isPrimaryWatchSurface(baseHref: string, video: ArticleEmbeddedVideo): boolean {
  let page: URL;
  try {
    page = new URL(baseHref);
  } catch {
    return false;
  }
  if (video.kind === "youtube" && video.id && youtubeVideoID(page) === video.id) return true;
  if (video.kind === "bilibili" && video.id && bilibiliEmbedID(page) === video.id) return true;
  return false;
}

function iframeSource(el: Element): string {
  return (el.getAttribute("src") ?? el.getAttribute("data-src") ?? "").trim();
}

function videoSource(el: Element): string {
  const own = (el.getAttribute("src") ?? "").trim();
  if (own) return own;
  const source = el.querySelector?.("source");
  return (source?.getAttribute("src") ?? "").trim();
}

function videoTitle(el: Element): string | undefined {
  const raw = (
    el.getAttribute("title")
    ?? el.getAttribute("aria-label")
    ?? el.getAttribute("alt")
    ?? ""
  ).replace(/\s+/gu, " ").trim();
  if (!raw) return undefined;
  return raw.slice(0, 120);
}

function isTrivialVideo(el: Element): boolean {
  const width = Number(el.getAttribute("width") ?? "");
  const height = Number(el.getAttribute("height") ?? "");
  if (Number.isFinite(width) && width > 0 && width < 64) return true;
  if (Number.isFinite(height) && height > 0 && height < 64) return true;
  return false;
}

function absoluteHTTPS(raw: string, baseHref: string): string | undefined {
  try {
    const url = new URL(raw, baseHref);
    return url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function isDirectMediaURL(raw: string): boolean {
  try {
    const url = new URL(raw);
    const path = url.pathname.toLowerCase();
    return /\.(?:mp4|mov|m4v|webm|m3u8)$/u.test(path);
  } catch {
    return false;
  }
}

function hasCredentialQuery(url: URL): boolean {
  for (const [key] of url.searchParams) {
    if (/^(?:signature|sig|token|expires?|expiry|ossaccesskeyid|x-amz-signature|x-amz-credential|x-amz-expires|auth_key|verify)$/iu.test(key)) {
      return true;
    }
  }
  return false;
}

function stripFragileQuery(raw: string): string {
  try {
    const url = new URL(raw);
    url.hash = "";
    return url.toString();
  } catch {
    return raw;
  }
}

function escapeAttr(value: string): string {
  return value
    .replace(/&/gu, "&amp;")
    .replace(/"/gu, "&quot;")
    .replace(/</gu, "")
    .replace(/>/gu, "")
    .replace(/\s+/gu, " ")
    .trim();
}
