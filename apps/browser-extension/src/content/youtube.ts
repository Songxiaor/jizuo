/**
 * YouTube single-video capture. Same seam as the Douyin adapter: the page the
 * user is watching is the only source — no private endpoints, no yt-dlp, no
 * login-wall bypass. Captions come from the video's own public timedtext
 * track exposed by the player response; videos without captions degrade to
 * metadata + description.
 */

export function youTubeVideoID(rawURL: string): string | undefined {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return undefined;
  }
  const host = url.hostname.toLowerCase().replace(/^www\.|^m\./, "");
  const idPattern = /^[A-Za-z0-9_-]{6,20}$/;
  if (host === "youtu.be") {
    const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
    return idPattern.test(id) ? id : undefined;
  }
  if (host === "youtube.com" || host.endsWith(".youtube.com")) {
    if (url.pathname === "/watch") {
      const id = url.searchParams.get("v") ?? "";
      return idPattern.test(id) ? id : undefined;
    }
    const shorts = url.pathname.match(/^\/shorts\/([A-Za-z0-9_-]{6,20})/);
    if (shorts?.[1]) return shorts[1];
    const live = url.pathname.match(/^\/live\/([A-Za-z0-9_-]{6,20})/);
    if (live?.[1]) return live[1];
  }
  return undefined;
}

export function isYouTubeWatchURL(rawURL: string): boolean {
  return youTubeVideoID(rawURL) !== undefined;
}

export function isYouTubeHost(rawURL: string): boolean {
  try {
    const host = new URL(rawURL).hostname.toLowerCase();
    return host === "youtu.be" || host === "youtube.com" || host.endsWith(".youtube.com");
  } catch {
    return false;
  }
}

export function youTubeThumbnailURL(videoID: string): string {
  return `https://i.ytimg.com/vi/${videoID}/hqdefault.jpg`;
}

export function isYouTubeThumbnailURL(raw: string): boolean {
  try {
    const url = new URL(raw);
    const host = url.hostname.toLowerCase();
    return url.protocol === "https:"
      && !url.username
      && !url.password
      && (!url.port || url.port === "443")
      && (host === "i.ytimg.com" || host === "img.youtube.com" || host.endsWith(".ytimg.com"));
  } catch {
    return false;
  }
}

export function youTubeCanonicalURL(videoID: string): string {
  return `https://www.youtube.com/watch?v=${videoID}`;
}

export type YouTubeCaptionTrack = {
  baseUrl: string;
  languageCode: string;
  /** "asr" marks auto-generated speech recognition tracks. */
  kind?: string;
  /** 播放器里显示的名字，如「中文（中国）」：文字记录面板的语言菜单按它认轨。 */
  name?: string;
};

/**
 * Prefer the viewer-relevant language, and human-authored tracks over ASR
 * within the same language: zh variants → en → first available.
 */
export function pickCaptionTrack(tracks: YouTubeCaptionTrack[]): YouTubeCaptionTrack | undefined {
  const usable = tracks.filter((track) => typeof track.baseUrl === "string" && track.baseUrl.length > 0);
  if (usable.length === 0) return undefined;
  const rank = (track: YouTubeCaptionTrack): number => {
    const language = (track.languageCode || "").toLowerCase();
    const authored = track.kind !== "asr" ? 0 : 1;
    // 简体在前：繁体字幕存进来还得再转一道（2026-09-29 实测 3Blue1Brown 选中了 zh-Hant）。
    // 不带地区的「zh」可能是繁体（3Blue1Brown 就是），明确的简体轨排它前面。
    if (/^zh-(?:hans|cn|sg)$/u.test(language)) return 0 + authored;
    if (language === "zh") return 2 + authored;
    if (language.startsWith("zh")) return 4 + authored;
    if (language.startsWith("en")) return 10 + authored;
    return 20 + authored;
  };
  return [...usable].sort((a, b) => rank(a) - rank(b))[0];
}

type JSON3Event = {
  tStartMs?: number;
  segs?: Array<{ utf8?: string }>;
};

/**
 * timedtext `fmt=json3` → readable paragraphs. Caption cues are subtitle-sized
 * fragments; a speech gap of >= 4s starts a new paragraph, everything else
 * joins CJK-aware (no space inside CJK, single space around Latin).
 */
export function transcriptFromJSON3(payload: unknown): string {
  const events = (payload as { events?: JSON3Event[] } | null)?.events;
  if (!Array.isArray(events)) return "";
  const paragraphs: string[] = [];
  let current = "";
  let previousStart: number | undefined;
  for (const event of events) {
    const piece = (event.segs ?? [])
      .map((seg) => seg.utf8 ?? "")
      .join("")
      .replace(/\s+/g, " ")
      .trim();
    if (!piece) continue;
    const start = typeof event.tStartMs === "number" ? event.tStartMs : undefined;
    if (current && previousStart !== undefined && start !== undefined && start - previousStart >= 4000) {
      paragraphs.push(current);
      current = "";
    }
    current = joinCJKAware(current, piece);
    if (start !== undefined) previousStart = start;
  }
  if (current) paragraphs.push(current);
  return paragraphs.join("\n\n").trim();
}

function joinCJKAware(left: string, right: string): string {
  if (!left) return right;
  if (!right) return left;
  // 区间写成转义而不是字面量：起点 U+3000 是全角空格，直接写进源码时既被
  // no-irregular-whitespace 判为错误，也没人能一眼看出那是个字符而不是缩进。
  // 区间本身没变：CJK 标点、汉字、全角字符。
  const isCJK = (char: string) => /[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]/u.test(char);
  const needsSpace = !isCJK(left[left.length - 1]!) || !isCJK(right[0]!);
  return left + (needsSpace ? " " : "") + right;
}

export type YouTubeCaptureFields = {
  title: string;
  author?: string;
  published?: string;
  likes?: string;
  views?: string;
  description?: string;
  transcript?: string;
  canonicalURL: string;
  coverImage?: string;
};

/** Frontmatter keys mirror the Douyin capture so the App parses them as-is. */
export function buildYouTubeMarkdown(fields: YouTubeCaptureFields): string {
  const lines: string[] = ["---"];
  if (fields.author) lines.push(`author: ${JSON.stringify(fields.author)}`);
  if (fields.published) lines.push(`published: ${JSON.stringify(fields.published)}`);
  const videoID = youTubeVideoID(fields.canonicalURL);
  const cover = (fields.coverImage && isYouTubeThumbnailURL(fields.coverImage)
    ? fields.coverImage
    : undefined)
    || (videoID ? youTubeThumbnailURL(videoID) : undefined);
  if (cover) lines.push(`cover_image: ${JSON.stringify(cover)}`);
  if (fields.likes) lines.push(`likes: ${JSON.stringify(fields.likes)}`);
  // 观看数走 frontmatter，由 App 顶部元数据条以眼睛图标展示，不占正文。
  if (fields.views) lines.push(`views: ${JSON.stringify(fields.views)}`);
  lines.push("---", "", `# ${fields.title}`, "");
  // 字幕是口播视频的正文，排在最前；简介多为推广链接，退居其后。
  const transcript = (fields.transcript ?? "").trim();
  if (transcript) {
    lines.push("## 字幕", "", transcript, "");
  } else {
    lines.push("_该视频未提供字幕，无法直接提取口播文字。_", "");
  }
  const description = (fields.description ?? "").trim();
  if (description) {
    lines.push("## 简介", "", description, "");
  }
  return lines.join("\n").trim();
}

export type YouTubePlayerSnapshot = {
  videoId?: string | undefined;
  title?: string | undefined;
  author?: string | undefined;
  shortDescription?: string | undefined;
  viewCount?: string | undefined;
  publishDate?: string | undefined;
  likeCount?: string | undefined;
  thumbnailURL?: string | undefined;
  captionTracks?: YouTubeCaptionTrack[] | undefined;
};

/**
 * MAIN-world probe. `ytInitialPlayerResponse` on window only reflects the
 * FIRST full page load — SPA navigation (homepage → video) leaves it stale
 * or missing. The player element's `getPlayerResponse()` is the live source,
 * so it is preferred; the window global is the cold-load fallback.
 * Self-contained — browser.scripting serializes just this body.
 */
export function readYouTubePlayerSnapshotInMainWorld(): YouTubePlayerSnapshot | undefined {
  const w = window as unknown as Record<string, unknown>;
  const player = document.getElementById("movie_player") as unknown as
    | { getPlayerResponse?: () => unknown }
    | null;
  const liveResponse =
    typeof player?.getPlayerResponse === "function" ? player.getPlayerResponse() : undefined;
  const playerResponse = (liveResponse ?? w.ytInitialPlayerResponse) as
    | {
        videoDetails?: {
          videoId?: string;
          title?: string;
          author?: string;
          shortDescription?: string;
          viewCount?: string;
          thumbnail?: { thumbnails?: Array<{ url?: string; width?: number }> };
        };
        microformat?: {
          playerMicroformatRenderer?: {
            publishDate?: string;
            likeCount?: string;
          };
        };
        captions?: {
          playerCaptionsTracklistRenderer?: {
            captionTracks?: Array<{
              baseUrl?: string;
              languageCode?: string;
              kind?: string;
              name?: { simpleText?: string; runs?: Array<{ text?: string }> };
            }>;
          };
        };
      }
    | undefined;
  if (!playerResponse || typeof playerResponse !== "object") return undefined;
  const details = playerResponse.videoDetails;
  const micro = playerResponse.microformat?.playerMicroformatRenderer;
  const tracks = playerResponse.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
  let thumbnailURL: string | undefined;
  let bestWidth = -1;
  for (const thumb of details?.thumbnail?.thumbnails ?? []) {
    const raw = thumb.url;
    const width = typeof thumb.width === "number" ? thumb.width : 0;
    if (typeof raw !== "string" || width <= bestWidth) continue;
    try {
      const parsed = new URL(raw);
      const host = parsed.hostname.toLowerCase();
      if (
        parsed.protocol !== "https:"
        || parsed.username
        || parsed.password
        || (parsed.port && parsed.port !== "443")
        || !(host === "i.ytimg.com" || host === "img.youtube.com" || host.endsWith(".ytimg.com"))
      ) continue;
      thumbnailURL = parsed.href;
      bestWidth = width;
    } catch {
      continue;
    }
  }
  return {
    videoId: details?.videoId,
    title: details?.title,
    author: details?.author,
    shortDescription: details?.shortDescription,
    viewCount: details?.viewCount,
    publishDate: micro?.publishDate,
    likeCount: micro?.likeCount,
    ...(thumbnailURL ? { thumbnailURL } : {}),
    captionTracks: tracks
      .filter((track) => typeof track.baseUrl === "string")
      .map((track) => {
        const name = (track.name?.simpleText ?? track.name?.runs?.map((run) => run.text ?? "").join("") ?? "").trim();
        return {
          baseUrl: track.baseUrl as string,
          languageCode: track.languageCode ?? "",
          ...(track.kind ? { kind: track.kind } : {}),
          ...(name ? { name } : {}),
        };
      }),
  };
}

/**
 * ISOLATED-world DOM fallback for watch pages when no player response is
 * reachable. A watch URL must never fall into the generic scraper — that
 * captures the SPA shell (feed, sidebar, avatars) instead of the video.
 */
export function extractYouTubeWatchDOMFallbackInPage(): {
  title?: string;
  author?: string;
  description?: string;
} {
  const clean = (value: string | null | undefined) =>
    (value ?? "").replace(/\s+/g, " ").trim();
  const title =
    clean(document.querySelector("h1.ytd-watch-metadata")?.textContent) ||
    clean(document.title.replace(/\s*-\s*YouTube\s*$/u, ""));
  const author = clean(
    document.querySelector("#owner #channel-name a, ytd-video-owner-renderer #channel-name a")?.textContent,
  );
  const description = clean(
    document.querySelector("#description-inline-expander")?.textContent,
  ).slice(0, 4_000);
  return {
    ...(title ? { title } : {}),
    ...(author ? { author } : {}),
    ...(description ? { description } : {}),
  };
}

/**
 * ISOLATED-world fetch of the caption track. Runs with the page's origin so
 * YouTube's own timedtext endpoint answers exactly as it does for the page.
 * json3 is preferred; some tracks only answer the default XML shape.
 */
export async function fetchYouTubeTranscriptPayloadInPage(
  baseUrl: string,
): Promise<{ format: "json3"; json: unknown } | { format: "xml"; text: string } | undefined> {
  const separator = baseUrl.includes("?") ? "&" : "?";
  try {
    const response = await fetch(`${baseUrl}${separator}fmt=json3`, { credentials: "omit" });
    if (response.ok) {
      const json = (await response.json()) as { events?: unknown[] } | undefined;
      if (Array.isArray(json?.events) && json.events.length > 0) return { format: "json3", json };
    }
  } catch {
    // fall through to XML
  }
  try {
    const response = await fetch(baseUrl, { credentials: "omit" });
    if (response.ok) {
      const text = await response.text();
      if (text.includes("<text")) return { format: "xml", text };
    }
  } catch {
    // no captions reachable
  }
  return undefined;
}

/** Default timedtext XML (`<text start="1.2">…</text>`) → paragraphs. */
export function transcriptFromTimedTextXML(xml: string): string {
  const decode = (value: string) =>
    value
      .replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&apos;/g, "'")
      .replace(/\s+/g, " ")
      .trim();
  const pattern = /<text[^>]*start="([\d.]+)"[^>]*>([\s\S]*?)<\/text>/g;
  const paragraphs: string[] = [];
  let current = "";
  let previousStart: number | undefined;
  for (const match of xml.matchAll(pattern)) {
    const piece = decode(match[2] ?? "");
    if (!piece) continue;
    const start = Number(match[1]) * 1000;
    if (current && previousStart !== undefined && Number.isFinite(start) && start - previousStart >= 4000) {
      paragraphs.push(current);
      current = "";
    }
    current = current ? `${current} ${piece}` : piece;
    if (Number.isFinite(start)) previousStart = start;
  }
  if (current) paragraphs.push(current);
  return paragraphs.join("\n\n").trim();
}

export type YouTubePanelSegment = { time: string; text: string };

/**
 * ISOLATED-world fallback when timedtext is blocked (YouTube 2025 起对
 * /api/timedtext 强制 pot 来源令牌，裸 fetch 返回 200 空体)。改走页面
 * 自己的「文字记录」面板：点开 → 等 segment 渲染 → 读文本 → 关面板。
 * 全程使用页面自身机制与用户会话，只读当前视频的可见内容。
 */
export async function collectYouTubeTranscriptFromPanelInPage(
  wanted?: { name: string; occurrence: number },
): Promise<YouTubePanelSegment[]> {
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
  const panelSelector = 'ytd-engagement-panel-section-list-renderer[target-id*="transcript"]';

  /**
   * 只取 YouTube 自己的字。网页翻译扩展会往字幕行里插译文（2026-09-29 实测 EGO 里的 `<xt-trans>`：
   * 双语模式是「译文 + 原文」，替换模式只把原文留在 `xt-origin` 属性里），直接读 textContent
   * 会把机器译文混进存档。跳过这类外来标签；原文被整个换掉时从 `xt-origin` 取回。
   */
  const ownText = (root: Element | null | undefined): string => {
    if (!root) return "";
    if (!root.childNodes) return root.textContent ?? "";
    let own = "";
    const origins: string[] = [];
    const walk = (node: Node): void => {
      for (const child of Array.from(node.childNodes)) {
        if (child.nodeType === 3) { own += child.textContent ?? ""; continue; }
        if (child.nodeType !== 1) continue;
        const element = child as Element;
        const tag = element.tagName.toLowerCase();
        const origin = element.getAttribute("xt-origin");
        const foreign = origin !== null
          || (tag.includes("-") && !/^(?:yt|ytd|tp-yt)-/u.test(tag))
          || /immersive-translate/u.test(element.getAttribute("class") ?? "");
        if (!foreign) { walk(element); continue; }
        if (origin) origins.push(origin);
      }
    };
    walk(root);
    const text = own.replace(/\s+/g, " ").trim();
    return text || origins.join(" ").replace(/\s+/g, " ").trim();
  };

  const readSegments = (): YouTubePanelSegment[] => {
    // 2025 UI 使用 transcript-segment-view-model；旧 UI 是 ytd-transcript-segment-renderer。
    const modern = [...document.querySelectorAll("transcript-segment-view-model")];
    if (modern.length > 0) {
      return modern.map((el) => ({
        time:
          el.querySelector('div[class*="Timestamp"]:not([class*="A11y"])')?.textContent?.trim() ?? "",
        text: ownText(el.querySelector("span")),
      }));
    }
    return [...document.querySelectorAll("ytd-transcript-segment-renderer")].map((el) => ({
      time: el.querySelector(".segment-timestamp")?.textContent?.trim() ?? "",
      text: ownText(el.querySelector(".segment-text")),
    }));
  };
  const fingerprintOf = (segments: YouTubePanelSegment[]) => segments.map((segment) => segment.text).join("\u0001");

  /**
   * 面板默认显示的语言不跟播放器字幕走（2026-09-29 实测 3Blue1Brown：播放器切到 zh-CN / en，
   * 面板仍是繁体「中文」）。面板底部有自己的语言菜单，选项和 captionTracks 同名同序；
   * 按名字（同名时按第几个）点中挑好的那条轨，等内容换掉再读。菜单不在或找不到就读默认。
   */
  const selectWantedLanguage = async (): Promise<void> => {
    if (!wanted?.name) return;
    const items = [...document.querySelectorAll(`${panelSelector} ytd-transcript-footer-renderer tp-yt-paper-item`)]
      .filter((item) => item.textContent?.replace(/\s+/g, " ").trim() === wanted.name) as HTMLElement[];
    const item = items[wanted.occurrence] ?? items[0];
    if (!item || item.getAttribute("aria-selected") === "true") return;
    const before = fingerprintOf(readSegments());
    item.click();
    for (let attempt = 0; attempt < 20; attempt += 1) {
      await sleep(500);
      const now = fingerprintOf(readSegments());
      if (now && now !== before) return;
    }
  };

  let segments = readSegments();
  const wasOpen = segments.some((segment) => segment.text);
  if (!wasOpen) {
    const findButton = (): HTMLElement | null =>
      (document.querySelector("ytd-video-description-transcript-section-renderer button") as HTMLElement | null) ??
      (document.querySelector('button[aria-label*="transcript" i]') as HTMLElement | null) ??
      (document.querySelector('button[aria-label*="文字记录"]') as HTMLElement | null) ??
      (document.querySelector('button[aria-label*="转写"]') as HTMLElement | null);

    let button = findButton();
    if (!button) {
      (document.querySelector("#description-inline-expander #expand") as HTMLElement | null)?.click();
      await sleep(600);
      button = findButton();
    }
    if (!button) return [];
    button.click();
    for (let attempt = 0; attempt < 24; attempt += 1) {
      await sleep(500);
      if (readSegments().some((segment) => segment.text)) break;
    }
  }

  await selectWantedLanguage();

  let previousFingerprint = "";
  for (let attempt = 0; attempt < 24; attempt += 1) {
    segments = readSegments();
    if (segments.some((segment) => segment.text)) {
      // YouTube 会渐进套用自动翻译；等两次读取完全一致再收，
      // 避免抓到"前半已翻译、后半还是原文"的中间态。
      const fingerprint = fingerprintOf(segments);
      if (fingerprint === previousFingerprint) break;
      previousFingerprint = fingerprint;
    }
    await sleep(500);
  }

  // 面板是抓取的副作用，读完即还原用户界面；用户本来开着的不替他关。
  if (!wasOpen) {
    const closeButton = document.querySelector(
      `${panelSelector} #visibility-button button`,
    ) as HTMLElement | null;
    closeButton?.click();
  }

  return segments.filter((segment) => segment.text);
}

/**
 * 面板 segment（"m:ss" 时间戳）→ 可读正文。
 * 直播字幕（CEA-608 rollup）每条 cue 会重带上一行，逐条做后缀-前缀
 * 重叠去重；">>" 是说话人切换标记，转为换段；≥8s 停顿或超长段落换段。
 */
export function transcriptFromPanelSegments(segments: YouTubePanelSegment[]): string {
  const toSeconds = (stamp: string): number | undefined => {
    const parts = stamp.split(":").map((part) => Number(part));
    if (parts.some((part) => !Number.isFinite(part))) return undefined;
    if (parts.length === 3) return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
    if (parts.length === 2) return parts[0]! * 60 + parts[1]!;
    return undefined;
  };
  // 区间写成转义而不是字面量：起点 U+3000 是全角空格，直接写进源码时既被
  // no-irregular-whitespace 判为错误，也没人能一眼看出那是个字符而不是缩进。
  // 区间本身没变：CJK 标点、汉字、全角字符。
  const isCJK = (char: string) => /[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]/u.test(char);
  // 面板里加载失败的段渲染为重试按钮，其文案不是字幕内容。
  const uiNoise = /^(?:\s*(?:点击重试|轻点即可重试|重试|Tap to retry|Click to retry|Retry|Try again)\s*)+$/iu;
  const stripOverlap = (tail: string, incoming: string): string => {
    // rollup 重叠一般不超过一整行；从长到短找累计尾部与 incoming 头部的
    // 最大公共片段（≥8 字符才视为重叠，避免误删短词）。
    const maximum = Math.min(tail.length, incoming.length, 120);
    for (let length = maximum; length >= 8; length -= 1) {
      if (tail.endsWith(incoming.slice(0, length))) {
        return incoming.slice(length).trim();
      }
    }
    return incoming;
  };

  const paragraphs: string[] = [];
  let current = "";
  // 去重尾巴跨段保留：8s 停顿换段后，rollup 重带的上一行仍要被剥掉。
  let dedupeTail = "";
  let previousStart: number | undefined;
  const flush = () => {
    if (current) paragraphs.push(current);
    current = "";
  };
  for (const segment of segments) {
    const start = toSeconds(segment.time);
    if (uiNoise.test(segment.text)) continue;
    // ">>" 标记说话人切换：先按标记拆成子片段，切换处换段。
    const pieces = segment.text.split(/\s*>>\s*/u).map((piece) => piece.trim());
    pieces.forEach((rawPiece, index) => {
      if (index > 0) flush();
      if (!rawPiece) return;
      const longPause =
        current !== "" && previousStart !== undefined && start !== undefined && start - previousStart >= 8;
      if (longPause || current.length > 600) flush();
      const piece = dedupeTail === "" ? rawPiece : stripOverlap(dedupeTail, rawPiece);
      if (!piece) return;
      const needsSpace =
        current !== "" && (!isCJK(current[current.length - 1] ?? "") || !isCJK(piece[0] ?? ""));
      current = current === "" ? piece : current + (needsSpace ? " " : "") + piece;
      dedupeTail = (dedupeTail + " " + piece).slice(-160);
    });
    if (start !== undefined) previousStart = start;
  }
  flush();
  return paragraphs.join("\n\n").trim();
}

/**
 * MAIN world：把播放器字幕轨切到指定原始语言（captionTracks 内的都是
 * 原始轨；自动翻译不在其中），面板语言跟随播放器轨道。返回切换前的
 * 轨道语言（含翻译语言标记），供抓取完成后恢复用户原状。
 */
export function setYouTubeCaptionTrackInMainWorld(languageCode: string): {
  previousLanguage?: string;
  previousTranslation?: string;
  wasOff: boolean;
} {
  const player = document.getElementById("movie_player") as unknown as {
    getOption?: (module: string, option: string) => unknown;
    setOption?: (module: string, option: string, value: unknown) => void;
    loadModule?: (module: string) => void;
  } | null;
  if (!player?.setOption) return { wasOff: true };
  const previous = (player.getOption?.("captions", "track") ?? {}) as {
    languageCode?: string;
    translationLanguage?: { languageCode?: string };
  };
  const wasOff = !previous?.languageCode;
  try { player.loadModule?.("captions"); } catch { /* already loaded */ }
  try { player.setOption("captions", "track", { languageCode }); } catch { /* keep whatever is on */ }
  return {
    ...(previous?.languageCode ? { previousLanguage: previous.languageCode } : {}),
    ...(previous?.translationLanguage?.languageCode
      ? { previousTranslation: previous.translationLanguage.languageCode }
      : {}),
    wasOff,
  };
}

/** MAIN world：抓取结束后恢复用户此前的字幕状态（含关闭态与翻译语言）。 */
export function restoreYouTubeCaptionTrackInMainWorld(state: {
  previousLanguage?: string;
  previousTranslation?: string;
  wasOff: boolean;
}): void {
  const player = document.getElementById("movie_player") as unknown as {
    setOption?: (module: string, option: string, value: unknown) => void;
    unloadModule?: (module: string) => void;
  } | null;
  if (!player?.setOption) return;
  try {
    if (state.wasOff) {
      player.unloadModule?.("captions");
      return;
    }
    const track: Record<string, unknown> = { languageCode: state.previousLanguage };
    if (state.previousTranslation) {
      track.translationLanguage = { languageCode: state.previousTranslation };
    }
    player.setOption("captions", "track", track);
  } catch { /* restoring is best-effort */ }
}
