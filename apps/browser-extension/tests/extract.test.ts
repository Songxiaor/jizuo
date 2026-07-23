import { describe, expect, it } from "vitest";
import {
  attachDetectedMedia,
  captureBodyLacksProse,
  enrichXCaptureWithTitleFallback,
  extractCurrentPage,
  extractPageInIsolatedWorld,
  formatXDisplayTitle,
  gitHubRepoSlug,
  formatXPostProse,
  isXProfileChromeImageURL,
  stripDouyinCaptionPrefix,
  stripBoilerplateLines,
  xMediaDedupeKey,
} from "../src/content/extract";
import { validateCapture } from "../src/contract";

type FakeNode = {
  nodeType: number;
  textContent?: string | null;
  tagName?: string;
  childNodes?: FakeNode[];
  parentNode?: FakeNode | null;
  attrs?: Record<string, string>;
  getAttribute?: (name: string) => string | null;
  querySelectorAll?: (selector: string) => FakeNode[];
  querySelector?: (selector: string) => FakeNode | null;
  cloneNode?: (deep?: boolean) => FakeNode;
  closest?: (selector: string) => FakeNode | null;
  remove?: () => void;
  contains?: (node: FakeNode | null) => boolean;
  getBoundingClientRect?: () => { left: number; top: number; right: number; bottom: number };
  paused?: boolean;
  ended?: boolean;
  readyState?: number;
  duration?: number;
  poster?: string;
  mediaKeys?: unknown;
};

const TEXT = 3;
const ELEMENT = 1;

function text(value: string): FakeNode {
  return { nodeType: TEXT, textContent: value };
}

function el(tag: string, children: FakeNode[] = [], attrs: Record<string, string> = {}): FakeNode {
  const node: FakeNode = {
    nodeType: ELEMENT,
    tagName: tag.toUpperCase(),
    childNodes: children,
    parentNode: null,
    attrs: { ...attrs },
    textContent: children.map((c) => c.textContent ?? "").join(""),
    getAttribute: (name) => attrs[name] ?? null,
    querySelectorAll: (selector) => collectMatching(node, selector),
    querySelector: (selector) => collectMatching(node, selector)[0] ?? null,
    cloneNode: () => structuredCloneNode(node),
    closest: (selector) => {
      if (matchesSimple(node, selector)) return node;
      return null;
    },
    remove: () => {
      const parent = node.parentNode;
      if (!parent?.childNodes) return;
      parent.childNodes = parent.childNodes.filter((child) => child !== node);
      parent.textContent = parent.childNodes.map((c) => c.textContent ?? "").join("");
      node.parentNode = null;
    },
    contains: (target) => target === node || (node.childNodes ?? []).some((child) => child.contains?.(target) ?? child === target),
    getBoundingClientRect: () => ({ left: 100, top: 100, right: 740, bottom: 460 }),
    paused: true,
    ended: false,
    readyState: 4,
    duration: 42,
    poster: attrs.poster ?? "",
    mediaKeys: null,
  };
  for (const child of children) child.parentNode = node;
  return node;
}

function structuredCloneNode(node: FakeNode): FakeNode {
  if (node.nodeType === TEXT) return text(node.textContent ?? "");
  const children = (node.childNodes ?? []).map(structuredCloneNode);
  return el((node.tagName ?? "div").toLowerCase(), children, { ...(node.attrs ?? {}) });
}

function collectMatching(root: FakeNode, selector: string): FakeNode[] {
  // Real querySelectorAll returns matches in tree order; comma is OR, not group-concat.
  const groups = selector.split(",").map((s) => s.trim()).filter(Boolean);
  const results: FakeNode[] = [];
  const seen = new Set<FakeNode>();
  const matchesAny = (node: FakeNode): boolean =>
    groups.some((group) => {
      const path = group.split(/\s+/).filter(Boolean);
      return path.length === 1 && matchesSimple(node, path[0]!);
    });
  const walk = (node: FakeNode) => {
    if (node.nodeType === ELEMENT && matchesAny(node) && !seen.has(node)) {
      seen.add(node);
      results.push(node);
    }
    for (const child of node.childNodes ?? []) walk(child);
  };
  walk(root);
  return results;
}

function matchesSimple(node: FakeNode, selector: string): boolean {
  if (node.nodeType !== ELEMENT) return false;
  const tag = (node.tagName ?? "").toLowerCase();
  const attrs = node.attrs ?? {};

  // tag[attr='value'] or [attr='value'] or tag or a[href]
  const re = /^([a-z0-9]+)?(?:\[([a-z0-9_-]+)(?:=['"]([^'"]*)['"])?\])?$/i;
  const m = selector.match(re);
  if (!m) {
    // fallback: plain tag
    return selector.toLowerCase() === tag;
  }
  const [, tagPart, attrName, attrValue] = m;
  if (tagPart && tagPart.toLowerCase() !== tag) return false;
  if (attrName) {
    const actual = attrs[attrName];
    if (actual == null) return false;
    if (attrValue !== undefined && actual !== attrValue) return false;
  }
  return true;
}

function makeDocument(options: {
  title: string;
  href: string;
  root: FakeNode;
  selection?: string;
  activityName?: string;
  /** When set, document-level tweetText query returns this text (legacy simple tests). */
  tweetText?: string;
}): Document {
  const body = el("body", [options.root]);

  const docQuery = (selector: string): FakeNode | null => {
    if (selector === "#js_content") {
      if ((options.root as { __id?: string }).__id === "js_content") return options.root;
      if (options.root.getAttribute?.("id") === "js_content") return options.root;
      return null;
    }
    if (selector === "#img-content") return null;
    if (selector === "#activity-name") {
      return options.activityName ? el("span", [text(options.activityName)]) : null;
    }
    if (selector === "[data-testid='tweetText']" && options.tweetText) {
      return el("span", [text(options.tweetText)], { "data-testid": "tweetText" });
    }
    if (selector === "h1") return collectMatching(body, "h1")[0] ?? null;
    if (selector === "meta[property='og:title']") return null;
    if (selector === "[itemprop='articleBody']") return null;
    if (selector === "article, main") {
      return collectMatching(body, "article")[0] ?? collectMatching(body, "main")[0] ?? null;
    }
    return collectMatching(body, selector)[0] ?? null;
  };

  const doc = {
    title: options.title,
    location: { href: options.href },
    defaultView: {
      getSelection: () => ({ toString: () => options.selection ?? "" }),
      innerWidth: 1280,
      innerHeight: 720,
    },
    activeElement: null,
    querySelector: docQuery,
    querySelectorAll: (selector: string) => {
      if (selector === "[data-testid='tweetText']" && options.tweetText) {
        return [el("span", [text(options.tweetText)], { "data-testid": "tweetText" })];
      }
      return collectMatching(body, selector);
    },
    body,
    documentElement: body,
  };
  return doc as unknown as Document;
}

describe("page extraction", () => {
  it("removes an author and relative-time prefix from a Douyin caption, but never returns empty", () => {
    expect(stripDouyinCaptionPrefix("@吴小杰 · 6天前为什么别人都是六改五？", "吴小杰"))
      .toBe("为什么别人都是六改五？");
    expect(stripDouyinCaptionPrefix("吴小杰 刚刚", "吴小杰")).toBe("吴小杰 刚刚");
  });

  it("keeps WeChat as an article/image capture even when the DOM contains video", () => {
    const page = {
      title: "公众号图文",
      url: "https://mp.weixin.qq.com/s/demo",
      text: "这是一篇包含正文图片和内嵌视频的公众号文章。",
      characterCount: 23,
      method: "rendered_dom" as const,
    };
    const media = {
      kind: "directFile" as const,
      pageURL: page.url,
      canonicalURL: page.url,
      platform: "wechat" as const,
      ephemeralPlaybackURL: "https://mmbiz.qpic.cn/video.mp4",
      transcriptionCapability: "supported" as const,
    };

    expect(attachDetectedMedia(page, media).mediaDescriptor).toBeUndefined();
    expect(attachDetectedMedia(page, { ...media, platform: "generic" }).mediaDescriptor).toBeDefined();
  });

  it("prefers article structure and keeps paragraphs instead of collapsing to one line", () => {
    const article = el("article", [
      el("h2", [text("一、先纠正一个认知")]),
      el("p", [text("本文用于验证 LinkDigest 的当前页面捕获链路。")]),
      el("p", [text("它不包含账号、Cookie 或真实私人内容。")]),
      el("ul", [el("li", [text("第一条")]), el("li", [text("第二条")])]),
    ]);
    const result = extractCurrentPage(
      makeDocument({
        title: "Fixed Test Article",
        href: "https://example.test/article",
        root: article,
      }),
    );
    expect(result.text).toContain("当前页面捕获链路");
    expect(result.text).toContain("## 一、先纠正一个认知");
    expect(result.text).toContain("- 第一条");
    expect(result.text).toContain("\n\n");
    expect(result.text.indexOf("当前页面捕获链路")).toBeLessThan(result.text.indexOf("它不包含账号"));
    expect(result.text.split("\n\n").length).toBeGreaterThan(1);
    expect(result.characterCount).toBe([...result.text].length);
  });

  it("drops wechat-style chrome lines and related-reading tails", () => {
    const lazyImage = "https://mmbiz.qpic.cn/mmbiz_jpg/example/640?wx_fmt=jpeg";
    const root = el("div", [
      el("p", [text("正文章节：远程操控可以节省碎片时间。")]),
      el("img", [], { "data-src": lazyImage, alt: "正文配图" }),
      el("p", [text("相关阅读")]),
      el("p", [text("关注公众号获取更多")]),
      el("p", [text("广告")]),
    ]);
    (root as { __id?: string }).__id = "js_content";
    root.getAttribute = (name: string) => (name === "id" ? "js_content" : null);
    root.attrs = { id: "js_content" };

    const documentLike = makeDocument({
      title: "WeChat fixture",
      href: "https://mp.weixin.qq.com/s/demo",
      root,
      activityName: "分享一下我的远程操控方案",
    });
    const result = extractCurrentPage(documentLike);
    expect(result.title).toBe("分享一下我的远程操控方案");
    expect(result.text).toContain("远程操控可以节省碎片时间");
    expect(result.text).toContain(`![正文配图](${lazyImage})`);
    expect(result.text).not.toContain("相关阅读");
    expect(result.text).not.toContain("关注公众号");
    expect(result.text.split("\n").some((line) => line.trim() === "广告")).toBe(false);

    const previousDocument = globalThis.document;
    Object.defineProperty(globalThis, "document", {
      configurable: true,
      writable: true,
      value: documentLike,
    });
    try {
      const injected = extractPageInIsolatedWorld();
      expect(injected.text).toContain("远程操控可以节省碎片时间");
      expect(injected.text).toContain(`![正文配图](${lazyImage})`);
    } finally {
      if (previousDocument) {
        Object.defineProperty(globalThis, "document", {
          configurable: true,
          writable: true,
          value: previousDocument,
        });
      } else {
        delete (globalThis as { document?: Document }).document;
      }
    }
  });

  it("preserves WeChat code-snippet blocks as fenced code with one line per <code>", () => {
    const root = el("div", [
      el("p", [text("我把 Prompt 放在这里，有需要的朋友直接复制：")]),
      el("section", [
        el(
          "ul",
          [el("li", [text("1")]), el("li", [text("2")]), el("li", [text("3")])],
          { class: "code-snippet__line-index code-snippet__js" },
        ),
        el(
          "pre",
          [
            el("code", [text("# 横纵分析法 Deep Research Prompt")]),
            el("code", [text("研究对象 = 「此处替换为你的研究对象名」")]),
            el("code", [text("    indented line")]),
          ],
          { class: "code-snippet__js" },
        ),
      ]),
      el("p", [text("以上就是完整内容。")]),
    ]);
    root.getAttribute = (name: string) => (name === "id" ? "js_content" : null);
    root.attrs = { id: "js_content" };

    const result = extractCurrentPage(
      makeDocument({
        title: "代码块文章",
        href: "https://mp.weixin.qq.com/s/code-demo",
        root,
      }),
    );
    // One fenced block, one source line per <code>, indentation intact.
    expect(result.text).toContain(
      "```\n# 横纵分析法 Deep Research Prompt\n研究对象 = 「此处替换为你的研究对象名」\n    indented line\n```",
    );
    // The line-number rail must not leak as a bullet list.
    expect(result.text).not.toMatch(/- 1\b/);
    expect(result.text).toContain("以上就是完整内容。");
  });

  it("stripBoilerplateLines keeps long prose that merely mentions a marker", () => {
    const prose = "本文讨论广告与内容的边界，并不是运营位。";
    expect(stripBoilerplateLines(prose)).toContain("广告与内容");
  });

  it("uses a short X title, not the whole post wall", () => {
    const post = "这是已经登录后在当前页面看到的一条 X 帖文，用于验证只从渲染 DOM 交接内容。";
    const result = extractCurrentPage(
      makeDocument({
        title: "X",
        href: "https://x.com/syc/status/123456789",
        root: el("article", [el("div", [text(post)], { "data-testid": "tweetText" })], {
          "data-testid": "tweet",
        }),
      }),
    );
    expect(result.title.length).toBeLessThanOrEqual(48);
    expect(result.text).toContain(post);
  });

  it("X status keeps body text and tweet photos; drops avatar and shell chrome", () => {
    const post = "99% 的人没看出来的数字人口播实战攻略";
    const avatar = "https://pbs.twimg.com/profile_images/1/abc_normal.jpg";
    const media = "https://pbs.twimg.com/media/POST_MEDIA.jpg";
    const article = el(
      "article",
      [
        el("div", [el("img", [], { src: avatar, alt: "Rachel" })]),
        el(
          "div",
          [el("a", [text("Rachel")], { href: "/Zesee" }), el("a", [text("@Zesee")], { href: "/Zesee" })],
          { "data-testid": "User-Name" },
        ),
        el("time", [], { datetime: "2026-07-19T04:00:00.000Z" }),
        el("div", [text(post)], { "data-testid": "tweetText" }),
        el("div", [el("img", [], { src: media, alt: "配图" })], { "data-testid": "tweetPhoto" }),
        el("div", [
          el("button", [], { "data-testid": "like", "aria-label": "128 Likes. Like" }),
          el("button", [], { "data-testid": "reply", "aria-label": "4 Replies. Reply" }),
          el("button", [text("乱入的 999")], { "data-testid": "retweet" }),
        ]),
      ],
      { "data-testid": "tweet" },
    );

    const result = extractCurrentPage(
      makeDocument({
        title: `X 上的 Rachel：“${post}” / X`,
        href: "https://x.com/Zesee/status/723280534851786",
        root: article,
      }),
    );

    expect(result.text).toContain(post);
    expect(result.text).toContain(media);
    expect(result.text).not.toContain(avatar);
    expect(result.text).not.toContain("乱入的 999");
    const bodyOnly = result.text.replace(/^---[\s\S]*?---\n*/, "");
    expect(bodyOnly).not.toMatch(/@Zesee/);
    // Text should appear before the image marker (document order).
    expect(bodyOnly.indexOf(post)).toBeLessThan(bodyOnly.indexOf(media));
    expect(result.text).toContain('author: "Rachel (@Zesee)"');
    expect(result.text).toContain('likes: "128"');
    expect(result.title).toBe(post);
    expect(result.title.length).toBeLessThanOrEqual(48);
  });

  it("interleaves text and photos in DOM order", () => {
    const a = "第一段文字";
    const b = "第二段文字";
    const img1 = "https://pbs.twimg.com/media/AAA?format=jpg&name=large";
    const img2 = "https://pbs.twimg.com/media/BBB?format=jpg&name=large";
    const article = el(
      "article",
      [
        el("div", [text(a)], { "data-testid": "tweetText" }),
        el("div", [el("img", [], { src: img1 })], { "data-testid": "tweetPhoto" }),
        el("div", [text(b)], { "data-testid": "tweetText" }),
        el("div", [el("img", [], { src: img2 })], { "data-testid": "tweetPhoto" }),
      ],
      { "data-testid": "tweet" },
    );
    const result = extractCurrentPage(
      makeDocument({ title: "X", href: "https://x.com/s/status/1", root: article }),
    );
    const body = result.text.replace(/^---[\s\S]*?---\n*/, "");
    const iA = body.indexOf(a);
    const i1 = body.indexOf(img1);
    const iB = body.indexOf(b);
    const i2 = body.indexOf(img2);
    expect(iA).toBeGreaterThanOrEqual(0);
    expect(iA).toBeLessThan(i1);
    expect(i1).toBeLessThan(iB);
    expect(iB).toBeLessThan(i2);
  });

  it("keeps X long-form headings, code blocks, prose, and photos in read-view DOM order", () => {
    const title = "99% 的人没看出来的数字人口播实战攻略";
    const intro =
      "昨天发了一条数字人口播视频。这里是一段足够长的导语，用来证明长文章不能再退回到全文加全部图片的分组拼接。";
    const sectionHeading = "四、怎么放进 Codex 执行";
    const section = "我会把每个数字人项目都按同一个目录结构放：";
    const codeText =
      "project/\n├── inputs/\n│   ├── portrait.jpg\n│   └── script.md\n└── outputs/\n    └── final-1080p.mp4";
    const ending = "五、这个 Skill 固定了什么";
    const cover = "https://pbs.twimg.com/media/COVER?format=jpg&name=medium";
    const img1 = "https://pbs.twimg.com/media/INLINE1?format=jpg&name=large";
    const img2 = "https://pbs.twimg.com/media/INLINE2?format=jpg&name=large";
    const readView = el(
      "div",
      [
        el("div", [el("img", [], { src: cover })], { "data-testid": "tweetPhoto" }),
        el("div", [el("span", [text(title)])], { "data-testid": "twitter-article-title" }),
        el("div", [el("span", [text(intro)])]),
        el("div", [el("img", [], { src: img1 })], { "data-testid": "tweetPhoto" }),
        el("h2", [el("span", [text(sectionHeading)])]),
        el("div", [el("span", [text(section)])]),
        el(
          "div",
          [
            el("div", [text("markdown")]),
            el("section", [el("pre", [el("code", [text(codeText)], { class: "language-markdown" })])]),
          ],
          { "data-testid": "markdown-code-block" },
        ),
        el("div", [el("img", [], { src: img2 })], { "data-testid": "tweetPhoto" }),
        el("h2", [el("span", [text(ending)])]),
        // Read-view chrome after the body: must never enter the capture.
        // Real DOM renders it both merged and as two separate blocks.
        el("div", [el("span", [text("想发布自己的文章？")])]),
        el("div", [el("span", [text("升级为 Premium")])]),
      ],
      { "data-testid": "twitterArticleReadView" },
    );
    const article = el("article", [readView], { "data-testid": "tweet" });
    const documentLike = makeDocument({
      title: `X 上的 Rachel：“${title}” / X`,
      href: "https://x.com/Zesee/status/2077723280534851786",
      root: article,
    });

    expect(article.querySelector?.("[data-testid='twitterArticleReadView']")).toBe(readView);
    const testable = extractCurrentPage(documentLike);
    const body = testable.text.replace(/^---[\s\S]*?---\n*/, "");
    expect(body).toContain(`# ${title}`);
    expect(body).toContain(`## ${sectionHeading}`);
    expect(body).toContain(`\`\`\`markdown\n${codeText}\n\`\`\``);
    expect(body).not.toMatch(/\n\nmarkdown\n\n/);
    expect(body.indexOf(cover)).toBeLessThan(body.indexOf(title));
    expect(body.indexOf(title)).toBeLessThan(body.indexOf(img1));
    expect(body.indexOf(img1)).toBeLessThan(body.indexOf(sectionHeading));
    expect(body.indexOf(sectionHeading)).toBeLessThan(body.indexOf(codeText));
    expect(body.indexOf(codeText)).toBeLessThan(body.indexOf(img2));
    expect(body.indexOf(img2)).toBeLessThan(body.indexOf(ending));
    // Premium upsell chrome after the article body must be dropped.
    expect(body).not.toContain("升级为 Premium");
    expect(testable.title).toBe(title);
    expect(testable.title.length).toBeLessThanOrEqual(48);

    const previousDocument = globalThis.document;
    Object.defineProperty(globalThis, "document", {
      configurable: true,
      writable: true,
      value: documentLike,
    });
    try {
      const injected = extractPageInIsolatedWorld();
      expect(injected.text).toBe(testable.text);
      expect(injected.title).toBe(testable.title);
    } finally {
      if (previousDocument) {
        Object.defineProperty(globalThis, "document", {
          configurable: true,
          writable: true,
          value: previousDocument,
        });
      } else {
        delete (globalThis as { document?: Document }).document;
      }
    }
  });

  it("X status without User-Name still captures tweetText and omits author", () => {
    const post = "只有正文没有作者壳的帖子";
    const article = el(
      "article",
      [el("div", [text(post)], { "data-testid": "tweetText" })],
      { "data-testid": "tweet" },
    );
    const result = extractCurrentPage(
      makeDocument({
        title: "X",
        href: "https://x.com/someone/status/1",
        root: article,
      }),
    );
    expect(result.text).toContain(post);
    expect(result.text).not.toContain("author:");
    expect(result.text).not.toMatch(/^---/m);
  });

  it("detects X profile chrome image URLs", () => {
    expect(isXProfileChromeImageURL("https://pbs.twimg.com/profile_images/1/x_normal.jpg")).toBe(true);
    expect(isXProfileChromeImageURL("https://pbs.twimg.com/media/abc.jpg")).toBe(false);
  });

  it("falls back to cleaned page title when tweetText is missing", () => {
    const post = "99% 的人没看出来的数字人口播实战攻略";
    const media = "https://pbs.twimg.com/media/HNWMh9eXQAAFCKW?format=jpg&name=medium";
    const article = el(
      "article",
      [
        el(
          "div",
          [el("a", [text("Rachel")], { href: "/Zesee" }), el("a", [text("@Zesee")], { href: "/Zesee" })],
          { "data-testid": "User-Name" },
        ),
        el("div", [el("img", [], { src: media })], { "data-testid": "tweetPhoto" }),
      ],
      { "data-testid": "tweet" },
    );
    const result = extractCurrentPage(
      makeDocument({
        title: `X 上的 Rachel🥥：“${post}” / X`,
        href: "https://x.com/Zesee/status/2077723280534851786",
        root: article,
      }),
    );
    // Image still captured; short title comes from tab chrome.
    expect(result.text).toContain(media);
    expect(result.title).toBe(post);
  });

  it("dedupes X media variants of the same asset id", () => {
    const post = "一条带多尺寸配图的帖";
    const afterFirstPosition = "这段文字位于同一媒体的大图变体之前";
    const id = "HNWMh9eXQAAFCKW";
    const small = `https://pbs.twimg.com/media/${id}?format=jpg&name=small`;
    const large = `https://pbs.twimg.com/media/${id}?format=jpg&name=large`;
    const other = "https://pbs.twimg.com/media/OTHERID?format=jpg&name=medium";
    const article = el(
      "article",
      [
        el("div", [text(post)], { "data-testid": "tweetText" }),
        el("div", [el("img", [], { src: small })], { "data-testid": "tweetPhoto" }),
        el("div", [text(afterFirstPosition)], { "data-testid": "tweetText" }),
        el("div", [el("img", [], { src: large })], { "data-testid": "tweetPhoto" }),
        el("div", [el("img", [], { src: other })], { "data-testid": "tweetPhoto" }),
      ],
      { "data-testid": "tweet" },
    );
    const result = extractCurrentPage(
      makeDocument({ title: "X", href: "https://x.com/syc/status/99", root: article }),
    );
    const images = result.text.split("\n").filter((line) => line.trim().startsWith("!["));
    expect(images).toHaveLength(2);
    expect(result.text).toContain(large);
    expect(result.text).not.toContain("name=small");
    expect(result.text.indexOf(large)).toBeLessThan(result.text.indexOf(afterFirstPosition));
    expect(result.text.indexOf(afterFirstPosition)).toBeLessThan(result.text.indexOf(other));
    expect(xMediaDedupeKey(small)).toBe(xMediaDedupeKey(large));
  });

  it("formatXDisplayTitle stays short and prefers tab hooks", () => {
    const wall =
      "99% 的人没看出来的数字人口播实战攻略昨天发了一条数字人讲 FDE 的口播视频，很多人的第一反应不是问我用了哪个工具";
    expect(formatXDisplayTitle(wall, 'X 上的 R：“99% 的人没看出来的数字人口播实战攻略” / X')).toBe(
      "99% 的人没看出来的数字人口播实战攻略",
    );
    expect(formatXDisplayTitle(wall).length).toBeLessThanOrEqual(40);
    expect(formatXPostProse("甲。乙。丙。")).toContain("\n");
  });

  it("rejects unread-count tab chrome like “(1) X” and falls back to prose", () => {
    const article = "How Anthropic runs large-scale code migrations with Claude Code";
    expect(formatXDisplayTitle(article, "(1) X")).toBe("How Anthropic runs large-scale code…");
    expect(formatXDisplayTitle(article, "(3+) X")).not.toContain("(3+)");
    // Unread prefix is stripped but a real hook after it is kept.
    expect(formatXDisplayTitle(article, "(2) 一条真正的推文标题 / X")).toBe("一条真正的推文标题");
  });

  it("keeps full English hooks instead of cutting at the first space", () => {
    const tab = "How Anthropic runs large-scale code migrations with Claude Code / X";
    const title = formatXDisplayTitle("", tab);
    expect(title).not.toBe("How Anthropic");
    expect(title.length).toBeGreaterThan(20);
  });

  it("gitHubRepoSlug owns repo roots only and feeds title/author", () => {
    expect(gitHubRepoSlug("https://github.com/bojieli/ai-agent-book")).toBe("bojieli/ai-agent-book");
    expect(gitHubRepoSlug("https://github.com/bojieli/ai-agent-book/issues/1")).toBeNull();
    expect(gitHubRepoSlug("https://github.com/search?q=x")).toBeNull();
    expect(gitHubRepoSlug("https://gist.github.com/user/abc")).toBeNull();
  });

  it("enriches image-only X captures and keeps a short title", () => {
    const tabTitle = 'X 上的 Rachel🥥：“99% 的人没看出来的数字人口播实战攻略” / X';
    const media = "https://pbs.twimg.com/media/HNWMh9eXQAAFCKW?format=jpg&name=medium";
    const page = {
      title: tabTitle,
      url: "https://x.com/Zesee/status/2077723280534851786",
      text: `---\nauthor: "Rachel (@Zesee)"\n---\n\n![](${media})`,
      characterCount: 80,
      method: "rendered_dom" as const,
    };
    expect(captureBodyLacksProse(page.text)).toBe(true);
    const enriched = enrichXCaptureWithTitleFallback(page, tabTitle);
    expect(enriched.text).toContain("99% 的人没看出来的数字人口播实战攻略");
    expect(enriched.title).toBe("99% 的人没看出来的数字人口播实战攻略");
    expect(enriched.title.length).toBeLessThanOrEqual(48);
  });

  it("shortens an oversized title when body already has prose", () => {
    const wall =
      "99% 的人没看出来的数字人口播实战攻略昨天发了一条数字人讲 FDE 的口播视频，很多人的第一反应不是问我用了哪个工具";
    const page = {
      title: wall.slice(0, 97) + "…",
      url: "https://x.com/Zesee/status/1",
      text: `---\n---\n\n${wall}\n\n![](https://pbs.twimg.com/media/X.jpg)`,
      characterCount: 200,
      method: "rendered_dom" as const,
    };
    const enriched = enrichXCaptureWithTitleFallback(
      page,
      'X 上的 R：“99% 的人没看出来的数字人口播实战攻略” / X',
    );
    expect(enriched.title).toBe("99% 的人没看出来的数字人口播实战攻略");
    // Body should not get a second copy of the hook prepended.
    expect(enriched.text.split("99% 的人没看出来的数字人口播实战攻略").length - 1).toBe(1);
  });

  it("maps contract errors", () => {
    const base = {
      version: 1 as const,
      requestId: "x",
      createdAt: new Date().toISOString(),
      source: { kind: "browser_capture" as const, url: "https://example.test", title: null, platform: "generic" as const },
      capture: {
        method: "rendered_dom" as const,
        text: "x",
        characterCount: 1,
        completeness: "full_article" as const,
        capturedAt: new Date().toISOString(),
      },
      evidence: { sourceLabel: "test", usedCookie: false as const },
    };
    expect(validateCapture({ ...base, source: { ...base.source, url: "file:///tmp/x" } })).toBe("CAPTURE_URL_UNSUPPORTED");
    expect(validateCapture({ ...base, capture: { ...base.capture, characterCount: 2 } })).toBe("CAPTURE_COUNT_MISMATCH");
  });
});

describe("douyin media extraction", () => {
  it("extracts https video src and media block from a douyin-like document", () => {
    const video = el("video", [], {
      src: "https://cdn.example.test/clip.mp4",
      poster: "https://cdn.example.test/cover.jpg",
    });
    const root = el("div", [video, el("p", [text("口播描述")])]);
    const result = extractCurrentPage(
      makeDocument({
        title: "口播标题",
        href: "https://www.douyin.com/video/7123456789012345678",
        root,
      }),
    );
    expect(result.method).toBe("rendered_dom");
    expect(result.mediaDescriptor?.platform).toBe("douyin");
    expect(result.mediaDescriptor?.ephemeralPlaybackURL).toBe("https://cdn.example.test/clip.mp4");
    expect(result.text.length).toBeGreaterThan(0);
    expect(
      validateCapture({
        version: 2,
        requestId: "douyin-1",
        createdAt: new Date().toISOString(),
        source: {
          kind: "browser_capture",
          url: result.url,
          title: result.title,
          platform: "douyin",
        },
        capture: {
          method: result.method,
          text: result.text,
          characterCount: result.characterCount,
          completeness: "full_article",
          capturedAt: new Date().toISOString(),
        },
        evidence: { sourceLabel: "Current page DOM", usedCookie: false },
        media: result.mediaDescriptor,
      }),
    ).toBeNull();
  });
});
