import { COMMUNITY_PROFILES, communityPlatformForURL, type CommunityProfile } from "./community-profiles";
import { absoluteUrl, htmlElementToMarkdown, scrubNoise, stripBoilerplateLines } from "./extract";

/**
 * 评论抓取：把「当前内容下面的评论区」收成一条条结构化记录，供弹窗勾选，
 * 再由 background 只把勾选的那些写进正文末尾的评论段。
 *
 * 边界：
 * - 只读当前标签页已经渲染出来的 DOM；不调隐藏接口、不导出 Cookie。
 * - 数量不够时只在用户主动抓取的这一次往下翻评论区，凑够设置的条数、或连续
 *   几轮没有新评论、或超过时间预算就停，并把滚动位置还原。
 * - 平台选择器集中在本文件，改版时只需要改这里。
 */

export const COMMENT_LIMIT_MIN = 10;
export const COMMENT_LIMIT_MAX = 100;
export const COMMENT_LIMIT_DEFAULT = 20;

export function clampCommentLimit(value: unknown): number {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(number)) return COMMENT_LIMIT_DEFAULT;
  return Math.min(COMMENT_LIMIT_MAX, Math.max(COMMENT_LIMIT_MIN, Math.round(number)));
}

export type CommentPlatform =
  | "reddit" | "community" | "x" | "youtube" | "bilibili" | "zhihu" | "douyin" | "xiaohongshu";

export type CapturedComment = {
  /** 同一页面内稳定：平台自带 id 优先，否则由作者+正文算出。勾选靠它对回去。 */
  id: string;
  author: string;
  body: string;
  /** 0 = 一级评论，1 = 楼中楼。 */
  depth: number;
  /** 点赞数（原样保留平台写法，如「1.2万」）。 */
  likes?: string;
  /** Reddit 的分数（有踩），与点赞分开。 */
  score?: string;
  published?: string;
  permalink?: string;
};

export type CommentCollection = {
  platform: CommentPlatform;
  comments: CapturedComment[];
  /** 页面自己显示的评论总数（可得时）。 */
  expectedCount?: number;
  limit: number;
  /** 页面显示了「登录查看全部评论」一类的登录墙：读到的只是未登录可见的部分。 */
  loginRequired?: boolean;
};

type CommentReading = {
  comments: CapturedComment[];
  expectedCount?: number;
  loginRequired?: boolean;
  /** 最后一条评论所在元素，用来找评论区自己的滚动容器。 */
  anchor?: Element | null;
};

type CommentReader = {
  read: (documentLike: Document) => CommentReading;
  /** 首次收集前的准备：把评论区滚进视野或点开折叠的评论。 */
  prime?: (documentLike: Document) => void;
  /**
   * 每轮滚动前点一下「加载更多」一类按钮。`stalled` 表示上一轮没读到新评论：
   * 一级评论到底了（或没登录只给看前几条），这时才去展开楼中楼补足条数。
   */
  loadMore?: (documentLike: Document, stalled: boolean) => void;
  /**
   * 虚拟列表：滚出屏幕的评论会被移出 DOM。用户已往下翻过时先回到顶部，
   * 等这个判断成立（评论区开头重新渲染出来）再读，才能从第一条开始。
   */
  topRendered?: (documentLike: Document) => boolean;
};

export function commentPlatformForURL(rawURL: string): CommentPlatform | undefined {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return undefined;
  }
  const host = url.hostname.toLowerCase();
  const path = url.pathname;
  const on = (domain: string) => host === domain || host.endsWith(`.${domain}`);
  if (on("reddit.com") && /\/comments\//u.test(path)) return "reddit";
  if (communityPlatformForURL(rawURL)) return "community";
  if ((on("x.com") || on("twitter.com")) && /\/status\/\d+/u.test(path)) return "x";
  if (on("youtube.com") && path === "/watch" && url.searchParams.has("v")) return "youtube";
  if (on("bilibili.com") && /\/video\//u.test(path)) return "bilibili";
  if (on("zhihu.com") && (/\/answer\/\d+/u.test(path) || (host === "zhuanlan.zhihu.com" && /^\/p\/\d+/u.test(path)))) return "zhihu";
  if (on("douyin.com") && (/\/video\/\d+/u.test(path) || /\/note\/\d+/u.test(path) || url.searchParams.has("modal_id"))) return "douyin";
  if (on("xiaohongshu.com") && /\/(?:explore|discovery\/item)\/[0-9a-f]+/iu.test(path)) return "xiaohongshu";
  return undefined;
}

// ---------------------------------------------------------------------------
// 收集主循环

export type CollectOptions = {
  maxMillis?: number;
  /** 每次滚动后最多等多久新评论出现（期间每 `pollMillis` 看一次，出现就继续）。 */
  settleMillis?: number;
  pollMillis?: number;
  /** 连续多少轮没有新评论就认为到底了。 */
  idleRounds?: number;
  sleep?: (milliseconds: number) => Promise<void>;
};

export async function collectCommentsFromDocument(
  documentLike: Document,
  rawLimit: unknown,
  options: CollectOptions = {},
): Promise<CommentCollection | null> {
  const platform = commentPlatformForURL(documentLike.location.href);
  if (!platform) return null;
  const limit = clampCommentLimit(rawLimit);
  const reader = readerFor(platform, documentLike);
  const sleep = options.sleep ?? ((milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  const maxMillis = options.maxMillis ?? 20_000;
  const settleMillis = options.settleMillis ?? 3_000;
  const pollMillis = options.pollMillis ?? 350;
  const idleRounds = options.idleRounds ?? 2;
  const view = documentLike.defaultView;
  const originalScroll = view ? { x: view.scrollX, y: view.scrollY } : undefined;
  const touchedScrollers = new Map<Element, number>();

  const merged = new Map<string, CapturedComment>();
  const order: string[] = [];
  let expectedCount: number | undefined;
  let loginRequired = false;
  const absorb = (): Element | null | undefined => {
    const reading = reader.read(documentLike);
    if (reading.expectedCount !== undefined) expectedCount = reading.expectedCount;
    if (reading.loginRequired) loginRequired = true;
    mergeInPageOrder(order, merged, reading.comments);
    return reading.anchor;
  };

  if (reader.topRendered && view && view.scrollY > 0) {
    view.scrollTo(view.scrollX, 0);
    const deadline = Date.now() + settleMillis;
    do {
      await sleep(pollMillis);
    } while (!reader.topRendered(documentLike) && Date.now() < deadline);
  }
  const started = Date.now();
  let anchor = absorb();
  // 平台懒加载一批评论要 1–3 秒：轮询到出现新评论就继续，不死等固定时长。
  const waitForGrowth = async (): Promise<void> => {
    const before = merged.size;
    const deadline = Date.now() + settleMillis;
    do {
      await sleep(pollMillis);
      anchor = absorb();
    } while (merged.size === before && Date.now() < deadline && Date.now() - started < maxMillis);
  };
  if (merged.size < limit && reader.prime) {
    try { reader.prime(documentLike); } catch { /* 准备失败不影响已渲染部分 */ }
    await waitForGrowth();
  }
  let idle = 0;
  while (merged.size < limit && idle < idleRounds && Date.now() - started < maxMillis) {
    const before = merged.size;
    try { reader.loadMore?.(documentLike, idle > 0); } catch { /* 忽略 */ }
    scrollTowardsMore(documentLike, anchor ?? null, touchedScrollers, Boolean(reader.topRendered));
    await waitForGrowth();
    idle = merged.size > before ? 0 : idle + 1;
  }

  for (const [scroller, top] of touchedScrollers) scroller.scrollTop = top;
  if (view && originalScroll) view.scrollTo(originalScroll.x, originalScroll.y);

  return {
    platform,
    comments: order.slice(0, limit).map((id) => merged.get(id)!),
    ...(expectedCount !== undefined ? { expectedCount } : {}),
    limit,
    ...(loginRequired ? { loginRequired } : {}),
  };
}

/**
 * 按页面上的先后顺序合并一次读取：新出现的评论插在同一次读取里它前面那条已知评论之后，
 * 而不是一律接到末尾。这样后来才展开的楼中楼回到所属评论下面，虚拟列表也不乱序。
 */
export function mergeInPageOrder(order: string[], merged: Map<string, CapturedComment>, reading: readonly CapturedComment[]): void {
  let cursor = -1;
  let pending: string[] = [];
  for (const comment of reading) {
    if (merged.has(comment.id)) {
      const index = order.indexOf(comment.id);
      if (index < 0) continue;
      if (pending.length) order.splice(index, 0, ...pending);
      cursor = index + pending.length + 1;
      pending = [];
      continue;
    }
    merged.set(comment.id, comment);
    if (cursor >= 0) {
      order.splice(cursor, 0, comment.id);
      cursor += 1;
    } else {
      pending.push(comment.id);
    }
  }
  if (pending.length) order.push(...pending);
}

function scrollTowardsMore(documentLike: Document, anchor: Element | null, touched: Map<Element, number>, stepwise = false): void {
  const view = documentLike.defaultView;
  // 虚拟列表一下跳到底，中间那段不会渲染：每次只翻大半屏。
  if (stepwise && view) {
    view.scrollTo(view.scrollX, view.scrollY + Math.max(300, (view.innerHeight || 800) * 0.8));
    return;
  }
  const scroller = anchor ? scrollableAncestor(anchor, documentLike) : null;
  if (scroller) {
    if (!touched.has(scroller)) touched.set(scroller, scroller.scrollTop);
    scroller.scrollTop = scroller.scrollHeight;
    return;
  }
  const root = documentLike.scrollingElement ?? documentLike.documentElement;
  if (view) view.scrollTo(view.scrollX, root.scrollHeight);
}

function scrollableAncestor(start: Element, documentLike: Document): Element | null {
  const view = documentLike.defaultView;
  let node: Node | null = start.parentNode;
  while (node) {
    if (node.nodeType === 1) {
      const element = node as Element;
      if (element === documentLike.documentElement || element === documentLike.body) return null;
      const overflow = view?.getComputedStyle(element).overflowY ?? "";
      if ((overflow === "auto" || overflow === "scroll") && element.scrollHeight > element.clientHeight + 10) return element;
      node = element.parentNode;
    } else if (node.nodeType === 11) {
      node = (node as ShadowRoot).host ?? null;
    } else {
      node = node.parentNode;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 写成正文里的评论段

/**
 * 格式与 App 阅读页的评论解析器对齐（MarkdownPresentation.commentSection）：
 * 标题 `## 评论（…）`，每条一行 `- **作者** · 细节`，细节里固定带
 * `回复层级 N`，使非 Reddit 作者名也能被认成评论头。
 */
export function commentsMarkdown(collection: Pick<CommentCollection, "platform" | "expectedCount">, comments: CapturedComment[]): string {
  if (!comments.length) return "";
  const count = comments.length;
  const expected = collection.expectedCount;
  const coverage = expected && expected > count ? `已保存 ${count} 条 / 页面显示 ${expected}` : `已保存 ${count} 条`;
  const lines = [`## 评论（${coverage}）`, ""];
  for (const comment of comments) {
    const depth = Math.max(0, Math.floor(comment.depth));
    const indent = "  ".repeat(Math.min(depth, 6));
    const author = sanitizeAuthor(comment.author);
    const details = [
      comment.score ? `score ${comment.score}` : undefined,
      comment.likes ? `赞 ${comment.likes}` : undefined,
      comment.published?.replace(/\s*·\s*/gu, " "),
      comment.permalink ? `[原评论](${comment.permalink})` : undefined,
      `回复层级 ${depth}`,
    ].filter(Boolean).join(" · ");
    lines.push(`${indent}- **${author}** · ${details}`);
    for (const line of comment.body.split("\n")) lines.push(`${indent}  ${line}`.trimEnd());
  }
  return lines.join("\n").trim();
}

function sanitizeAuthor(raw: string): string {
  return raw.replace(/\*+/gu, "").replace(/\s+/gu, " ").trim() || "未知用户";
}

/** 去掉提取器自带的评论段（Reddit/论坛），换成按勾选重排的那一段。 */
export function stripEmbeddedCommentSection(text: string): string {
  const pattern = /\n## 评论(?:与回复)?（[^\n]*）\s*\n/gu;
  let cut = -1;
  for (const match of text.matchAll(pattern)) cut = match.index ?? cut;
  return cut >= 0 ? text.slice(0, cut).trimEnd() : text;
}

export function selectComments(comments: CapturedComment[], selectedIDs: readonly string[] | undefined, limit: number): CapturedComment[] {
  if (!selectedIDs) return comments.slice(0, limit);
  const wanted = new Set(selectedIDs);
  return comments.filter((comment) => wanted.has(comment.id));
}

// ---------------------------------------------------------------------------
// 平台读取器

function readerFor(platform: CommentPlatform, documentLike: Document): CommentReader {
  switch (platform) {
    case "reddit": return redditReader;
    case "community": {
      const community = communityPlatformForURL(documentLike.location.href);
      return communityReader(community ? COMMUNITY_PROFILES[community] : undefined);
    }
    case "x": return xReader;
    case "youtube": return youtubeReader;
    case "bilibili": return bilibiliReader;
    case "zhihu": return zhihuReader;
    case "douyin": return douyinReader;
    case "xiaohongshu": return xiaohongshuReader;
  }
}

export function commentHashID(author: string, body: string): string {
  let hash = 0x811c9dc5;
  const input = `${author}\u0000${body.slice(0, 400)}`;
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `h${hash.toString(36)}`;
}

function clean(text: string | null | undefined): string {
  // 知乎按钮文字前带零宽空格（「\u200b176 条评论」）。
  return (text ?? "").replace(/[\u200b-\u200d\ufeff]/gu, "").replace(/\s+/gu, " ").trim();
}

function blockText(node: Element | null | undefined): string {
  if (!node) return "";
  const raw = (node as HTMLElement).innerText ?? node.textContent ?? "";
  return raw.replace(/\r/gu, "").split("\n").map((line) => line.trim()).filter(Boolean).join("\n");
}

function elementMarkdown(node: Element, baseHref: string): string {
  const clone = node.cloneNode(true) as Element;
  scrubNoise(clone);
  return stripBoilerplateLines(htmlElementToMarkdown(clone, baseHref)).trim();
}

/** 第一个有字的匹配。Discourse 每楼先放一个也带 `data-user-card` 的头像链接，里面只有图片；
 *  只取第一个匹配，linux.do 的评论作者全成了「未知用户」（2026-10-02）。 */
function firstTextIn(root: ParentNode, selectors: readonly string[]): string {
  for (const selector of selectors) {
    for (const node of Array.from(root.querySelectorAll(selector))) {
      const value = clean(node.textContent);
      if (value) return value;
    }
  }
  return "";
}

function firstIn(root: ParentNode | null | undefined, selectors: readonly string[]): Element | null {
  if (!root) return null;
  for (const selector of selectors) {
    const node = root.querySelector(selector);
    if (node) return node;
  }
  return null;
}

function countFrom(text: string | null | undefined): number | undefined {
  // 「2,345 条评论」「1.2万」：先去千分位逗号再取数。
  const value = clean(text).replace(/(\d)[,，](?=\d{3})/gu, "$1");
  const match = value.match(/(\d+(?:\.\d+)?)\s*(万|w|k|千)?/iu);
  if (!match) return undefined;
  const base = Number(match[1]);
  const unit = match[2]?.toLowerCase();
  const multiplier = unit === "万" || unit === "w" ? 10_000 : unit === "k" || unit === "千" ? 1_000 : 1;
  const result = Math.round(base * multiplier);
  return Number.isFinite(result) && result > 0 ? result : undefined;
}

function likesText(text: string | null | undefined): string | undefined {
  const value = clean(text);
  return /\d/u.test(value) ? value.replace(/[^\d.,万wWkK千亿]/gu, "") || undefined : undefined;
}

function clickByText(root: ParentNode, selector: string, pattern: RegExp): boolean {
  for (const node of Array.from(root.querySelectorAll<HTMLElement>(selector))) {
    if (pattern.test(clean(node.textContent))) {
      node.click();
      return true;
    }
  }
  return false;
}

// Reddit ---------------------------------------------------------------------

const redditReader: CommentReader = {
  read(documentLike) {
    const baseHref = documentLike.location.href;
    const rendered = Array.from(documentLike.querySelectorAll("shreddit-comment[thingid]"))
      .filter((comment) => comment.getAttribute("aria-hidden") !== "true");
    const comments: CapturedComment[] = [];
    for (const comment of rendered) {
      const body = comment.querySelector("[slot='comment']");
      if (!body || body.closest("shreddit-comment") !== comment) continue;
      const clone = body.cloneNode(true) as Element;
      clone.querySelectorAll("shreddit-comment").forEach((node) => node.remove());
      const markdown = htmlElementToMarkdown(clone, baseHref).trim();
      if (!markdown) continue;
      const depthRaw = Number(comment.getAttribute("depth") ?? "0");
      const score = clean(comment.getAttribute("score")).replace(/[,\s]/gu, "");
      const created = clean(comment.getAttribute("created")).replace(/([+-]\d{2})(\d{2})$/u, "$1:$2");
      const permalink = absoluteUrl(comment.getAttribute("permalink") ?? "", baseHref);
      comments.push({
        id: comment.getAttribute("thingid") ?? commentHashID("", markdown),
        author: `u/${clean(comment.getAttribute("author")) || "[deleted]"}`,
        body: markdown,
        depth: Number.isFinite(depthRaw) && depthRaw > 0 ? Math.floor(depthRaw) : 0,
        ...(/^-?\d+$/u.test(score) ? { score } : {}),
        ...(created ? { published: created } : {}),
        ...(permalink ? { permalink } : {}),
      });
    }
    const post = documentLike.querySelector("shreddit-post");
    const expected = countFrom(post?.getAttribute("comment-count"));
    return { comments, ...(expected ? { expectedCount: expected } : {}), anchor: rendered.at(-1) ?? null };
  },
  loadMore(documentLike) {
    clickByText(documentLike, "button", /^(View more comments|More replies|查看更多评论|更多回复)/iu);
  },
};

// 论坛类（HN / V2EX / Stack Overflow / dev.to / Discourse） --------------------

function communityReader(profile: CommunityProfile | undefined): CommentReader {
  return {
    read(documentLike) {
      if (!profile) return { comments: [] };
      const baseHref = documentLike.location.href;
      const bodyNode = firstIn(documentLike, profile.body);
      const seen = new Set<Element>();
      const candidates: Element[] = [];
      for (const selector of profile.comments) {
        for (const node of Array.from(documentLike.querySelectorAll(selector))) {
          if (!seen.has(node)) { seen.add(node); candidates.push(node); }
        }
      }
      const comments: CapturedComment[] = [];
      const bodies = new Set<string>();
      for (const node of candidates) {
        const commentBody = firstIn(node, profile.commentBody);
        if (!commentBody || (bodyNode && (commentBody === bodyNode || commentBody.contains(bodyNode)))) continue;
        const markdown = elementMarkdown(commentBody, baseHref);
        if (!markdown || bodies.has(markdown)) continue;
        bodies.add(markdown);
        const author = firstTextIn(node, profile.commentAuthor) || "未知用户";
        const published = clean(firstIn(node, profile.commentPublished)?.textContent);
        comments.push({
          id: node.id ? `n-${node.id}` : commentHashID(author, markdown),
          author,
          body: markdown,
          depth: 0,
          ...(published ? { published } : {}),
        });
      }
      return { comments, anchor: candidates.at(-1) ?? null };
    },
  };
}

// X ---------------------------------------------------------------------------

function xStatusIDFromURL(rawURL: string): string | undefined {
  return rawURL.match(/\/status\/(\d+)/u)?.[1];
}

const xReader: CommentReader = {
  topRendered(documentLike) {
    const focalID = xStatusIDFromURL(documentLike.location.href);
    return Array.from(documentLike.querySelectorAll<HTMLAnchorElement>("article[data-testid='tweet'] a[href*='/status/']"))
      .some((link) => Boolean(link.querySelector("time")) && xStatusIDFromURL(link.href) === focalID);
  },
  read(documentLike) {
    const focalID = xStatusIDFromURL(documentLike.location.href);
    const cells = Array.from(documentLike.querySelectorAll("[data-testid='cellInnerDiv']"));
    const comments: CapturedComment[] = [];
    // X 的列表是虚拟滚动：往下翻后原推文会被移出 DOM。原推文不在时，
    // 页面上剩下的就都是它下面的回复（仍排除原推文自己）。
    const statusIDOf = (cell: Element): string | undefined => {
      const link = Array.from(cell.querySelectorAll<HTMLAnchorElement>("article[data-testid='tweet'] a[href*='/status/']"))
        .find((candidate) => candidate.querySelector("time"));
      return link ? xStatusIDFromURL(link.href) : undefined;
    };
    const focalRendered = Boolean(focalID) && cells.some((cell) => statusIDOf(cell) === focalID);
    let afterFocal = !focalRendered;
    let anchor: Element | null = null;
    for (const cell of cells) {
      // 回复下面是「发现更多」推荐流，不属于这条推文的评论区。
      const heading = clean(cell.querySelector("h2")?.textContent);
      if (afterFocal && heading && /Discover more|More posts|发现更多|更多帖子|更多内容/iu.test(heading)) break;
      const article = cell.querySelector("article[data-testid='tweet']");
      if (!article) continue;
      const statusLink = Array.from(article.querySelectorAll<HTMLAnchorElement>("a[href*='/status/']"))
        .find((link) => link.querySelector("time"));
      const statusID = statusLink ? xStatusIDFromURL(statusLink.href) : undefined;
      if (!afterFocal) {
        if (statusID === focalID || (!statusID && article.getAttribute("tabindex") === "-1")) afterFocal = true;
        continue;
      }
      // 广告没有带时间的推文链接，已在这里排除；placementTracking 是视频播放器，不代表广告。
      if (!statusID || statusID === focalID) continue;
      const textNode = article.querySelector("[data-testid='tweetText']");
      const body = textNode ? elementMarkdown(textNode, documentLike.location.href) : "";
      if (!body) continue;
      const nameBlock = article.querySelector("[data-testid='User-Name']");
      const handle = Array.from(nameBlock?.querySelectorAll("a[href^='/']") ?? [])
        .map((link) => clean(link.textContent))
        .find((text) => text.startsWith("@"));
      const displayName = clean(nameBlock?.querySelector("a span")?.textContent);
      const author = [displayName, handle].filter(Boolean).join(" ") || handle || "未知用户";
      const likeButton = article.querySelector("[data-testid='like'], [data-testid='unlike']");
      const likes = likesText(likeButton?.getAttribute("aria-label")?.match(/[\d,.万kK]+/u)?.[0] ?? likeButton?.textContent);
      const published = article.querySelector("time")?.getAttribute("datetime") ?? undefined;
      comments.push({
        id: `x-${statusID}`,
        author,
        body,
        depth: 0,
        ...(likes && likes !== "0" ? { likes } : {}),
        ...(published ? { published } : {}),
        ...(statusLink ? { permalink: statusLink.href.split("?")[0] } : {}),
      });
      anchor = cell;
    }
    return { comments, anchor };
  },
  loadMore(documentLike) {
    clickByText(documentLike, "button, [role='button']", /^(Show more replies|Show replies|Show probable spam|显示更多回复|显示回复)$/iu);
  },
};

// YouTube ---------------------------------------------------------------------

const youtubeReader: CommentReader = {
  read(documentLike) {
    const threads = Array.from(documentLike.querySelectorAll("ytd-comment-thread-renderer"));
    const comments: CapturedComment[] = [];
    for (const thread of threads) {
      const comment = thread.querySelector("#comment, ytd-comment-view-model, ytd-comment-renderer");
      if (!comment) continue;
      const body = blockText(comment.querySelector("#content-text"));
      if (!body) continue;
      const author = clean(comment.querySelector("#author-text")?.textContent) || "未知用户";
      const timeLink = comment.querySelector<HTMLAnchorElement>("#published-time-text a");
      const permalink = timeLink?.href;
      const lc = permalink ? new URL(permalink, documentLike.location.href).searchParams.get("lc") : null;
      const likes = likesText(comment.querySelector("#vote-count-middle")?.textContent);
      const published = clean(timeLink?.textContent);
      comments.push({
        id: lc ? `yt-${lc}` : commentHashID(author, body),
        author,
        body,
        depth: 0,
        ...(likes ? { likes } : {}),
        ...(published ? { published } : {}),
        ...(permalink ? { permalink } : {}),
      });
    }
    const expected = countFrom(documentLike.querySelector("ytd-comments-header-renderer #count")?.textContent);
    return { comments, ...(expected ? { expectedCount: expected } : {}), anchor: threads.at(-1) ?? null };
  },
  prime(documentLike) {
    documentLike.querySelector("ytd-comments#comments, #comments")?.scrollIntoView({ block: "start" });
  },
};

// B 站 ------------------------------------------------------------------------

function shadow(node: Element | null | undefined): ShadowRoot | null {
  return node?.shadowRoot ?? null;
}

function bilibiliCommentFrom(renderer: Element | null, depth: number): CapturedComment | null {
  const root = shadow(renderer);
  if (!root) return null;
  const author = clean(shadow(root.querySelector("bili-comment-user-info"))?.querySelector("#user-name")?.textContent);
  const richText = shadow(root.querySelector("bili-rich-text"));
  const body = blockText(richText?.querySelector("#contents") ?? null);
  if (!body) return null;
  const actions = shadow(root.querySelector("bili-comment-action-buttons-renderer"));
  const likes = likesText(actions?.querySelector("#like #count, #like")?.textContent);
  const published = clean(actions?.querySelector("#pubdate")?.textContent);
  return {
    id: commentHashID(author, body),
    author: author || "未知用户",
    body,
    depth,
    ...(likes ? { likes } : {}),
    ...(published ? { published } : {}),
  };
}

const bilibiliReader: CommentReader = {
  read(documentLike) {
    const comments: CapturedComment[] = [];
    const root = shadow(documentLike.querySelector("bili-comments"));
    let anchor: Element | null = null;
    if (root) {
      const threads = Array.from(root.querySelectorAll("bili-comment-thread-renderer"));
      for (const thread of threads) {
        const threadRoot = shadow(thread);
        const main = bilibiliCommentFrom(threadRoot?.querySelector("#comment, bili-comment-renderer") ?? null, 0);
        if (!main) continue;
        comments.push(main);
        const replies = shadow(threadRoot?.querySelector("bili-comment-replies-renderer"));
        for (const reply of Array.from(replies?.querySelectorAll("bili-comment-reply-renderer") ?? [])) {
          const item = bilibiliCommentFrom(reply, 1);
          if (item) comments.push(item);
        }
      }
      const headerCount = countFrom(
        shadow(root.querySelector("bili-comments-header-renderer"))?.querySelector("#count")?.textContent,
      );
      // 评论在 Shadow DOM 里、随整页滚动加载：不给锚点，主循环滚窗口。
      return { comments, ...(headerCount ? { expectedCount: headerCount } : {}), anchor: null };
    }
    // 旧版评论区（非 Web Components）。
    for (const item of Array.from(documentLike.querySelectorAll(".reply-list .reply-item"))) {
      const author = clean(item.querySelector(".root-reply-container .user-name, .user-name")?.textContent);
      const body = blockText(item.querySelector(".root-reply .reply-content, .reply-content"));
      if (!body) continue;
      const likes = likesText(item.querySelector(".root-reply .reply-like span, .reply-like")?.textContent);
      const published = clean(item.querySelector(".root-reply .reply-time, .reply-time")?.textContent);
      comments.push({ id: commentHashID(author, body), author: author || "未知用户", body, depth: 0, ...(likes ? { likes } : {}), ...(published ? { published } : {}) });
      for (const sub of Array.from(item.querySelectorAll(".sub-reply-item"))) {
        const subAuthor = clean(sub.querySelector(".sub-user-name")?.textContent);
        const subBody = blockText(sub.querySelector(".reply-content"));
        if (!subBody) continue;
        const subLikes = likesText(sub.querySelector(".sub-reply-like span")?.textContent);
        comments.push({ id: commentHashID(subAuthor, subBody), author: subAuthor || "未知用户", body: subBody, depth: 1, ...(subLikes ? { likes: subLikes } : {}) });
      }
      anchor = item;
    }
    return { comments, anchor };
  },
  prime(documentLike) {
    documentLike.querySelector("bili-comments, #commentapp, .reply-list")?.scrollIntoView({ block: "start" });
  },
};

// 知乎 ------------------------------------------------------------------------

/** 回答页上同时有「问题的评论」和多条回答的评论：只认地址栏里那条回答。 */
function zhihuAnswerScope(documentLike: Document): Element | null {
  const answerID = documentLike.location.href.match(/\/answer\/(\d+)/u)?.[1];
  return answerID ? documentLike.querySelector(`.AnswerItem[name="${answerID}"], [itemprop="answer"][name="${answerID}"]`) : null;
}

const zhihuReader: CommentReader = {
  read(documentLike) {
    const comments: CapturedComment[] = [];
    const answer = zhihuAnswerScope(documentLike);
    const scope: ParentNode = answer?.querySelector(".CommentContent, [class*='CommentContent']") ? answer : documentLike;
    const items = Array.from(scope.querySelectorAll("div[data-id]"))
      .filter((node) => node.querySelector(".CommentContent, [class*='CommentContent']"))
      .filter((node) => !node.closest(".QuestionHeader"));
    for (const item of items) {
      const own = (node: Element) => node.closest("div[data-id]") === item;
      const bodyNode = Array.from(item.querySelectorAll(".CommentContent, [class*='CommentContent']")).find(own);
      const body = blockText(bodyNode);
      if (!body) continue;
      // 第一个 /people/ 链接是头像（没有文字），取第一个有文字的。
      const author = Array.from(item.querySelectorAll("a[href*='/people/']"))
        .filter(own)
        .map((link) => clean(link.textContent))
        .find(Boolean) || "未知用户";
      const depth = item.parentElement?.closest("div[data-id]") ? 1 : 0;
      // 点赞按钮只有一个数字；「回复」按钮是文字。
      const likes = Array.from(item.querySelectorAll("button"))
        .filter(own)
        .map((button) => clean(button.textContent))
        .find((text) => /^\d[\d,.万]*$/u.test(text));
      const published = Array.from(item.querySelectorAll("span"))
        .filter(own)
        .map((span) => clean(span.textContent))
        .find((text) => /^(\d{4}-\d{2}-\d{2}|\d{2}-\d{2}|\d+\s*(分钟|小时|天)前|昨天.*|今天.*|刚刚)/u.test(text));
      comments.push({
        id: `zh-${item.getAttribute("data-id")}`,
        author,
        body,
        depth,
        ...(likes && likes !== "0" ? { likes } : {}),
        ...(published ? { published } : {}),
      });
    }
    return { comments, anchor: items.at(-1) ?? null };
  },
  prime(documentLike) {
    const answer = zhihuAnswerScope(documentLike);
    const scope: ParentNode = answer ?? documentLike;
    if (scope.querySelector(".CommentContent, [class*='CommentContent']")) return;
    // 必须点这条回答自己的按钮：页面最上面那个「N 条评论」属于问题本身。
    const buttons = Array.from(scope.querySelectorAll<HTMLElement>("button"))
      .filter((button) => !button.closest(".QuestionHeader"))
      .filter((button) => /^\d[\d,.万]*\s*条评论$|^(评论|添加评论)$/u.test(clean(button.textContent)));
    buttons[0]?.click();
  },
  loadMore(documentLike) {
    clickByText(documentLike, "button, div[role='button']", /^(点击查看全部评论|查看全部\s*\d*\s*条评论)$/u);
  },
};

// 抖音 ------------------------------------------------------------------------

const douyinReader: CommentReader = {
  read(documentLike) {
    const comments: CapturedComment[] = [];
    const items = Array.from(documentLike.querySelectorAll("[data-e2e='comment-item']"));
    for (const item of items) {
      // 楼中楼回复嵌在上一层评论里，另作一条读取；这里先去掉，免得正文里重复一遍。
      const nested = Array.from(item.querySelectorAll(".replyContainer, [data-e2e='comment-item']"));
      const own = (node: Element | null) => (node && !nested.some((reply) => reply.contains(node)) ? node : null);
      // 真评论都带作者主页链接；没有的是悬浮预览、引用卡一类的重复渲染。
      const link = Array.from(item.querySelectorAll("a[href*='/user/']")).map(own).find((node) => clean(node?.textContent));
      const lines = ownText(item, nested).split("\n");
      // 链接文字会连上「作者」标记（「ami.moment作者」），首行才是纯昵称。
      const linkText = clean(link?.textContent);
      const author = lines[0] && linkText.startsWith(lines[0]) ? lines[0] : linkText;
      if (!author) continue;
      const body = douyinCommentBody(lines, author);
      if (!body) continue;
      const published = lines.find((line) => /(\d+\s*(秒|分钟|小时|天|周|月|年)前|\d{4}-\d{2}-\d{2}|\d{1,2}-\d{1,2}|昨天|刚刚)/u.test(line));
      // 统计区第一个数字是点赞（其后是分享、回复）。
      const likes = likesText(Array.from(item.querySelectorAll(".comment-item-stats-container p span, [class*='like'] span, [data-e2e='comment-like-count']"))
        .map(own).find(Boolean)?.textContent);
      const depth = item.parentElement?.closest("[data-e2e='comment-item']") ? 1 : 0;
      comments.push({
        id: commentHashID(author, body),
        author,
        body,
        depth,
        ...(likes ? { likes } : {}),
        ...(published ? { published: clean(published) } : {}),
      });
    }
    // 标题前可能带「大家都在搜：xxx」，只取「评论」后面的数字。
    const header = clean(documentLike.querySelector("[data-e2e='comment-list']")?.previousElementSibling?.textContent);
    const countText = header.match(/评论\s*[（(]?\s*(\d[\d.,]*\s*[万wW]?)/u)?.[1];
    const expected = countText ? countFrom(countText) : undefined;
    return { comments, ...(expected ? { expectedCount: expected } : {}), anchor: items.at(-1) ?? null };
  },
  prime(documentLike) {
    // 精选/推荐页（?modal_id=）评论面板默认收起：点当前视频的评论按钮展开。
    if (documentLike.querySelector("[data-e2e='comment-list']")) return;
    documentLike.querySelector<HTMLElement>("[data-e2e='feed-active-video'] [data-e2e='feed-comment-icon']")?.click();
  },
  loadMore(documentLike, stalled) {
    if (stalled) clickByText(documentLike, ".comment-reply-expand-btn, button", /^展开\s*\d+\s*条回复/u);
  },
};

/** 去掉嵌套回复后的可见文字：克隆会丢掉 innerText 的换行，所以按原节点逐个减掉回复块的行。 */
function ownText(item: Element, nested: Element[]): string {
  let lines = blockText(item).split("\n");
  for (const reply of nested) {
    if (nested.some((outer) => outer !== reply && outer.contains(reply))) continue;
    const replyLines = blockText(reply).split("\n").filter(Boolean);
    if (!replyLines.length) continue;
    const start = findSequence(lines, replyLines);
    if (start >= 0) lines = [...lines.slice(0, start), ...lines.slice(start + replyLines.length)];
  }
  return lines.join("\n");
}

function findSequence(lines: string[], part: string[]): number {
  for (let start = 0; start + part.length <= lines.length; start += 1) {
    if (part.every((line, offset) => lines[start + offset] === line)) return start;
  }
  return -1;
}

/** 抖音评论项没有稳定的正文 class：去掉作者、标签、时间和操作文字后剩下的就是正文。 */
function douyinCommentBody(lines: string[], author: string): string {
  const noise = /^(作者|作者赞过|置顶|回复|分享|举报|\.{2,}|…+|展开\d*条回复|展开更多|收起|\d+(?:\.\d+)?[万wW]?|·|\d+\s*(秒|分钟|小时|天|周|月|年)前.*|\d{4}-\d{2}-\d{2}.*|\d{1,2}-\d{1,2}.*|昨天.*|刚刚.*)$/u;
  const kept = lines.filter((line, index) => !(index === 0 && line === author) && line !== author && !noise.test(line));
  return kept.join("\n").trim();
}

// 小红书 ----------------------------------------------------------------------

function xiaohongshuComment(item: Element, depth: number): CapturedComment | null {
  const author = clean(item.querySelector(".author .name, .author-wrapper .name")?.textContent) || "未知用户";
  const body = blockText(item.querySelector(".content .note-text, .content"));
  if (!body) return null;
  const likes = likesText(item.querySelector(".like .count, .like-wrapper .count")?.textContent);
  const published = clean(item.querySelector(".info .date, .date")?.textContent);
  const rawID = item.id?.replace(/^comment-/u, "");
  return {
    id: rawID ? `xhs-${rawID}` : commentHashID(author, body),
    author,
    body,
    depth,
    ...(likes && likes !== "0" ? { likes } : {}),
    ...(published ? { published } : {}),
  };
}

const xiaohongshuReader: CommentReader = {
  read(documentLike) {
    const comments: CapturedComment[] = [];
    const parents = Array.from(documentLike.querySelectorAll(".comments-container .parent-comment, .comments-el .parent-comment"));
    for (const parent of parents) {
      const main = parent.querySelector(".comment-item:not(.comment-item-sub)");
      const item = main ? xiaohongshuComment(main, 0) : null;
      if (!item) continue;
      comments.push(item);
      for (const sub of Array.from(parent.querySelectorAll(".comment-item-sub"))) {
        const reply = xiaohongshuComment(sub, 1);
        if (reply) comments.push(reply);
      }
    }
    const expected = countFrom(documentLike.querySelector(".comments-container .total, .comments-el .total")?.textContent);
    const loginRequired = Boolean(documentLike.querySelector(".comments-login"));
    return {
      comments,
      ...(expected ? { expectedCount: expected } : {}),
      ...(loginRequired ? { loginRequired } : {}),
      anchor: parents.at(-1) ?? null,
    };
  },
  loadMore(documentLike, stalled) {
    // 未登录时点「展开回复」会弹登录框打扰用户；出现登录墙就只保存已显示的部分。
    if (stalled && !documentLike.querySelector(".comments-login")) {
      clickByText(documentLike, ".show-more", /^展开\s*\d+\s*条回复/u);
    }
  },
};
