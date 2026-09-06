/**
 * X 收藏夹同步：扩展只在收藏夹页面滚动、收集推文 id（及卡片预览），正文由桌面
 * App 用公开端点逐条取回。这里放纯逻辑（页面识别、id 校验、响应解析），滚动
 * 采集函数因需注入页面而必须自包含，单列在下方并有显式说明。
 */

/**
 * 当前标签页是不是 X 的收藏/历史页。
 *
 * 2026 年中起，侧栏「书签/收藏」在部分账号上改名为「历史」，
 * `/i/bookmarks` 会 302 到 `/i/history`；旧路径仍保留兼容。
 * 历史页内有书签、喜欢、视频、文章等分页——同步按钮出现后，
 * 用户需停在「书签/收藏」分页再点，否则会滚到别的列表。
 */
export function isXBookmarksURL(rawURL: string | undefined): boolean {
  if (!rawURL) return false;
  try {
    const url = new URL(rawURL);
    if (url.protocol !== "https:") return false;
    const host = url.hostname.toLowerCase().replace(/^www\./u, "");
    if (host !== "x.com" && host !== "twitter.com") return false;
    // /i/bookmarks、/i/bookmarks/all、命名收藏夹 /i/bookmarks/<id>；
    // 以及新入口 /i/history（及其子路径，若日后拆分）。
    return /^\/i\/(?:bookmarks|history)(?:\/|$)/u.test(url.pathname);
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

/** 解析 App 对收藏夹查重的响应。非本类响应或字段不合法一律返回 null。 */
export function parseBookmarksLookup(value: unknown): string[] | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.kind !== "bookmarksLookup") return null;
  if (candidate.version !== 1) return null;
  if (!Array.isArray(candidate.existingIDs)) return null;
  const ids: string[] = [];
  for (const raw of candidate.existingIDs) {
    if (!isValidTweetID(raw)) return null;
    ids.push(raw);
  }
  return ids;
}

/** 同步结束时给用户看的一句话。 */
export function bookmarksSyncMessage(
  outcome: BookmarksSyncOutcome,
  collected: number,
  reachedKnown: boolean,
): string {
  if (collected === 0) return "没有找到可同步的收藏。请确认已打开历史页的「书签/收藏」分页。";
  const parts: string[] = [];
  if (outcome.queued > 0) parts.push(`新增 ${outcome.queued} 条正在抓取`);
  if (outcome.skipped > 0) parts.push(`${outcome.skipped} 条已在库`);
  const head = parts.length > 0 ? parts.join("，") : "本次没有新增";
  const tail = reachedKnown ? "（已同步到上次的位置）" : "";
  return `${head}${tail}`;
}

/** 单次同步的 id 上限，与 App 侧 XBookmarksSyncRequest.maximumIDs 保持一致。 */
export const MAX_BOOKMARK_IDS = 300;

/** 弹窗卡片用的一条收藏预览（正文仍由 App 取回）。 */
export type BookmarkPreviewItem = {
  id: string;
  author: string;
  text: string;
  /** 扩展本地游标里见过，或 App 历史确认已在库——默认不勾选。 */
  alreadySynced: boolean;
};

export type CollectResult = {
  items: BookmarkPreviewItem[];
  /** 与 items[].id 同序，方便只关心 id 的调用方。 */
  ids: string[];
  /** 连续遇到 stopAfterKnownStreak 条已知 id 而提前停止（仅增量模式）。 */
  reachedKnown: boolean;
};

export function normalizeBookmarkItems(raw: unknown): BookmarkPreviewItem[] {
  if (!Array.isArray(raw)) return [];
  const out: BookmarkPreviewItem[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    if (!isValidTweetID(row.id)) continue;
    out.push({
      id: row.id,
      author: typeof row.author === "string" ? row.author.slice(0, 80) : "",
      text: typeof row.text === "string" ? row.text.slice(0, 200) : "",
      alreadySynced: row.alreadySynced === true,
    });
  }
  return out;
}

/**
 * 在收藏夹页面滚动收集推文预览。
 *
 * 必须完全自包含：`browser.scripting.executeScript` 只序列化本函数体，任何
 * 模块级 helper 都不会被注入页面（这一点在 X 图片过滤上已经踩过一次）。
 *
 * 收藏夹是虚拟滚动列表：滚过的条目会从 DOM 里回收，所以只收 id + 短预览
 * （一瞬间的事）。勾选后由 App 逐条向公开端点取回完整推文。
 *
 * `stopAfterKnownStreak <= 0` 时不因「追上已知」而早停——勾选模式需要尽量
 * 滚完整段列表，已知条目仍会收进来并标 alreadySynced。
 */
export async function collectXBookmarkIDsInPage(
  knownIDs: string[],
  maxIDs: number,
  stopAfterKnownStreak: number,
): Promise<CollectResult> {
  const known = new Set(knownIDs);
  const seen = new Set<string>();
  const items: Array<{ id: string; author: string; text: string; alreadySynced: boolean }> = [];
  let knownStreak = 0;
  let reachedKnown = false;

  const idFromHref = (href: string | null): string | null => {
    if (!href) return null;
    const match = href.match(/\/status\/(\d{8,25})(?:$|[/?#])/u);
    return match?.[1] ?? null;
  };

  const isWeakText = (text: string): boolean => !text.trim();

  const previewFromArticle = (
    article: Element,
  ): { author: string; text: string; hasMedia: boolean } => {
    // 作者：只取 User-Name 里的链接文案，避开「· 16小时」这类相对时间。
    const nameRoot = article.querySelector("[data-testid='User-Name']");
    let display = "";
    let handle = "";
    if (nameRoot) {
      for (const link of Array.from(nameRoot.querySelectorAll("a[href]"))) {
        const label = (link.textContent ?? "").replace(/\s+/gu, " ").trim();
        if (!label) continue;
        if (label.startsWith("@") && label.length > 1) {
          handle = label.slice(1).replace(/[^A-Za-z0-9_]/gu, "") || handle;
          continue;
        }
        if (/^\d/u.test(label) || /^(·|•)$/u.test(label)) continue;
        if (!display && label.length <= 80) display = label;
      }
      if (!display && !handle) {
        const raw = (nameRoot.textContent ?? "").replace(/\s+/gu, " ").trim();
        const at = raw.match(/@([A-Za-z0-9_]{1,15})/u);
        if (at) handle = at[1] ?? "";
        const beforeAt = raw.split("@")[0]?.replace(/[·•].*$/u, "").trim() ?? "";
        if (beforeAt) display = beforeAt.slice(0, 80);
      }
    }
    const author = display && handle
      ? `${display} (@${handle})`
      : handle
        ? `@${handle}`
        : display;

    // 正文：合并全部 tweetText；长文走 Article 阅读视图；再不行才扫可见文本。
    const textNodes = Array.from(article.querySelectorAll("[data-testid='tweetText']"));
    let text = textNodes
      .map((node) => (node.textContent ?? "").replace(/\s+/gu, " ").trim())
      .filter(Boolean)
      .join(" ")
      .slice(0, 200);

    if (!text) {
      const articleView = article.querySelector("[data-testid='twitterArticleReadView']");
      if (articleView) {
        text = (articleView.textContent ?? "").replace(/\s+/gu, " ").trim().slice(0, 200);
      }
    }

    if (!text) {
      // 图片帖有时正文还在，但不挂 tweetText；去掉名字/媒体/按钮区再取一段。
      const clone = article.cloneNode(true) as Element;
      for (const junk of Array.from(clone.querySelectorAll(
        "[data-testid='User-Name'],[data-testid='tweetPhoto'],[data-testid='videoPlayer'],button,svg,time,[role='group']",
      ))) {
        junk.remove();
      }
      text = (clone.textContent ?? "").replace(/\s+/gu, " ").trim().slice(0, 200);
      if (/^@?[A-Za-z0-9_]{1,15}$/u.test(text) || /^\d/u.test(text)) text = "";
    }

    const hasMedia = Boolean(
      article.querySelector("[data-testid='tweetPhoto'],[data-testid='videoPlayer'],video"),
    );
    return { author, text, hasMedia };
  };

  const placeholderFor = (alreadySynced: boolean, hasMedia: boolean): string => {
    if (alreadySynced) return "（已同步过）";
    if (hasMedia) return "（图片/视频，正文未读到）";
    return "（暂无预览）";
  };

  // 顺带记住「有没有媒体」，方便最后仍无正文时写准占位。
  const mediaById = new Map<string, boolean>();

  const harvest = (): boolean => {
    const articles = Array.from(document.querySelectorAll("article[data-testid='tweet']"));
    for (const article of articles) {
      let id: string | null = null;
      const anchors = Array.from(article.querySelectorAll("a[href*='/status/']"));
      for (const anchor of anchors) {
        if (!anchor.querySelector("time")) continue;
        id = idFromHref(anchor.getAttribute("href"));
        if (id) break;
      }
      if (!id) continue;

      const preview = previewFromArticle(article);
      if (preview.hasMedia) mediaById.set(id, true);
      const alreadySynced = known.has(id);

      // 关键点：滚动时第一次扫到的常常是半成品 DOM（只有头像/图、还没有 tweetText）。
      // 若已经收过但正文仍弱，允许用后续更完整的预览覆盖。
      const existingIndex = items.findIndex((item) => item.id === id);
      if (existingIndex >= 0) {
        const existing = items[existingIndex]!;
        if (isWeakText(existing.text) && preview.text) {
          items[existingIndex] = {
            id,
            author: preview.author || existing.author,
            text: preview.text,
            alreadySynced: existing.alreadySynced,
          };
        } else if (!existing.author && preview.author) {
          existing.author = preview.author;
        }
        continue;
      }

      if (seen.has(id)) continue;
      seen.add(id);

      if (alreadySynced) {
        knownStreak += 1;
        if (stopAfterKnownStreak > 0 && knownStreak >= stopAfterKnownStreak) {
          reachedKnown = true;
          items.push({
            id,
            author: preview.author,
            text: preview.text || placeholderFor(true, preview.hasMedia),
            alreadySynced: true,
          });
          return true;
        }
      } else {
        knownStreak = 0;
      }

      items.push({
        id,
        author: preview.author,
        // 收集过程中先留空文，方便下一轮补全；返回前再填占位。
        text: preview.text,
        alreadySynced,
      });
      if (items.length >= maxIDs) return true;
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
    if (height === lastHeight) {
      stagnant += 1;
      if (stagnant >= 3) break;
    } else {
      stagnant = 0;
      lastHeight = height;
    }
  }

  // 滚完后再扫一轮，尽量把弱预览补全。
  harvest();

  for (const item of items) {
    if (isWeakText(item.text)) {
      item.text = placeholderFor(item.alreadySynced, mediaById.get(item.id) === true);
    }
  }

  return {
    items,
    ids: items.map((item) => item.id),
    reachedKnown,
  };
}
