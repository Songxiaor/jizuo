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
  "[class*='ad-' i],[id*='ad-' i],[class*='advert' i],[class*='promo' i]";

/**
 * Testable extraction against a Document-like object.
 * Production injection uses extractPageInIsolatedWorld (must stay self-contained).
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
  const body = stripBoilerplateLines(markdown);
  const meta = resolvePageMetadata(documentLike);
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
      if (!href || isXProfileChromeImageURL(href)) return;
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

function pickContentRoot(documentLike: Document): Element {
  // Non-X pages only. X status uses extractXStatusPage.
  const selectors = ["#js_content", "#img-content", "[itemprop='articleBody']", "article", "main"];
  for (const selector of selectors) {
    const node = documentLike.querySelector(selector);
    if (node && (node.textContent?.trim().length ?? 0) >= 20) return node;
  }
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
  const activity = documentLike.querySelector("#activity-name")?.textContent?.trim();
  if (activity) return activity;
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
  author?: string;
  published?: string;
  likes?: string;
  replies?: string;
  reposts?: string;
}): string {
  const lines: string[] = ["---"];
  if (fields.author) lines.push(`author: ${JSON.stringify(fields.author)}`);
  if (fields.published) lines.push(`published: ${JSON.stringify(fields.published)}`);
  // Engagement is optional structured chrome — only when a stable parse succeeded.
  if (fields.likes) lines.push(`likes: ${JSON.stringify(fields.likes)}`);
  if (fields.replies) lines.push(`replies: ${JSON.stringify(fields.replies)}`);
  if (fields.reposts) lines.push(`reposts: ${JSON.stringify(fields.reposts)}`);
  // Intentionally omit meta/og:description: WeChat and many sites fill it with
  // promotional SEO blurbs that are not a faithful article abstract.
  if (lines.length === 1) return "";
  lines.push("---", "");
  return lines.join("\n");
}

export function resolvePageMetadata(documentLike: Document): {
  author?: string;
  published?: string;
} {
  const author =
    documentLike.querySelector("#js_name")?.textContent?.trim() ||
    documentLike.querySelector("a.rich_media_meta_link")?.textContent?.trim() ||
    metaContent(documentLike, "author") ||
    metaContent(documentLike, "article:author", "property") ||
    metaContent(documentLike, "og:article:author", "property") ||
    // GitHub repo pages expose no author meta; the owner is the author.
    gitHubRepoSlug(documentLike.location.href)?.split("/")[0];
  const published =
    documentLike.querySelector("#publish_time")?.textContent?.trim() ||
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
      const raw =
        el.getAttribute("data-src") ||
        el.getAttribute("data-original") ||
        el.getAttribute("src") ||
        "";
      const href = absoluteUrl(raw, baseHref);
      if (!href) return alt ? `\n\n${alt}\n\n` : "";
      if (isXProfileChromeImageURL(href)) return "";
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
  // On the feed the caption is the item's title; only trust og:title when the
  // active container yields no caption of its own.
  const rawTitle = scopedDesc || ogTitle || document.querySelector("h1")?.textContent?.trim() || document.title || "抖音视频";
  const unprefixedTitle = rawTitle.replace(/\s+-\s+抖音.*$/u, "").replace(/(?:…|\.{3})?\s*展开$/u, "").trim();
  const description = cleanLines(
    scopedDesc
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
    const cleanNickname = (raw: string): string =>
      raw
        .replace(/(?:官方|企业|个人|机构)?认证(?:徽章|信息|标识)?/gu, "")
        .replace(/已认证/gu, "")
        .replace(/\s+/gu, " ")
        .trim();
    for (const scope of safeItemScopes) {
      const node = scope.querySelector(
        "[data-e2e='feed-video-nickname'],[data-e2e='video-author-info-nickname'],[data-e2e='user-info']",
      );
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
  const title = (() => {
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
  })();
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

/**
 * Injected via chrome.scripting.executeScript — must be fully self-contained.
 * Do not reference module-level helpers from this function body.
 */
export function extractPageInIsolatedWorld(): ExtractedPage {
  // Hard cap on extracted text: 1 MB chars (~350K Chinese / ~1M ASCII).
  // Truncates at paragraph boundary; falls back to hard cut at 50% threshold.
  const MAX_TEXT_CHARS = 1_048_576;
  const capText = (raw: string): string => {
    if (raw.length <= MAX_TEXT_CHARS) return raw;
    const cutAt = raw.lastIndexOf("\n\n", MAX_TEXT_CHARS);
    const body =
      cutAt > MAX_TEXT_CHARS * 0.5 ? raw.slice(0, cutAt) : raw.slice(0, MAX_TEXT_CHARS);
    return body + "\n\n…（内容过长，已截断）";
  };

  const selection = document.defaultView?.getSelection()?.toString() ?? "";
  if (selection.trim()) {
    const text = capText(
      selection
        .replace(/\r\n/g, "\n")
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .replace(/[ \t]{2,}/g, " ")
        .trim(),
    );
    return {
      title: document.title ?? "",
      url: document.location.href,
      text,
      characterCount: [...text].length,
      method: "selection",
    };
  }

  // Douyin single-video path (self-contained — no module imports).
  // Requires a concrete aweme id (/video/{id} or modal_id=…); bare feed shells fall through.
  {
    const href = document.location.href;
    let host: string;
    let awemeId = "";
    try {
      const url = new URL(href);
      host = url.hostname.toLowerCase();
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
      host = "";
    }
    const isDouyin =
      host === "www.douyin.com"
      || host === "douyin.com"
      || host === "v.douyin.com"
      || host === "www.iesdouyin.com"
      || host === "iesdouyin.com"
      || host.endsWith(".douyin.com")
      || host.endsWith(".iesdouyin.com");
    // Only treat the surface as single-video when the current URL identifies the item.
    if (isDouyin && awemeId) {
      const shellLines = new Set([
        "精选", "AI抖音", "关注", "朋友", "我的", "直播", "放映厅", "短剧",
        "推荐", "搜索", "充钻石", "下载电脑客户端", "壁纸", "通知", "消息",
        "投稿", "登录", "客户端", "读屏标签已关闭",
      ]);
      const ogTitle = document.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
      const ogDesc = document.querySelector("meta[property='og:description']")?.getAttribute("content")?.trim();
      const author =
        document.querySelector("meta[name='author']")?.getAttribute("content")?.trim()
        || document.querySelector("[data-e2e='user-info']")?.textContent?.trim()
        || undefined;
      const rawTitle = ogTitle || document.querySelector("h1")?.textContent?.trim() || document.title || "抖音视频";
      const title = rawTitle.replace(/\s+-\s+抖音.*$/u, "").trim() || "抖音视频";
      const descriptionRaw =
        ogDesc
        || document.querySelector("[data-e2e='video-desc']")?.textContent?.trim()
        || document.querySelector("[data-e2e='browse-video-desc']")?.textContent?.trim()
        || "";
      const description = descriptionRaw
        .split(/\n+/u)
        .map((line) => line.trim())
        .filter((line) => {
          if (!line || shellLines.has(line)) return false;
          if (/^(?:朋友|关注|消息|通知)\s*\d+$/u.test(line)) return false;
          return true;
        })
        .join("\n")
        .trim();
      const lines = ["---"];
      if (author) lines.push(`author: ${JSON.stringify(author)}`);
      lines.push(`aweme_id: ${JSON.stringify(awemeId)}`);
      const header = `${lines.join("\n")}\n---\n\n`;
      // Never use document.body — feed chrome would become the capture body.
      const body = [title ? `# ${title}` : "", description].filter(Boolean).join("\n\n");
      const text = `${header}${body}`.trim() || "抖音公开视频";
      return {
        title,
        url: `https://www.douyin.com/video/${awemeId}`,
        text,
        characterCount: [...text].length,
        method: "rendered_dom",
      };
    }
  }

  const markers =
    "相关阅读|相关推荐|推荐阅读|热门文章|猜你喜欢|更多精彩|点击关注|扫码关注|分享到|版权声明|免责声明|阅读原文|写留言|精选留言|打开微信|关注公众号|广告".split(
      "|",
    );
  const noiseSelector =
    "script,style,noscript,template,nav,footer,header,aside,form,iframe,svg,button," +
    "[class*='qrcode' i],[id*='qrcode' i],[class*='reward' i]," +
    "[class*='rich_media_tool' i],[class*='rich_media_area_extra' i],[id*='js_tags' i]," +
    "[class*='sns_opr' i],[class*='comment' i],[id*='comment' i]," +
    "[class*='related' i],[class*='recommend' i],[class*='hot-article' i]," +
    "[class*='ad-' i],[id*='ad-' i],[class*='advert' i],[class*='promo' i]";

  const baseHref = document.location.href;
  const isXStatus = (() => {
    try {
      const url = new URL(document.location.href);
      const host = url.hostname.toLowerCase();
      return (
        (host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")) &&
        /^\/[^/]+\/status\/\d+(?:\/|$)/u.test(url.pathname)
      );
    } catch {
      return false;
    }
  })();

  const absoluteUrl = (href: string): string | null => {
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
  };

  const collapseInline = (value: string): string =>
    value
      .replace(/[ \t\u00a0]+/g, " ")
      .replace(/\n+/g, " ")
      .trim();

  const normalize = (value: string): string => {
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
  };

  const isProfileChrome = (href: string): boolean => {
    try {
      const path = new URL(href).pathname.toLowerCase();
      const full = href.toLowerCase();
      if (full.includes("profile_images") || full.includes("default_profile")) return true;
      if (/_(?:normal|bigger|mini|x96|400x400)\./.test(path)) return true;
      return false;
    } catch {
      return false;
    }
  };

  const TEXT_NODE = 3;
  const ELEMENT_NODE = 1;
  const walk = (node: Node): string => {
    if (node.nodeType === TEXT_NODE) {
      return (node.textContent ?? "").replace(/\u00a0/g, " ");
    }
    if (node.nodeType !== ELEMENT_NODE) return "";
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    const inner = Array.from(el.childNodes).map(walk).join("");
    if (tag === "br") return "\n";
    if (/^h[1-6]$/.test(tag)) {
      return `\n\n${"#".repeat(Number(tag[1]))} ${collapseInline(inner)}\n\n`;
    }
    if (tag === "p") {
      const body = collapseInline(inner);
      return body ? `\n\n${body}\n\n` : "\n";
    }
    if (tag === "div" || tag === "section" || tag === "figure" || tag === "span") {
      const hasBlock = Array.from(el.childNodes).some((child) => {
        if (child.nodeType !== ELEMENT_NODE) return false;
        const childTag = (child as Element).tagName.toLowerCase();
        return (
          childTag === "p" ||
          childTag === "div" ||
          childTag === "section" ||
          childTag === "figure" ||
          childTag === "ul" ||
          childTag === "ol" ||
          childTag === "li" ||
          childTag === "blockquote" ||
          childTag === "pre" ||
          childTag === "img" ||
          /^h[1-6]$/.test(childTag)
        );
      });
      if (hasBlock) return `\n${inner}\n`;
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
      const raw =
        el.getAttribute("data-src") ||
        el.getAttribute("data-original") ||
        el.getAttribute("src") ||
        "";
      const href = absoluteUrl(raw);
      if (!href || isProfileChrome(href)) return "";
      return `\n\n![${alt.replace(/[[\]]/g, "")}](${href})\n\n`;
    }
    return inner;
  };

  // —— X status: semantic nodes only (mirrors extractXStatusPage) ——
  if (isXStatus) {
    const article =
      document.querySelector("article[data-testid='tweet']") ?? document.querySelector("article");
    const scope: ParentNode = article ?? document;

    const reserved = new Set([
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
    let display: string | undefined;
    let handle: string | undefined;
    const userName = scope.querySelector("[data-testid='User-Name']");
    if (userName) {
      userName.querySelectorAll("a[href]").forEach((link) => {
        const href = (link.getAttribute("href") ?? "").trim();
        const pathMatch = href.match(/^\/@?([A-Za-z0-9_]{1,15})(?:\/|$|\?)/);
        const pathHandle = pathMatch?.[1];
        if (pathHandle && !reserved.has(pathHandle.toLowerCase())) handle = pathHandle;
        const label = (link.textContent ?? "").replace(/\s+/g, " ").trim();
        if (!label) return;
        if (label.startsWith("@") && label.length > 1) {
          handle = label.slice(1).replace(/[^A-Za-z0-9_]/g, "") || handle;
          return;
        }
        if (!/^\d/.test(label) && !/^(·|•)$/.test(label) && label.length <= 80 && !display) {
          display = label;
        }
      });
      if (!display && !handle) {
        const raw = (userName.textContent ?? "").replace(/\s+/g, " ").trim();
        const at = raw.match(/@([A-Za-z0-9_]{1,15})/);
        if (at) handle = at[1];
        const beforeAt = raw.split("@")[0]?.trim();
        if (beforeAt && beforeAt.length >= 1 && beforeAt.length <= 80) display = beforeAt;
      }
    }
    let author: string | undefined;
    if (display && handle) author = `${display} (@${handle})`;
    else if (handle) author = `@${handle}`;
    else if (display) author = display;

    const published = scope.querySelector("time[datetime]")?.getAttribute("datetime")?.trim() || undefined;

    const parseCount = (selector: string, verb: RegExp): string | undefined => {
      const node = scope.querySelector(selector);
      if (!node) return undefined;
      const label =
        node.getAttribute("aria-label")?.trim() ||
        node.closest("[aria-label]")?.getAttribute("aria-label")?.trim() ||
        "";
      if (!label || !verb.test(label)) return undefined;
      const match =
        label.match(
          /([\d.,]+ ?[KkMm万亿]?)\s*(?:次)?\s*(?:Likes?|Replies|Reposts?|Retweets?|喜欢|赞|回复|回应|转帖|转发|转推)/i,
        ) ||
        label.match(
          /(?:Likes?|Replies|Reposts?|Retweets?|喜欢|赞|回复|回应|转帖|转发|转推)\s*([\d.,]+ ?[KkMm万亿]?)/i,
        );
      const value = match?.[1]?.trim();
      if (!value || !/[\d]/.test(value)) return undefined;
      return value;
    };
    const likes = parseCount("[data-testid='like'], [data-testid='unlike']", /like|喜欢|赞/i);
    const replies = parseCount("[data-testid='reply']", /repl(?:y|ies)|回复|回应/i);
    const reposts = parseCount(
      "[data-testid='retweet'], [data-testid='unretweet']",
      /repost|retweet|转帖|转发|转推/i,
    );

    const fm: string[] = ["---"];
    if (author) fm.push(`author: ${JSON.stringify(author)}`);
    if (published) fm.push(`published: ${JSON.stringify(published)}`);
    if (likes) fm.push(`likes: ${JSON.stringify(likes)}`);
    if (replies) fm.push(`replies: ${JSON.stringify(replies)}`);
    if (reposts) fm.push(`reposts: ${JSON.stringify(reposts)}`);
    const header = fm.length > 1 ? `${fm.join("\n")}\n---\n\n` : "";

    // querySelectorAll order — never early-return on wrappers that nest tweetText.
    const bodyParts: string[] = [];
    const seenMedia = new Map<string, { href: string; rank: number }>();
    const seenText = new Set<string>();
    const rootEl: Element = article ?? document.documentElement;

    const formatProse = (raw: string): string => {
      let value = raw
        .replace(/\r\n/g, "\n")
        .split("\n")
        .map((line) => line.replace(/[ \t\u00a0]+/g, " ").trim())
        .join("\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim();
      if (value.split("\n").filter(Boolean).length <= 1 && /[。！？；]/.test(value)) {
        value = value
          .replace(/([。！？])(?=["”」』]?)/g, "$1\n\n")
          .replace(/(?=[（(]?[一二三四五六七八九十百]+[、．.])/g, "\n\n")
          .replace(/(?=\d+[.、．]\s*)/g, "\n")
          .replace(/\n{3,}/g, "\n\n")
          .trim();
      }
      return value;
    };

    const extractBreaks = (rootElInner: Element): string => {
      const parts: string[] = [];
      const walkBreaks = (node: Node): void => {
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
        Array.from(el.childNodes).forEach((child) => walkBreaks(child));
        if (block) parts.push("\n");
      };
      walkBreaks(rootElInner);
      return formatProse(parts.join(""));
    };

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
        const href = absoluteUrl(raw);
        if (!href || isProfileChrome(href)) return;
        let key = href;
        try {
          const url = new URL(href);
          const match = url.pathname.match(/\/media\/([^/]+)/i);
          key = match?.[1]?.replace(/\.(jpg|jpeg|png|webp|gif)$/i, "") ?? `${url.origin}${url.pathname}`;
        } catch {
          /* keep */
        }
        let rank = 25;
        try {
          const name = new URL(href).searchParams.get("name")?.toLowerCase() ?? "";
          if (name === "large" || name === "orig") rank = 40;
          else if (name === "medium") rank = 30;
          else if (name === "small") rank = 20;
        } catch {
          rank = 0;
        }
        const prev = seenMedia.get(key);
        if (prev && prev.rank > rank) return;
        if (prev) {
          const marker = `![](${prev.href})`;
          const idx = bodyParts.indexOf(marker);
          if (idx >= 0) bodyParts[idx] = `![](${href})`;
        } else {
          bodyParts.push(`![](${href})`);
        }
        seenMedia.set(key, { href, rank });
      });
    };

    const appendProse = (raw: string) => {
      const prose = formatProse(raw);
      const key = prose.replace(/\s+/g, " ").trim();
      if (key.length < 1 || seenText.has(key)) return;
      seenText.add(key);
      bodyParts.push(prose);
    };

    const appendMarkdownBlock = (markdown: string, plainText = markdown) => {
      const cleaned = markdown.trim();
      const key = plainText.replace(/\s+/g, " ").trim();
      if (!cleaned || !key || seenText.has(key)) return;
      seenText.add(key);
      bodyParts.push(cleaned);
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
      const walkArticle = (node: Node): void => {
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
          const heading = formatProse(el.textContent ?? "").replace(/\s+/g, " ").trim();
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
          const quote = formatProse(el.textContent ?? "");
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
        Array.from(el.childNodes).forEach((child) => walkArticle(child));
        if (block) proseParts.push("\n");
      };
      walkArticle(articleRoot);
      flushProse();
    };

    const richArticle = rootEl.querySelector("[data-testid='twitterArticleReadView']");
    if (richArticle) {
      walkRichArticleInOrder(richArticle);
      // The read view appends a Premium upsell row after the article body.
      const upsell =
        /^(?:想发布自己的文章[？?]?(?:\s*升级为\s*Premium。?)?|升级为\s*Premium。?|Want to publish your own Articles\??(?:\s*Upgrade to Premium\.?)?|Upgrade to Premium\.?)$/iu;
      for (let index = bodyParts.length - 1; index >= 0; index -= 1) {
        if (upsell.test((bodyParts[index] ?? "").replace(/\s+/g, " ").trim())) bodyParts.splice(index, 1);
      }
    } else {
      rootEl
        .querySelectorAll(
          "[data-testid='tweetText'], [data-testid='tweetPhoto'], [data-testid='videoPlayer']",
        )
        .forEach((node) => {
          const testId = node.getAttribute("data-testid") ?? "";
          if (testId === "tweetText") {
            const prose = extractBreaks(node as Element);
            const key = prose.replace(/\s+/g, " ").trim();
            if (key.length >= 1 && !seenText.has(key)) {
              seenText.add(key);
              bodyParts.push(prose);
            }
            return;
          }
          if (testId === "tweetPhoto" || testId === "videoPlayer") emitMedia(node as Element);
        });
    }

    if (!seenText.size) {
      const clone = rootEl.cloneNode(true) as Element;
      clone
        .querySelectorAll(
          "[data-testid='User-Name'],[data-testid='tweetPhoto'],[data-testid='videoPlayer']," +
            "[data-testid='card.wrapper'],[data-testid='like'],[data-testid='unlike']," +
            "[data-testid='reply'],[data-testid='retweet'],[data-testid='unretweet']," +
            "[data-testid='bookmark'],time,button,svg,[role='group']",
        )
        .forEach((n) => n.remove());
      clone.querySelectorAll("img").forEach((img) => {
        const src = img.getAttribute("src") ?? "";
        if (isProfileChrome(src) || src.includes("profile_images")) img.remove();
      });
      const prose = extractBreaks(clone);
      if (prose.length >= 2 && !/^@?[A-Za-z0-9_]{1,15}$/.test(prose.replace(/\s+/g, ""))) {
        bodyParts.unshift(prose);
      }
    }

    // Preserve indentation inside fenced code blocks; prose blocks were already
    // normalized before they entered bodyParts.
    const body = bodyParts.join("\n\n").replace(/\r\n/g, "\n").trim();
    const firstProse =
      bodyParts
        .find((b) => b.trim() && !b.trim().startsWith("![") && !/^`{3,}/.test(b.trim()))
        ?.replace(/^#{1,6}\s+/, "")
        .replace(/\s+/g, " ")
        .trim() ?? "";
    let title = firstProse;
    const tab = (document.title ?? "").replace(/\s+/g, " ").trim();
    let cleanedTab = tab.replace(/\s*\/\s*X\s*$/iu, "").trim();
    cleanedTab = cleanedTab.replace(/^X\s*上的\s+.+?[:：]\s*/u, "").trim();
    cleanedTab = cleanedTab.replace(/^.+?\s+on\s+X\s*[:：]\s*/iu, "").trim();
    cleanedTab = cleanedTab.replace(/^[\s"'“”「『]+|[\s"'“”」』]+$/gu, "").trim();
    if (cleanedTab && cleanedTab.length <= 48) title = cleanedTab;
    else if (firstProse) {
      const soft = firstProse.match(
        /^(.{8,36}?)(?=昨天|今天|刚才|之前|我把|我们|很多|首先|一、|1[.、]|GitHub|http)/u,
      );
      if (soft?.[1]) title = soft[1].trim();
      else if (firstProse.length > 36) title = `${firstProse.slice(0, 36).trim()}…`;
    }

    const text = capText(`${header}${body}`.trim());
    return {
      title: title || document.title || "",
      url: document.location.href,
      text,
      characterCount: [...text].length,
      method: "rendered_dom",
    };
  }

  // —— Generic page path ——
  const pickRoot = (): Element => {
    for (const selector of ["#js_content", "#img-content", "[itemprop='articleBody']", "article", "main"]) {
      const node = document.querySelector(selector);
      if (node && (node.textContent?.trim().length ?? 0) >= 20) return node;
    }
    return document.body ?? document.documentElement;
  };

  const root = pickRoot().cloneNode(true) as Element;
  root.querySelectorAll(noiseSelector).forEach((node) => node.remove());
  let markdown = normalize(walk(root));
  markdown = normalize(
    markdown
      .split("\n")
      .filter((line) => {
        const trimmed = line.trim();
        if (!trimmed) return true;
        if (trimmed.startsWith("![") && trimmed.includes("](")) return true;
        for (const marker of markers) {
          if (trimmed === marker) return false;
          if (trimmed.startsWith(marker) && trimmed.length <= marker.length + 16) return false;
          if (trimmed.includes(marker) && trimmed.length <= marker.length + 8) return false;
        }
        return true;
      })
      .join("\n"),
  );

  const metaLine = (key: string, attr: "name" | "property" = "name"): string | undefined => {
    const value = document.querySelector(`meta[${attr}='${key}']`)?.getAttribute("content")?.trim();
    return value || undefined;
  };
  const author =
    document.querySelector("#js_name")?.textContent?.trim() ||
    document.querySelector("a.rich_media_meta_link")?.textContent?.trim() ||
    metaLine("author") ||
    metaLine("article:author", "property");
  const published =
    document.querySelector("#publish_time")?.textContent?.trim() ||
    metaLine("article:published_time", "property") ||
    metaLine("og:published_time", "property") ||
    metaLine("date");
  const fm: string[] = ["---"];
  if (author) fm.push(`author: ${JSON.stringify(author)}`);
  if (published) fm.push(`published: ${JSON.stringify(published)}`);
  const header = fm.length > 1 ? `${fm.join("\n")}\n---\n\n` : "";

  let title = document.title ?? "";
  const activity = document.querySelector("#activity-name")?.textContent?.trim();
  if (activity) title = activity;
  else {
    const h1 = document.querySelector("h1")?.textContent?.trim();
    if (h1 && h1.length >= 2) title = h1;
    else {
      const og = document.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim();
      if (og) title = og;
    }
  }

  const text = capText(`${header}${markdown}`.trim());
  return {
    title,
    url: document.location.href,
    text,
    characterCount: [...text].length,
    method: "rendered_dom",
  };
}
