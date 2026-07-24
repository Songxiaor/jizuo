/**
 * X 收藏夹同步：扩展只在收藏夹页面滚动、收集推文 id，正文由桌面 App 用公开
 * 端点逐条取回。这里放纯逻辑（页面识别、id 校验、响应解析），滚动采集函数
 * 因需注入页面而必须自包含，单列在下方并有显式说明。
 */

/** 当前标签页是不是 X 的收藏夹页。只认 x.com / twitter.com 的 /i/bookmarks。 */
export function isXBookmarksURL(rawURL: string | undefined): boolean {
  if (!rawURL) return false;
  try {
    const url = new URL(rawURL);
    if (url.protocol !== "https:") return false;
    const host = url.hostname.toLowerCase().replace(/^www\./u, "");
    if (host !== "x.com" && host !== "twitter.com") return false;
    // /i/bookmarks 以及 /i/bookmarks/all、命名收藏夹 /i/bookmarks/<id>。
    return /^\/i\/bookmarks(?:\/|$)/u.test(url.pathname);
  } catch {
    return false;
  }
}

export function isValidTweetID(value: unknown): value is string {
  return typeof value === "string" && /^\d{8,25}$/u.test(value);
}

/** 从 /status/{id} 形式的 href 里取出推文 id。 */
export function tweetIDFromHref(href: string | null | undefined): string | null {
  if (!href) return null;
  const match = href.match(/\/status\/(\d{8,25})(?:$|[/?#])/u);
  return match?.[1] ?? null;
}

/**
 * 从一条时间线帖子的容器里读出它的推文 id。只认时间戳链接（其内含 <time>），
 * 从而避开引用推文、卡片预览里指向别条推文的链接。返回 null 表示这条不是可
 * 同步的独立推文（例如纯广告位）。
 *
 * 这是给常驻 content script 用的普通函数——它由 WXT 正常打包，可以自由复用，
 * 不同于 executeScript 注入的自包含函数。
 */
export function tweetIDFromArticle(article: Element): string | null {
  const anchors = Array.from(article.querySelectorAll("a[href*='/status/']"));
  for (const anchor of anchors) {
    if (!anchor.querySelector("time")) continue;
    const id = tweetIDFromHref(anchor.getAttribute("href"));
    if (id) return id;
  }
  return null;
}

export type BookmarksSyncOutcome = { queued: number; skipped: number };

/** 解析 App 对收藏夹同步的响应。非本类响应或字段不合法一律返回 null。 */
export function parseBookmarksAccepted(value: unknown): BookmarksSyncOutcome | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.kind !== "bookmarksAccepted") return null;
  if (candidate.version !== 1) return null;
  const { queuedCount, skippedCount } = candidate;
  if (typeof queuedCount !== "number" || !Number.isInteger(queuedCount) || queuedCount < 0) return null;
  if (typeof skippedCount !== "number" || !Number.isInteger(skippedCount) || skippedCount < 0) return null;
  return { queued: queuedCount, skipped: skippedCount };
}

/** 同步结束时给用户看的一句话。 */
export function bookmarksSyncMessage(
  outcome: BookmarksSyncOutcome,
  collected: number,
  reachedKnown: boolean,
): string {
  if (collected === 0) return "没有找到可同步的收藏。请确认已打开收藏夹页面。";
  const parts: string[] = [];
  if (outcome.queued > 0) parts.push(`新增 ${outcome.queued} 条正在抓取`);
  if (outcome.skipped > 0) parts.push(`${outcome.skipped} 条已在库`);
  const head = parts.length > 0 ? parts.join("，") : "本次没有新增";
  const tail = reachedKnown ? "（已同步到上次的位置）" : "";
  return `${head}${tail}`;
}

/** 单次同步的 id 上限，与 App 侧 XBookmarksSyncRequest.maximumIDs 保持一致。 */
export const MAX_BOOKMARK_IDS = 300;

export type CollectResult = {
  ids: string[];
  /** 连续遇到 stopAfterKnownStreak 条已知 id 而提前停止（增量同步追上了）。 */
  reachedKnown: boolean;
};

/**
 * 在收藏夹页面滚动收集推文 id，遇到连续若干条已知 id 即停（增量）。
 *
 * 必须完全自包含：`browser.scripting.executeScript` 只序列化本函数体，任何
 * 模块级 helper 都不会被注入页面（这一点在 X 图片过滤上已经踩过一次）。
 *
 * 收藏夹是虚拟滚动列表：滚过的条目会从 DOM 里回收，所以只收 id（一瞬间的事）
 * 而不在这里抓正文。返回后由 App 逐条向公开端点取回完整推文。
 */
export async function collectXBookmarkIDsInPage(
  knownIDs: string[],
  maxIDs: number,
  stopAfterKnownStreak: number,
): Promise<CollectResult> {
  const known = new Set(knownIDs);
  const seen = new Set<string>();
  const ordered: string[] = [];
  let knownStreak = 0;
  let reachedKnown = false;

  const idFromHref = (href: string | null): string | null => {
    if (!href) return null;
    const match = href.match(/\/status\/(\d{8,25})(?:$|[/?#])/u);
    return match?.[1] ?? null;
  };

  const harvest = (): boolean => {
    // data-testid='tweet' 是收藏夹每条推文的稳定容器；取其内的 status 链接。
    const articles = Array.from(document.querySelectorAll("article[data-testid='tweet']"));
    for (const article of articles) {
      let id: string | null = null;
      const anchors = Array.from(article.querySelectorAll("a[href*='/status/']"));
      for (const anchor of anchors) {
        // 排除引用推文里的链接：只取时间戳链接（其内含 <time>）。
        if (!anchor.querySelector("time")) continue;
        id = idFromHref(anchor.getAttribute("href"));
        if (id) break;
      }
      if (!id) continue;
      if (seen.has(id)) continue;
      seen.add(id);
      if (known.has(id)) {
        knownStreak += 1;
        if (knownStreak >= stopAfterKnownStreak) {
          reachedKnown = true;
          return true; // 追上上次同步的位置。
        }
        continue;
      }
      knownStreak = 0;
      ordered.push(id);
      if (ordered.length >= maxIDs) return true;
    }
    return false;
  };

  const scroller =
    (document.querySelector("[data-testid='primaryColumn']") as HTMLElement | null) ??
    document.scrollingElement ??
    document.documentElement;

  let lastHeight = -1;
  let stagnant = 0;
  const maxRounds = 400;
  for (let round = 0; round < maxRounds; round += 1) {
    if (harvest()) break;
    window.scrollBy(0, window.innerHeight * 0.9);
    scroller.scrollTop = scroller.scrollHeight;
    await new Promise((resolve) => setTimeout(resolve, 350));
    const height = scroller.scrollHeight;
    // 高度连续多轮不再增长，说明已滚到底。
    if (height === lastHeight) {
      stagnant += 1;
      if (stagnant >= 3) break;
    } else {
      stagnant = 0;
      lastHeight = height;
    }
  }
  return { ids: ordered, reachedKnown };
}
