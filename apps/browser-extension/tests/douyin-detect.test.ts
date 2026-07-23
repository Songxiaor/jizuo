import { describe, expect, it } from "vitest";
import {
  collectIdsFromText,
  detectDouyinAwemeIdFromURL,
  isDouyinShellLine,
  isDouyinSingleVideoURL,
  normalizeDouyinTitle,
  rankCandidates,
} from "../src/content/douyin-detect";
import { canonicalizeDouyinVideoURL, isDouyinVideoURL } from "../src/platform";
import { extractDouyinPage } from "../src/content/extract";

describe("douyin multi-source id detection (StepAudio-aligned)", () => {
  it("resolves modal_id from jingxuan feed overlay URLs", () => {
    const raw =
      "https://www.douyin.com/jingxuan?modal_id=7635842095491632418";
    expect(isDouyinVideoURL(raw)).toBe(true);
    expect(isDouyinSingleVideoURL(raw)).toBe(true);
    const hit = detectDouyinAwemeIdFromURL(raw);
    expect(hit?.awemeId).toBe("7635842095491632418");
    expect(hit?.canonicalURL).toBe(
      "https://www.douyin.com/video/7635842095491632418",
    );
    expect(canonicalizeDouyinVideoURL(raw)).toBe(hit?.canonicalURL);
  });

  it("resolves /video/{id} path", () => {
    const raw = "https://www.douyin.com/video/7123456789012345678";
    expect(detectDouyinAwemeIdFromURL(raw)?.awemeId).toBe("7123456789012345678");
  });

  it("does not treat bare feed shell as a single video", () => {
    expect(isDouyinVideoURL("https://www.douyin.com/jingxuan")).toBe(false);
    expect(isDouyinVideoURL("https://www.douyin.com/")).toBe(false);
    expect(detectDouyinAwemeIdFromURL("https://www.douyin.com/jingxuan")).toBeNull();
  });

  it("collects ids from script-like text with key patterns", () => {
    const text = '{"modal_id":"7635842095491632418","aweme_id":"7635842095491632418"}';
    const ids = collectIdsFromText(text, 50, "script");
    expect(ids.some((item) => item.id === "7635842095491632418")).toBe(true);
    const ranked = rankCandidates(ids);
    expect(ranked[0]?.id).toBe("7635842095491632418");
  });

  it("normalizes Douyin browser titles", () => {
    expect(normalizeDouyinTitle("口播标题 - 抖音")).toBe("口播标题");
    expect(
      normalizeDouyinTitle("当下最稳发财赛道 - 抖音"),
    ).toBe("当下最稳发财赛道");
  });

  it("classifies feed chrome lines as shell noise", () => {
    expect(isDouyinShellLine("精选")).toBe(true);
    expect(isDouyinShellLine("朋友 15")).toBe(true);
    expect(isDouyinShellLine("读屏标签已关闭")).toBe(true);
    expect(isDouyinShellLine("这是真正的视频描述")).toBe(false);
  });
});

describe("extractDouyinPage single-item body", () => {
  function makeDoc(options: {
    href: string;
    title: string;
    ogTitle?: string;
    ogDesc?: string;
    desc?: string;
  }): Document {
    const href = options.href;
    const attrs = (node: Element, name: string) => node.getAttribute(name);
    const metaNodes: Array<{ prop?: string; name?: string; content: string }> = [];
    if (options.ogTitle) metaNodes.push({ prop: "og:title", content: options.ogTitle });
    if (options.ogDesc) metaNodes.push({ prop: "og:description", content: options.ogDesc });

    const fake = {
      location: { href },
      title: options.title,
      querySelector(selector: string) {
        if (selector === "meta[property='og:title']" && options.ogTitle) {
          return {
            getAttribute: (n: string) => (n === "content" ? options.ogTitle! : null),
          };
        }
        if (selector === "meta[property='og:description']" && options.ogDesc) {
          return {
            getAttribute: (n: string) => (n === "content" ? options.ogDesc! : null),
          };
        }
        if (selector === "[data-e2e='video-desc']" && options.desc) {
          return { textContent: options.desc };
        }
        if (selector === "video") return null;
        if (selector === "h1") return null;
        if (selector === "meta[name='author']") return null;
        if (selector === "[data-e2e='user-info']") return null;
        if (selector === "meta[property='og:image']") return null;
        return null;
      },
      querySelectorAll(selector: string) {
        if (selector === "script") return [];
        return [];
      },
    };
    void attrs;
    void metaNodes;
    return fake as unknown as Document;
  }

  it("canonicalizes modal_id feed URL and avoids shell navigation body", () => {
    const doc = makeDoc({
      href: "https://www.douyin.com/jingxuan?modal_id=7635842095491632418",
      title: "当下最稳发财赛道 - 抖音",
      ogTitle: "当下最稳发财赛道，全在超细粉小领域",
      ogDesc: "真正的口播描述，不是导航",
      desc: "精选\n关注\n真正的口播描述，不是导航",
    });
    const page = extractDouyinPage(doc);
    expect(page.url).toBe("https://www.douyin.com/video/7635842095491632418");
    expect(page.title).toContain("当下最稳发财赛道");
    expect(page.text).not.toMatch(/^精选$/mu);
    expect(page.text).not.toContain("\n关注\n");
    expect(page.text).toContain("真正的口播描述");
    expect(page.text).toContain("aweme_id");
  });
});

describe("background douyin hard-fork contract", () => {
  it("treats any douyin host as single-item surface via isDouyinHost", async () => {
    const { isDouyinHost } = await import("../src/content/douyin-detect");
    expect(isDouyinHost("https://www.douyin.com/jingxuan?modal_id=1")).toBe(true);
    expect(isDouyinHost("https://www.douyin.com/video/1")).toBe(true);
    // Bare feed is still douyin host — background must not generic-scrape it.
    expect(isDouyinHost("https://www.douyin.com/jingxuan")).toBe(true);
  });
});


describe("douyin caption and publish-time normalization", () => {
  it("strips the trailing 展开 expander label from captions", async () => {
    const { normalizeDouyinTitle } = await import("../src/content/douyin-detect");
    expect(normalizeDouyinTitle("盘点隐藏细节#功夫女足展开")).toBe("盘点隐藏细节#功夫女足");
    expect(normalizeDouyinTitle("正文…展开")).toBe("正文");
    // 展开 mid-sentence is content, not chrome.
    expect(normalizeDouyinTitle("展开讲讲这个话题")).toBe("展开讲讲这个话题");
  });

  it("converts decorated relative/short publish dates to absolute days", async () => {
    const { normalizeDouyinPublishedText } = await import("../src/content/douyin-detect");
    const now = new Date(2026, 6, 22, 19, 0, 0); // 2026-07-22 local
    expect(normalizeDouyinPublishedText("· 2天前", now)).toBe("2026年7月20日");
    expect(normalizeDouyinPublishedText("· 6月29日 · 广东", now)).toBe("2026年6月29日");
    // A month/day later than today belongs to last year.
    expect(normalizeDouyinPublishedText("12月1日", now)).toBe("2025年12月1日");
    expect(normalizeDouyinPublishedText("昨天", now)).toBe("2026年7月21日");
    expect(normalizeDouyinPublishedText("刚刚", now)).toBe("2026年7月22日");
    expect(normalizeDouyinPublishedText("2025年3月5日", now)).toBe("2025年3月5日");
    // ISO datetimes pass through untouched; unknown shapes come back cleaned.
    expect(normalizeDouyinPublishedText("2026-06-29T10:00:00Z", now)).toBe("2026-06-29T10:00:00Z");
    expect(normalizeDouyinPublishedText("· 广东", now)).toBe("广东");
    expect(normalizeDouyinPublishedText("· ", now)).toBeUndefined();
  });
});
