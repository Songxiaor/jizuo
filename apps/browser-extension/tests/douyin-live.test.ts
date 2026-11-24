import { describe, expect, it } from "vitest";

import {
  douyinRoomID,
  isDouyinLiveURL,
  joinPaceChunks,
  liveQualityLabel,
  parseDouyinLiveRoom,
  pickQualityOptions,
  selectLiveVariant,
  variantsFromResourceURLs,
  type LiveVariant,
} from "../src/content/douyin-live";

/** 形态与线上的 `self.__pace_f.push([1,"…"])` 一致：JSON 被当成 JS 字符串字面量转义了一次。 */
function paceChunk(payload: string): string {
  return `<script>self.__pace_f.push([1,${JSON.stringify(payload)}])</script>`;
}

const stream = {
  flv_pull_url: {
    FULL_HD1: "http://pull-flv.example.test/stream-demo_or4.flv?sign=sanitized&expire=1",
    HD1: "http://pull-flv.example.test/stream-demo_hd.flv?sign=sanitized&expire=1",
    SD1: "http://pull-flv.example.test/stream-demo_ld.flv?sign=sanitized&expire=1",
    SD2: "http://pull-flv.example.test/stream-demo_sd.flv?sign=sanitized&expire=1",
  },
  hls_pull_url_map: {
    FULL_HD1: "http://pull-hls.example.test/stream-demo_or4.m3u8?sign=sanitized&expire=1",
    HD1: "http://pull-hls.example.test/stream-demo_hd.m3u8?sign=sanitized&expire=1",
    SD1: "http://pull-hls.example.test/stream-demo_ld.m3u8?sign=sanitized&expire=1",
    SD2: "http://pull-hls.example.test/stream-demo_sd.m3u8?sign=sanitized&expire=1",
  },
  hls_pull_url: "http://pull-hls.example.test/stream-demo_sd.m3u8?sign=sanitized&expire=1",
  live_core_sdk_data: {
    pull_data: {
      options: {
        qualities: [
          { name: "标清", sdk_key: "ld", resolution: "540x960" },
          { name: "高清", sdk_key: "sd", resolution: "720x1280" },
          { name: "超清", sdk_key: "hd", resolution: "720x1280" },
          { name: "蓝光", sdk_key: "origin", resolution: "1080x1920" },
        ],
      },
    },
  },
};

function pageHTML(): string {
  const room = {
    anchorStore: {
      roomInfo: {
        stream_url: stream,
        owner: {
          id_str: "10001",
          sec_uid: "SEC_demo",
          nickname: "示例主播",
          avatar_thumb: { url_list: ["https://avatar.example.test/anchor.jpg"] },
        },
      },
    },
  };
  return [
    "<html><head></head><body>",
    paceChunk("d:[\"$\",\"$L12\",null,"),
    paceChunk(JSON.stringify(room)),
    paceChunk("]"),
    "</body></html>",
  ].join("");
}

describe("抖音直播间取流解析", () => {
  it("只接受 live.douyin.com 的数字房间号", () => {
    expect(isDouyinLiveURL("https://live.douyin.com/427518068747")).toBe(true);
    expect(douyinRoomID("https://live.douyin.com/427518068747/?from=share")).toBe("427518068747");
    expect(isDouyinLiveURL("https://www.douyin.com/root/live/123")).toBe(false);
    expect(isDouyinLiveURL("https://live.douyin.com.evil.test/123")).toBe(false);
    expect(isDouyinLiveURL("https://live.douyin.com/abc")).toBe(false);
  });

  it("拼接被拆开的 __pace_f 片段并解出主播与各档地址", () => {
    const html = pageHTML();
    expect(joinPaceChunks(html)).toContain("\"stream_url\"");
    const room = parseDouyinLiveRoom(html, {
      pageURL: "https://live.douyin.com/427518068747",
      title: "示例主播正在直播",
    });
    expect(room?.roomID).toBe("427518068747");
    expect(room?.anchorName).toBe("示例主播");
    expect(room?.anchorID).toBe("SEC_demo");
    expect(room?.anchorAvatarURL).toBe("https://avatar.example.test/anchor.jpg");
    expect(room?.anchorProfileURL).toBe("https://www.douyin.com/user/SEC_demo");
    expect(room?.title).toBe("示例主播正在直播");
    expect(room?.variants.map((variant) => `${variant.quality}:${variant.container}`)).toEqual([
      "origin:hls",
      "origin:flv",
      "hd:flv",
      "hd:hls",
      "sd:flv",
      "sd:hls",
      "ld:flv",
      "ld:hls",
    ]);
  });

  it("原画只选 HLS；其他档优先 FLV，缺档时向下退", () => {
    const variants: LiveVariant[] = [
      { quality: "origin", container: "flv", url: "http://x.test/a.flv" },
      { quality: "origin", container: "hls", url: "http://x.test/a.m3u8" },
      { quality: "sd", container: "hls", url: "http://x.test/sd.m3u8" },
    ];
    expect(selectLiveVariant(variants, "origin")?.container).toBe("hls");
    expect(selectLiveVariant(variants, "hd")?.quality).toBe("sd");
    expect(selectLiveVariant([{ quality: "origin", container: "flv", url: "http://x.test/a.flv" }], "origin")).toBeNull();
    expect(selectLiveVariant([], "origin")).toBeNull();
  });

  it("下拉框每档只有一条，并给出可读标签", () => {
    const variants = variantsFromResourceURLs([
      "http://x.test/stream_hd.flv?sign=1",
      "http://x.test/stream_hd5.m3u8?sign=2",
      "http://x.test/stream.flv?sign=3",
      "http://x.test/stream_or4.m3u8?sign=4",
      "http://x.test/stream_ld.flv?sign=5",
    ]);
    const options = pickQualityOptions(variants);
    expect(options.map((variant) => variant.quality)).toEqual(["origin", "hd", "ld"]);
    expect(liveQualityLabel({ quality: "origin", label: "蓝光", resolution: "1080x1920" })).toBe("蓝光 · 1080x1920");
    expect(liveQualityLabel({ quality: "origin" })).toBe("原画");
  });

  it("页面数据缺失时用播放器请求过的地址兜底", () => {
    const room = parseDouyinLiveRoom("<html><body>空壳</body></html>", {
      pageURL: "https://live.douyin.com/123456789",
      resourceURLs: ["https://pull-hls.example.test/stream_sd.m3u8?sign=sanitized"],
    });
    expect(room?.variants).toEqual([
      { quality: "sd", container: "hls", url: "https://pull-hls.example.test/stream_sd.m3u8?sign=sanitized" },
    ]);
    expect(parseDouyinLiveRoom("<html></html>", { pageURL: "https://live.douyin.com/123456789" })).toBeNull();
  });
});
