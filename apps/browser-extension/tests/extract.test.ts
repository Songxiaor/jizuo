import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  attachDetectedMedia,
  captureBodyLacksProse,
  enrichXCaptureWithTitleFallback,
  extractBilibiliPage,
  extractCurrentPage,
  extractPageInIsolatedWorld,
  extractXiaohongshuPage,
  formatXDisplayTitle,
  gitHubRepoSlug,
  formatXPostProse,
  isXProfileChromeImageURL,
  isXVideoThumbnailURL,
  isMediumProfileChromeImageURL,
  resolveResponsiveImageURL,
  resolveZhihuAnswerMetadata,
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
      let current: FakeNode | null = node;
      const groups = selector.split(",").map((value) => value.trim()).filter(Boolean);
      while (current) {
        if (groups.some((group) => matchesSimple(current!, group))) return current;
        current = current.parentNode ?? null;
      }
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
  // Support descendant combinators (`.a .b`): match the final simple selector on
  // the node, then satisfy the preceding parts against any ancestor chain, the
  // way a real querySelector does. Single-segment selectors stay a plain match.
  const matchesGroup = (node: FakeNode, group: string): boolean => {
    const path = group.split(/\s+/).filter(Boolean);
    if (path.length === 0 || !matchesSimple(node, path[path.length - 1]!)) return false;
    let index = path.length - 2;
    let ancestor = node.parentNode ?? null;
    while (index >= 0 && ancestor) {
      if (matchesSimple(ancestor, path[index]!)) index -= 1;
      ancestor = ancestor.parentNode ?? null;
    }
    return index < 0;
  };
  const matchesAny = (node: FakeNode): boolean =>
    groups.some((group) => matchesGroup(node, group));
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
  const classNames = new Set((attrs.class ?? "").split(/\s+/u).filter(Boolean));

  const idMatch = selector.match(/^([a-z0-9]+)?#([a-z0-9_-]+)$/iu);
  if (idMatch) {
    if (idMatch[1] && idMatch[1].toLowerCase() !== tag) return false;
    return (attrs.id ?? "") === idMatch[2];
  }

  const classMatch = selector.match(/^([a-z0-9]+)?((?:\.[a-z0-9_-]+)+)$/iu);
  if (classMatch) {
    if (classMatch[1] && classMatch[1].toLowerCase() !== tag) return false;
    return classMatch[2]!.split(".").filter(Boolean).every((name) => classNames.has(name));
  }

  // tag[attr='value'], [attr*='value'], tag, or a[href]
  const re = /^([a-z0-9]+)?(?:\[([a-z0-9_-]+)(?:([*^$]?=)['"]([^'"]*)['"])?\])?$/i;
  const m = selector.match(re);
  if (!m) {
    // fallback: plain tag
    return selector.toLowerCase() === tag;
  }
  const [, tagPart, attrName, operator, attrValue] = m;
  if (tagPart && tagPart.toLowerCase() !== tag) return false;
  if (attrName) {
    const actual = attrs[attrName];
    if (actual == null) return false;
    if (operator === "=" && actual !== attrValue) return false;
    if (operator === "*=" && !actual.includes(attrValue ?? "")) return false;
    if (operator === "^=" && !actual.startsWith(attrValue ?? "")) return false;
    if (operator === "$=" && !actual.endsWith(attrValue ?? "")) return false;
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

  it("captures item-scoped Zhihu answer metadata without leaking question totals", () => {
    const answerID = "2035509772494033394";
    const answer = el("div", [
      el("span", [text("Echo")], { class: "AuthorInfo-name" }),
      el("span", [text("发布于 2026-07-24 10:30")], { class: "ContentItem-time" }),
      el("div", [
        el("p", [text("AI Agent 落地效果差，不是方向错了，而是把模型当成了操作系统。")]),
      ], { class: "Post-RichText" }),
      el("button", [text("赞同 361")], { class: "VoteButton--up" }),
      el("button", [text("36 条评论")], { class: "ContentItem-action", "aria-label": "36 条评论" }),
      el("button", [text("收藏 616")], { class: "ContentItem-action", "aria-label": "收藏 616" }),
    ], { class: "AnswerItem", "data-answer-id": answerID });
    const root = el("main", [
      el("div", [text("关注者 4,466 被浏览 2,827,534")]),
      answer,
    ]);
    const documentLike = makeDocument({
      title: "如何评价当前的 AI Agent 落地效果普遍不佳的问题？",
      href: `https://www.zhihu.com/question/13476251758/answer/${answerID}`,
      root,
    });

    expect(resolveZhihuAnswerMetadata(documentLike)).toEqual({
      author: "Echo",
      published: "2026-07-24 10:30",
      likes: "361",
      comments: "36",
      collects: "616",
    });
    const testable = extractCurrentPage(documentLike);
    expect(testable.text).toContain('author: "Echo"');
    expect(testable.text).toContain('likes: "361"');
    expect(testable.text).toContain('comments: "36"');
    expect(testable.text).toContain('collects: "616"');
    expect(testable.text).not.toContain("2,827,534");

    const previousDocument = globalThis.document;
    Object.defineProperty(globalThis, "document", {
      configurable: true,
      writable: true,
      value: documentLike,
    });
    try {
      expect(extractPageInIsolatedWorld().text).toBe(testable.text);
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

  it("uses Medium responsive content images and drops the tiny author avatar", () => {
    const avatar = "https://miro.medium.com/v2/resize:fill:64:64/1*avatar.jpeg";
    const small = "https://miro.medium.com/v2/resize:fit:212/1*article.png";
    const large = "https://miro.medium.com/v2/resize:fit:1200/1*article.png";
    const image = el("img", [], {
      alt: "文章插图",
      src: small,
      srcset: `${small} 212w, ${large} 1200w`,
    });
    expect(resolveResponsiveImageURL(image as unknown as Element, "https://humanparts.medium.com/story")).toBe(large);
    expect(isMediumProfileChromeImageURL(avatar)).toBe(true);
    expect(isMediumProfileChromeImageURL(large)).toBe(false);

    const article = el("article", [
      el("img", [], { alt: "Lydia Sohn", src: avatar }),
      el("p", [text("I asked several people in their nineties what they regretted most.")]),
      image,
    ]);
    const documentLike = makeDocument({
      title: "What Do 90-Somethings Regret Most?",
      href: "https://humanparts.medium.com/what-its-like-to-be-90-something-368780082573",
      root: article,
    });
    const testable = extractCurrentPage(documentLike);
    expect(testable.text).toContain(`![文章插图](${large})`);
    expect(testable.text).not.toContain(avatar);

    const previousDocument = globalThis.document;
    Object.defineProperty(globalThis, "document", {
      configurable: true,
      writable: true,
      value: documentLike,
    });
    try {
      expect(extractPageInIsolatedWorld().text).toBe(testable.text);
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
    expect(result.text).toContain('comments: "4"');
    expect(result.text).not.toContain("replies:");
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

  it("keeps the video-thumbnail filter inside the injected function, not only as a module helper", () => {
    // `browser.scripting.executeScript` 只序列化被注入函数的函数体：写在模块
    // 级的同名 helper 根本不会进到页面里。这条曾经真的发生过——模块级版本改
    // 好了、构建产物里却连字符串都没有，封面图照旧进正文。
    const source = readFileSync(new URL("../src/content/extract.ts", import.meta.url), "utf8");
    const injected = source.slice(source.indexOf("export function extractPageInIsolatedWorld"));
    expect(injected).not.toHaveLength(0);
    expect(injected).toContain("amplify_video_thumb");
    expect(injected).toContain("isVideoThumbnail(href)");
  });

  it("detects X video thumbnails so a cover frame never doubles the video in the body", () => {
    for (const cover of [
      "https://pbs.twimg.com/amplify_video_thumb/2080486192186109952/img/cover.jpg",
      "https://pbs.twimg.com/ext_tw_video_thumb/123/pu/img/frame.jpg",
      "https://pbs.twimg.com/tweet_video_thumb/abc.jpg",
    ]) {
      expect(isXVideoThumbnailURL(cover)).toBe(true);
    }
    // 帖子里真正的配图仍旧要进正文。
    expect(isXVideoThumbnailURL("https://pbs.twimg.com/media/HN6_kUyaAAAlH_y?format=jpg")).toBe(false);
    expect(isXVideoThumbnailURL("not a url")).toBe(false);
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

  it("captures a Bilibili video's author, publish time and toolbar engagement as frontmatter", () => {
    const root = el("div", [
      el("h1", [text("测试视频标题")]),
      el("div", [text("测试UP主")], { class: "up-name" }),
      el("div", [text("这是视频简介")], { class: "basic-desc-info" }),
      el("div", [text("2024-03-01 12:00:00")], { class: "pubdate-text" }),
      el("div", [text("10.5万")], { class: "view-text" }),
      el("div", [text("8000")], { class: "video-like-info" }),
      el("div", [text("1200")], { class: "video-fav-info" }),
      el("div", [text("300")], { class: "video-share-info" }),
    ]);
    const doc = makeDocument({
      title: "测试视频标题_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1xx411c7mD",
      root,
    });

    const result = extractBilibiliPage(doc);

    expect(result.url).toBe("https://www.bilibili.com/video/BV1xx411c7mD");
    expect(result.title).toBe("测试视频标题");
    expect(result.text).toContain('author: "测试UP主"');
    expect(result.text).toContain('published: "2024-03-01 12:00:00"');
    expect(result.text).toContain('likes: "8000"');
    expect(result.text).toContain('collects: "1200"');
    expect(result.text).toContain('shares: "300"');
    expect(result.text).toContain('views: "10.5万"');
    // 评论/弹幕 have no faithful in-page toolbar source; never fabricate them.
    expect(result.text).not.toContain("comments:");
    // Title is the detail header's job; it must not be duplicated as a body H1.
    expect(result.text).not.toContain("# 测试视频标题");
    expect(result.title).toBe("测试视频标题");
    expect(result.text).toContain("这是视频简介");
  });

  it("keeps a Bilibili capture's body to the on-page description, never the SEO meta tail", () => {
    // 实测 og:description 的形状：真简介之后拼上统计、作者简介和一串推荐视频标题。
    const seoDescription =
      "爽！！！, 视频播放量 71312、弹幕量 184、点赞数 8962、投硬币枚数 2499、收藏人数 1264、转发人数 241,"
      + " 视频作者 柳知萧, 作者简介 月声配音社CV，努力配音！，相关视频：【小缘】鸣潮演唱会vlog，【KuroFest】鸣潮歌手的一日Vlog";
    const doc = makeDocument({
      title: "美美站上鸣潮演唱会舞台！_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1p8gy6oEGo",
      root: el("div", [
        el("h1", [text("美美站上鸣潮演唱会舞台！")]),
        el("div", [text("柳知萧")], { class: "up-name" }),
        el("div", [text("爽！！！")], { class: "basic-desc-info" }),
        el("meta", [], { property: "og:description", content: seoDescription }),
      ]),
    });

    const result = extractBilibiliPage(doc);

    expect(result.text).toContain("爽！！！");
    // 统计、作者简介、推荐位标题都不属于这条视频的正文。
    expect(result.text).not.toContain("视频播放量");
    expect(result.text).not.toContain("作者简介");
    expect(result.text).not.toContain("相关视频");
    expect(result.text).not.toContain("鸣潮歌手的一日Vlog");
  });

  it("falls back to the truncated meta description when the page has no description block", () => {
    const doc = makeDocument({
      title: "无简介视频_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1p8gy6oEGo",
      root: el("div", [
        el("h1", [text("无简介视频")]),
        el("meta", [], {
          property: "og:description",
          content: "只有一句简介, 视频播放量 100、弹幕量 2, 视频作者 某人, 作者简介 略，相关视频：别的视频",
        }),
      ]),
    });

    const result = extractBilibiliPage(doc);

    expect(result.text).toContain("只有一句简介");
    expect(result.text).not.toContain("视频播放量");
    expect(result.text).not.toContain("别的视频");
  });

  it("drops Bilibili's generic promo when an empty-description video falls back to OG metadata", () => {
    const genericPromo =
      "更多实用攻略教学，爆笑沙雕集锦，你所不知道的游戏知识，热门游戏视频7*24小时持续更新，"
      + "尽在哔哩哔哩bilibili, 视频播放量 100、弹幕量 2, 视频作者 某人";
    const doc = makeDocument({
      title: "没有填写简介的视频_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1SyKp6AEKk",
      root: el("div", [
        el("h1", [text("没有填写简介的视频")]),
        el("meta", [], { property: "og:description", content: genericPromo }),
      ]),
    });

    const testable = extractBilibiliPage(doc);
    expect(testable.text).toBe("哔哩哔哩公开视频");
    expect(testable.text).not.toContain("更多实用攻略教学");
    expect(testable.text).not.toContain("尽在哔哩哔哩");

    const previousDocument = globalThis.document;
    Object.defineProperty(globalThis, "document", {
      configurable: true,
      writable: true,
      value: doc,
    });
    try {
      expect(extractPageInIsolatedWorld()).toEqual(testable);
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

  it("drops a title-only Bilibili OG description but keeps real text that adds information", () => {
    const duplicate = makeDocument({
      title: "完美！三星 Fold 8 一小时使用感受！_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1xx411c7mD",
      root: el("div", [
        el("h1", [text("完美！三星 Fold 8 一小时使用感受！")]),
        el("meta", [], {
          property: "og:description",
          content: "完美！三星 Fold 8 一小时使用感受！, 视频播放量 100、弹幕量 2",
        }),
      ]),
    });
    const genuine = makeDocument({
      title: "完美！三星 Fold 8 一小时使用感受！_哔哩哔哩_bilibili",
      href: "https://www.bilibili.com/video/BV1xx411c7mD",
      root: el("div", [
        el("h1", [text("完美！三星 Fold 8 一小时使用感受！")]),
        el("meta", [], {
          property: "og:description",
          content: "完美！三星 Fold 8 一小时使用感受！补充了折叠屏比例和续航实测, 视频播放量 100",
        }),
      ]),
    });

    expect(extractBilibiliPage(duplicate).text).toBe("哔哩哔哩公开视频");
    expect(extractBilibiliPage(genuine).text).toContain("补充了折叠屏比例和续航实测");
  });

  it("captures a Xiaohongshu note's author, date and engage-bar counts, ignoring feed-card and per-comment likes", () => {
    // 实测结构：信息流卡片与每条评论用的都是同一套 `.like-wrapper .count`，
    // 笔记打开成弹层时它们还排在 `#noteContainer` 前面。笔记自己的数字只在
    // `#noteContainer .engage-bar` 里。
    const feedCard = el("div", [
      el("div", [el("span", [text("36000")], { class: "count" })], { class: "like-wrapper" }),
    ], { class: "note-item" });
    const noteContainer = el("div", [
      el("div", [text("笔记标题")], { id: "detail-title" }),
      el("div", [text("笔记正文内容")], { id: "detail-desc" }),
      el("div", [el("span", [text("测试作者")], { class: "username" })], { class: "author-wrapper" }),
      el("div", [el("span", [text("2024-05-20")], { class: "date" })], { class: "bottom-container" }),
      // 评论自带的点赞数，排在 engage-bar 之前。
      el("div", [
        el("div", [el("span", [text("42")], { class: "count" })], { class: "like-wrapper" }),
      ], { class: "comment-item" }),
      el("div", [
        el("div", [el("span", [text("9670")], { class: "count" })], { class: "like-wrapper" }),
        el("div", [el("span", [text("2709")], { class: "count" })], { class: "collect-wrapper" }),
        el("div", [el("span", [text("3102")], { class: "count" })], { class: "chat-wrapper" }),
      ], { class: "engage-bar" }),
    ], { id: "noteContainer" });
    const doc = makeDocument({
      title: "笔记标题 - 小红书",
      href: "https://www.xiaohongshu.com/explore/64703496000000001203e971",
      root: el("div", [feedCard, noteContainer]),
    });

    const result = extractXiaohongshuPage(doc);

    expect(result.title).toBe("笔记标题");
    expect(result.text).toContain('author: "测试作者"');
    expect(result.text).toContain('published: "2024-05-20"');
    expect(result.text).toContain('likes: "9670"');
    expect(result.text).toContain('collects: "2709"');
    expect(result.text).toContain('comments: "3102"');
    // 弹层背后的信息流卡片和评论的点赞数都不得冒充笔记的点赞数。
    expect(result.text).not.toContain('likes: "36000"');
    expect(result.text).not.toContain('likes: "42"');
    expect(result.text).toContain("笔记正文内容");
  });

  it("inlines a Xiaohongshu note's gallery in slide order, dropping swiper clones and non-note images", () => {
    const cdn = "https://sns-webpic-qc.xhscdn.com/202607251040";
    const slide = (src: string, index: string, extraClass = "") =>
      el("div", [el("img", [], { src })], {
        class: `swiper-slide${extraClass ? ` ${extraClass}` : ""}`,
        "data-swiper-slide-index": index,
      });
    const noteContainer = el("div", [
      el("div", [text("笔记标题")], { id: "detail-title" }),
      el("div", [text("笔记正文内容")], { id: "detail-desc" }),
      // 实测的 loop 版式：首尾各插一个克隆，第一个是最后一张图的克隆；真实的
      // 末张 slide 带 `swiper-slide-duplicate-prev`，子串匹配会把它误杀。
      el("div", [
        slide(`${cdn}/c/notes_pre_post/third!nd_dft_wlteh_webp_3`, "2", "swiper-slide-duplicate swiper-slide-prev"),
        slide(`${cdn}/a/notes_pre_post/first!nd_dft_wlteh_webp_3`, "0", "swiper-slide-active"),
        slide(`${cdn}/b/notes_pre_post/second!nd_dft_wlteh_webp_3`, "1"),
        slide(`${cdn}/c/notes_pre_post/third!nd_dft_wlteh_webp_3`, "2", "swiper-slide-duplicate-prev"),
        slide(`${cdn}/a/notes_pre_post/first!nd_dft_wlteh_webp_3`, "0", "swiper-slide-duplicate"),
      ], { class: "swiper note-slider" }),
      // 头像与评论配图同域，但既不在轮播里也不该出现在正文。
      el("img", [], { src: "https://sns-avatar-qc.xhscdn.com/avatar/abc?imageView2/2/w/120" }),
      el("div", [
        el("img", [], { src: `${cdn}/d/comment/pic!nc_n_webp_mw_1` }),
      ], { class: "comment-item" }),
    ], { id: "noteContainer" });
    const doc = makeDocument({
      title: "笔记标题 - 小红书",
      href: "https://www.xiaohongshu.com/explore/64703496000000001203e971",
      root: noteContainer,
    });

    const result = extractXiaohongshuPage(doc);

    expect(result.imageCount).toBe(3);
    const gallery = result.text.slice(result.text.indexOf("笔记正文内容"));
    expect(gallery.match(/!\[\]\(([^)]+)\)/gu)).toEqual([
      `![](${cdn}/a/notes_pre_post/first!nd_dft_wlteh_webp_3)`,
      `![](${cdn}/b/notes_pre_post/second!nd_dft_wlteh_webp_3)`,
      `![](${cdn}/c/notes_pre_post/third!nd_dft_wlteh_webp_3)`,
    ]);
    expect(result.text).not.toContain("sns-avatar-qc");
    expect(result.text).not.toContain("/comment/");
  });

  it("falls back to slide DOM order for a Xiaohongshu slider without swiper index attributes", () => {
    const cdn = "https://sns-webpic-qc.xhscdn.com/202607251040";
    const noteContainer = el("div", [
      el("div", [text("笔记标题")], { id: "detail-title" }),
      el("div", [text("笔记正文内容")], { id: "detail-desc" }),
      el("div", [
        el("div", [el("img", [], { src: `${cdn}/a/notes_pre_post/first` })], { class: "swiper-slide" }),
        el("div", [el("img", [], { src: `${cdn}/b/notes_pre_post/second` })], { class: "swiper-slide" }),
        el("div", [el("img", [], { src: `${cdn}/a/notes_pre_post/first` })], { class: "swiper-slide swiper-slide-duplicate" }),
      ], { class: "swiper note-slider" }),
    ], { id: "noteContainer" });
    const doc = makeDocument({
      title: "笔记标题 - 小红书",
      href: "https://www.xiaohongshu.com/explore/64703496000000001203e971",
      root: noteContainer,
    });

    const result = extractXiaohongshuPage(doc);

    expect(result.imageCount).toBe(2);
    expect(result.text.match(/!\[\]\(([^)]+)\)/gu)).toEqual([
      `![](${cdn}/a/notes_pre_post/first)`,
      `![](${cdn}/b/notes_pre_post/second)`,
    ]);
  });

  it("skips the Xiaohongshu gallery for a video note, whose slider only holds the cover", () => {
    const noteContainer = el("div", [
      el("div", [text("视频笔记")], { id: "detail-title" }),
      el("div", [text("视频笔记正文")], { id: "detail-desc" }),
      el("video", [], { src: "blob:https://www.xiaohongshu.com/abc" }),
      el("div", [
        el("div", [el("img", [], { src: "https://sns-webpic-qc.xhscdn.com/x/notes_pre_post/cover" })], { class: "swiper-slide" }),
      ], { class: "swiper note-slider" }),
    ], { id: "noteContainer" });
    const doc = makeDocument({
      title: "视频笔记 - 小红书",
      href: "https://www.xiaohongshu.com/explore/64703496000000001203e971",
      root: noteContainer,
    });

    const result = extractXiaohongshuPage(doc);

    expect(result.imageCount).toBeUndefined();
    expect(result.text).not.toContain("![](");
  });
});

describe("host-scoped content root", () => {
  // 头条的 `.article-content` 把标题行和「时间·来源」行包在正文容器里，而通用候选
  // 顺序又让它排在 `article` 前面。2026-07-26 真机实测两篇：1321→1278、205→165
  // 字符，差值正是那两行。这类"多抓了东西"不会报错也不会崩，只会让每篇头条的正文
  // 开头重复一遍标题，所以只能靠断言正文首段钉住。
  const toutiaoRoot = () =>
    el("div", [
      el("h1", [text("“义乌发展经验”，习近平这样总结")]),
      el("div", [text("2026-07-26 14:02·央视新闻")]),
      el("article", [
        el("p", [text("浙江义乌，一座生长在市场上的城市，连接中国制造的神经末梢，感知全球贸易的脉动。")]),
        el("p", [text("总书记十分关心义乌的发展，在浙江工作期间，多次到义乌调研。")]),
      ]),
    ], { class: "article-content" });

  it("prefers article over .article-content on toutiao so the title line stays out of the body", () => {
    const result = extractCurrentPage(
      makeDocument({
        title: "“义乌发展经验”，习近平这样总结 - 今日头条",
        href: "https://www.toutiao.com/article/7666713007799452212/",
        root: toutiaoRoot(),
      }),
    );
    expect(result.text).toContain("浙江义乌，一座生长在市场上的城市");
    expect(result.text).not.toContain("2026-07-26 14:02·央视新闻");
  });

  it("leaves .article-content alone on every other host", () => {
    // 收窄按站点生效，不动通用候选顺序——那个顺序同时服务所有没在真机验过的站点。
    const result = extractCurrentPage(
      makeDocument({
        title: "Some other site",
        href: "https://example.test/post",
        root: toutiaoRoot(),
      }),
    );
    expect(result.text).toContain("2026-07-26 14:02·央视新闻");
  });
});
