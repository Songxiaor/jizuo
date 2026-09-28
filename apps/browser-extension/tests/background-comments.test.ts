import { afterEach, describe, expect, it, vi } from "vitest";
import type { ExtractedPage } from "../src/content/extract";
import type { CommentCollection } from "../src/content/comments";

afterEach(() => vi.unstubAllGlobals());

async function loadBackground(sendNativeMessage = vi.fn()) {
  vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
  vi.stubGlobal("browser", { runtime: { sendNativeMessage } });
  vi.stubGlobal("defineBackground", (factory: unknown) => factory);
  vi.resetModules();
  return import("../src/entrypoints/background");
}

const page: ExtractedPage = {
  title: "帖子",
  url: "https://www.reddit.com/r/x/comments/abc/t/",
  text: "# 帖子\n\n正文\n\n## 评论（当前页面已加载 1 / 页面显示 9）\n\n- **u/old** · score 1\n  old",
  characterCount: 0,
  method: "rendered_dom",
  completeness: "visible_only",
};

const collection: CommentCollection = {
  platform: "reddit",
  limit: 2,
  expectedCount: 9,
  comments: [
    { id: "t1_a", author: "u/a", body: "first", depth: 0, score: "5" },
    { id: "t1_b", author: "u/b", body: "second", depth: 1 },
    { id: "t1_c", author: "u/c", body: "third", depth: 0 },
  ],
};

describe("capture preferences", () => {
  it("reads the App's comment limit and clamps it", async () => {
    const sendNativeMessage = vi.fn().mockResolvedValue({
      kind: "capturePreferences", version: 1, requestId: "fixed", commentLimit: 300,
    });
    const { commentLimitPreference } = await loadBackground(sendNativeMessage);
    await expect(commentLimitPreference()).resolves.toBe(100);
    expect(sendNativeMessage).toHaveBeenCalledWith(
      "com.syc.linkdigest.v01",
      { kind: "getCapturePreferences", version: 1, requestId: "fixed" },
    );
  });

  it("falls back to 20 when an older App answers with an error", async () => {
    const sendNativeMessage = vi.fn().mockResolvedValue({ kind: "error", error: { code: "CAPTURE_SCHEMA_INVALID" } });
    const { commentLimitPreference } = await loadBackground(sendNativeMessage);
    await expect(commentLimitPreference()).resolves.toBe(20);
  });

  it("falls back to 20 when the native host is missing", async () => {
    const { commentLimitPreference } = await loadBackground(vi.fn().mockRejectedValue(new Error("Specified native messaging host not found.")));
    await expect(commentLimitPreference()).resolves.toBe(20);
  });
});

describe("pageWithComments", () => {
  it("replaces the extractor's comment section with the first N when nothing was ticked", async () => {
    const { pageWithComments } = await loadBackground();
    const result = pageWithComments(page, collection, undefined);
    expect(result.text).toBe([
      "# 帖子\n\n正文\n",
      "## 评论（已保存 2 条 / 页面显示 9）",
      "",
      "- **u/a** · score 5 · 回复层级 0",
      "  first",
      "  - **u/b** · 回复层级 1",
      "    second",
    ].join("\n"));
    expect(result.characterCount).toBe([...result.text].length);
    expect(result.completeness).toBe("full_article");
  });

  it("keeps only the ticked comments", async () => {
    const { pageWithComments } = await loadBackground();
    const result = pageWithComments(page, collection, ["t1_c"]);
    expect(result.text).toContain("- **u/c** · 回复层级 0\n  third");
    expect(result.text).not.toContain("first");
    expect(result.text).not.toContain("u/old");
  });

  it("drops every comment when the user unticked all of them", async () => {
    const { pageWithComments } = await loadBackground();
    expect(pageWithComments(page, collection, []).text).toBe("# 帖子\n\n正文");
  });

  it("leaves the page untouched when collection failed or read nothing", async () => {
    const { pageWithComments } = await loadBackground();
    expect(pageWithComments(page, undefined, undefined)).toBe(page);
    expect(pageWithComments(page, { ...collection, comments: [] }, undefined)).toBe(page);
  });
});

describe("commentPickerItems", () => {
  it("shortens bodies, hides images and strips the Reddit u/ prefix", async () => {
    const { commentPickerItems } = await loadBackground();
    const item = commentPickerItems([
      { id: "1", author: "u/a", body: `![图](https://i.example/x.png)\n${"长".repeat(300)}`, depth: 0, score: "7" },
    ])[0]!;
    expect(item.author).toBe("a");
    expect(item.excerpt.startsWith("[图片] 长")).toBe(true);
    expect(item.excerpt.length).toBe(160);
    expect(item.likes).toBe("7");
  });
});

describe("sameContentURL", () => {
  it("ignores tracking params and trailing slashes but keeps content ids", async () => {
    const { sameContentURL } = await loadBackground();
    expect(sameContentURL(
      "https://www.bilibili.com/video/BV1GJ411x7h7/?vd_source=abc",
      "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.788&vd_source=abc",
    )).toBe(true);
    expect(sameContentURL("https://www.youtube.com/watch?v=a&t=10", "https://www.youtube.com/watch?v=a")).toBe(true);
    expect(sameContentURL("https://www.youtube.com/watch?v=a", "https://www.youtube.com/watch?v=b")).toBe(false);
    expect(sameContentURL("https://www.bilibili.com/video/BV1", "https://www.bilibili.com/video/BV2")).toBe(false);
  });
});
