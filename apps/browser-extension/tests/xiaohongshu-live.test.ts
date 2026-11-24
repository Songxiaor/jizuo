import { describe, expect, it } from "vitest";

import { selectLiveVariant } from "../src/content/douyin-live";
import {
  isXiaohongshuLiveURL,
  parseXiaohongshuPullConfig,
  xiaohongshuAnchorInfo,
  xiaohongshuRoomID,
} from "../src/content/xiaohongshu-live";
import { validateLiveRecording } from "../src/contract";

const pullConfig = JSON.stringify({
  streams: [
    {
      quality_type: "HCV5401",
      quality_type_name: "1080P 高帧率",
      codec_v2: "EF5",
      protocol: "flv",
      max_bitrate: 6_000_000,
      master_url: "http://live-source-play.example.test/live/570537012912716275_hcv5401.flv",
    },
    {
      quality_type: "HCV5301",
      quality_type_name: "1080P 蓝光",
      codec_v2: "EF5",
      protocol: "flv",
      max_bitrate: 4_000_000,
      master_url: "http://live-source-play.example.test/live/570537012912716275_hcv5301.flv",
    },
    {
      quality_type: "HCV5201",
      quality_type_name: "1080P 高清",
      codec_v2: "EF5",
      protocol: "flv",
      max_bitrate: 2_000_000,
      master_url: "http://live-source-play.example.test/live/570537012912716275_hcv5201.flv",
    },
    {
      quality_type: "FLV",
      quality_type_name: "原画",
      codec_v2: "EF4",
      protocol: "flv",
      max_bitrate: 3_500_000,
      master_url: "http://live-source-play.example.test/live/570537012912716275.flv",
    },
  ],
});

describe("小红书直播间取流", () => {
  it("识别 livestream 地址", () => {
    expect(isXiaohongshuLiveURL("https://www.xiaohongshu.com/livestream/570537012912716275?xsec_token=x")).toBe(true);
    expect(xiaohongshuRoomID("https://www.xiaohongshu.com/livestream/570537012912716275")).toBe("570537012912716275");
    expect(isXiaohongshuLiveURL("https://www.xiaohongshu.com/explore/abc")).toBe(false);
    expect(isXiaohongshuLiveURL("https://www.xiaohongshu.com.evil.test/livestream/1")).toBe(false);
  });

  it("原画映射为 origin，其余按码率排 hd/sd/ld，http 统一改 https", () => {
    const variants = parseXiaohongshuPullConfig(pullConfig);
    expect(variants.map((variant) => `${variant.quality}:${variant.container}`)).toEqual([
      "origin:flv", "hd:flv", "sd:flv", "ld:flv",
    ]);
    expect(variants.every((variant) => variant.url.startsWith("https://"))).toBe(true);
    expect(variants[1]?.label).toBe("1080P 高帧率");
    expect(selectLiveVariant(variants, "origin", "xiaohongshu")?.url)
      .toBe("https://live-source-play.example.test/live/570537012912716275.flv");
  });

  it("pullConfig 缺失时用 deeplink 的 flvUrl 兜底", () => {
    const variants = parseXiaohongshuPullConfig("", "http://live-source-play.example.test/live/1.flv");
    expect(variants).toEqual([
      { quality: "origin", container: "flv", url: "https://live-source-play.example.test/live/1.flv" },
    ]);
  });

  it("合同允许小红书原画 FLV", () => {
    const message = {
      kind: "liveRecording",
      version: 1,
      requestId: "req-xhs",
      createdAt: "2026-11-11T12:00:00.000Z",
      platform: "xiaohongshu",
      pageURL: "https://www.xiaohongshu.com/livestream/570537012912716275",
      quality: "origin",
      variants: [{ quality: "origin", container: "flv", url: "https://live-source-play.example.test/live/1.flv" }],
    };
    expect(validateLiveRecording(message)).toBeNull();
  });

  it("从 roomInfo.host 取出昵称、主播 id、头像和主页", () => {
    const anchor = xiaohongshuAnchorInfo({
      hostId: "5f0000000000000000000001",
      nickname: "示例主播",
      avatar: "https://avatar.example.test/xhs.jpg",
    });
    expect(anchor.anchorName).toBe("示例主播");
    expect(anchor.anchorID).toBe("5f0000000000000000000001");
    expect(anchor.anchorAvatarURL).toBe("https://avatar.example.test/xhs.jpg");
    expect(anchor.anchorProfileURL)
      .toBe("https://www.xiaohongshu.com/user/profile/5f0000000000000000000001");
  });

  it("线上 roomData.hostInfo 的 nickName/userId/avatar 也能直接取", () => {
    const anchor = xiaohongshuAnchorInfo({
      nickName: "示例主播",
      userId: "5f0000000000000000000002",
      avatar: "https://avatar.example.test/xhs-hostinfo.jpg",
    });
    expect(anchor).toEqual({
      anchorName: "示例主播",
      anchorID: "5f0000000000000000000002",
      anchorAvatarURL: "https://avatar.example.test/xhs-hostinfo.jpg",
      anchorProfileURL: "https://www.xiaohongshu.com/user/profile/5f0000000000000000000002",
    });
  });

  it("host 是字符串时只取昵称，缺字段不猜", () => {
    expect(xiaohongshuAnchorInfo("只有昵称")).toEqual({ anchorName: "只有昵称" });
    expect(xiaohongshuAnchorInfo({ nick_name: "旧字段" }, "备用名")).toEqual({ anchorName: "旧字段" });
    expect(xiaohongshuAnchorInfo(undefined, "备用名")).toEqual({ anchorName: "备用名" });
  });
});
