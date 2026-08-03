import { GENERIC_CONTENT_ROOTS, siteProfile, type SiteProfile } from "./site-profiles";
import type { MediaDescriptor } from "../contract";
import type { DouyinSessionDiagnostic } from "./douyin-session-detail";
import type { DouyinMetadataDOMDiagnostic } from "./douyin-metadata-diagnostic";
import { detectMediaInPage } from "./media-detection";
import {
  detectDouyinAwemeIdFromURL,
  isDouyinHost,
  isDouyinShellLine,
  normalizeDouyinTitle,
} from "./douyin-detect";
import { isDouyinVideoURL } from "../platform";
import { bilibiliVideoID, bilibiliCanonicalURL, isBilibiliVideoURL } from "./bilibili";
import { xiaohongshuCanonicalURL, isXiaohongshuNoteURL } from "./xiaohongshu";

export type ExtractedPage = {
  title: string;
  url: string;
  text: string;
  characterCount: number;
  method: "selection" | "rendered_dom";
  /** V2 media capability handoff. The playback URL is process-memory-only. */
  mediaDescriptor?: MediaDescriptor;
  /** True only after an explicit same-origin session-detail fallback succeeds. */
  usedCookie?: boolean;
  /** Internal popup-only diagnostic. Never enters a CaptureEnvelope. */
  mediaDiagnostic?: DouyinSessionDiagnostic;
  /** 图文帖的图片张数，仅用于 popup 文案；正文里的图片本身走 Markdown。 */
  imageCount?: number;
};

/**
 * WeChat captures are article/image records. Embedded <video> elements remain
 * browser-page content and must not promote the whole capture to a V2 video.
 */
export function attachDetectedMedia(
  page: ExtractedPage,
  mediaDescriptor: MediaDescriptor | undefined,
): ExtractedPage {
  if (!mediaDescriptor || mediaDescriptor.platform === "wechat") return page;
  return { ...page, mediaDescriptor };
}

export function isXStatusURL(rawURL: string): boolean {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase();
    if (!(host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com"))) {
      return false;
    }
    return /^\/[^/]+\/status\/\d+(?:\/|$)/u.test(url.pathname);
  } catch {
    return false;
  }
}

export function isZhihuAnswerURL(rawURL: string): boolean {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase();
    return (host === "zhihu.com" || host.endsWith(".zhihu.com"))
      && /^\/question\/\d+\/answer\/\d+(?:\/|$)/u.test(url.pathname);
  } catch {
    return false;
  }
}

/** Removes feed chrome that some caption containers prepend to the real title. */
export function stripDouyinCaptionPrefix(rawTitle: string, author: string | undefined): string {
  const original = rawTitle.trim();
  if (!original || !author?.trim()) return original;
  const escapedAuthor = author.trim().replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const authorPrefix = new RegExp(`^\\s*@?${escapedAuthor.replace(/^@/u, "@?")}\\s*`, "u");
  const withoutAuthor = original.replace(authorPrefix, "");
  if (withoutAuthor === original) return original;
  const cleaned = withoutAuthor.replace(
    /^(?:[·•|｜,，]\s*)?(?:(?:\d+\s*(?:秒|分钟|小时|天|周|月|年)\s*前)|刚刚|昨天|前天)(?:\s*[·•|｜,，])?\s*/u,
    "",
  ).trim();
  return cleaned || original;
}

/** Line-level noise aligned with Swift MinimalHTMLExtractor.boilerplateLineMarkers. */
export const BOILERPLATE_LINE_MARKERS = [
  "相关阅读",
  "相关推荐",
  "推荐阅读",
  "热门文章",
  "猜你喜欢",
  "更多精彩",
  "点击关注",
  "扫码关注",
  "分享到",
  "版权声明",
  "免责声明",
  "阅读原文",
  "写留言",
  "精选留言",
  "打开微信",
  "关注公众号",
  "广告",
] as const;

// Single string (not array.join) so minifiers keep attribute selectors intact.
const NOISE_SELECTOR =
  "script,style,noscript,template,nav,footer,header,aside,form,iframe,svg,button," +
  "[class*='qrcode' i],[id*='qrcode' i],[class*='reward' i]," +
  "[class*='rich_media_tool' i],[class*='rich_media_area_extra' i],[id*='js_tags' i]," +
  "[class*='sns_opr' i],[class*='comment' i],[id*='comment' i]," +
  "[class*='related' i],[class*='recommend' i],[class*='hot-article' i]," +
  "[class*='ad-' i],[id*='ad-' i],[class*='advert' i],[class*='promo' i]," +
  "[class*='subscribe' i],[class*='subscription' i],[class*='newsletter' i]";

/**
 * Testable extraction against a Document-like object.
 * Production injection runs this same function through entrypoints/extract-page.ts.
 */
export function extractCurrentPage(documentLike: Document = document): ExtractedPage {
  const selection = documentLike.defaultView?.getSelection()?.toString() ?? "";
  if (selection.trim()) {
    const text = normalizeMarkdownWhitespace(selection);
    return page(documentLike, text, "selection");
  }

  if (isXStatusURL(documentLike.location.href)) {
    return extractXStatusPage(documentLike);
  }

  if (isDouyinVideoURL(documentLike.location.href)) {
    return extractDouyinPage(documentLike);
  }

  if (isBilibiliVideoURL(documentLike.location.href)) {
    return extractBilibiliPage(documentLike);
  }

  if (isXiaohongshuNoteURL(documentLike.location.href)) {
    return extractXiaohongshuPage(documentLike);
  }

  // Bare Douyin feed (no modal_id /video id): do not scrape the site chrome as "article".
  if (isDouyinHost(documentLike.location.href)) {
    const text =
      "未识别到单条抖音视频。请打开具体视频页，或在精选里点开弹层后再发送。";
    return {
      title: normalizeDouyinTitle(resolveTitle(documentLike)) || "抖音",
      url: documentLike.location.href,
      text,
      characterCount: [...text].length,
      method: "rendered_dom",
    };
  }

  const root = pickContentRoot(documentLike);
  const clone = root.cloneNode(true) as Element;
  scrubNoise(clone);
  const baseHref = documentLike.location.href;
  const markdown = htmlElementToMarkdown(clone, baseHref);
  // 出口归一化：来源怎么写标题都不影响产出的层级结构。
  const body = rebaseHeadingLevels(stripBoilerplateLines(markdown));
  const meta = isZhihuAnswerURL(baseHref)
    ? { ...resolvePageMetadata(documentLike), ...resolveZhihuAnswerMetadata(documentLike) }
    : resolvePageMetadata(documentLike);
  const header = buildCaptureFrontmatter(meta);
  const text = `${header}${body}`.trim();
  return page(documentLike, text, "rendered_dom");
}

function page(
  documentLike: Document,
  text: string,
  method: ExtractedPage["method"],
  mediaDescriptor?: MediaDescriptor,
): ExtractedPage {
  const cleaned = text.trim();
  return {
    title: resolveTitle(documentLike),
    url: documentLike.location.href,
    text: cleaned,
    characterCount: [...cleaned].length,
    method,
    ...(mediaDescriptor ? { mediaDescriptor } : {}),
  };
}

/**
 * Single Douyin video only — never the jingxuan/feed chrome.
 * URL is canonicalized to `/video/{awemeId}` when an ID is known (incl. modal_id).
 * Media classification reads only the current DOM's public video/source state.
 */
export function extractDouyinPage(documentLike: Document): ExtractedPage {
  const pageHref = documentLike.location.href;
  const detected = detectDouyinAwemeIdFromURL(pageHref);
  const canonicalURL = detected?.canonicalURL || pageHref;

  const detectedMedia = detectMediaInPage(documentLike);
  const meta = resolvePageMetadata(documentLike);
  const ogTitle = documentLike.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
  const ogDescription = documentLike
    .querySelector("meta[property='og:description']")
    ?.getAttribute("content")
    ?.trim();
  const rawTitle =
    ogTitle
    || documentLike.querySelector("h1")?.textContent?.trim()
    || resolveTitle(documentLike);
  const author =
    meta.author
    || documentLike.querySelector("[data-e2e='user-info']")?.textContent?.trim()
    || documentLike.querySelector("[data-e2e='feed-video-nickname']")?.textContent?.trim()
    || undefined;
  const title = normalizeDouyinTitle(stripDouyinCaptionPrefix(rawTitle, author)) || "抖音视频";
  // Prefer description nodes for the *current* item; never walk the full body chrome.
  const descriptionRaw =
    ogDescription
    || documentLike.querySelector("[data-e2e='video-desc']")?.textContent?.trim()
    || documentLike.querySelector("[data-e2e='browse-video-desc']")?.textContent?.trim()
    || documentLike.querySelector("[class*='video-info-detail']")?.textContent?.trim()
    || "";
  const description = descriptionRaw
    .split(/\n+/u)
    .map((line) => line.trim())
    .filter((line) => line && !isDouyinShellLine(line))
    .join("\n")
    .trim();

  const lines = ["---"];
  if (author) lines.push(`author: ${JSON.stringify(author)}`);
  if (detected?.awemeId) lines.push(`aweme_id: ${JSON.stringify(detected.awemeId)}`);
  const header = lines.length > 1 ? `${lines.join("\n")}\n---\n\n` : "";
  const bodyParts = [title ? `# ${title}` : "", description].filter(Boolean);
  // Never fall back to document.body — that is how feed navigation leaked in.
  const text = `${header}${bodyParts.join("\n\n")}`.trim() || "抖音公开视频";
  const cleaned = text.trim();
  return {
    title,
    url: canonicalURL,
    text: cleaned,
    characterCount: [...cleaned].length,
    method: "rendered_dom",
    ...(detectedMedia ? {
      mediaDescriptor: {
        ...detectedMedia,
        pageURL: pageHref,
        canonicalURL,
        platform: "douyin" as const,
        ...(author ? { author } : {}),
      },
    } : {}),
  };
}

/**
 * Bilibili single video (v1): a public text record of title / uploader /
 * description, keyed to the canonical `/video/{BV|av}` page. No DASH download
 * and no subtitle fetch — those stay a later, opt-in step. Reads only og:meta
 * and the watching page's own DOM; never a private API or login-walled data.
 */
/**
 * 截掉 B 站 og:description 的 SEO 尾巴。拼接点固定是「, 视频播放量 <数字>」，
 * 之后全是统计、作者简介和相关视频标题，一个字都不属于这条视频的正文。
 */
function stripBilibiliMetaTail(raw: string): string {
  return raw.split(/[,，]\s*视频播放量\s*\d/u)[0]?.trim() ?? "";
}

function normalizeBilibiliComparable(raw: string): string {
  return raw
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[\p{P}\p{S}\s]+/gu, "");
}

/**
 * B 站在视频未填写简介时会拿站点宣传语或视频标题填充 og:description。
 * 这里只清理两类有明确现场证据的假正文；只要描述比标题多出真实信息就保留。
 */
function cleanBilibiliMetaDescription(raw: string, title: string): string {
  const candidate = stripBilibiliMetaTail(raw);
  if (!candidate) return "";

  const compact = candidate.replace(/\s+/gu, "");
  if (/更多实用攻略教学/iu.test(compact) && /尽在哔哩哔哩bilibili/iu.test(compact)) {
    return "";
  }

  const normalizedTitle = normalizeBilibiliComparable(title);
  const normalizedCandidate = normalizeBilibiliComparable(
    candidate.replace(/[_\-—|]\s*(哔哩哔哩|bilibili).*$/iu, ""),
  );
  if (
    normalizedTitle
    && normalizedCandidate
    && normalizedCandidate.length % normalizedTitle.length === 0
    && normalizedCandidate === normalizedTitle.repeat(normalizedCandidate.length / normalizedTitle.length)
  ) {
    return "";
  }
  return candidate;
}

export function extractBilibiliPage(documentLike: Document): ExtractedPage {
  const pageHref = documentLike.location.href;
  const videoID = bilibiliVideoID(pageHref);
  const canonicalURL = videoID ? bilibiliCanonicalURL(videoID) : pageHref;

  const meta = resolvePageMetadata(documentLike);
  const ogTitle = documentLike.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
  const ogDescription = documentLike
    .querySelector("meta[property='og:description']")
    ?.getAttribute("content")
    ?.trim();
  const rawTitle =
    ogTitle
    || documentLike.querySelector("h1")?.getAttribute("title")?.trim()
    || documentLike.querySelector("h1")?.textContent?.trim()
    || resolveTitle(documentLike);
  // B 站的 og:title 常带「_哔哩哔哩_bilibili」站点后缀，去掉更干净。
  const title = (rawTitle || "")
    .replace(/[_\-—|]\s*(哔哩哔哩|bilibili).*$/iu, "")
    .trim() || "哔哩哔哩视频";
  const author =
    meta.author
    || documentLike.querySelector(".up-name, .up-detail-top a, [class*='up-name' i]")?.textContent?.trim()
    || undefined;
  // B 站的 og:description 是给搜索引擎看的：简介后面接着播放量/弹幕/点赞/投币/
  // 收藏/转发、作者、作者简介，最后还拼上一串"相关视频"标题。实测 351 字里只有
  // 前 16 字是真简介，所以从「视频播放量」这个固定拼接点截断，绝不把推荐位标题
  // 当成正文。
  //
  // 2026-07-26 真机实测更正：下面三个 DOM 候选**当前一个都拿不到简介**。
  // `.basic-desc-info` 是个空 div，父容器 `#v_desc` 还带着 `style="display:none;"`，
  // 简介正文根本没进 DOM（推测在 MAIN world 的 `__INITIAL_STATE__` 里，隔离世界
  // 的 content script 够不着）。也就是说实际走的永远是下面的 og 兜底路径。
  // 选择器留着当保险——它们只花一次 querySelector，B 站改回服务端渲染就自动生效；
  // 但别再据此以为「优先读 DOM」是当前的真实行为。
  // 没填简介时的通用宣传语或标题副本由 cleanBilibiliMetaDescription 丢弃。
  const description = (documentLike
    .querySelector(".basic-desc-info, [class*='desc-info' i], [class*='video-desc' i]")
    ?.textContent?.trim()
    || cleanBilibiliMetaDescription(ogDescription ?? "", title)
    || "")
    .split(/\n+/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n")
    .trim();

  // Engagement + publish time come from the watch-page toolbar, which renders
  // the human-facing 万/亿 strings the reader already sees. The SSR
  // `__INITIAL_STATE__` is a MAIN-world global the isolated content script can
  // never reach, so the toolbar DOM is the only stable in-page source. `reply`
  // (评论) lives in the lazy comment component and is intentionally skipped.
  const published =
    documentLike.querySelector(".pubdate-text, [class*='pubdate']")?.textContent?.trim()
    || meta.published
    || undefined;
  const header = buildCaptureFrontmatter({
    author,
    published,
    likes: firstDomCount(documentLike, ".video-like-info"),
    collects: firstDomCount(documentLike, ".video-fav-info"),
    shares: firstDomCount(documentLike, ".video-share-info"),
    views: firstDomCount(documentLike, ".view-text"),
  });
  // Title is shown by the app's detail header already; drop the body H1 dup.
  const text = `${header}${description}`.trim() || "哔哩哔哩公开视频";
  const cleaned = text.trim();
  return {
    title,
    url: canonicalURL,
    text: cleaned,
    characterCount: [...cleaned].length,
    method: "rendered_dom",
  };
}

/**
 * 笔记图集：只收轮播里的正片图。loop 模式的 swiper 会在首尾插克隆 slide（实测
 * 7 张图渲染成 9 个节点，第一个就是最后一张的克隆），每个 slide 上的
 * `data-swiper-slide-index` 才是这张图在笔记里的真实序号——按它排序既能去掉
 * 克隆重复，也能在某个真实 slide 尚未懒加载出 src 时由克隆补位。
 * 类名判断必须按空格切词：真实的末张 slide 带 `swiper-slide-duplicate-prev`，
 * 子串匹配会把它误判成克隆。评论配图与头像走别的子域/路径，顺带挡掉。
 */
function xiaohongshuNoteImages(scope: ParentNode, baseHref: string): string[] {
  // 视频笔记的轮播里放的是封面，不是图集；带 <video> 就整体不收。
  if (scope.querySelector("video")) return [];
  const galleryURL = (raw: string | null | undefined): string => {
    const trimmed = (raw ?? "").trim();
    if (!trimmed || trimmed.length > 2048) return "";
    try {
      const url = new URL(trimmed, baseHref);
      // 部分 <img> 给的是 http，同一资源 https 可取。
      if (url.protocol === "http:") url.protocol = "https:";
      if (url.protocol !== "https:") return "";
      const host = url.hostname.toLowerCase();
      if (host !== "xhscdn.com" && !host.endsWith(".xhscdn.com")) return "";
      if (host.startsWith("sns-avatar")) return "";
      if (url.pathname.includes("/comment/")) return "";
      return url.href;
    } catch {
      return "";
    }
  };
  const byIndex = new Map<number, string>();
  const inDOMOrder: string[] = [];
  for (const node of scope.querySelectorAll(".swiper-slide img")) {
    const slide = node.closest?.(".swiper-slide") ?? null;
    const srcset = node.getAttribute("srcset");
    const url = galleryURL(node.getAttribute("src"))
      || galleryURL(srcset ? srcset.split(",")[0]?.trim().split(/\s+/u)[0] : null);
    if (!url) continue;
    const rawIndex = slide?.getAttribute("data-swiper-slide-index");
    if (rawIndex && /^\d{1,3}$/u.test(rawIndex)) {
      const index = Number(rawIndex);
      if (!byIndex.has(index)) byIndex.set(index, url);
      continue;
    }
    // 没有序号属性（未开 loop 的轮播）时退回 DOM 顺序，并跳过克隆。
    const classes = (slide?.getAttribute("class") ?? "").split(/\s+/u);
    if (classes.includes("swiper-slide-duplicate")) continue;
    if (!inDOMOrder.includes(url)) inDOMOrder.push(url);
  }
  const ordered = byIndex.size > 0
    ? [...byIndex.entries()].sort((a, b) => a[0] - b[0]).map(([, url]) => url)
    : inDOMOrder;
  // 小红书单篇图文笔记最多 18 张，收得比这多说明圈进了别的笔记。
  return ordered.slice(0, 18);
}

/**
 * Xiaohongshu note (v1): a public text record of the note's title / author /
 * body from the page the user is viewing in their own session. Reads og:meta
 * and the note DOM only — never the signed x-s/x-t API, never the feed shell.
 */
export function extractXiaohongshuPage(documentLike: Document): ExtractedPage {
  const pageHref = documentLike.location.href;
  const canonicalURL = xiaohongshuCanonicalURL(pageHref);

  const meta = resolvePageMetadata(documentLike);
  // 笔记详情容器。信息流卡片和每一条评论都带 `.like-wrapper .count`，笔记打开成
  // 弹层时它们还排在 DOM 前面，所有笔记级读取都必须先收敛到这里。
  const note: ParentNode = documentLike.querySelector("#noteContainer") ?? documentLike;
  const ogTitle = documentLike.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
  const ogDescription = documentLike
    .querySelector("meta[property='og:description']")
    ?.getAttribute("content")
    ?.trim();
  const rawTitle =
    ogTitle
    || note.querySelector("#detail-title, .title")?.textContent?.trim()
    || resolveTitle(documentLike);
  const title = (rawTitle || "")
    .replace(/[_\-—|]\s*(小红书|xiaohongshu|RED).*$/iu, "")
    .trim() || "小红书笔记";
  const author =
    meta.author
    || note.querySelector(".author-wrapper .username, .username, [class*='author' i] [class*='name' i]")?.textContent?.trim()
    || undefined;
  const description = (ogDescription
    || note.querySelector("#detail-desc, .note-content .desc, .desc")?.textContent?.trim()
    || "")
    .split(/\n+/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n")
    .trim();

  // 笔记自己的互动数只在详情 `.engage-bar` 里。评论用的是同名的 `.like-wrapper
  // .count`，信息流卡片同样如此，所以这里既要限定在笔记容器内，也要限定在
  // engage-bar 内——两层缺一层就会读到别人的数字。选择器失配时宁可不写数字，
  // 也不回退到全文档匹配。发布日期在 `.bottom-container`，剥掉「编辑于」前缀。
  const published =
    note.querySelector(".bottom-container .date")?.textContent?.trim()
      ?.replace(/^(?:编辑于|发布于)\s*/u, "").trim()
    || meta.published
    || undefined;
  const header = buildCaptureFrontmatter({
    author,
    published,
    likes: firstDomCount(note, ".engage-bar .like-wrapper .count"),
    comments: firstDomCount(note, ".engage-bar .chat-wrapper .count"),
    collects: firstDomCount(note, ".engage-bar .collect-wrapper .count"),
  });
  // Title is shown by the app's detail header already; drop the body H1 dup.
  // 图集内联成 Markdown 图片，由 App 的远程图片暂存路径下载落地。
  const images = xiaohongshuNoteImages(note, pageHref);
  const gallery = images.map((url) => `![](${url})`).join("\n\n");
  const body = [description, gallery].filter(Boolean).join("\n\n");
  // 抓不到正文时给人话提示，绝不回退到 document.body 的信息流外壳。
  const text = body
    ? `${header}${body}`.trim()
    : "未能从当前页面提取小红书笔记正文。请在具体笔记详情页打开后再发送。";
  const cleaned = text.trim();
  return {
    title,
    url: canonicalURL,
    text: cleaned,
    characterCount: [...cleaned].length,
    method: "rendered_dom",
    ...(images.length > 0 ? { imageCount: images.length } : {}),
  };
}

/**
 * X status posts: walk the main tweet in document order (text ↔ photos interleaved).
 * Author / time / engagement → frontmatter only when a stable parse succeeds.
 */
function extractXStatusPage(documentLike: Document): ExtractedPage {
  const baseHref = documentLike.location.href;
  const article =
    documentLike.querySelector("article[data-testid='tweet']") ??
    documentLike.querySelector("article");

  const meta = resolveXStatusMetadata(documentLike, article);
  const header = buildCaptureFrontmatter(meta);
  const body = buildXStatusBody(documentLike, article, baseHref);
  const text = `${header}${body}`.trim();
  // X long-form articles carry an explicit title node — always the full
  // headline, unlike tab titles which browsers truncate and prefix.
  const articleTitle = documentLike
    .querySelector("[data-testid='twitter-article-title']")
    ?.textContent?.replace(/\s+/g, " ")
    .trim();
  // page() would re-resolve title from DOM; set short display title explicitly.
  const postText = firstProseFromMarkdown(body);
  const shortTitle =
    (articleTitle && articleTitle.length >= 4 && articleTitle.length <= 120 ? articleTitle : "")
    || formatXDisplayTitle(postText, documentLike.title ?? "");
  const cleaned = text.trim();
  return {
    title: shortTitle || resolveTitle(documentLike),
    url: documentLike.location.href,
    text: cleaned,
    characterCount: [...cleaned].length,
    method: "rendered_dom",
  };
}

/**
 * DOM-order blocks: tweetText segments and tweetPhoto images as they appear.
 * Never collapse the whole article into one line then dump all photos at the end.
 */
function buildXStatusBody(
  documentLike: Document,
  article: Element | null,
  baseHref: string,
): string {
  const root = article ?? documentLike.documentElement;
  const blocks = collectXStatusBlocksInOrder(root, baseHref);
  if (blocks.length === 0) {
    const fallback = cleanXPageTitle(documentLike.title ?? "");
    return fallback;
  }
  // Every block is already normalized. Do not collapse repeated spaces here:
  // fenced code blocks rely on indentation (for example directory trees).
  return blocks.join("\n\n").replace(/\r\n/g, "\n").trim();
}

/**
 * Collect X prose + media in document order.
 *
 * Regular posts expose tweetText/tweetPhoto semantic nodes. X long-form articles
 * instead put their prose inside twitterArticleReadView while keeping media as
 * tweetPhoto nodes. Both paths must emit from one tree-order walk; rebuilding the
 * body from "all prose" plus "all photos" destroys the source layout.
 */
export function collectXStatusBlocksInOrder(root: Element, baseHref: string): string[] {
  const blocks: string[] = [];
  const seenMedia = new Map<string, { href: string; rank: number }>();
  const textChunks: string[] = [];

  const emitMedia = (mediaRoot: Element) => {
    const tag = mediaRoot.tagName.toLowerCase();
    const candidates =
      tag === "img" || tag === "video"
        ? [mediaRoot]
        : Array.from(mediaRoot.querySelectorAll("img, video[poster]"));
    candidates.forEach((media) => {
      const raw =
        media.getAttribute("data-src") ||
        media.getAttribute("data-original") ||
        media.getAttribute("src") ||
        media.getAttribute("poster") ||
        "";
      const href = absoluteUrl(raw, baseHref);
      // 视频封面不进正文：视频本体由 App 换直链存下来，封面只会重复一遍画面。
      if (!href || isXProfileChromeImageURL(href) || isXVideoThumbnailURL(href)) return;
      const key = xMediaDedupeKey(href);
      const rank = xMediaSizeRank(href);
      const prev = seenMedia.get(key);
      if (prev && prev.rank > rank) return;
      if (prev) {
        const marker = `![](${prev.href})`;
        const idx = blocks.indexOf(marker);
        if (idx >= 0) blocks[idx] = `![](${href})`;
      } else {
        blocks.push(`![](${href})`);
      }
      seenMedia.set(key, { href, rank });
    });
  };

  const appendProse = (raw: string) => {
    const prose = formatXPostProse(raw);
    const key = prose.replace(/\s+/g, " ").trim();
    if (key.length < 1 || textChunks.includes(key)) return;
    textChunks.push(key);
    blocks.push(prose);
  };

  const appendMarkdownBlock = (markdown: string, plainText = markdown) => {
    const cleaned = markdown.trim();
    const key = plainText.replace(/\s+/g, " ").trim();
    if (!cleaned || !key || textChunks.includes(key)) return;
    textChunks.push(key);
    blocks.push(cleaned);
  };

  const appendCodeBlock = (container: Element) => {
    const pre = container.tagName.toLowerCase() === "pre" ? container : container.querySelector("pre");
    const code = pre?.querySelector("code") ?? pre;
    const raw = (code?.textContent ?? "").replace(/\r\n/g, "\n").replace(/^\n|\n+$/g, "");
    if (!raw) return;
    const language = (code?.getAttribute("class") ?? "").match(/(?:^|\s)language-([A-Za-z0-9_+-]+)/)?.[1] ?? "";
    const longestBackticks = Math.max(0, ...(raw.match(/`+/g) ?? []).map((run) => run.length));
    const fence = "`".repeat(Math.max(3, longestBackticks + 1));
    appendMarkdownBlock(`${fence}${language}\n${raw}\n${fence}`, raw);
  };

  const walkRichArticleInOrder = (articleRoot: Element) => {
    const proseParts: string[] = [];
    const flushProse = () => {
      const raw = proseParts.join("");
      proseParts.length = 0;
      appendProse(raw);
    };
    const walk = (node: Node): void => {
      if (node.nodeType === 3) {
        proseParts.push((node.textContent ?? "").replace(/\u00a0/g, " "));
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node as Element;
      const tag = el.tagName.toLowerCase();
      const testId = el.getAttribute("data-testid") ?? "";
      if (testId === "tweetPhoto" || testId === "videoPlayer") {
        flushProse();
        emitMedia(el);
        return;
      }
      if (testId === "markdown-code-block") {
        flushProse();
        appendCodeBlock(el);
        return;
      }
      if (testId === "twitter-article-title" || /^h[1-6]$/.test(tag)) {
        flushProse();
        const heading = formatXPostProse(el.textContent ?? "").replace(/\s+/g, " ").trim();
        const level = testId === "twitter-article-title" ? 1 : Number(tag[1]);
        appendMarkdownBlock(`${"#".repeat(level)} ${heading}`, heading);
        return;
      }
      if (tag === "pre") {
        flushProse();
        appendCodeBlock(el);
        return;
      }
      if (tag === "blockquote") {
        flushProse();
        const quote = formatXPostProse(el.textContent ?? "");
        appendMarkdownBlock(
          quote
            .split("\n")
            .map((line) => (line.trim() ? `> ${line}` : ">"))
            .join("\n"),
          quote,
        );
        return;
      }
      if (tag === "ul" || tag === "ol") {
        const items = Array.from(el.children).filter((child) => child.tagName.toLowerCase() === "li");
        if (items.length > 0) {
          flushProse();
          const lines = items.map((item, index) => {
            const prefix = tag === "ol" ? `${index + 1}.` : "-";
            return `${prefix} ${(item.textContent ?? "").replace(/\s+/g, " ").trim()}`;
          });
          appendMarkdownBlock(lines.join("\n"), lines.join(" "));
          return;
        }
      }
      if (
        testId === "User-Name" ||
        tag === "script" ||
        tag === "style" ||
        tag === "noscript" ||
        tag === "template" ||
        tag === "button" ||
        tag === "time" ||
        tag === "svg"
      ) {
        return;
      }
      if (tag === "br") {
        proseParts.push("\n");
        return;
      }
      const block =
        tag === "div" ||
        tag === "p" ||
        tag === "section" ||
        tag === "li";
      if (block) proseParts.push("\n");
      Array.from(el.childNodes).forEach((child) => walk(child));
      if (block) proseParts.push("\n");
    };
    walk(articleRoot);
    flushProse();
  };

  // X long-form posts have no tweetText nodes. Their read-view container is the
  // smallest stable scope that contains both article prose and inline media.
  const richArticle = root.querySelector("[data-testid='twitterArticleReadView']");
  if (richArticle) {
    walkRichArticleInOrder(richArticle);
    // The read view appends a Premium upsell row after the article body;
    // it is page chrome, not the author's prose.
    const kept = dropXArticleUpsellBlocks(blocks);
    if (kept.length > 0) return kept;
  }

  const nodes = Array.from(
    root.querySelectorAll(
      "[data-testid='tweetText'], [data-testid='tweetPhoto'], [data-testid='videoPlayer']",
    ),
  );
  for (const node of nodes) {
    const testId = node.getAttribute("data-testid") ?? "";
    if (testId === "tweetText") {
      appendProse(extractXTextWithBreaks(node));
      continue;
    }
    if (testId === "tweetPhoto" || testId === "videoPlayer") emitMedia(node);
  }

  if (!textChunks.length) {
    const scrubbed = scrubXArticleChrome(root.cloneNode(true) as Element);
    const scrubProse = formatXPostProse(extractXTextWithBreaks(scrubbed));
    const scrubKey = scrubProse.replace(/\s+/g, " ").trim();
    if (scrubKey.length >= 2 && !/^@?[A-Za-z0-9_]{1,15}$/.test(scrubKey)) {
      blocks.unshift(scrubProse);
    }
  }

  return blocks;
}

// The read-view upsell renders as one merged block or as two separate
// blocks ("想发布自己的文章？" + "升级为 Premium"); both shapes are chrome.
const X_ARTICLE_UPSELL_PATTERN =
  /^(?:想发布自己的文章[？?]?(?:\s*升级为\s*Premium。?)?|升级为\s*Premium。?|Want to publish your own Articles\??(?:\s*Upgrade to Premium\.?)?|Upgrade to Premium\.?)$/iu;

function dropXArticleUpsellBlocks(blocks: string[]): string[] {
  return blocks.filter((block) => !X_ARTICLE_UPSELL_PATTERN.test(block.replace(/\s+/g, " ").trim()));
}

/** Prefer real line breaks from the DOM; soft-wrap Chinese walls when X gives one blob. */
export function extractXTextWithBreaks(root: Element): string {
  const parts: string[] = [];
  const walk = (node: {
    nodeType: number;
    textContent?: string | null;
    tagName?: string;
    childNodes?: ArrayLike<Node>;
  }): void => {
    if (node.nodeType === 3) {
      parts.push((node.textContent ?? "").replace(/\u00a0/g, " "));
      return;
    }
    if (node.nodeType !== 1) return;
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    if (tag === "br") {
      parts.push("\n");
      return;
    }
    if (tag === "img" || tag === "svg" || tag === "button" || tag === "time") return;
    const block = tag === "p" || tag === "div" || tag === "li" || tag === "blockquote" || /^h[1-6]$/.test(tag);
    if (block) parts.push("\n");
    Array.from(el.childNodes).forEach((child) => walk(child));
    if (block) parts.push("\n");
  };
  walk(root);
  return parts.join("");
}

/** Turn a raw X text blob into readable markdown paragraphs. */
export function formatXPostProse(raw: string): string {
  let value = raw.replace(/\r\n/g, "\n").replace(/[ \t]+\n/g, "\n").trim();
  if (!value) return "";
  // Collapse spaces inside lines but keep intentional breaks.
  value = value
    .split("\n")
    .map((line) => line.replace(/[ \t\u00a0]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  const lineCount = value.split("\n").filter((l) => l.trim()).length;
  if (lineCount <= 1 && /[。！？；]/.test(value)) {
    // X often delivers long posts as one line — restore sentence / section breaks.
    value = value
      .replace(/([。！？])(?=["”」』]?)/g, "$1\n\n")
      .replace(/(?=[（(]?[一二三四五六七八九十百]+[、．.])/g, "\n\n")
      .replace(/(?=\d+[.、．]\s*)/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }
  return value;
}

/** Short list/reading title — never the whole post wall. */
export function formatXDisplayTitle(postText: string, pageOrTabTitle = ""): string {
  const fromTab = cleanXPageTitle(pageOrTabTitle);
  if (fromTab && fromTab.length <= 48) return fromTab;

  const prose = postText.replace(/\s+/g, " ").trim();
  if (!prose) return fromTab;

  // Prefer first sentence when punctuation exists.
  const sentence = prose.match(/^.{4,48}?[。！？!?]/u)?.[0];
  if (sentence && sentence.length >= 4 && sentence.length <= 48) {
    return sentence.replace(/[。！？!?]$/u, "").trim() || sentence;
  }

  // No punctuation between hook and body (common on X): take a short prefix.
  // Prefer breaking before “昨天/我把/今天/分享” style continuations when early.
  const soft = prose.match(
    /^(.{8,36}?)(?=昨天|今天|刚才|之前|我把|我们|很多|首先|一、|1[.、]|GitHub|http)/u,
  );
  if (soft?.[1]) return soft[1].trim();

  const clipped = prose.slice(0, 36).trim();
  return prose.length > 36 ? `${clipped}…` : clipped;
}

function firstProseFromMarkdown(markdown: string): string {
  for (const line of markdown.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("![") || /^`{3,}/.test(t) || t === "---") continue;
    if (/^(author|published|likes|replies|reposts):/i.test(t)) continue;
    return t.replace(/^#{1,6}\s+/, "");
  }
  // Multi-line first paragraph
  const withoutImages = markdown
    .split("\n")
    .filter((l) => !l.trim().startsWith("!["))
    .join("\n");
  return withoutImages.replace(/^---[\s\S]*?---\n*/, "").trim();
}

/** Strip author row, timestamps, action bars, and media so remaining text is the post. */
function scrubXArticleChrome(root: Element): Element {
  root
    .querySelectorAll(
      "[data-testid='User-Name'],[data-testid='tweetPhoto'],[data-testid='videoPlayer']," +
        "[data-testid='card.wrapper'],[data-testid='like'],[data-testid='unlike']," +
        "[data-testid='reply'],[data-testid='retweet'],[data-testid='unretweet']," +
        "[data-testid='bookmark'],time,button,svg",
    )
    .forEach((node) => node.remove());
  root.querySelectorAll("[role='group']").forEach((node) => node.remove());
  root.querySelectorAll("img").forEach((img) => {
    const src = img.getAttribute("src") ?? "";
    if (isXProfileChromeImageURL(src) || src.includes("profile_images")) img.remove();
  });
  return root;
}

/**
 * Browser tab titles for X status pages often look like:
 * - `X 上的 Name：“quote” / X`
 * - `Name on X: "quote" / X`
 */
export function cleanXPageTitle(raw: string): string {
  let value = raw.replace(/\s+/g, " ").trim();
  if (!value) return "";
  // Browser tabs prefix unread counts ("(1) X"); they are chrome, not title.
  value = value.replace(/^[（(]\d+\+?[)）]\s*/u, "").trim();
  value = value.replace(/\s*\/\s*X\s*$/iu, "").trim();
  value = value.replace(/^X\s*上的\s+.+?[:：]\s*/u, "").trim();
  value = value.replace(/^.+?\s+on\s+X\s*[:：]\s*/iu, "").trim();
  value = value.replace(/^[\s"'“”«»「『]+|[\s"'“”«»」』]+$/gu, "").trim();
  if (!value || /^x$/i.test(value) || /^@?[A-Za-z0-9_]{1,15}$/.test(value)) return "";
  // Tab titles should stay short hooks, not full posts. Cut at sentence
  // punctuation only — cutting at the first space truncated English titles
  // down to their first words.
  if (value.length > 48) {
    const sentence = value.match(/^(.{4,48}?)[。！？!?]/u);
    if (sentence?.[1]) return sentence[1].trim();
    return `${value.slice(0, 36).trim()}…`;
  }
  return value;
}

/** True when capture body has no prose — only YAML / image markers. */
export function captureBodyLacksProse(markdown: string): boolean {
  const withoutYaml = markdown.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, "");
  for (const line of withoutYaml.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("![") && trimmed.includes("](")) continue;
    if (/^https?:\/\//i.test(trimmed)) continue;
    return false;
  }
  return true;
}

/**
 * Normalize X capture titles after extraction / inject tab-title prose only when
 * the body is image-only. Never turn the whole post into the list title.
 */
export function enrichXCaptureWithTitleFallback(
  page: ExtractedPage,
  tabTitle?: string | null,
): ExtractedPage {
  if (!isXStatusURL(page.url)) return page;

  const bodyProse = firstProseFromMarkdown(page.text.replace(/^---[\s\S]*?---\n*/, ""));
  let next = page;

  if (captureBodyLacksProse(page.text)) {
    const cleaned =
      cleanXPageTitle(tabTitle ?? "") ||
      cleanXPageTitle(page.title) ||
      "";
    if (cleaned) {
      const text = injectProseAfterFrontmatter(page.text, cleaned);
      next = { ...page, text, characterCount: [...text].length };
    }
  }

  const title = formatXDisplayTitle(
    firstProseFromMarkdown(next.text.replace(/^---[\s\S]*?---\n*/, "")) || bodyProse,
    tabTitle || page.title,
  );
  if (title) {
    next = { ...next, title };
  }
  return next;
}

function injectProseAfterFrontmatter(markdown: string, prose: string): string {
  const normalized = markdown.replace(/\r\n/g, "\n");
  if (normalized.startsWith("---\n")) {
    const end = normalized.indexOf("\n---", 4);
    if (end !== -1) {
      const header = normalized.slice(0, end + 4);
      const rest = normalized.slice(end + 4).replace(/^\n+/, "");
      // Avoid duplicating the same hook already present as the first prose line.
      if (rest.replace(/\s+/g, " ").includes(prose.slice(0, Math.min(20, prose.length)))) {
        return `${header}\n\n${rest}`.trim();
      }
      return `${header}\n\n${prose}\n\n${rest}`.trim();
    }
  }
  return `${prose}\n\n${normalized}`.trim();
}

/** pbs.twimg.com/media/ID?... → ID; otherwise full URL. */
export function xMediaDedupeKey(href: string): string {
  try {
    const url = new URL(href);
    const match = url.pathname.match(/\/media\/([^/]+)/i);
    if (match?.[1]) return match[1].replace(/\.(jpg|jpeg|png|webp|gif)$/i, "");
    return `${url.origin}${url.pathname}`;
  } catch {
    return href;
  }
}

function xMediaSizeRank(href: string): number {
  try {
    const name = new URL(href).searchParams.get("name")?.toLowerCase() ?? "";
    if (name === "large" || name === "orig" || name === "4096x4096") return 40;
    if (name === "medium") return 30;
    if (name === "small") return 20;
    if (name === "thumb" || name === "120x120") return 10;
    return 25;
  } catch {
    return 0;
  }
}

/** Avatar / default-profile CDN — never treat as post media. */
export function isXProfileChromeImageURL(href: string): boolean {
  try {
    const path = new URL(href).pathname.toLowerCase();
    const full = href.toLowerCase();
    if (full.includes("profile_images") || full.includes("default_profile")) return true;
    if (/_(?:normal|bigger|mini|x96|400x400)\./.test(path)) return true;
    return false;
  } catch {
    return false;
  }
}

/**
 * X 视频的封面帧：`video[poster]` 与 `*_video_thumb/` 路径都是同一段视频的
 * 静止画面。桌面 App 现在能换回真实直链并把视频本体存下来，正文里再塞一张
 * 封面就成了重复内容（帖子本身也不显示它）。
 */
export function isXVideoThumbnailURL(href: string): boolean {
  try {
    const path = new URL(href).pathname.toLowerCase();
    return /\/(?:amplify_video_thumb|ext_tw_video_thumb|tweet_video_thumb)\//.test(path);
  } catch {
    return false;
  }
}

export function resolveXStatusMetadata(
  documentLike: Document,
  article: Element | null = null,
): {
  author?: string;
  published?: string;
  likes?: string;
  replies?: string;
  reposts?: string;
} {
  const scope = article ?? documentLike;
  const metadata: {
    author?: string;
    published?: string;
    likes?: string;
    replies?: string;
    reposts?: string;
  } = {};

  const author = parseXAuthor(scope);
  if (author) metadata.author = author;

  const published = parseXPublished(scope);
  if (published) metadata.published = published;

  const engagement = parseXEngagement(scope);
  if (engagement.likes) metadata.likes = engagement.likes;
  if (engagement.replies) metadata.replies = engagement.replies;
  if (engagement.reposts) metadata.reposts = engagement.reposts;

  return metadata;
}

const X_RESERVED_PATHS = new Set([
  "home",
  "explore",
  "search",
  "i",
  "settings",
  "messages",
  "notifications",
  "compose",
  "login",
  "signup",
  "intent",
  "hashtag",
  "share",
]);

function parseXAuthor(scope: ParentNode): string | undefined {
  const userName = scope.querySelector("[data-testid='User-Name']");
  if (!userName) return undefined;

  let display: string | undefined;
  let handle: string | undefined;

  userName.querySelectorAll("a[href]").forEach((link) => {
    const href = (link.getAttribute("href") ?? "").trim();
    const pathMatch = href.match(/^\/@?([A-Za-z0-9_]{1,15})(?:\/|$|\?)/);
    const pathHandle = pathMatch?.[1];
    if (pathHandle && !X_RESERVED_PATHS.has(pathHandle.toLowerCase())) {
      handle = pathHandle;
    }
    const label = (link.textContent ?? "").replace(/\s+/g, " ").trim();
    if (!label) return;
    if (label.startsWith("@") && label.length > 1) {
      handle = label.slice(1).replace(/[^A-Za-z0-9_]/g, "") || handle;
      return;
    }
    // Display name is usually the first non-@ link text; skip pure timestamps.
    if (!/^\d/.test(label) && !/^(·|•)$/.test(label) && label.length <= 80) {
      if (!display) display = label;
    }
  });

  if (!display && !handle) {
    const raw = (userName.textContent ?? "").replace(/\s+/g, " ").trim();
    if (!raw) return undefined;
    const at = raw.match(/@([A-Za-z0-9_]{1,15})/);
    if (at) handle = at[1];
    const beforeAt = raw.split("@")[0]?.trim();
    if (beforeAt && beforeAt.length >= 1 && beforeAt.length <= 80) display = beforeAt;
  }

  if (display && handle) return `${display} (@${handle})`;
  if (handle) return `@${handle}`;
  if (display) return display;
  return undefined;
}

function parseXPublished(scope: ParentNode): string | undefined {
  const time = scope.querySelector("time[datetime]");
  const value = time?.getAttribute("datetime")?.trim();
  return value && value.length > 0 ? value : undefined;
}

/**
 * Only accept stable aria-label counts. Unknown / non-numeric chrome is ignored
 * (never dumped into the body).
 */
function parseXEngagement(scope: ParentNode): {
  likes?: string;
  replies?: string;
  reposts?: string;
} {
  const out: { likes?: string; replies?: string; reposts?: string } = {};
  const like = parseAriaCount(scope, "[data-testid='like'], [data-testid='unlike']", /like|喜欢|赞/i);
  const reply = parseAriaCount(scope, "[data-testid='reply']", /repl(?:y|ies)|回复|回应/i);
  const repost = parseAriaCount(
    scope,
    "[data-testid='retweet'], [data-testid='unretweet']",
    /repost|retweet|转帖|转发|转推/i,
  );
  if (like) out.likes = like;
  if (reply) out.replies = reply;
  if (repost) out.reposts = repost;
  return out;
}

function parseAriaCount(scope: ParentNode, selector: string, verb: RegExp): string | undefined {
  const node = scope.querySelector(selector);
  if (!node) return undefined;
  const label =
    node.getAttribute("aria-label")?.trim() ||
    node.closest("[aria-label]")?.getAttribute("aria-label")?.trim() ||
    "";
  if (!label || !verb.test(label)) return undefined;
  // Examples: "123 Likes. Like", "1,234 likes", "12 次喜欢", "赞 1.2万"
  const match =
    label.match(/([\d.,]+ ?[KkMm万亿]?)\s*(?:次)?\s*(?:Likes?|Replies|Reposts?|Retweets?|喜欢|赞|回复|回应|转帖|转发|转推)/i) ||
    label.match(/(?:Likes?|Replies|Reposts?|Retweets?|喜欢|赞|回复|回应|转帖|转发|转推)\s*([\d.,]+ ?[KkMm万亿]?)/i);
  const value = match?.[1]?.trim();
  if (!value || !/[\d]/.test(value)) return undefined;
  return value;
}

/**
 * 站点专属正文根。通用候选顺序在这些站点上会命中一个偏大的容器，把标题、时间
 * 和来源一起卷进正文（App 详情页已单独显示标题，正文里再来一遍是重复）。
 * 按站点收窄而不是调通用候选的先后：那个顺序同时服务所有未列站点，动它会波及
 * 没在真机上验过的场景。
 */
/**
 * 当前页面的站点档案。
 *
 * 从 href 解析而不是读 `location.hostname`：注入版和单测的 document 都保证有
 * href，hostname 则不一定，读它会让这个分支在测试里静默失效。
 */
function profileFor(documentLike: Document): SiteProfile | undefined {
  try {
    const host = new URL(documentLike.location?.href ?? "").hostname;
    return host ? siteProfile(host) : undefined;
  } catch {
    return undefined;
  }
}

/** 命中后仍要求文本够长，否则宁可退回下一候选，也不产出一个空壳正文。 */
function firstSubstantiveNode(
  documentLike: Document,
  selectors: readonly string[],
): Element | null {
  for (const selector of selectors) {
    const node = documentLike.querySelector(selector);
    if (node && (node.textContent?.trim().length ?? 0) >= 20) return node;
  }
  return null;
}

function pickContentRoot(documentLike: Document): Element {
  // Non-X pages only. X status uses extractXStatusPage.
  //
  // 站点专属选择器先行，然后才是跨站点通用的语义标记。带站点色彩的类名一律
  // 住在 SITE_PROFILES 里——混进通用清单就等于通用路径认识具体站点。
  const profile = profileFor(documentLike);
  const scoped = profile?.contentRoot
    ? firstSubstantiveNode(documentLike, profile.contentRoot)
    : null;
  if (scoped) return scoped;
  const generic = firstSubstantiveNode(documentLike, GENERIC_CONTENT_ROOTS);
  if (generic) return generic;
  const legacy = documentLike.querySelector("article, main");
  if (legacy) return legacy;
  return documentLike.body ?? documentLike.documentElement;
}

function scrubNoise(root: Element): void {
  root.querySelectorAll(NOISE_SELECTOR).forEach((node) => node.remove());
}

function resolveTitle(documentLike: Document): string {
  if (isXStatusURL(documentLike.location.href)) {
    const article =
      documentLike.querySelector("article[data-testid='tweet']") ??
      documentLike.querySelector("article");
    const body = buildXStatusBody(documentLike, article, documentLike.location.href);
    const short = formatXDisplayTitle(firstProseFromMarkdown(body), documentLike.title ?? "");
    if (short) return short;
  }
  // GitHub repo roots keep hidden a11y headings (e.g. the search dialog's
  // "Search code, repositories…"); the canonical owner/repo slug is the title.
  const repoSlug = gitHubRepoSlug(documentLike.location.href);
  if (repoSlug) return repoSlug;
  // 站点专属标题选择器（如公众号的 #activity-name：页面 h1 常是空的或站点名）。
  const profile = profileFor(documentLike);
  if (profile?.title) {
    for (const selector of profile.title) {
      const value = documentLike.querySelector(selector)?.textContent?.trim();
      if (value) return value;
    }
  }
  const h1 = documentLike.querySelector("h1")?.textContent?.trim();
  if (h1 && h1.length >= 2) return h1;
  const og = documentLike.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
  if (og) return og;
  return documentLike.title ?? "";
}

/**
 * "owner/repo" only for a repository root URL on github.com; deeper pages
 * (issues, blobs, search) keep their own headings.
 */
export function gitHubRepoSlug(href: string): string | null {
  try {
    const url = new URL(href);
    const host = url.hostname.toLowerCase();
    if (host !== "github.com" && host !== "www.github.com") return null;
    const [owner, repo, ...rest] = url.pathname.split("/").filter(Boolean);
    if (!owner || !repo || rest.length > 0) return null;
    const valid = /^[A-Za-z0-9_.-]+$/;
    if (!valid.test(owner) || !valid.test(repo)) return null;
    return `${owner}/${repo}`;
  } catch {
    return null;
  }
}

function metaContent(
  documentLike: Document,
  key: string,
  attr: "name" | "property" = "name",
): string | undefined {
  const value = documentLike.querySelector(`meta[${attr}='${key}']`)?.getAttribute("content")?.trim();
  return value && value.length > 0 ? value : undefined;
}

/** Lightweight YAML-like header (Tolaria/Obsidian style). */
export function buildCaptureFrontmatter(fields: {
  // Values are `| undefined` so DOM-resolved optionals (which are often absent)
  // can be passed straight through; every field is guarded before it serializes.
  author?: string | undefined;
  published?: string | undefined;
  likes?: string | undefined;
  comments?: string | undefined;
  shares?: string | undefined;
  collects?: string | undefined;
  views?: string | undefined;
  /** Legacy internal names from the X extractor; serialized canonically below. */
  replies?: string | undefined;
  reposts?: string | undefined;
}): string {
  const lines: string[] = ["---"];
  if (fields.author) lines.push(`author: ${JSON.stringify(fields.author)}`);
  if (fields.published) lines.push(`published: ${JSON.stringify(fields.published)}`);
  // Engagement is optional structured chrome — only when a stable parse succeeded.
  if (fields.likes) lines.push(`likes: ${JSON.stringify(fields.likes)}`);
  if (fields.comments ?? fields.replies) {
    lines.push(`comments: ${JSON.stringify(fields.comments ?? fields.replies)}`);
  }
  if (fields.shares ?? fields.reposts) {
    lines.push(`shares: ${JSON.stringify(fields.shares ?? fields.reposts)}`);
  }
  if (fields.collects) lines.push(`collects: ${JSON.stringify(fields.collects)}`);
  if (fields.views) lines.push(`views: ${JSON.stringify(fields.views)}`);
  // Intentionally omit meta/og:description: WeChat and many sites fill it with
  // promotional SEO blurbs that are not a faithful article abstract.
  if (lines.length === 1) return "";
  lines.push("---", "");
  return `${lines.join("\n")}\n`;
}

/**
 * Reads a single engagement count straight off the page as the site already
 * renders it (for example B站's "1.0亿" or 小红书's "9670"). Whitespace is
 * collapsed and a value is kept only when it actually contains a digit, so an
 * unrendered placeholder button never becomes a bogus `likes: ""`.
 */
function firstDomCount(scope: ParentNode, selector: string): string | undefined {
  const raw = scope.querySelector(selector)?.textContent?.replace(/\s+/gu, "").trim();
  return raw && /\d/u.test(raw) ? raw : undefined;
}

type ZhihuAnswerMetadata = {
  author?: string;
  published?: string;
  likes?: string;
  comments?: string;
  collects?: string;
};

function semanticCount(
  scope: ParentNode,
  selectors: string[],
  keyword: RegExp,
): string | undefined {
  const candidates: Element[] = [];
  const seen = new Set<Element>();
  for (const selector of selectors) {
    const node = scope.querySelector(selector);
    if (node && !seen.has(node)) {
      seen.add(node);
      candidates.push(node);
    }
  }
  // Class names drift on Zhihu. This bounded, answer-scoped fallback reads only
  // buttons/labels from the current answer, never question-level header stats.
  for (const node of Array.from(scope.querySelectorAll("button, [aria-label], [title]")).slice(0, 100)) {
    if (!seen.has(node)) {
      seen.add(node);
      candidates.push(node);
    }
  }
  for (const node of candidates) {
    const raw = [
      node.getAttribute("aria-label"),
      node.getAttribute("title"),
      node.textContent,
    ].filter(Boolean).join(" ").replace(/\s+/gu, " ").trim();
    if (!raw || !keyword.test(raw)) continue;
    const match =
      raw.match(new RegExp(`(?:${keyword.source})\\s*([\\d.,]+\\s*[KkMm万亿]?)`, "iu"))
      || raw.match(new RegExp(`([\\d.,]+\\s*[KkMm万亿]?)\\s*(?:条|个|次)?\\s*(?:${keyword.source})`, "iu"));
    const value = match?.[1]?.replace(/\s+/gu, "").trim();
    if (value && /\d/u.test(value)) return value;
  }
  return undefined;
}

/**
 * Reads metadata only from the answer identified by the current URL. Question
 * follower/view totals are deliberately excluded because they describe a
 * different object than the captured answer.
 */
export function resolveZhihuAnswerMetadata(documentLike: Document): ZhihuAnswerMetadata {
  if (!isZhihuAnswerURL(documentLike.location.href)) return {};
  const answerID = new URL(documentLike.location.href).pathname.match(/\/answer\/(\d+)/u)?.[1];
  const identified =
    (answerID
      ? documentLike.querySelector(
        `[data-answer-id='${answerID}'], [data-zop*='${answerID}'], [data-za-extra-module*='${answerID}']`,
      )
      : null);
  const scope =
    identified?.closest(".AnswerItem, [data-answer-id]")
    || identified
    || documentLike.querySelector(".AnswerItem")
    || documentLike.querySelector("main")
    || documentLike;

  const author =
    scope.querySelector(".AuthorInfo-name")?.textContent?.trim()
    || scope.querySelector(".UserLink-link")?.textContent?.trim()
    || scope.querySelector("[itemprop='name']")?.getAttribute("content")?.trim()
    || scope.querySelector("[itemprop='name']")?.textContent?.trim()
    || undefined;
  const publishedNode =
    scope.querySelector("time[datetime]")
    || scope.querySelector(".ContentItem-time")
    || scope.querySelector("[data-tooltip]");
  const publishedRaw =
    publishedNode?.getAttribute("datetime")?.trim()
    || publishedNode?.getAttribute("data-tooltip")?.trim()
    || publishedNode?.textContent?.trim()
    || "";
  const published = publishedRaw.replace(/^(?:编辑于|发布于)\s*/u, "").trim() || undefined;

  const metadata: ZhihuAnswerMetadata = {};
  if (author) metadata.author = author;
  if (published) metadata.published = published;
  const likes = semanticCount(
    scope,
    [".VoteButton--up", "[aria-label*='赞同']", "[title*='赞同']"],
    /赞同|赞成|upvote/u,
  );
  const comments = semanticCount(
    scope,
    ["[aria-label*='评论']", "[title*='评论']", ".ContentItem-action"],
    /评论|comment/iu,
  );
  const collects = semanticCount(
    scope,
    ["[aria-label*='收藏']", "[title*='收藏']", ".ContentItem-action"],
    /收藏|collect|favou?rite/iu,
  );
  if (likes) metadata.likes = likes;
  if (comments) metadata.comments = comments;
  if (collects) metadata.collects = collects;
  return metadata;
}

export function resolvePageMetadata(documentLike: Document): {
  author?: string;
  published?: string;
} {
  const profile = profileFor(documentLike);
  const fromProfile = (selectors: readonly string[] | undefined): string | undefined => {
    for (const selector of selectors ?? []) {
      const value = documentLike.querySelector(selector)?.textContent?.trim();
      if (value) return value;
    }
    return undefined;
  };
  const author =
    fromProfile(profile?.author) ||
    metaContent(documentLike, "author") ||
    metaContent(documentLike, "article:author", "property") ||
    metaContent(documentLike, "og:article:author", "property") ||
    // GitHub repo pages expose no author meta; the owner is the author.
    gitHubRepoSlug(documentLike.location.href)?.split("/")[0];
  const published =
    fromProfile(profile?.published) ||
    metaContent(documentLike, "article:published_time", "property") ||
    metaContent(documentLike, "og:published_time", "property") ||
    metaContent(documentLike, "publish_date") ||
    metaContent(documentLike, "date");
  const metadata: { author?: string; published?: string } = {};
  if (author) metadata.author = author;
  if (published) metadata.published = published;
  return metadata;
}

function absoluteUrl(href: string, baseHref: string): string | null {
  try {
    if (!href || href.startsWith("data:") || href.startsWith("file:") || href.startsWith("javascript:")) {
      return null;
    }
    const url = new URL(href, baseHref);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    return url.href;
  } catch {
    return null;
  }
}

function imageCandidateScore(rawURL: string, descriptor: string | undefined, priority: number): number {
  const width = descriptor?.match(/^(\d+)w$/u)?.[1];
  if (width) return Number(width) * 10 + priority;
  const density = descriptor?.match(/^(\d+(?:\.\d+)?)x$/u)?.[1];
  if (density) return Number(density) * 10_000 + priority;
  const embeddedWidth = rawURL.match(/resize:(?:fit|fill):(\d+)(?::\d+)?/iu)?.[1];
  if (embeddedWidth) return Number(embeddedWidth) * 10 + priority;
  return priority;
}

/**
 * Chooses the highest-quality real URL exposed by lazy/responsive image
 * markup. Medium commonly puts a small placeholder in `src` and the useful
 * article image in `srcset` or a surrounding `<picture>`.
 */
export function resolveResponsiveImageURL(image: Element, baseHref: string): string | null {
  const candidates: Array<{ href: string; score: number }> = [];
  const add = (raw: string | null | undefined, descriptor: string | undefined, priority: number) => {
    const trimmed = raw?.trim();
    if (!trimmed) return;
    const href = absoluteUrl(trimmed, baseHref);
    if (href) candidates.push({ href, score: imageCandidateScore(trimmed, descriptor, priority) });
  };
  const addSrcset = (raw: string | null | undefined, priority: number) => {
    for (const candidate of raw?.split(",") ?? []) {
      const [url, descriptor] = candidate.trim().split(/\s+/u);
      add(url, descriptor, priority);
    }
  };

  addSrcset(image.getAttribute("data-srcset"), 60);
  addSrcset(image.getAttribute("srcset"), 50);
  const picture = image.closest("picture");
  picture?.querySelectorAll("source").forEach((source) => {
    addSrcset(source.getAttribute("data-srcset"), 40);
    addSrcset(source.getAttribute("srcset"), 30);
  });
  add(image.getAttribute("data-src"), undefined, 25);
  add(image.getAttribute("data-original"), undefined, 20);
  add(image.getAttribute("data-lazy-src"), undefined, 15);
  add(image.getAttribute("src"), undefined, 10);

  return candidates.sort((a, b) => b.score - a.score)[0]?.href ?? null;
}

export function isMediumProfileChromeImageURL(href: string): boolean {
  try {
    const url = new URL(href);
    const host = url.hostname.toLowerCase();
    if (host !== "miro.medium.com" && !host.endsWith(".miro.medium.com")) return false;
    const size = url.pathname.match(/resize:fill:(\d+):(\d+)/iu);
    return Boolean(size && Number(size[1]) <= 128 && Number(size[2]) <= 128);
  } catch {
    return false;
  }
}

function htmlElementToMarkdown(root: Element, baseHref: string): string {
  const TEXT_NODE = 3;
  const ELEMENT_NODE = 1;
  const walk = (node: {
    nodeType: number;
    textContent?: string | null;
    tagName?: string;
    childNodes?: ArrayLike<Node>;
    getAttribute?: (n: string) => string | null;
  }): string => {
    if (node.nodeType === TEXT_NODE) {
      return (node.textContent ?? "").replace(/\u00a0/g, " ");
    }
    if (node.nodeType !== ELEMENT_NODE) return "";
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    const inner = Array.from(el.childNodes).map(walk).join("");

    if (tag === "br") return "\n";
    if (/^h[1-6]$/.test(tag)) {
      const level = Number(tag[1]);
      return `\n\n${"#".repeat(level)} ${collapseInline(inner)}\n\n`;
    }
    if (tag === "p") {
      const body = collapseInline(inner);
      return body ? `\n\n${body}\n\n` : "\n";
    }
    if (tag === "div" || tag === "section" || tag === "figure" || tag === "span") {
      if (hasBlockChild(el)) return `\n${inner}\n`;
      const body = collapseInline(inner);
      return body ? `\n\n${body}\n\n` : "\n";
    }
    if (tag === "li") {
      const body = collapseInline(inner);
      return body ? `\n- ${body}` : "";
    }
    if ((tag === "ul" || tag === "ol") && /code-snippet__line-index/.test(el.getAttribute?.("class") ?? "")) {
      return ""; // WeChat code line numbers are chrome, not content.
    }
    if (tag === "ul" || tag === "ol") return `\n${inner}\n`;
    if (tag === "blockquote") {
      const quoted = collapseInline(inner)
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => `> ${line}`)
        .join("\n");
      return quoted ? `\n\n${quoted}\n\n` : "";
    }
    if (tag === "pre") {
      // WeChat code-snippet renders one <code> per line; joining them with
      // newlines restores the original block. Other sites keep newlines in
      // the <pre> text itself.
      const preChildren = Array.from(el.childNodes ?? []);
      const codeLines = preChildren.filter(
        (child) =>
          (child as Node).nodeType === ELEMENT_NODE &&
          ((child as Element).tagName ?? "").toLowerCase() === "code",
      );
      const rawCode =
        codeLines.length > 1
          ? codeLines.map((line) => ((line as Node).textContent ?? "").replace(/\n+$/g, "")).join("\n")
          : (el.textContent ?? "");
      const cleanedCode = rawCode.replace(/\r\n/g, "\n").replace(/^\n+|\n+$/g, "");
      if (!cleanedCode.trim()) return "";
      const longestBackticks = Math.max(0, ...(cleanedCode.match(/`+/g) ?? []).map((run) => run.length));
      const fence = "`".repeat(Math.max(3, longestBackticks + 1));
      return `\n\n${fence}\n${cleanedCode}\n${fence}\n\n`;
    }
    if (tag === "strong" || tag === "b") return `**${collapseInline(inner)}**`;
    if (tag === "em" || tag === "i") return `*${collapseInline(inner)}*`;
    if (tag === "code") return `\`${collapseInline(inner)}\``;
    if (tag === "a") return collapseInline(inner);
    if (tag === "img") {
      const alt = (el.getAttribute("alt") ?? el.getAttribute("data-alt") ?? "图像").trim() || "图像";
      const href = resolveResponsiveImageURL(el, baseHref);
      if (!href) return alt ? `\n\n${alt}\n\n` : "";
      if (isXProfileChromeImageURL(href) || isMediumProfileChromeImageURL(href)) return "";
      const safeAlt = alt.replace(/[[\]]/g, "");
      return `\n\n![${safeAlt}](${href})\n\n`;
    }
    return inner;
  };

  return normalizeMarkdownWhitespace(walk(root));
}

function hasBlockChild(el: Element): boolean {
  return Array.from(el.childNodes).some((child) => {
    if (child.nodeType !== 1) return false;
    const tag = (child as Element).tagName.toLowerCase();
    return (
      tag === "p" ||
      tag === "div" ||
      tag === "section" ||
      tag === "figure" ||
      tag === "ul" ||
      tag === "ol" ||
      tag === "li" ||
      tag === "blockquote" ||
      tag === "pre" ||
      tag === "img" ||
      /^h[1-6]$/.test(tag)
    );
  });
}

function collapseInline(value: string): string {
  return value
    .replace(/[ \t\u00a0]+/g, " ")
    .replace(/\n+/g, " ")
    .trim();
}

function normalizeMarkdownWhitespace(value: string): string {
  // Space collapsing must not touch fenced code lines, or indentation-based
  // code (directory trees, Python) is destroyed.
  const lines = value.replace(/\r\n/g, "\n").replace(/[ \t]+\n/g, "\n").split("\n");
  let inFence = false;
  const kept = lines.map((line) => {
    if (/^\s*`{3,}/.test(line)) {
      inFence = !inFence;
      return line;
    }
    return inFence ? line : line.replace(/[ \t]{2,}/g, " ");
  });
  return kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

/**
 * 把正文里的标题层级整体重基到 h2 起。
 *
 * 出口归一化的一部分：**不管来源页面怎么写标题，产出的层级结构必须一致**。
 * 阅读区已经把条目标题按 h1 显示了，正文里再出现 h1 就是第二个「文档标题」——
 * 实测 support.claude.com 一篇 852 字的帮助页里有 4 个 h1，全部渲染成 23pt，
 * 一篇小短文被切成四段巨标题。
 *
 * 只做平移，不压缩：所有标题同时下移相同的量，原有的相对层级差完整保留。
 * 已经从 h2 或更深开始的文档一个字都不动。
 *
 * 围栏代码块里的 `#` 是代码不是标题，必须跳过——否则 Python / Shell 注释会被
 * 当成标题改写，那是**破坏内容**，比排版难看严重得多。
 */
export function rebaseHeadingLevels(markdown: string): string {
  const lines = markdown.split("\n");
  const headingAt: number[] = [];
  let inFence = false;
  let shallowest = 7;

  lines.forEach((line, index) => {
    if (/^\s*(?:```|~~~)/.test(line)) {
      inFence = !inFence;
      return;
    }
    if (inFence) return;
    const match = /^(#{1,6})\s+\S/.exec(line);
    const hashes = match?.[1];
    if (!hashes) return;
    headingAt.push(index);
    shallowest = Math.min(shallowest, hashes.length);
  });

  if (!headingAt.length || shallowest >= 2) return markdown;
  const shift = 2 - shallowest;

  for (const index of headingAt) {
    const line = lines[index];
    if (line === undefined) continue;
    lines[index] = line.replace(/^(#{1,6})(\s+)/, (_, hashes: string, gap: string) => {
      // 上限 6：再深就不是合法 ATX 标题了，宁可让最深的几级挤在一起，
      // 也不能产出 `#######` 这种渲染不出来的东西。
      const level = Math.min(hashes.length + shift, 6);
      return `${"#".repeat(level)}${gap}`;
    });
  }
  return lines.join("\n");
}

export function stripBoilerplateLines(markdown: string): string {
  const lines = markdown.split("\n");
  const kept = lines.filter((line) => {
    const trimmed = line.trim();
    if (!trimmed) return true;
    if (trimmed.startsWith("![") && trimmed.includes("](")) return true;
    for (const marker of BOILERPLATE_LINE_MARKERS) {
      if (trimmed === marker) return false;
      if (trimmed.startsWith(marker) && trimmed.length <= marker.length + 16) return false;
      if (trimmed.includes(marker) && trimmed.length <= marker.length + 8) return false;
    }
    return true;
  });
  return normalizeMarkdownWhitespace(kept.join("\n"));
}

/**
 * Injected: read only single-item metadata from the open Douyin tab.
 * Never walks document.body (that is how feed chrome was captured).
 */
export type DouyinSingleItemMeta = {
  awemeId: string;
  canonicalURL: string;
  title: string;
  author: string | null;
  publishedAt?: string;
  description: string;
  pageURL: string;
  mediaDescriptor?: MediaDescriptor;
  stats?: { likes?: string; comments?: string; shares?: string; collects?: string };
  /** 图文帖（图集）的图片 CDN 地址，按页面渲染顺序；视频帖为空。 */
  imageURLs?: string[];
  /** Internal injection handoff only; never copied into ExtractedPage. */
  metadataDiagnostic?: DouyinMetadataDOMDiagnostic;
};

export function extractDouyinSingleItemMetaInPage(): DouyinSingleItemMeta | null {
  const href = document.location.href;
  let awemeId = "";
  try {
    const url = new URL(href);
    for (const key of ["modal_id", "aweme_id", "item_id", "video_id", "group_id"]) {
      const value = url.searchParams.get(key);
      if (value && /^\d{8,25}$/u.test(value)) {
        awemeId = value;
        break;
      }
    }
    if (!awemeId) {
      const pathMatch = url.pathname.match(/\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$)/u);
      if (pathMatch?.[1]) awemeId = pathMatch[1];
    }
  } catch {
    return null;
  }
  if (!awemeId) {
    const modal = href.match(/[?&#]modal_id=(\d{8,25})/u);
    if (modal?.[1]) awemeId = modal[1];
  }

  // Active-video anchoring. Douyin's URL modal_id and page-level
  // og:title/og:description reflect the SSR/first feed item and lag behind
  // vertical scrolling, so anchoring on them captures the previous video. The
  // clip the viewer is actually watching is the reliable anchor: pick the
  // largest visible <video> (currentTime>0 and !paused only break ties, so the
  // main player wins over muted side previews), then read the item id and, via
  // `activeVideoContainer`, the caption/author from its nearest container.
  // Mirrors the shipped douyin-detector getBestVisibleVideo heuristic. Any miss
  // falls back to the URL/og values. Kept fully inline: browser.scripting
  // serializes this function body without module-level helpers.
  let activeVideoContainer: Element | null = null;
  // Distinguishes "no safe scope at all" from "stopped early at a conflicting
  // ancestor but kept a deeper proven-safe one", so the popup diagnostic says
  // which of the two happened instead of collapsing both into one code.
  let identityConflictStoppedClimb = false;
  let dominantVisibleVideo: HTMLVideoElement | null = null;
  let positiveVisibleVideoCount = 0;
  let initialVideoNodeLimit = false;
  try {
    const viewW = document.defaultView?.innerWidth ?? 0;
    const viewH = document.defaultView?.innerHeight ?? 0;
    const videoEls = Array.from(document.querySelectorAll("video")) as HTMLVideoElement[];
    initialVideoNodeLimit = videoEls.length > 1000;
    let bestVideo: HTMLVideoElement | null = null;
    let bestScore = Number.NEGATIVE_INFINITY;
    for (const candidate of videoEls) {
      const rect = candidate.getBoundingClientRect();
      const visibleWidth = Math.max(0, Math.min(rect.right, viewW) - Math.max(rect.left, 0));
      const visibleHeight = Math.max(0, Math.min(rect.bottom, viewH) - Math.max(rect.top, 0));
      if (visibleWidth * visibleHeight > 0 && positiveVisibleVideoCount < 1000) positiveVisibleVideoCount += 1;
      const score = visibleWidth * visibleHeight
        + (candidate.currentTime > 0 ? 1000 : 0)
        + (!candidate.paused && !candidate.ended && candidate.readyState > 0 ? 2000 : 0);
      if (score > bestScore) {
        bestScore = score;
        bestVideo = candidate;
      }
    }
    if (bestVideo && bestScore > 0) {
      dominantVisibleVideo = bestVideo;
      let node: Element | null = bestVideo;
      for (let depth = 0; node && depth < 12; depth += 1) {
        if (node === document.body || node === document.documentElement) break;
        let foundId = "";
        for (const attr of [
          "data-aweme-id", "data-aweme_id", "data-item-id", "data-item_id",
          "data-video-id", "data-video_id", "data-modal-id", "data-group-id",
        ]) {
          const raw = node.getAttribute(attr)?.trim();
          if (raw && /^\d{8,25}$/u.test(raw)) { foundId = raw; break; }
        }
        if (!foundId) {
          const link = node.querySelector(
            "a[href*='/video/'],a[href*='/note/'],a[href*='modal_id='],a[href*='aweme_id=']",
          );
          const linkHref = link?.getAttribute("href") ?? node.getAttribute("href") ?? "";
          const linkMatch = linkHref.match(
            /\/(?:video|note)\/(\d{8,25})|[?&#](?:modal_id|aweme_id|item_id|video_id|group_id)=(\d{8,25})/u,
          );
          if (linkMatch) foundId = linkMatch[1] ?? linkMatch[2] ?? "";
        }
        if (foundId && /^\d{8,25}$/u.test(foundId)) {
          if (!awemeId || foundId === awemeId) {
            awemeId = foundId;
            activeVideoContainer = node;
            break;
          }
          // A neighbouring feed card owns this ancestor. Everything found below
          // it was already proven to name only the locked aweme, so stop the
          // climb and keep it — discarding it here is what left `safeItemScopes`
          // empty and dropped published time and every engagement count on a
          // capture whose title, video and id were all correct.
          identityConflictStoppedClimb = true;
          break;
        }
        if (
          !activeVideoContainer
          && !foundId
          && node.querySelector("[data-e2e='video-desc'],[data-e2e='feed-video-desc'],[data-e2e='browse-video-desc']")
        ) {
          activeVideoContainer = node;
        }
        node = node.parentElement;
      }
    }
  } catch {
    // Keep the URL-derived awemeId and page-level metadata on any DOM error.
  }

  if (!awemeId) return null;

  const shell = new Set([
    "精选", "AI抖音", "关注", "朋友", "我的", "直播", "放映厅", "短剧",
    "推荐", "搜索", "充钻石", "下载电脑客户端", "壁纸", "通知", "消息",
    "投稿", "登录", "客户端", "读屏标签已关闭",
  ]);
  const cleanLines = (raw: string) =>
    raw
      .split(/\n+/u)
      .map((line) => line.trim())
      .filter((line) => {
        if (!line || shell.has(line)) return false;
        if (/^(?:朋友|关注|消息|通知)\s*\d+$/u.test(line)) return false;
        return true;
      })
      .join("\n")
      .trim();

  // Prefer text scoped to the active video's container (so caption/author follow
  // the scrolled clip); fall back to page-level meta only when the container has
  // none. `scopedText` returns the first non-empty match inside the container.
  const scopedText = (selectors: string): string => {
    const scoped = activeVideoContainer?.querySelector(selectors)?.textContent?.trim();
    return scoped || "";
  };
  const ogTitle = document.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
  const ogDesc = document.querySelector("meta[property='og:description']")?.getAttribute("content")?.trim();
  const scopedDesc = scopedText(
    "[data-e2e='video-desc'],[data-e2e='feed-video-desc'],[data-e2e='browse-video-desc'],[data-e2e='video-desc-content'],[data-e2e='video-desc-text']",
  );
  const stripCaptionChrome = (value: string): string =>
    value.replace(/\s+-\s+抖音.*$/u, "").replace(/(?:…|\.{3})?\s*展开$/u, "").trim();
  // 详情页把长文案折叠成「…展开」，scoped 抓到的只是截断版——末尾常留一个孤零零
  // 的 #（tag 被切掉一半）。og:title 是完整文案，但正如上面所述，信息流里它可能
  // 仍指向 SSR 首条而不是当前条，直接采用会把别的视频标题安到这条上。所以只在
  // 确认 og 版本是这段截断文案的扩展时才升级。
  //
  // 比较必须先归一化：DOM 里的话题是「#日落🌄」（emoji 是真字符），og 里是
  // 「#日落」，逐字前缀匹配必然失败。只留字母数字（含汉字）后再比。
  const captionKey = (value: string): string =>
    value.replace(/[^\p{L}\p{N}]/gu, "").toLowerCase();
  const scopedLooksTruncated = /(?:…|\.{3})?\s*展开$|…$/u.test(scopedDesc.trim());
  const expandedCaption = (() => {
    if (!scopedLooksTruncated) return "";
    const scopedKey = captionKey(stripCaptionChrome(scopedDesc));
    if (!scopedKey) return "";
    for (const candidate of [ogTitle, ogDesc]) {
      const cleaned = stripCaptionChrome(candidate ?? "");
      if (!cleaned) continue;
      const candidateKey = captionKey(cleaned);
      // 必须严格更长，否则拿回来的只是同一段截断文案。
      if (candidateKey.startsWith(scopedKey) && candidateKey.length > scopedKey.length) return cleaned;
    }
    return "";
  })();
  // On the feed the caption is the item's title; only trust og:title when the
  // active container yields no caption of its own.
  const rawTitle = expandedCaption || scopedDesc || ogTitle || document.querySelector("h1")?.textContent?.trim() || document.title || "抖音视频";
  const unprefixedTitle = stripCaptionChrome(rawTitle);
  const description = cleanLines(
    expandedCaption
      || scopedDesc
      || ogDesc
      || document.querySelector("[data-e2e='video-desc']")?.textContent?.trim()
      || document.querySelector("[data-e2e='browse-video-desc']")?.textContent?.trim()
      || document.querySelector("[class*='video-info-detail']")?.textContent?.trim()
      || "",
  );

  // Metadata may live in a sibling action bar rather than inside the player
  // container. Walk only a few common ancestors and accept one only when every
  // explicit aweme identity in that scope names the currently locked item.
  // This keeps a neighboring feed card from lending its author/time/stats.
  const safeItemScopes: Element[] = [];
  const identityAttributeNames = [
    "data-aweme-id", "data-aweme_id", "data-item-id", "data-item_id",
    "data-video-id", "data-video_id", "data-modal-id", "data-group-id",
  ];
  const identityDescendantSelector = [
    "[data-aweme-id]", "[data-aweme_id]", "[data-item-id]", "[data-item_id]",
    "[data-video-id]", "[data-video_id]", "[data-modal-id]", "[data-group-id]",
    "a[href*='/video/']", "a[href*='/note/']", "a[href*='/share/video/']",
    "a[href*='modal_id=']", "a[href*='aweme_id=']", "a[href*='item_id=']",
    "a[href*='video_id=']", "a[href*='group_id=']",
  ].join(",");
  const addAwemeIDs = (raw: string | null, ids: Set<string>) => {
    if (!raw) return;
    const trimmed = raw.trim();
    if (/^\d{8,25}$/u.test(trimmed)) ids.add(trimmed);
    for (const pattern of [
      /\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$|[?#])/gu,
      /[?&#](?:modal_id|aweme_id|item_id|video_id|group_id)=(\d{8,25})(?:[&#]|$)/gu,
    ]) {
      let match: RegExpExecArray | null;
      while ((match = pattern.exec(raw)) !== null) if (match[1]) ids.add(match[1]);
    }
  };
  if (activeVideoContainer) {
    let scope: Element | null = activeVideoContainer;
    for (let depth = 0; scope && depth < 6; depth += 1) {
      if (scope === document.body || scope === document.documentElement) break;
      const ids = new Set<string>();
      for (const attributeName of identityAttributeNames) {
        addAwemeIDs(scope.getAttribute(attributeName), ids);
      }
      addAwemeIDs(scope.getAttribute("href"), ids);
      const descendants = typeof scope.querySelectorAll === "function"
        ? scope.querySelectorAll(identityDescendantSelector)
        : [];
      // Do not inspect a prefix and call the ancestor safe: a 121st identity
      // could be another aweme. Refuse this scope and all broader ancestors.
      if (descendants.length > 120) break;
      for (const node of descendants) {
        for (const attributeName of identityAttributeNames) addAwemeIDs(node.getAttribute(attributeName), ids);
        addAwemeIDs(node.getAttribute("href"), ids);
      }
      if (ids.size > 0 && [...ids].every((id) => id === awemeId)) safeItemScopes.push(scope);
      if (ids.size > 0 && [...ids].some((id) => id !== awemeId)) break;
      scope = scope.parentElement;
    }
  }

  // A canonical /video/{id} page sometimes keeps the date/action rail beside
  // an otherwise identity-less player subtree. That is safe to use only when
  // the viewport itself proves there is one dominant video. This is deliberately
  // separate from safeItemScopes: author identity is never relaxed.
  const dedicatedMetadataScopes: Element[] = [];
  let dedicatedIdentityConflict = false;
  let isDedicatedMetadataRoute = false;
  let uniquelyDominantDedicatedVideo = false;
  try {
    const url = new URL(href);
    const host = url.hostname.toLowerCase();
    const canonicalPath = new RegExp(`^/video/${awemeId}$`, "u");
    const recognizedItemQueryKeys = ["modal_id", "aweme_id", "item_id", "video_id", "group_id"];
    const recognizedItemValues = recognizedItemQueryKeys.flatMap((key) => url.searchParams.getAll(key));
    // A feed/modal route is eligible only when every recognized item identity
    // it exposes agrees with the ID already locked from the current player.
    // Multiple parameters are intentionally fail-closed: one neighbouring ID
    // is enough to make this identity-less fallback unsafe.
    const hasOnlyLockedQueryIDs = recognizedItemValues.length > 0
      && recognizedItemValues.every((value) => value === awemeId);
    isDedicatedMetadataRoute = (host === "douyin.com" || host.endsWith(".douyin.com"))
      && ((canonicalPath.test(url.pathname) && recognizedItemValues.length === 0) || hasOnlyLockedQueryIDs);
  } catch {
    // URL parsing already failed above for an invalid page URL.
  }
  if (isDedicatedMetadataRoute && dominantVisibleVideo) {
    const viewportWidth = document.defaultView?.innerWidth ?? 0;
    const viewportHeight = document.defaultView?.innerHeight ?? 0;
    const viewportArea = viewportWidth * viewportHeight;
    const visibleArea = (video: HTMLVideoElement): number => {
      const rect = video.getBoundingClientRect();
      return Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0))
        * Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
    };
    const visibleVideoNodes = document.querySelectorAll("video");
    // Do not materialize an adversarially large NodeList merely to decide if
    // this optional identity-less fallback is available.
    if (visibleVideoNodes.length <= 1000) {
      const visibleVideos = Array.from(visibleVideoNodes) as HTMLVideoElement[];
      const rankedAreas = visibleVideos.map(visibleArea).filter((area) => area > 0).sort((a, b) => b - a);
      const dedicatedVideo = visibleVideos.find((video) => visibleArea(video) === rankedAreas[0]);
      const dominantArea = dedicatedVideo ? visibleArea(dedicatedVideo) : 0;
      const uniquelyDominant = rankedAreas.length === 1
        || (rankedAreas.length > 1
          && dominantArea === rankedAreas[0]
          && dominantArea >= rankedAreas[1]! * 4
          && viewportArea > 0
          && dominantArea >= viewportArea * 0.2);
      if (uniquelyDominant && dedicatedVideo) {
      uniquelyDominantDedicatedVideo = true;
      // Metadata belongs to the player/card, never to the bare <video> node.
      // Starting at the parent also prevents a lower node from looking proven
      // before its actual metadata container has been checked in full.
      let scope: Element | null = dedicatedVideo.parentElement;
      for (let depth = 0; scope && depth < 6; depth += 1) {
        if (scope === document.body || scope === document.documentElement) break;
        // This fallback needs complete identity and sibling-video checks. If a
        // malformed DOM node cannot enumerate descendants, fail closed.
        if (typeof scope.querySelectorAll !== "function") break;
        const ids = new Set<string>();
        for (const attributeName of identityAttributeNames) addAwemeIDs(scope.getAttribute(attributeName), ids);
        addAwemeIDs(scope.getAttribute("href"), ids);
        const descendants = scope.querySelectorAll(identityDescendantSelector);
        // The whole fixed list must fit. A 121st node could carry a conflicting
        // identity, so neither this scope nor any wider scope is usable.
        if (descendants.length > 120) break;
        for (const node of descendants) {
          for (const attributeName of identityAttributeNames) addAwemeIDs(node.getAttribute(attributeName), ids);
          addAwemeIDs(node.getAttribute("href"), ids);
        }
        if ([...ids].some((id) => id !== awemeId)) {
          if (dedicatedMetadataScopes.length === 0) dedicatedIdentityConflict = true;
          break;
        }
        const videosInScope = [
          ...((scope.tagName ?? "").toLowerCase() === "video" ? [scope as HTMLVideoElement] : []),
          ...(Array.from(scope.querySelectorAll("video")) as HTMLVideoElement[]),
        ];
        if (videosInScope.some((video) => video !== dedicatedVideo && visibleArea(video) > 0)) {
          break;
        }
        // An explicit locked identity belongs to safeItemScopes. This fallback
        // exists only for the verified identity-less canonical-player layout.
        if (ids.size === 0) dedicatedMetadataScopes.push(scope);
        scope = scope.parentElement;
      }
      }
    }
  }
  const metadataScopes: ParentNode[] = [...safeItemScopes, ...dedicatedMetadataScopes];
  const author = (() => {
    // The nickname element also carries screen-reader-only badge labels
    // ("认证徽章" and friends) as real text nodes, so textContent alone yields
    // "王自如AI认证徽章". Prefer the element's own direct text nodes — the
    // nickname itself — and strip badge wording from whatever remains.
    const cleanNickname = (raw: string): string => {
      let value = raw
        .replace(/(?:官方|企业|个人|机构)?认证(?:徽章|信息|标识)?/gu, "")
        .replace(/已认证/gu, "")
        .replace(/\s+/gu, " ")
        .trim();
      // 作者信息块把昵称与「粉丝 2918 获赞 76.4万 关注」连在一起，textContent
      // 会拼成「迟遇粉丝2918获赞76.4万关注」。只从尾部逐段剥，避免误伤本身
      // 带「关注」「喜欢」字样的昵称。
      let previous = "";
      while (value && value !== previous) {
        previous = value;
        value = value
          .replace(/(?:粉丝|获赞|关注|作品|喜欢|朋友)\s*[\d.,]*\s*[万千亿]?\s*$/u, "")
          .trim();
      }
      return value;
    };
    // 逗号选择器返回的是文档顺序第一个匹配，不是这里的书写顺序——宽泛的
    // `user-info`（整块作者信息）会因此赢过专用昵称节点。必须逐个按优先级试。
    const nicknameSelectors = [
      "[data-e2e='feed-video-nickname']",
      "[data-e2e='video-author-info-nickname']",
      "[data-e2e='user-info']",
    ];
    for (const scope of safeItemScopes) {
      let node: Element | null = null;
      for (const selector of nicknameSelectors) {
        node = scope.querySelector(selector);
        if (node) break;
      }
      if (!node) continue;
      const directText = Array.from(node.childNodes ? node.childNodes : [])
        .filter((child) => child.nodeType === 3)
        .map((child) => child.textContent ?? "")
        .join("")
        .trim();
      const value = cleanNickname(directText || node.textContent?.trim() || "");
      if (value) return value;
    }
    return null;
  })();
  // Caption elements in some feed layouts include the author/time row as a
  // leading text node. The selector above avoids that broad container; this
  // second guard keeps a stored title clean when the DOM shape still joins it.
  // 与 douyin-detect.ts 的 stripTrailingDouyinHashtags 同一条规则。这个函数是
  // 用 `func:` 注入的，够不着模块作用域，只能内联一份。
  const stripTrailingHashtags = (value: string): string => {
    const stripped = value
      .replace(/\s+#\s*$/u, "")
      .replace(/(?:\s*#[^\s#]+)+\s*$/u, "")
      .trim();
    return stripped || value;
  };
  const title = stripTrailingHashtags((() => {
    if (!unprefixedTitle) return "抖音视频";
    if (!author) return unprefixedTitle;
    const escapedAuthor = author.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
    const authorPrefix = new RegExp(`^\\s*@?${escapedAuthor.replace(/^@/u, "@?")}\\s*`, "u");
    const withoutAuthor = unprefixedTitle.replace(authorPrefix, "");
    if (withoutAuthor === unprefixedTitle) return unprefixedTitle;
    const withoutRelativeTime = withoutAuthor.replace(
      /^(?:[·•|｜,，]\s*)?(?:(?:\d+\s*(?:秒|分钟|小时|天|周|月|年)\s*前)|刚刚|昨天|前天)(?:\s*[·•|｜,，])?\s*/u,
      "",
    ).trim();
    return withoutRelativeTime || unprefixedTitle;
  })());
  let publishedSelectorHit = false;
  // Inline copy of normalizeDouyinPublishedText: the injected function must
  // stay self-contained (browser.scripting serializes only this body).
  const normalizePublished = (raw: string): string | undefined => {
    const cleaned = String(raw || "").replace(/^[\s·•|｜,，]+|[\s·•|｜,，]+$/gu, "").trim();
    if (!cleaned) return undefined;
    if (/^\d{4}-\d{2}-\d{2}T/.test(cleaned)) return cleaned;
    const now = new Date();
    const dayMs = 86400000;
    const dateText = (year: number, month: number, day: number) => `${year}年${month}月${day}日`;
    const fromOffset = (milliseconds: number) => {
      const shifted = new Date(now.getTime() - milliseconds);
      return dateText(shifted.getFullYear(), shifted.getMonth() + 1, shifted.getDate());
    };
    const parseSegment = (segment: string): string | undefined => {
      let match = segment.match(/^(\d{4})[年.-](\d{1,2})[月.-](\d{1,2})日?$/u);
      if (match) return dateText(Number(match[1]), Number(match[2]), Number(match[3]));
      match = segment.match(/^(\d{1,2})[月.-](\d{1,2})日?$/u);
      if (match) {
        let year = now.getFullYear();
        const candidate = new Date(year, Number(match[1]) - 1, Number(match[2]));
        if (candidate.getTime() - now.getTime() > dayMs) year -= 1;
        return dateText(year, Number(match[1]), Number(match[2]));
      }
      if (/^刚刚$/u.test(segment)) return dateText(now.getFullYear(), now.getMonth() + 1, now.getDate());
      match = segment.match(/^(\d+)\s*秒前$/u);
      if (match) return fromOffset(Number(match[1]) * 1000);
      match = segment.match(/^(\d+)\s*分钟前$/u);
      if (match) return fromOffset(Number(match[1]) * 60000);
      match = segment.match(/^(\d+)\s*小时前$/u);
      if (match) return fromOffset(Number(match[1]) * 3600000);
      if (/^昨天/u.test(segment)) return fromOffset(dayMs);
      if (/^前天/u.test(segment)) return fromOffset(2 * dayMs);
      match = segment.match(/^(\d+)\s*天前$/u);
      if (match) return fromOffset(Number(match[1]) * dayMs);
      match = segment.match(/^(\d+)\s*周前$/u);
      if (match) return fromOffset(Number(match[1]) * 7 * dayMs);
      return undefined;
    };
    const segments = cleaned.split(/[·•|｜]/u).map((part) => part.trim()).filter(Boolean);
    for (const segment of segments) {
      const parsed = parseSegment(segment);
      if (parsed) return parsed;
    }
    return cleaned;
  };
  const publishedAt = (() => {
    for (const scope of metadataScopes) {
      const datetimeNode = scope.querySelector("time[datetime]");
      if (datetimeNode) publishedSelectorHit = true;
      const datetime = datetimeNode?.getAttribute("datetime")?.trim();
      if (datetime) return normalizePublished(datetime);
      const textNode = scope.querySelector("[data-e2e*='publish'],[data-e2e*='create-time'],[class*='publish-time'],[class*='create-time']");
      if (textNode) publishedSelectorHit = true;
      const text = textNode?.textContent?.trim();
      if (text) return normalizePublished(text);
    }
    return undefined;
  })();

  const canonicalURL = `https://www.douyin.com/video/${awemeId}`;
  const videoNodes = document.querySelectorAll("video");
  let mediaDescriptor: MediaDescriptor | undefined;
  // Keep this bound inside the injected function: browser.scripting serializes
  // the function body without module-level helpers or constants.
  const maximumMediaCandidates = 1000;
  if (videoNodes.length > maximumMediaCandidates) {
    mediaDescriptor = {
      kind: "unsupported",
      pageURL: href,
      canonicalURL,
      platform: "douyin",
      transcriptionCapability: "unavailable",
      failureReason: "multiple_candidates",
      selectionReason: "ambiguous",
      playbackState: "unknown",
      ...(author ? { author } : {}),
    };
  } else if (videoNodes.length > 0) {
    const videos = Array.from(videoNodes) as HTMLVideoElement[];
    const viewportWidth = document.defaultView?.innerWidth ?? 0;
    const viewportHeight = document.defaultView?.innerHeight ?? 0;
    const activeElement = document.activeElement;
    const identityAttributeNames = [
      "data-aweme-id", "data-aweme_id", "data-item-id", "data-item_id",
      "data-video-id", "data-video_id", "data-modal-id", "data-group-id",
    ];
    const addAwemeIds = (raw: string | null | undefined, ids: Set<string>) => {
      if (!raw) return;
      const trimmed = raw.trim();
      if (/^\d{8,25}$/u.test(trimmed)) ids.add(trimmed);
      for (const pattern of [
        /\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$|[?#])/gu,
        /[?&#](?:modal_id|aweme_id|item_id|video_id|group_id)=(\d{8,25})(?:[&#]|$)/gu,
      ]) {
        let match: RegExpExecArray | null;
        while ((match = pattern.exec(raw)) !== null) {
          if (match[1]) ids.add(match[1]);
        }
      }
    };
    const boundedAwemeIdsForVideo = (video: HTMLVideoElement): string[] => {
      let current: Element | null = video;
      // Nearest identity-bearing container wins. The fixed depth and two
      // querySelector probes per level avoid whole-page/card-grid traversal.
      for (let depth = 0; current && depth < 12; depth += 1) {
        if (current === document.body || current === document.documentElement) break;
        const ids = new Set<string>();
        for (const attributeName of identityAttributeNames) {
          addAwemeIds(current.getAttribute(attributeName), ids);
        }
        addAwemeIds(current.getAttribute("href"), ids);
        const matchingLink = current.querySelector(
          `a[href*='/video/${awemeId}'],a[href*='modal_id=${awemeId}'],a[href*='aweme_id=${awemeId}']`,
        );
        addAwemeIds(matchingLink?.getAttribute("href"), ids);
        const identityLink = current.querySelector(
          "a[href*='/video/'],a[href*='modal_id='],a[href*='aweme_id=']",
        );
        addAwemeIds(identityLink?.getAttribute("href"), ids);
        if (ids.size > 0) return [...ids];
        current = current.parentElement;
      }
      return [];
    };
    const candidates = videos.map((video) => {
      const rect = video.getBoundingClientRect();
      const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
      const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
      const centerX = (rect.left + rect.right) / 2;
      const centerY = (rect.top + rect.bottom) / 2;
      const playbackState: NonNullable<MediaDescriptor["playbackState"]> = video.ended
        ? "ended"
        : video.readyState === 0
          ? "notLoaded"
          : video.paused
            ? "paused"
            : "playing";
      return {
        video,
        playing: !video.paused && !video.ended && video.readyState > 0,
        recentlyInteracted: activeElement === video || (activeElement != null && video.contains(activeElement)),
        visibleArea: visibleWidth * visibleHeight,
        viewportCenterDistance: Math.hypot(centerX - viewportWidth / 2, centerY - viewportHeight / 2),
        playbackState,
        boundAwemeIds: boundedAwemeIdsForVideo(video),
      };
    });

    let pool = candidates.map((_, index) => index);
    let selectedIndex: number | undefined;
    let selectionReason: NonNullable<MediaDescriptor["selectionReason"]> = "ambiguous";
    const identityMatches = pool.filter((index) => {
      const ids = candidates[index]!.boundAwemeIds;
      return ids.length > 0 && ids.every((id) => id === awemeId);
    });
    const hasExplicitOtherIdentity = pool.some((index) => {
      const ids = candidates[index]!.boundAwemeIds;
      return ids.some((id) => id !== awemeId);
    });
    if (identityMatches.length > 0) pool = identityMatches;
    const identityMismatch = identityMatches.length === 0 && hasExplicitOtherIdentity;

    if (identityMismatch) {
      // The open URL identifies A, but the bounded video containers identify
      // only other items. Never hand B's transient playback URL to A.
    } else if (pool.length === 1) {
      selectedIndex = pool[0];
      selectionReason = "singleCandidate";
    } else {
      const playing = pool.filter((index) => candidates[index]!.playing);
      if (playing.length === 1) {
        selectedIndex = playing[0];
        selectionReason = "playing";
      } else {
        if (playing.length > 1) pool = playing;
        const interacted = pool.filter((index) => candidates[index]!.recentlyInteracted);
        if (interacted.length === 1) {
          selectedIndex = interacted[0];
          selectionReason = "recentInteraction";
        } else {
          if (interacted.length > 1) pool = interacted;
          let maxArea = Number.NEGATIVE_INFINITY;
          for (const index of pool) maxArea = Math.max(maxArea, candidates[index]!.visibleArea);
          const largest = pool.filter((index) => candidates[index]!.visibleArea === maxArea);
          if (largest.length === 1) {
            selectedIndex = largest[0];
            selectionReason = "largestVisibleArea";
          } else {
            pool = largest;
            let minDistance = Number.POSITIVE_INFINITY;
            for (const index of pool) {
              minDistance = Math.min(minDistance, candidates[index]!.viewportCenterDistance);
            }
            const nearest = pool.filter((index) => candidates[index]!.viewportCenterDistance === minDistance);
            if (nearest.length === 1) {
              selectedIndex = nearest[0];
              selectionReason = "nearestViewportCenter";
            }
          }
        }
      }
    }

    if (selectedIndex === undefined) {
      mediaDescriptor = {
        kind: "unsupported",
        pageURL: href,
        canonicalURL,
        platform: "douyin",
        transcriptionCapability: "unavailable",
        failureReason: "multiple_candidates",
        candidateCount: candidates.length,
        selectionReason: "ambiguous",
        playbackState: "unknown",
        ...(author ? { author } : {}),
      };
    } else {
      const selected = candidates[selectedIndex]!;
      const video = selected.video;
      const sourceNode = video.querySelector("source");
      const source = (video.currentSrc || video.src || video.getAttribute("src") || sourceNode?.getAttribute("src") || "").trim();
      const mimeType = video.getAttribute("type") || sourceNode?.getAttribute("type") || undefined;
      let kind: MediaDescriptor["kind"] = "unsupported";
      let transcriptionCapability: MediaDescriptor["transcriptionCapability"] = "unavailable";
      let failureReason: MediaDescriptor["failureReason"];
      let ephemeralPlaybackURL: string | undefined;
      if (video.mediaKeys != null) {
        failureReason = "drm_or_encrypted";
      } else if (/^(?:blob|mediasource|data):/u.test(source)) {
        kind = "browserSessionOnly"; failureReason = "blob_or_mse";
      } else if (!source) {
        kind = "browserSessionOnly"; failureReason = video.readyState === 0 ? "video_not_loaded" : "no_transferable_source";
      } else {
        try {
          const parsed = new URL(source, href);
          const type = (mimeType ?? "").toLowerCase().split(";", 1)[0]?.trim() ?? "";
          if (parsed.protocol !== "https:") {
            kind = "browserSessionOnly"; failureReason = "browser_session_required";
          } else if (parsed.pathname.toLowerCase().endsWith(".m3u8") || type.includes("mpegurl")) {
            kind = "hls"; transcriptionCapability = "conditional"; ephemeralPlaybackURL = parsed.toString();
          } else {
            const path = parsed.pathname.toLowerCase();
            const hostname = parsed.hostname.toLowerCase();
            const isDouyinVODHost = hostname === "douyinvod.com" || hostname.endsWith(".douyinvod.com");
            const isDouyinPlayPath = /^\/aweme\/v1\/(?:web\/)?play(?:\/|$)/u.test(path);
            if (/\.(?:mp4|mov)$/u.test(path) || type === "video/mp4" || type === "video/quicktime" || isDouyinVODHost || isDouyinPlayPath) {
              kind = "directFile"; transcriptionCapability = "supported"; ephemeralPlaybackURL = parsed.toString();
            } else {
              failureReason = "unsupported_media_type";
            }
          }
        } catch {
          failureReason = "unknown";
        }
      }
      mediaDescriptor = {
        kind,
        pageURL: href,
        canonicalURL,
        platform: "douyin",
        ...(ephemeralPlaybackURL ? { ephemeralPlaybackURL } : {}),
        ...(mimeType ? { mimeType } : {}),
        ...(author ? { author } : {}),
        transcriptionCapability,
        ...(failureReason ? { failureReason } : {}),
        candidateCount: candidates.length,
        selectionReason,
        playbackState: selected.playbackState,
      };
    }
  }

  // DOM-based stats extraction (fallback for when __INITIAL_STATE__ is unavailable).
  // Multi-video feeds must stay scoped to the active item's identity container;
  // never fill missing fields from the whole document, even with one <video>.
  const statScopes: ParentNode[] = metadataScopes;
  let statSelectorHitMask = 0;
  const countFrom = (raw: string): string | undefined => {
    const match = raw.trim().match(/[\d][\d,.]*(?:\s*[万亿wWkKmM])?/u);
    return match?.[0]?.replace(/\s+/gu, "");
  };
  const readStat = (bit: number, selectors: string[], ariaKeyword: RegExp): string | undefined => {
    const semanticSignal = (node: Element): boolean => {
      const candidates: Element[] = [];
      let current: Element | null = node;
      for (let depth = 0; current && depth <= 3; depth += 1) {
        candidates.push(current);
        if (current.previousElementSibling) candidates.push(current.previousElementSibling);
        if (current.nextElementSibling) candidates.push(current.nextElementSibling);
        current = current.parentElement;
      }
      return candidates.some((candidate) => ariaKeyword.test([
        candidate.getAttribute("aria-label") ?? "",
        candidate.getAttribute("title") ?? "",
        candidate.getAttribute("data-e2e") ?? "",
        candidate.getAttribute("class") ?? "",
      ].join(" ")));
    };
    for (const scope of statScopes) {
      for (const selector of selectors) {
        const node = scope.querySelector(selector);
        if (node) statSelectorHitMask |= bit;
        const value = countFrom(node?.textContent ?? "");
        if (value) return value;
      }
      for (const node of Array.from(scope.querySelectorAll("[aria-label]"))) {
        const label = node.getAttribute("aria-label")?.trim() ?? "";
        if (!ariaKeyword.test(label)) continue;
        statSelectorHitMask |= bit;
        const value = countFrom(label);
        if (value) return value;
      }
    }
    // Selector names change frequently, but this fallback must never relax
    // item identity: unlike the established selector/aria path, it does not
    // inspect identity-less dedicated metadata scopes. First collect at most
    // 200 numeric candidates. Seeing a 201st discards the entire scope so a
    // favorable early node cannot bias an oversized action region.
    for (const scope of safeItemScopes) {
      const candidates: Element[] = [];
      const nodes = scope.querySelectorAll("*");
      let exceededCandidateLimit = false;
      for (let index = 0; index < nodes.length; index += 1) {
        const node = nodes[index]!;
        const raw = node.textContent ?? "";
        if (!/^\s*\d+(?:\.\d+)?\s*[万亿wWkKmM]?\s*$/u.test(raw)) continue;
        if (candidates.length === 200) {
          exceededCandidateLimit = true;
          break;
        }
        candidates.push(node);
      }
      if (exceededCandidateLimit) continue;
      for (const node of candidates) {
        if (!semanticSignal(node)) continue;
        statSelectorHitMask |= bit;
        const value = countFrom(node.textContent ?? "");
        if (value) return value;
      }
    }
    return undefined;
  };
  const domStats = {
    likes: readStat(1,
      ["[data-e2e='like-count']", "[data-e2e='digg-count']", "[data-e2e='video-like-count']", "[data-e2e='feed-video-like-count']", "[data-e2e='feed-video-digg-count']", "[data-e2e='browse-video-like-count']"],
      /digg|like|praise|点赞|喜欢|赞/iu,
    ),
    comments: readStat(2,
      ["[data-e2e='comment-count']", "[data-e2e='video-comment-count']", "[data-e2e='feed-video-comment-count']", "[data-e2e='browse-video-comment-count']"],
      /评论|comment/iu,
    ),
    shares: readStat(4,
      ["[data-e2e='share-count']", "[data-e2e='video-share-count']", "[data-e2e='feed-video-share-count']", "[data-e2e='browse-video-share-count']"],
      /分享|转发|share/iu,
    ),
    collects: readStat(8,
      ["[data-e2e='collect-count']", "[data-e2e='favorite-count']", "[data-e2e='video-collect-count']", "[data-e2e='video-favorite-count']", "[data-e2e='feed-video-collect-count']", "[data-e2e='feed-video-favorite-count']", "[data-e2e='browse-video-collect-count']", "[data-e2e='browse-video-favorite-count']"],
      /收藏|collect|favou?rite/iu,
    ),
  };
  const definedDomStats: { likes?: string; comments?: string; shares?: string; collects?: string } = {};
  if (domStats.likes !== undefined) definedDomStats.likes = domStats.likes;
  if (domStats.comments !== undefined) definedDomStats.comments = domStats.comments;
  if (domStats.shares !== undefined) definedDomStats.shares = domStats.shares;
  if (domStats.collects !== undefined) definedDomStats.collects = domStats.collects;
  const hasDomStats = Object.keys(definedDomStats).length > 0;
  const scopeRejectCode: DouyinMetadataDOMDiagnostic["scopes"]["rejectCode"] =
    dedicatedMetadataScopes.length > 0
      ? "dominant_video_proof"
      : safeItemScopes.length > 0
        ? (identityConflictStoppedClimb ? "identity_conflict_stopped" : "none")
        : dedicatedIdentityConflict || activeVideoContainer ? "identity_conflict" : "not_dedicated";
  const routeRejectCode: DouyinMetadataDOMDiagnostic["route"]["rejectCode"] = isDedicatedMetadataRoute
    ? "none"
    : "non_canonical_route";
  const videoRejectCode: DouyinMetadataDOMDiagnostic["video"]["rejectCode"] = initialVideoNodeLimit
    ? "video_node_limit"
    : positiveVisibleVideoCount === 0
      ? "no_visible_video"
      : isDedicatedMetadataRoute && !uniquelyDominantDedicatedVideo
        ? "not_uniquely_dominant"
        : "none";

  // 图文帖（图集）的图片只从 DOM 读。SSR 水合数据实测在弹层页和详情页都不
  // 含这条 aweme（精确命中恒为否），而同源 detail API 需要 session cookie，
  // V1 信封的契约又把 usedCookie 锁死为 false。页面渲染出来的 <img> 是唯一
  // 既拿得到、又不动用 cookie 的来源。
  const imageURLs: string[] = [];
  try {
    const galleryURL = (raw: string | null | undefined): string => {
      const trimmed = (raw ?? "").trim();
      if (!trimmed || trimmed.length > 2048) return "";
      try {
        const url = new URL(trimmed, href);
        if (url.protocol !== "https:") return "";
        const host = url.hostname.toLowerCase();
        if (host !== "douyinpic.com" && !host.endsWith(".douyinpic.com")) return "";
        // 抖音自己在图片地址上标了用途，这比任何 DOM 位置启发式都准：
        // 图文帖正片图是 biz_tag=aweme_images（路径同时带 tplv-dy-aweme-images），
        // 评论区配图是 biz_tag=aweme_comment，头像与推荐位封面没有这个标记。
        // 实测同一页面上三类混在一起：只收正片图，7 张的帖子才不会收成 19 张。
        const isGalleryImage = url.searchParams.get("biz_tag") === "aweme_images"
          || /tplv-dy-aweme-images/u.test(url.pathname);
        if (!isGalleryImage) return "";
        return url.href;
      } catch {
        return "";
      }
    };
    // 抖音图文帖本身最多 35 张。收得比这还多，说明圈进的不是这条帖子的图集。
    const maximumGallery = 35;
    const addImage = (raw: string | null | undefined) => {
      if (imageURLs.length >= maximumGallery) return;
      const url = galleryURL(raw);
      if (url && !imageURLs.includes(url)) imageURLs.push(url);
    };
    const collectFrom = (root: ParentNode): string[] => {
      const found: string[] = [];
      if (typeof root.querySelectorAll !== "function") return found;
      const nodes = root.querySelectorAll("img");
      if (nodes.length > 200) return found;
      for (const node of nodes) {
        // 懒加载版式把真实地址放在 srcset 的第一个候选里。
        const srcset = node.getAttribute("srcset");
        for (const raw of [
          node.getAttribute("src"),
          srcset ? srcset.split(",")[0]?.trim().split(/\s+/u)[0] : null,
        ]) {
          const url = galleryURL(raw);
          if (url && !found.includes(url)) found.push(url);
        }
      }
      return found;
    };
    // metadataScopes 是从内到外的祖先链。只认最靠内、第一个出图的那层：再往外
    // 一层就会把右侧推荐列表的封面圈进来（实测 7 张的帖子一路收到 30 张）。
    // 某层一次收超过 35 张就是已经越界，更外层只会更宽，直接放弃 scope 路径。
    for (const scope of metadataScopes) {
      const found = collectFrom(scope);
      if (found.length > maximumGallery) break;
      if (found.length > 0) {
        for (const url of found) addImage(url);
        break;
      }
    }
    if (imageURLs.length === 0) {
      // 搜索页弹层没有任何通过身份校验的 scope（实测 safeCount 0）。biz_tag 已经
      // 精确到正片图，所以这里按 DOM 顺序全页收即可——不能按可见面积筛，轮播里
      // 还没滚到的 slide 面积为 0，那正是要保住的几张。
      const nodes = document.querySelectorAll("img");
      if (nodes.length <= 1000) {
        for (const node of nodes) {
          addImage(node.getAttribute("src"));
          const srcset = node.getAttribute("srcset");
          if (srcset) addImage(srcset.split(",")[0]?.trim().split(/\s+/u)[0]);
        }
      }
    }
  } catch {
    // 图片是增量信息，读取失败不影响这条抓取的其余部分。
  }

  return {
    awemeId,
    canonicalURL,
    title,
    author,
    ...(publishedAt ? { publishedAt } : {}),
    description,
    pageURL: href,
    ...(mediaDescriptor ? { mediaDescriptor } : {}),
    ...(hasDomStats ? { stats: definedDomStats } : {}),
    ...(imageURLs.length > 0 ? { imageURLs } : {}),
    metadataDiagnostic: {
      route: { eligible: isDedicatedMetadataRoute, rejectCode: routeRejectCode },
      video: {
        positiveVisibleCount: positiveVisibleVideoCount,
        dominantVideoCount: dominantVisibleVideo ? 1 : 0,
        rejectCode: videoRejectCode,
      },
      scopes: { safeCount: safeItemScopes.length, dedicatedCount: dedicatedMetadataScopes.length, rejectCode: scopeRejectCode },
      dom: {
        publishedSelectorHit,
        statSelectorHitMask,
        statAcceptedCount: Object.keys(definedDomStats).length,
      },
    },
  };
}
