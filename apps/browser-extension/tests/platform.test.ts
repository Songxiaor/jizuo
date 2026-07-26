import { describe, expect, it } from "vitest";
import { detectCapturePlatform, isDouyinVideoURL, isXStatusURL } from "../src/platform";
import { bilibiliVideoID, isBilibiliVideoURL, bilibiliCanonicalURL } from "../src/content/bilibili";
import { xiaohongshuNoteID, isXiaohongshuNoteURL } from "../src/content/xiaohongshu";

describe("capture platform recognition", () => {
  it.each([
    ["https://mp.weixin.qq.com/s/example", "wechat"],
    ["https://x.com/syc/status/123456789", "x"],
    ["https://mobile.twitter.com/syc/status/123456789", "x"],
    ["https://github.com/openai/openai-node", "github"],
    ["https://www.douyin.com/video/7123456789012345678", "douyin"],
    ["https://www.douyin.com/jingxuan?modal_id=7635842095491632418", "douyin"],
    ["https://v.douyin.com/AbCdEf/", "douyin"],
    ["https://www.zhihu.com/question/123/answer/456", "zhihu"],
    ["https://zhuanlan.zhihu.com/p/123456", "zhihu"],
    ["https://medium.com/@author/some-post-abc123", "medium"],
    ["https://publication.substack.com/p/some-issue", "substack"],
    ["https://substack.com/home", "substack"],
    ["https://www.toutiao.com/article/7123456789012345678/", "toutiao"],
    ["https://www.bilibili.com/video/BV1xx411c7mD", "bilibili"],
    ["https://b23.tv/AbCdEf", "bilibili"],
    ["https://www.xiaohongshu.com/explore/6512a1b2c3d4e5f6a7b8c9d0", "xiaohongshu"],
    ["https://xhslink.com/AbCdEf", "xiaohongshu"],
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

  it("resolves a Bilibili video id and canonical page only for concrete video URLs", () => {
    expect(bilibiliVideoID("https://www.bilibili.com/video/BV1xx411c7mD?p=2")).toBe("BV1xx411c7mD");
    expect(bilibiliVideoID("https://www.bilibili.com/video/av170001")).toBe("av170001");
    expect(bilibiliVideoID("https://www.bilibili.com/")).toBeUndefined();
    expect(bilibiliVideoID("https://space.bilibili.com/123")).toBeUndefined();
    expect(isBilibiliVideoURL("https://www.bilibili.com/video/BV1xx411c7mD")).toBe(true);
    expect(isBilibiliVideoURL("https://www.bilibili.com/")).toBe(false);
    expect(bilibiliCanonicalURL("BV1xx411c7mD")).toBe("https://www.bilibili.com/video/BV1xx411c7mD");
  });

  it("resolves a Xiaohongshu note id only for a concrete note surface", () => {
    expect(xiaohongshuNoteID("https://www.xiaohongshu.com/explore/6512a1b2c3d4e5f6a7b8c9d0")).toBe("6512a1b2c3d4e5f6a7b8c9d0");
    expect(xiaohongshuNoteID("https://www.xiaohongshu.com/discovery/item/6512a1b2c3d4e5f6a7b8c9d0")).toBe("6512a1b2c3d4e5f6a7b8c9d0");
    expect(xiaohongshuNoteID("https://www.xiaohongshu.com/")).toBeUndefined();
    expect(isXiaohongshuNoteURL("https://www.xiaohongshu.com/explore/6512a1b2c3d4e5f6a7b8c9d0")).toBe(true);
    expect(isXiaohongshuNoteURL("https://www.xiaohongshu.com/user/profile/123")).toBe(false);
  });
});
