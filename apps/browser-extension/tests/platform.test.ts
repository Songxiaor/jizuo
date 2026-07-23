import { describe, expect, it } from "vitest";
import { detectCapturePlatform, isDouyinVideoURL, isXStatusURL } from "../src/platform";

describe("capture platform recognition", () => {
  it.each([
    ["https://mp.weixin.qq.com/s/example", "wechat"],
    ["https://x.com/syc/status/123456789", "x"],
    ["https://mobile.twitter.com/syc/status/123456789", "x"],
    ["https://github.com/openai/openai-node", "github"],
    ["https://www.douyin.com/video/7123456789012345678", "douyin"],
    ["https://www.douyin.com/jingxuan?modal_id=7635842095491632418", "douyin"],
    ["https://v.douyin.com/AbCdEf/", "douyin"],
    ["https://example.com/article", "generic"],
    ["not a URL", "generic"],
  ] as const)("recognizes %s as %s", (url, platform) => {
    expect(detectCapturePlatform(url)).toBe(platform);
  });

  it("treats modal_id feed overlays as single-video surfaces", () => {
    expect(isDouyinVideoURL("https://www.douyin.com/jingxuan?modal_id=7635842095491632418")).toBe(true);
    expect(isDouyinVideoURL("https://www.douyin.com/jingxuan")).toBe(false);
  });

  it("only opts into the X post strategy for a concrete status URL", () => {
    expect(isXStatusURL("https://x.com/syc/status/123456789")).toBe(true);
    expect(isXStatusURL("https://x.com/syc/with_replies")).toBe(false);
    expect(isXStatusURL("https://github.com/syc/status/123456789")).toBe(false);
  });
});
