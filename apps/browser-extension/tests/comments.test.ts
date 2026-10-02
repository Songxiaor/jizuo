import { describe, expect, it } from "vitest";
import {
  clampCommentLimit,
  collectCommentsFromDocument,
  commentHashID,
  commentPlatformForURL,
  commentsMarkdown,
  mergeInPageOrder,
  selectComments,
  stripEmbeddedCommentSection,
  type CapturedComment,
} from "../src/content/comments";

const sample: CapturedComment[] = [
  { id: "a", author: "小明", body: "第一条评论\n第二行", depth: 0, likes: "1.2万", published: "2026-09-20" },
  { id: "b", author: "作者**本人**", body: "回复一下", depth: 1, permalink: "https://x.com/u/status/2" },
  { id: "c", author: "u/redditor", body: "reddit body", depth: 0, score: "42" },
];

describe("comment limit", () => {
  it("clamps to the 10–100 range and defaults on garbage", () => {
    expect(clampCommentLimit(5)).toBe(10);
    expect(clampCommentLimit(250)).toBe(100);
    expect(clampCommentLimit(35)).toBe(35);
    expect(clampCommentLimit("50")).toBe(50);
    expect(clampCommentLimit(undefined)).toBe(20);
    expect(clampCommentLimit("abc")).toBe(20);
  });
});

describe("commentPlatformForURL", () => {
  it.each([
    ["https://www.reddit.com/r/x/comments/abc/title/", "reddit"],
    ["https://news.ycombinator.com/item?id=1", "community"],
    ["https://x.com/someone/status/123456", "x"],
    ["https://www.youtube.com/watch?v=abc", "youtube"],
    ["https://www.bilibili.com/video/BV1xx411c7mD", "bilibili"],
    ["https://www.zhihu.com/question/1/answer/2", "zhihu"],
    ["https://zhuanlan.zhihu.com/p/123", "zhihu"],
    ["https://www.douyin.com/video/7300000000000000000", "douyin"],
    ["https://www.douyin.com/jingxuan?modal_id=7300000000000000000", "douyin"],
    ["https://www.xiaohongshu.com/explore/64a1b2c3d4e5f6a7b8c9d0e1", "xiaohongshu"],
  ])("%s → %s", (url, platform) => {
    expect(commentPlatformForURL(url)).toBe(platform);
  });

  it.each([
    "https://x.com/someone",
    "https://mp.weixin.qq.com/s/abc",
    "https://www.youtube.com/",
    "https://www.reddit.com/r/x/",
    "not a url",
  ])("%s has no comment reader", (url) => {
    expect(commentPlatformForURL(url)).toBeUndefined();
  });
});

describe("commentsMarkdown", () => {
  it("writes the heading and headers the App comment parser recognizes", () => {
    const markdown = commentsMarkdown({ platform: "x", expectedCount: 88 }, sample);
    expect(markdown).toBe([
      "## 评论（已保存 3 条 / 页面显示 88）",
      "",
      "- **小明** · 赞 1.2万 · 2026-09-20 · 回复层级 0",
      "  第一条评论",
      "  第二行",
      "  - **作者本人** · [原评论](https://x.com/u/status/2) · 回复层级 1",
      "    回复一下",
      "- **u/redditor** · score 42 · 回复层级 0",
      "  reddit body",
    ].join("\n"));
  });

  it("omits the page total when everything was kept", () => {
    expect(commentsMarkdown({ platform: "x", expectedCount: 2 }, sample.slice(0, 2)).split("\n")[0])
      .toBe("## 评论（已保存 2 条）");
  });

  it("returns empty text when nothing is selected", () => {
    expect(commentsMarkdown({ platform: "x" }, [])).toBe("");
  });
});

describe("selection", () => {
  it("takes the first N when the popup made no choice", () => {
    expect(selectComments(sample, undefined, 2).map((comment) => comment.id)).toEqual(["a", "b"]);
  });

  it("keeps only ticked comments in page order", () => {
    expect(selectComments(sample, ["c", "a"], 2).map((comment) => comment.id)).toEqual(["a", "c"]);
  });

  it("an empty tick list keeps nothing", () => {
    expect(selectComments(sample, [], 20)).toEqual([]);
  });
});

describe("stripEmbeddedCommentSection", () => {
  it("removes the extractor's own trailing comment section", () => {
    const text = "# 标题\n\n正文\n\n## 评论（当前页面已加载 3）\n\n- **u/a** · score 1\n  hi";
    expect(stripEmbeddedCommentSection(text)).toBe("# 标题\n\n正文");
  });

  it("also handles community sections and leaves other pages alone", () => {
    expect(stripEmbeddedCommentSection("正文\n\n## 评论与回复（当前页面已加载 2）\n\n- **x**\n  y")).toBe("正文");
    expect(stripEmbeddedCommentSection("正文\n\n## 评论区的设计\n\n文字")).toBe("正文\n\n## 评论区的设计\n\n文字");
  });
});

describe("commentHashID", () => {
  it("is stable across calls and sensitive to author and body", () => {
    expect(commentHashID("a", "b")).toBe(commentHashID("a", "b"));
    expect(commentHashID("a", "b")).not.toBe(commentHashID("a", "c"));
    expect(commentHashID("a", "b")).not.toBe(commentHashID("b", "b"));
  });
});

describe("collectCommentsFromDocument", () => {
  it("returns null on pages without a comment reader", async () => {
    const documentLike = { location: { href: "https://mp.weixin.qq.com/s/abc" } } as unknown as Document;
    expect(await collectCommentsFromDocument(documentLike, 20)).toBeNull();
  });

  it("scrolls until the limit is reached, dedupes by id and restores the scroll position", async () => {
    // 最小假 DOM：每滚一次就多渲染 2 条小红书评论。
    let rendered = 2;
    const scrollCalls: number[] = [];
    const view = {
      scrollX: 0,
      scrollY: 120,
      scrollTo: (_x: number, y: number) => {
        scrollCalls.push(y);
        if (y !== 120) rendered += 2;
      },
      getComputedStyle: () => ({ overflowY: "visible" }),
    };
    const makeText = (value: string) => ({ textContent: value, innerText: value });
    const parent = (index: number) => {
      const main = {
        id: `comment-${index}`,
        querySelector: (selector: string) => {
          if (selector.includes(".name")) return makeText(`用户${index}`);
          if (selector.includes(".note-text")) return makeText(`评论内容 ${index}`);
          if (selector.includes(".count")) return makeText(String(index));
          return null;
        },
      };
      return {
        parentNode: null,
        querySelector: (selector: string) => (selector.startsWith(".comment-item:not") ? main : null),
        querySelectorAll: () => [],
      };
    };
    const documentLike = {
      location: { href: "https://www.xiaohongshu.com/explore/64a1b2c3d4e5f6a7b8c9d0e1" },
      defaultView: view,
      documentElement: {},
      body: {},
      scrollingElement: { scrollHeight: 5000 },
      querySelector: () => null,
      querySelectorAll: (selector: string) => (selector.includes(".parent-comment")
        ? Array.from({ length: rendered }, (_, index) => parent(index))
        : []),
    } as unknown as Document;

    const collection = await collectCommentsFromDocument(documentLike, 10, { sleep: async () => undefined, settleMillis: 0 });
    expect(collection?.platform).toBe("xiaohongshu");
    expect(collection?.comments.map((comment) => comment.id)).toEqual(
      Array.from({ length: 10 }, (_, index) => `xhs-${index}`),
    );
    expect(collection?.comments[3]).toMatchObject({ author: "用户3", body: "评论内容 3", likes: "3", depth: 0 });
    expect(scrollCalls.at(-1)).toBe(120);
  });

  it("stops after idle rounds when the page has fewer comments than the limit", async () => {
    let scrolls = 0;
    const documentLike = {
      location: { href: "https://www.xiaohongshu.com/explore/64a1b2c3d4e5f6a7b8c9d0e1" },
      defaultView: { scrollX: 0, scrollY: 0, scrollTo: () => { scrolls += 1; }, getComputedStyle: () => ({ overflowY: "visible" }) },
      documentElement: {},
      body: {},
      scrollingElement: { scrollHeight: 100 },
      querySelector: () => null,
      querySelectorAll: () => [],
    } as unknown as Document;
    const collection = await collectCommentsFromDocument(documentLike, 50, { sleep: async () => undefined, settleMillis: 0, idleRounds: 3 });
    expect(collection?.comments).toEqual([]);
    // 3 轮空转 + 最后一次还原位置。
    expect(scrolls).toBe(4);
  });
});

describe("page totals", () => {
  it("reads thousands separators and 万 units from comment headers", async () => {
    const header = (text: string) => ({
      location: { href: "https://www.xiaohongshu.com/explore/64a1b2c3d4e5f6a7b8c9d0e1" },
      defaultView: { scrollX: 0, scrollY: 0, scrollTo: () => undefined, getComputedStyle: () => ({ overflowY: "visible" }) },
      documentElement: {}, body: {}, scrollingElement: { scrollHeight: 0 },
      querySelector: (selector: string) => (selector.includes(".total") ? { textContent: text } : null),
      querySelectorAll: () => [],
    }) as unknown as Document;
    const options = { sleep: async () => undefined, settleMillis: 0, idleRounds: 0 };
    expect((await collectCommentsFromDocument(header("共 2,345,678 条评论"), 10, options))?.expectedCount).toBe(2_345_678);
    expect((await collectCommentsFromDocument(header("共 1.2万 条评论"), 10, options))?.expectedCount).toBe(12_000);
  });
});

describe("douyin feed modal", () => {
  it("opens the collapsed comment panel and reads the total after the search hint", async () => {
    let opened = false;
    const documentLike = {
      location: { href: "https://www.douyin.com/jingxuan?modal_id=7300000000000000000" },
      defaultView: { scrollX: 0, scrollY: 0, scrollTo: () => undefined, getComputedStyle: () => ({ overflowY: "visible" }) },
      documentElement: {}, body: {}, scrollingElement: { scrollHeight: 0 },
      querySelector: (selector: string) => {
        if (selector.includes("feed-comment-icon")) return { click: () => { opened = true; } };
        if (selector === "[data-e2e='comment-list']" && opened) {
          return { previousElementSibling: { textContent: "大家都在搜：Mac mini 6全部评论(293)" } };
        }
        return null;
      },
      querySelectorAll: () => [],
    } as unknown as Document;
    const collection = await collectCommentsFromDocument(documentLike, 10, { sleep: async () => undefined, settleMillis: 0, idleRounds: 0 });
    expect(opened).toBe(true);
    expect(collection?.expectedCount).toBe(293);
  });
});

describe("mergeInPageOrder", () => {
  const c = (id: string, depth = 0): CapturedComment => ({ id, author: id, body: id, depth });
  const merge = (readings: CapturedComment[][]) => {
    const order: string[] = [];
    const merged = new Map<string, CapturedComment>();
    for (const reading of readings) mergeInPageOrder(order, merged, reading);
    return order;
  };

  it("puts replies expanded later back under their parent", () => {
    expect(merge([
      [c("a"), c("b"), c("c")],
      [c("a"), c("a1", 1), c("a2", 1), c("b"), c("c"), c("d")],
    ])).toEqual(["a", "a1", "a2", "b", "c", "d"]);
  });

  it("keeps page order when a virtual list drops the top and shows new ones above known items", () => {
    expect(merge([
      [c("c"), c("d")],
      [c("a"), c("b"), c("c")],
      [c("d"), c("e")],
    ])).toEqual(["a", "b", "c", "d", "e"]);
  });
});

describe("virtualized lists", () => {
  it("scrolls X back to the top before reading and restores the position afterwards", async () => {
    const scrolls: number[] = [];
    const view = {
      scrollX: 0,
      scrollY: 900,
      scrollTo: (_x: number, y: number) => { scrolls.push(y); },
      getComputedStyle: () => ({ overflowY: "visible" }),
    };
    const documentLike = {
      location: { href: "https://x.com/someone/status/123" },
      defaultView: view,
      documentElement: {}, body: {}, scrollingElement: { scrollHeight: 0 },
      querySelector: () => null,
      querySelectorAll: () => [],
    } as unknown as Document;
    await collectCommentsFromDocument(documentLike, 10, { sleep: async () => undefined, settleMillis: 0, idleRounds: 0 });
    expect(scrolls[0]).toBe(0);
    expect(scrolls.at(-1)).toBe(900);
  });
});

describe("forum comment authors", () => {
  it("skips Discourse's avatar link (it has no text) and reads the name next to it", async () => {
    const cooked = {
      nodeType: 1, tagName: "DIV", textContent: "接受邀请！", childNodes: [{ nodeType: 3, textContent: "接受邀请！" }],
      cloneNode: () => cooked, querySelectorAll: () => [], querySelector: () => null, getAttribute: () => null,
    };
    const avatar = { textContent: "\n  \n" };
    const name = { textContent: "\n  zhey（开学了）\n" };
    const post = {
      id: "post_2",
      querySelector: (selector: string) => (selector === ".cooked" ? cooked : selector === "[data-user-card]" ? avatar : null),
      querySelectorAll: (selector: string) => (selector === "[data-user-card]" ? [avatar, name] : []),
    };
    const documentLike = {
      location: { href: "https://linux.do/t/topic/847468" },
      defaultView: { scrollX: 0, scrollY: 0, scrollTo: () => undefined, getComputedStyle: () => ({ overflowY: "visible" }) },
      documentElement: {}, body: {}, scrollingElement: { scrollHeight: 0 },
      querySelector: () => null,
      querySelectorAll: (selector: string) => (selector === "article[id^='post_']" ? [post] : []),
    } as unknown as Document;
    const collection = await collectCommentsFromDocument(documentLike, 10, { sleep: async () => undefined, settleMillis: 0, idleRounds: 0 });
    expect(collection?.comments[0]).toMatchObject({ author: "zhey（开学了）", body: "接受邀请！" });
  });
});
