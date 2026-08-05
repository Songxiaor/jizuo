/**
 * Multi-source Douyin aweme ID detection.
 * Logic adapted from Syc's StepAudio Douyin Transcriber (v3.0.1) detector:
 * page URL / modal_id first, then path /video/{id}, then free text patterns.
 * Pure functions only — safe for unit tests without a live DOM.
 */

const ID_KEYS = [
  "modal_id",
  "aweme_id",
  "awemeId",
  "item_id",
  "itemId",
  "group_id",
  "groupId",
  "video_id",
  "videoId",
  "modal-id",
  "aweme-id",
  "item-id",
  "group-id",
  "video-id",
] as const;

const KEY_RE = ID_KEYS.join("|");

export type DouyinIdCandidate = {
  id: string;
  score: number;
  source: string;
  hits?: number;
};

export type DouyinDetectResult = {
  awemeId: string;
  source: string;
  canonicalURL: string;
  title: string;
};

/**
 * True when this is a single-video surface (not a bare feed shell).
 * - Numeric id known (path or modal_id / aweme_id query), or
 * - Short link host `v.douyin.com` (id resolved after redirect).
 */
export function isDouyinSingleVideoURL(rawURL: string): boolean {
  if (detectDouyinAwemeIdFromURL(rawURL)?.awemeId) return true;
  try {
    const host = new URL(rawURL).hostname.toLowerCase();
    // Share short links always target one item; ID appears after redirect follow.
    //
    // 两个约束缺一不可：必须是 `v.` 短链前缀（否则 `www.douyin.com/jingxuan`
    // 这种信息流外壳也会被当成单条视频），且后缀匹配必须带点（否则
    // `v.mydouyin.com` 会被判成自己人——仿冒站点跳过通用抓取走进抖音分支，
    // 而 detectCapturePlatform 又把它标成 generic，平台字段与抓取分支自相矛盾）。
    if (host === "v.douyin.com" || (host.startsWith("v.") && host.endsWith(".douyin.com"))) {
      return true;
    }
  } catch {
    return false;
  }
  return false;
}

export function isDouyinHost(rawURL: string): boolean {
  try {
    const host = new URL(rawURL).hostname.toLowerCase();
    return (
      host === "www.douyin.com"
      || host === "douyin.com"
      || host === "v.douyin.com"
      || host === "www.iesdouyin.com"
      || host === "iesdouyin.com"
      || host.endsWith(".douyin.com")
      || host.endsWith(".iesdouyin.com")
    );
  } catch {
    return false;
  }
}

/**
 * Resolve a single aweme ID from a URL string (location, share link, Feed modal).
 * Prefer modal_id / aweme_id query, then /video/{id} path.
 */
export function detectDouyinAwemeIdFromURL(rawURL: string): DouyinDetectResult | null {
  if (!isDouyinHost(rawURL)) return null;

  const candidates = collectIdsFromText(rawURL, 100, "location");
  // Boost explicit query keys that StepAudio ranks highest.
  try {
    const url = new URL(rawURL);
    for (const key of ["modal_id", "aweme_id", "item_id", "video_id", "group_id"]) {
      const value = url.searchParams.get(key);
      if (value && /^\d{8,25}$/u.test(value)) {
        candidates.push({ id: value, score: 110, source: `query:${key}` });
      }
    }
    const pathMatch = url.pathname.match(/\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$)/u);
    if (pathMatch?.[1]) {
      candidates.push({ id: pathMatch[1], score: 108, source: "path" });
    }
  } catch {
    // fall through to text patterns only
  }

  const ranked = rankCandidates(candidates);
  const best = ranked[0];
  if (!best) return null;

  return {
    awemeId: best.id,
    source: best.source,
    canonicalURL: `https://www.douyin.com/video/${best.id}`,
    title: "",
  };
}

/** Collect numeric IDs from free text (scripts, HTML snippets, etc.). */
export function collectIdsFromText(
  text: string,
  score = 0,
  source = "text",
): DouyinIdCandidate[] {
  if (!text) return [];

  const byId = new Map<string, DouyinIdCandidate>();
  const patterns: Array<{ re: RegExp; bonus: number }> = [
    { re: /\/(?:video|note|share\/video)\/(\d{8,25})(?=[/?#&"'\\\s]|$)/gu, bonus: 8 },
    {
      re: new RegExp(
        `(?:${KEY_RE})(?:\\s*["']?\\s*[:=]\\s*["']?|["'=:%?&/\\\\\\s]+)(\\d{8,25})`,
        "gu",
      ),
      bonus: 5,
    },
    {
      re: new RegExp(`"(?:${KEY_RE})"\\s*:\\s*"?(\\d{8,25})"?`, "gu"),
      bonus: 4,
    },
  ];

  for (const variant of textVariants(text)) {
    for (const { re, bonus } of patterns) {
      re.lastIndex = 0;
      let match: RegExpExecArray | null;
      while ((match = re.exec(variant))) {
        const id = match[1];
        if (!id || !/^\d{8,25}$/u.test(id)) continue;
        const item: DouyinIdCandidate = { id, score: score + bonus, source };
        const existing = byId.get(id);
        if (!existing || item.score > existing.score) byId.set(id, item);
      }
    }
  }

  return Array.from(byId.values());
}

export function rankCandidates(items: DouyinIdCandidate[]): DouyinIdCandidate[] {
  const byId = new Map<string, DouyinIdCandidate & { hits: number }>();

  for (const item of items) {
    if (!/^\d{8,25}$/u.test(item.id)) continue;
    const existing = byId.get(item.id);
    if (!existing) {
      byId.set(item.id, { id: item.id, score: item.score, source: item.source, hits: 1 });
      continue;
    }
    existing.hits += 1;
    if (item.score > existing.score) {
      existing.score = item.score;
      existing.source = item.source;
    }
  }

  return Array.from(byId.values()).sort(
    (a, b) => b.score - a.score || b.hits - a.hits,
  );
}

/** Strip the common Douyin browser title suffix. */
export function normalizeDouyinTitle(title: string): string {
  const cleaned = String(title || "")
    .replace(/\s+-\s+抖音.*$/u, "")
    // The caption "expand" button label gets concatenated onto the caption
    // text when read via textContent; it is chrome, not content.
    .replace(/(?:…|\.{3})?\s*展开$/u, "")
    .trim();
  return stripTrailingDouyinHashtags(cleaned);
}

/**
 * 抖音的话题标签是拼在文案末尾的（「文案 #九门 #陈伟霆 …」），标题里只要文案。
 *
 * 只削末尾那一串：句子中间的 `#` 是文案的一部分，删了句子就断了。
 * 整条文案全是标签时保留原样——那时标签就是仅有的信息。
 *
 * 贴着正文写的标签同样要削（`盘点隐藏细节#功夫女足`），所以不能要求标签前面
 * 有空白。但这样一来 `我在学C#语言` 也会被削成「我在学C」——`C#`、`F#`、`A#`
 * 这些是名字的一部分，不是标签。
 *
 * 判据落在 **`#` 前面那个字符**上：真标签接的是中文、表情或标点
 * （`细节#功夫女足`、`实录#数码`），而 `C#` 这类前面一定是 ASCII 字母或数字。
 * 所以 `#` 紧跟在 ASCII 字母/数字后面时不当作标签起点。
 *
 * 分不开、也没打算分的边界：`这是#话题#中间的话` 和 `开箱实录#数码#开箱`
 * 语法完全同构，只能靠语义辨别。这里按后者处理（削）——末尾接着 `#` 的中文串
 * 在抖音文案里绝大多数确实是标签。
 */
export function stripTrailingDouyinHashtags(title: string): string {
  const stripped = String(title || "")
    // 折叠文案被截断时末尾会剩一个孤零零的 `#`（标签被切掉一半）。
    .replace(/\s+#\s*$/u, "")
    .replace(/(?<![0-9A-Za-z])(?:\s*#[^\s#]+)+\s*$/u, "")
    .trim();
  return stripped || title;
}

/**
 * Douyin publish times read from the DOM are decorated relative/short dates
 * ("· 2天前", "· 6月29日 · 广东"). Convert them to an absolute day at capture
 * time; unknown shapes pass through cleaned so nothing is fabricated.
 */
export function normalizeDouyinPublishedText(raw: string, now: Date = new Date()): string | undefined {
  const cleaned = String(raw || "")
    .replace(/^[\s·•|｜,，]+|[\s·•|｜,，]+$/gu, "")
    .trim();
  if (!cleaned) return undefined;
  if (/^\d{4}-\d{2}-\d{2}T/.test(cleaned)) return cleaned;

  const dateText = (year: number, month: number, day: number) => `${year}年${month}月${day}日`;
  const fromOffset = (milliseconds: number) => {
    const shifted = new Date(now.getTime() - milliseconds);
    return dateText(shifted.getFullYear(), shifted.getMonth() + 1, shifted.getDate());
  };
  const dayMs = 86_400_000;
  const parseSegment = (segment: string): string | undefined => {
    let match = segment.match(/^(\d{4})[年.-](\d{1,2})[月.-](\d{1,2})日?$/u);
    if (match) return dateText(Number(match[1]), Number(match[2]), Number(match[3]));
    match = segment.match(/^(\d{1,2})[月.-](\d{1,2})日?$/u);
    if (match) {
      // No year on Douyin means "within roughly the last year".
      let year = now.getFullYear();
      const candidate = new Date(year, Number(match[1]) - 1, Number(match[2]));
      if (candidate.getTime() - now.getTime() > dayMs) year -= 1;
      return dateText(year, Number(match[1]), Number(match[2]));
    }
    if (/^刚刚$/u.test(segment)) return dateText(now.getFullYear(), now.getMonth() + 1, now.getDate());
    match = segment.match(/^(\d+)\s*秒前$/u);
    if (match) return fromOffset(Number(match[1]) * 1_000);
    match = segment.match(/^(\d+)\s*分钟前$/u);
    if (match) return fromOffset(Number(match[1]) * 60_000);
    match = segment.match(/^(\d+)\s*小时前$/u);
    if (match) return fromOffset(Number(match[1]) * 3_600_000);
    if (/^昨天/u.test(segment)) return fromOffset(dayMs);
    if (/^前天/u.test(segment)) return fromOffset(2 * dayMs);
    match = segment.match(/^(\d+)\s*天前$/u);
    if (match) return fromOffset(Number(match[1]) * dayMs);
    match = segment.match(/^(\d+)\s*周前$/u);
    if (match) return fromOffset(Number(match[1]) * 7 * dayMs);
    return undefined;
  };

  // Location and other decorations ride along in dotted segments; the first
  // segment that parses as a date wins.
  const segments = cleaned.split(/[·•|｜]/u).map((part) => part.trim()).filter(Boolean);
  for (const segment of segments) {
    const parsed = parseSegment(segment);
    if (parsed) return parsed;
  }
  return cleaned;
}

/**
 * Douyin feed chrome lines that must never become capture body.
 * Adapted from observed jingxuan shell captures.
 */
export const DOUYIN_SHELL_LINE_MARKERS = [
  "精选",
  "AI抖音",
  "关注",
  "朋友",
  "我的",
  "直播",
  "放映厅",
  "短剧",
  "推荐",
  "搜索",
  "充钻石",
  "下载电脑客户端",
  "壁纸",
  "通知",
  "消息",
  "投稿",
  "登录",
  "客户端",
  "读屏标签已关闭",
] as const;

export function isDouyinShellLine(line: string): boolean {
  const trimmed = line.trim();
  if (!trimmed) return true;
  if (DOUYIN_SHELL_LINE_MARKERS.includes(trimmed as (typeof DOUYIN_SHELL_LINE_MARKERS)[number])) {
    return true;
  }
  // "朋友 15" style badge lines
  if (/^(?:朋友|关注|消息|通知)\s*\d+$/u.test(trimmed)) return true;
  return false;
}

function textVariants(value: string): string[] {
  const raw = String(value || "");
  const unescaped = raw
    .replace(/\\u002[fF]/gu, "/")
    .replace(/\\u003[dD]/gu, "=")
    .replace(/\\u003[aA]/gu, ":")
    .replace(/\\u0026/gu, "&")
    .replace(/\\u0022/gu, "\"")
    .replace(/\\"/gu, "\"")
    .replace(/&#x2F;/giu, "/")
    .replace(/&quot;/giu, "\"")
    .replace(/&amp;/giu, "&");

  return unique([
    raw,
    unescaped,
    safeDecode(raw),
    safeDecode(unescaped),
    safeDecode(safeDecode(unescaped)),
  ]);
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return String(value || "")
      .replace(/%2[fF]/gu, "/")
      .replace(/%3[dD]/gu, "=")
      .replace(/%3[aA]/gu, ":")
      .replace(/%22/gu, "\"")
      .replace(/%26/gu, "&");
  }
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}
