import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  bookmarksSyncMessage,
  isValidTweetID,
  isXBookmarksURL,
  parseBookmarksAccepted,
  tweetIDFromArticle,
  tweetIDFromHref,
} from "../src/content/x-bookmarks";

describe("X bookmarks page detection", () => {
  it("accepts the bookmarks routes and rejects everything else", () => {
    for (const ok of [
      "https://x.com/i/bookmarks",
      "https://x.com/i/bookmarks/all",
      "https://x.com/i/bookmarks/1889000",
      "https://www.twitter.com/i/bookmarks",
    ]) {
      expect(isXBookmarksURL(ok)).toBe(true);
    }
    for (const no of [
      "https://x.com/home",
      "https://x.com/op7418/status/2080486709729587300",
      "https://x.com/i/bookmarksomething",
      "http://x.com/i/bookmarks",
      "https://evil.test/i/bookmarks",
      undefined,
    ]) {
      expect(isXBookmarksURL(no)).toBe(false);
    }
  });
});

describe("bookmarks native response parsing", () => {
  it("accepts a well-formed bookmarksAccepted and rejects anything off", () => {
    expect(parseBookmarksAccepted({ kind: "bookmarksAccepted", version: 1, requestId: "r", queuedCount: 5, skippedCount: 2 }))
      .toEqual({ queued: 5, skipped: 2 });
    // 别的 kind、错版本、负数、非整数、缺字段都返回 null。
    expect(parseBookmarksAccepted({ kind: "taskAccepted", version: 1, requestId: "r", characterCount: 3 })).toBeNull();
    expect(parseBookmarksAccepted({ kind: "bookmarksAccepted", version: 2, queuedCount: 1, skippedCount: 0 })).toBeNull();
    expect(parseBookmarksAccepted({ kind: "bookmarksAccepted", version: 1, queuedCount: -1, skippedCount: 0 })).toBeNull();
    expect(parseBookmarksAccepted({ kind: "bookmarksAccepted", version: 1, queuedCount: 1.5, skippedCount: 0 })).toBeNull();
    expect(parseBookmarksAccepted(null)).toBeNull();
  });
});

describe("sync result copy", () => {
  it("summarizes queued and skipped, noting when it caught up", () => {
    expect(bookmarksSyncMessage({ queued: 12, skipped: 3 }, 15, true))
      .toBe("新增 12 条正在抓取，3 条已在库（已同步到上次的位置）");
    expect(bookmarksSyncMessage({ queued: 4, skipped: 0 }, 4, false))
      .toBe("新增 4 条正在抓取");
    expect(bookmarksSyncMessage({ queued: 0, skipped: 8 }, 8, true))
      .toBe("8 条已在库（已同步到上次的位置）");
    expect(bookmarksSyncMessage({ queued: 0, skipped: 0 }, 0, false))
      .toContain("没有找到");
  });
});

describe("tweet id validation", () => {
  it("only accepts 8–25 digit strings", () => {
    expect(isValidTweetID("2080486709729587300")).toBe(true);
    expect(isValidTweetID("1234567")).toBe(false); // 太短
    expect(isValidTweetID("12345678")).toBe(true);
    expect(isValidTweetID("12a4567890")).toBe(false);
    expect(isValidTweetID(12345678)).toBe(false);
  });
});

describe("reading a tweet id from a timeline article", () => {
  const anchor = (href: string, withTime: boolean) => {
    const a: { getAttribute: (n: string) => string | null; querySelector: (s: string) => object | null } = {
      getAttribute: (n) => (n === "href" ? href : null),
      querySelector: (s) => (withTime && s === "time" ? {} : null),
    };
    return a;
  };
  const article = (anchors: ReturnType<typeof anchor>[]) =>
    ({ querySelectorAll: (s: string) => (s.includes("status") ? anchors : []) }) as unknown as Element;

  it("takes the timestamp link and ignores quote/card links to other tweets", () => {
    const el = article([
      // 引用推文的链接排在前面，但它没有 <time>，必须跳过。
      anchor("/someone/status/1111111111111", false),
      anchor("/op7418/status/2080486709729587300", true),
    ]);
    expect(tweetIDFromArticle(el)).toBe("2080486709729587300");
  });

  it("returns null when no timestamp link is present", () => {
    expect(tweetIDFromArticle(article([anchor("/i/status/123", false)]))).toBeNull();
    expect(tweetIDFromArticle(article([]))).toBeNull();
  });

  it("parses ids from assorted href shapes", () => {
    expect(tweetIDFromHref("/op7418/status/2080486709729587300")).toBe("2080486709729587300");
    expect(tweetIDFromHref("https://x.com/a/status/1234567890123?s=20")).toBe("1234567890123");
    // /status/ 后接图片/回复子路径时仍取那条推文 id。
    expect(tweetIDFromHref("/op7418/status/1234567890123/photo/1")).toBe("1234567890123");
    expect(tweetIDFromHref("/op7418/status/12")).toBeNull(); // 太短
    expect(tweetIDFromHref("/op7418")).toBeNull();
    expect(tweetIDFromHref(null)).toBeNull();
  });
});

describe("injected collector stays self-contained", () => {
  it("keeps id harvesting inside the injected function, not only as module helpers", () => {
    // browser.scripting.executeScript 只序列化被注入函数的函数体——模块级 helper
    // 不会进到页面里。这一点在 X 图片过滤上真的踩过一次，这里钉死。
    const source = readFileSync(new URL("../src/content/x-bookmarks.ts", import.meta.url), "utf8");
    const injected = source.slice(source.indexOf("export async function collectXBookmarkIDsInPage"));
    expect(injected).not.toHaveLength(0);
    expect(injected).toContain("article[data-testid='tweet']");
    expect(injected).toContain("/status/");
    // 不能引用模块级的 isValidTweetID：注入体内自带正则。
    expect(injected).not.toContain("isValidTweetID(");
  });
});
