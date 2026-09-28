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

describe("per-platform comment preferences", () => {
  const reply = (extra: Record<string, unknown>) => ({
    kind: "capturePreferences", version: 1, requestId: "fixed", commentLimit: 20, ...extra,
  });

  it("parses per-platform limits and auto-save, clamping values and keeping 0 as disabled", async () => {
    const { parseCapturePreferences } = await loadBackground();
    expect(parseCapturePreferences(reply({
      commentLimits: { reddit: 0, youtube: 50, bilibili: 5, zhihu: 300, x: -3 },
      autoSaveComments: true,
    }), "fixed")).toEqual({
      commentLimit: 20,
      commentLimits: { reddit: 0, youtube: 50, bilibili: 10, zhihu: 100, x: 0 },
      autoSaveComments: true,
    });
  });

  it("ignores unknown platforms, non-integers and malformed fields", async () => {
    const { parseCapturePreferences } = await loadBackground();
    expect(parseCapturePreferences(reply({
      commentLimits: { reddit: 12.5, youtube: "50", weibo: 30, douyin: null, xiaohongshu: 40 },
      autoSaveComments: "true",
    }), "fixed")).toEqual({ commentLimit: 20, commentLimits: { xiaohongshu: 40 }, autoSaveComments: false });
    expect(parseCapturePreferences(reply({ commentLimits: [0, 1] }), "fixed")?.commentLimits).toEqual({});
    expect(parseCapturePreferences(reply({ commentLimits: null }), "fixed")?.commentLimits).toEqual({});
  });

  it("keeps the kind / version / requestId checks", async () => {
    const { parseCapturePreferences } = await loadBackground();
    const good = reply({ commentLimits: { reddit: 0 } });
    expect(parseCapturePreferences({ ...good, requestId: "other" }, "fixed")).toBeUndefined();
    expect(parseCapturePreferences({ ...good, version: 2 }, "fixed")).toBeUndefined();
    expect(parseCapturePreferences({ ...good, kind: "error" }, "fixed")).toBeUndefined();
    expect(parseCapturePreferences("nope", "fixed")).toBeUndefined();
  });

  it("treats an old host reply (no new fields) exactly like before", async () => {
    const { parseCapturePreferences, parseCapturePreferencesLimit } = await loadBackground();
    expect(parseCapturePreferences(reply({ commentLimit: 35 }), "fixed"))
      .toEqual({ commentLimit: 35, commentLimits: {}, autoSaveComments: false });
    expect(parseCapturePreferencesLimit(reply({ commentLimit: 35 }), "fixed")).toBe(35);
  });

  it("picks the platform's own limit, otherwise the default", async () => {
    const { effectiveCommentLimit } = await loadBackground();
    const preferences = { commentLimit: 30, commentLimits: { reddit: 0, youtube: 60 }, autoSaveComments: false };
    expect(effectiveCommentLimit(preferences, "reddit")).toBe(0);
    expect(effectiveCommentLimit(preferences, "youtube")).toBe(60);
    expect(effectiveCommentLimit(preferences, "bilibili")).toBe(30);
  });

  it("validates the comment mode the popup hands back", async () => {
    const { parseCommentSendMode } = await loadBackground();
    expect(parseCommentSendMode({ kind: "disabled" })).toEqual({ kind: "disabled" });
    expect(parseCommentSendMode({ kind: "auto", limit: 500 })).toEqual({ kind: "auto", limit: 100 });
    expect(parseCommentSendMode({ kind: "auto", limit: 0 })).toBeUndefined();
    expect(parseCommentSendMode({ kind: "auto" })).toBeUndefined();
    expect(parseCommentSendMode({ kind: "other" })).toBeUndefined();
    expect(parseCommentSendMode(undefined)).toBeUndefined();
  });
});

describe("collectCommentsForPicker with App preferences", () => {
  const redditURL = "https://www.reddit.com/r/x/comments/abc/t/";

  async function loadWith(preferences: Record<string, unknown> | Error) {
    const sendNativeMessage = preferences instanceof Error
      ? vi.fn().mockRejectedValue(preferences)
      : vi.fn().mockResolvedValue({ kind: "capturePreferences", version: 1, requestId: "fixed", ...preferences });
    const executeScript = vi.fn(async (options: { files?: string[] }) => (
      options.files?.includes("/extract-comments.js") ? [{ result: collection }] : [{ result: undefined }]
    ));
    const storage = new Map<string, unknown>();
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.stubGlobal("browser", {
      runtime: { sendNativeMessage },
      tabs: { get: vi.fn().mockResolvedValue({ url: redditURL, title: "帖子" }) },
      scripting: { executeScript },
      storage: { session: {
        get: vi.fn(async (key: string) => (storage.has(key) ? { [key]: storage.get(key) } : {})),
        set: vi.fn(async (value: Record<string, unknown>) => { for (const [k, v] of Object.entries(value)) storage.set(k, v); }),
        remove: vi.fn(async (key: string) => { storage.delete(key); }),
      } },
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.resetModules();
    const background = await import("../src/entrypoints/background");
    return { background, executeScript };
  }

  it("does not inject the collector when the platform is set to 不抓", async () => {
    const { background, executeScript } = await loadWith({ commentLimit: 20, commentLimits: { reddit: 0 } });
    await expect(background.collectCommentsForPicker(1)).resolves.toEqual({ ok: false, code: "disabled", platform: "reddit" });
    expect(executeScript).not.toHaveBeenCalled();
  });

  it("skips the picker when auto-save is on and reports the effective limit", async () => {
    const { background, executeScript } = await loadWith({ commentLimit: 20, commentLimits: { reddit: 40 }, autoSaveComments: true });
    await expect(background.collectCommentsForPicker(1))
      .resolves.toEqual({ ok: false, code: "auto", platform: "reddit", limit: 40 });
    expect(executeScript).not.toHaveBeenCalled();
  });

  it("collects with the platform's own limit in picker mode", async () => {
    const { background, executeScript } = await loadWith({ commentLimit: 20, commentLimits: { reddit: 55, youtube: 0 } });
    const result = await background.collectCommentsForPicker(1);
    expect(result.ok).toBe(true);
    expect(executeScript.mock.calls[0]?.[0]).toMatchObject({ args: [55] });
  });

  it("keeps today's picker flow with the default limit when the host is old or missing", async () => {
    const { background, executeScript } = await loadWith(new Error("Specified native messaging host not found."));
    const result = await background.collectCommentsForPicker(1);
    expect(result.ok).toBe(true);
    expect(executeScript.mock.calls[0]?.[0]).toMatchObject({ args: [20] });
  });
});

describe("pageWithoutComments", () => {
  it("strips the extractor's embedded comment section when the platform is set to 不抓", async () => {
    const { pageWithoutComments } = await loadBackground();
    const result = pageWithoutComments(page);
    expect(result.text).toBe("# 帖子\n\n正文");
    expect(result.characterCount).toBe([...result.text].length);
    const plain = { ...page, text: "# 帖子\n\n正文" };
    expect(pageWithoutComments(plain)).toBe(plain);
  });
});

describe("sendCapture comment modes", () => {
  const redditURL = "https://www.reddit.com/r/x/comments/abc/t/";

  async function sendWith(mode: unknown, selected?: string[], commentsCollected = collection) {
    const sent: Array<{ capture: { text: string } }> = [];
    const sendNativeMessage = vi.fn(async (_host: string, wire: { requestId: string; capture: { text: string; characterCount: number } }) => {
      sent.push(wire);
      return { kind: "taskAccepted", version: 1, requestId: wire.requestId, characterCount: wire.capture.characterCount };
    });
    const executeScript = vi.fn(async (options: { files?: string[] }) => {
      if (options.files?.includes("/extract-page.js")) return [{ result: { ...page, characterCount: [...page.text].length } }];
      if (options.files?.includes("/extract-comments.js")) return [{ result: commentsCollected }];
      return [{ result: undefined }];
    });
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.stubGlobal("browser", {
      runtime: { sendNativeMessage },
      tabs: { get: vi.fn().mockResolvedValue({ url: redditURL, title: "帖子" }) },
      scripting: { executeScript },
      storage: { session: { get: vi.fn(async () => ({})), set: vi.fn(), remove: vi.fn() } },
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.resetModules();
    const { sendCapture, parseCommentSendMode } = await import("../src/entrypoints/background");
    const result = await sendCapture(1, "save", selected, parseCommentSendMode(mode));
    return { result, sent, executeScript };
  }

  it("auto-save collects with the given limit and saves the first N without a picker", async () => {
    const { result, sent, executeScript } = await sendWith({ kind: "auto", limit: 20 });
    expect(result.response.kind).toBe("taskAccepted");
    const limitCall = executeScript.mock.calls.find((call) => (call[0] as { args?: unknown[] }).args?.[0] === 20);
    expect(limitCall).toBeDefined();
    const text = sent[0]!.capture.text;
    // collection.limit = 2 → the first two comments, the third is left out.
    expect(text).toContain("## 评论（已保存 2 条 / 页面显示 9）");
    expect(text).toContain("first");
    expect(text).toContain("second");
    expect(text).not.toContain("third");
    expect(text).not.toContain("u/old");
  });

  it("auto-save still saves the page when comment collection fails", async () => {
    const { result, sent } = await sendWith({ kind: "auto", limit: 20 }, undefined, null as unknown as CommentCollection);
    expect(result.response.kind).toBe("taskAccepted");
    expect(sent[0]!.capture.text).toContain("正文");
  });

  it("disabled platform saves the page without any comments", async () => {
    const { result, sent, executeScript } = await sendWith({ kind: "disabled" });
    expect(result.response.kind).toBe("taskAccepted");
    expect(sent[0]!.capture.text).not.toContain("## 评论");
    expect(executeScript.mock.calls.some((call) => (call[0] as { files?: string[] }).files?.includes("/extract-comments.js"))).toBe(false);
  });

  it("without a mode (old host / picker) keeps the extractor's section when nothing was picked", async () => {
    const { sent, executeScript } = await sendWith(undefined);
    expect(sent[0]!.capture.text).toContain("u/old");
    expect(executeScript.mock.calls.some((call) => (call[0] as { files?: string[] }).files?.includes("/extract-comments.js"))).toBe(false);
  });
});
