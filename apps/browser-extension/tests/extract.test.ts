import { describe, expect, it } from "vitest";
import { extractCurrentPage } from "../src/content/extract";
import { validateCapture } from "../src/contract";

describe("page extraction", () => {
  it("prefers article and excludes script text", () => {
    const article = { textContent: "本文用于验证 LinkDigest 的当前页面捕获链路。 它不包含账号、Cookie 或真实私人内容。" };
    const fakeDocument = { title: "Fixed Test Article", location: { href: "https://example.test/article" }, defaultView: { getSelection: () => ({ toString: () => "" }) }, querySelector: (selector: string) => selector === "article, main" ? article : null, body: article } as unknown as Document;
    const result = extractCurrentPage(fakeDocument);
    expect(result.text).toContain("当前页面捕获链路");
    expect(result.text).not.toContain("never-read");
    expect(result.characterCount).toBe([...result.text].length);
  });
  it("maps contract errors", () => {
    const base = { version: 1 as const, requestId: "x", createdAt: new Date().toISOString(), source: { kind: "browser_capture" as const, url: "https://example.test", title: null, platform: "generic" as const }, capture: { method: "rendered_dom" as const, text: "x", characterCount: 1, completeness: "full_article" as const, capturedAt: new Date().toISOString() }, evidence: { sourceLabel: "test", usedCookie: false as const } };
    expect(validateCapture({ ...base, source: { ...base.source, url: "file:///tmp/x" } })).toBe("CAPTURE_URL_UNSUPPORTED");
    expect(validateCapture({ ...base, capture: { ...base.capture, characterCount: 2 } })).toBe("CAPTURE_COUNT_MISMATCH");
  });
});
