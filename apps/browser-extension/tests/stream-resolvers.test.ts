import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it } from "vitest";

import { readBilibiliStreamInMainWorld } from "../src/content/bilibili";
import { readXiaohongshuVideoStreamInMainWorld } from "../src/content/xiaohongshu";
import { validateCapture } from "../src/contract";

/**
 * 两个 reader 都是注入 MAIN world 的自包含函数，读的是页面自己的 JS 全局。
 * 测试用最小 window 桩复现实测到的形状：小红书 SSR 给 http 地址，B 站把 PCDN
 * 节点混在 baseUrl / backupUrl 里。
 */
const stubWindow = (value: Record<string, unknown>) => {
  (globalThis as Record<string, unknown>).window = value;
};

afterEach(() => {
  delete (globalThis as Record<string, unknown>).window;
});

const xhsState = (note: Record<string, unknown>) => ({
  __INITIAL_STATE__: { note: { noteDetailMap: { "6a41bf03000000001101f712": { note } } } },
});

describe("Xiaohongshu video stream resolver", () => {
  it("returns the h264 master URL upgraded to https, with duration and signed expiry", () => {
    stubWindow(xhsState({
      type: "video",
      video: {
        capa: { duration: 53 },
        media: {
          stream: {
            h264: [{
              // 实测 SSR 给的是 http，`t` 是十六进制秒级时间戳。
              masterUrl: "http://sns-video-v2.xhscdn.com/stream/79/110/259/01ea_259.mp4?sign=abc&t=6a68c2f0",
              backupUrls: [
                "http://sns-bak-v1.xhscdn.com/stream/79/110/259/01ea_259.mp4",
                "http://cdn.example.com/not-xiaohongshu.mp4",
              ],
              size: 7396909,
              duration: 53376,
            }],
          },
        },
      },
    }));

    const stream = readXiaohongshuVideoStreamInMainWorld("6a41bf03000000001101f712");

    expect(stream?.url).toBe("https://sns-video-v2.xhscdn.com/stream/79/110/259/01ea_259.mp4?sign=abc&t=6a68c2f0");
    // 非小红书 CDN 的备份地址不得混进来。
    expect(stream?.backupURLs).toEqual(["https://sns-bak-v1.xhscdn.com/stream/79/110/259/01ea_259.mp4"]);
    expect(stream?.durationSeconds).toBe(53);
    expect(stream?.sizeBytes).toBe(7396909);
    expect(stream?.expiresAt).toBe(new Date(0x6a68c2f0 * 1000).toISOString());
  });

  it("falls back to h265 when h264 is absent and derives duration from the stream entry", () => {
    stubWindow(xhsState({
      type: "video",
      video: { media: { stream: { h264: [], h265: [{ masterUrl: "https://sns-video-v2.xhscdn.com/a.mp4", duration: 12000 }] } } },
    }));

    const stream = readXiaohongshuVideoStreamInMainWorld("6a41bf03000000001101f712");

    expect(stream?.url).toBe("https://sns-video-v2.xhscdn.com/a.mp4");
    expect(stream?.durationSeconds).toBe(12);
    expect(stream?.expiresAt).toBeUndefined();
  });

  it("returns null for an image note, a foreign CDN, and a missing SSR state", () => {
    stubWindow(xhsState({ type: "normal", video: { media: { stream: { h264: [{ masterUrl: "https://sns-video-v2.xhscdn.com/a.mp4" }] } } } }));
    expect(readXiaohongshuVideoStreamInMainWorld("6a41bf03000000001101f712")).toBeNull();

    stubWindow(xhsState({ type: "video", video: { media: { stream: { h264: [{ masterUrl: "https://evil.example.com/a.mp4" }] } } } }));
    expect(readXiaohongshuVideoStreamInMainWorld("6a41bf03000000001101f712")).toBeNull();

    stubWindow({});
    expect(readXiaohongshuVideoStreamInMainWorld("6a41bf03000000001101f712")).toBeNull();
  });

  it("ignores a note detail that belongs to a different note id", () => {
    stubWindow(xhsState({ type: "video", video: { media: { stream: { h264: [{ masterUrl: "https://sns-video-v2.xhscdn.com/a.mp4" }] } } } }));
    expect(readXiaohongshuVideoStreamInMainWorld("6a3ad0fb0000000006031e3b")).toBeNull();
  });
});

describe("Bilibili stream resolver", () => {
  it("prefers the complete durl mp4 over dash", () => {
    stubWindow({
      __playinfo__: {
        data: {
          timelength: 628836,
          durl: [{ url: "https://upos-sz-mirrorcos.bilivideo.com/full.mp4?deadline=1784955384", backup_url: [] }],
          dash: { audio: [{ baseUrl: "https://upos-sz-estgoss.bilivideo.com/audio.m4s", bandwidth: 100 }] },
        },
      },
    });

    const stream = readBilibiliStreamInMainWorld();

    expect(stream?.mimeType).toBe("video/mp4");
    expect(stream?.url).toBe("https://upos-sz-mirrorcos.bilivideo.com/full.mp4?deadline=1784955384");
    expect(stream?.durationSeconds).toBeCloseTo(628.836, 3);
    expect(stream?.expiresAt).toBe(new Date(1784955384 * 1000).toISOString());
  });

  it("pairs a 1080p H.264 video track with the best audio track and skips PCDN nodes", () => {
    stubWindow({
      __playinfo__: {
        data: {
          timelength: 60000,
          durl: [],
          dash: {
            audio: [
              { id: 30216, bandwidth: 65694, baseUrl: "https://xy220x180x77x78xy.mcdn.bilivideo.cn:8082/v1/resource/low.m4s", backupUrl: ["https://upos-sz-mirrorcos.bilivideo.com/low.m4s"] },
              {
                id: 30280,
                bandwidth: 175505,
                // baseUrl 是 PCDN 节点（自定义端口），只有 backupUrl 是可直连的 CDN。
                baseUrl: "https://xy61x170x60x36xy.mcdn.bilivideo.cn:8082/v1/resource/best.m4s",
                backupUrl: [
                  "https://b-xxx.edge.mountaintoys.cn:4483/best.m4s",
                  "https://upos-sz-estgoss.bilivideo.com/best.m4s?deadline=1784955384",
                ],
              },
            ],
            video: [
              // 1080P60（116）超过封顶，不要——4:31 的片子那档就 212MB。
              { id: 116, codecs: "avc1.640033", bandwidth: 6288682, baseUrl: "https://cn-a.bilivideo.com/1080p60.m4s" },
              // 同为 1080P 时 avc1 优先于 hvc1，AV1 直接跳过。
              { id: 80, codecs: "av01.0.08M.08", bandwidth: 1197405, baseUrl: "https://cn-a.bilivideo.com/1080p-av1.m4s" },
              { id: 80, codecs: "hvc1.1.6.L150.90", bandwidth: 1334759, baseUrl: "https://cn-a.bilivideo.com/1080p-hevc.m4s" },
              { id: 80, codecs: "avc1.640033", bandwidth: 3277118, baseUrl: "https://cn-a.bilivideo.com/1080p-avc.m4s?deadline=1784955384" },
              { id: 64, codecs: "avc1.640033", bandwidth: 1354034, baseUrl: "https://cn-a.bilivideo.com/720p-avc.m4s" },
            ],
          },
        },
      },
    });

    const stream = readBilibiliStreamInMainWorld();

    expect(stream?.mimeType).toBe("video/mp4");
    expect(stream?.url).toBe("https://cn-a.bilivideo.com/1080p-avc.m4s?deadline=1784955384");
    expect(stream?.companionAudioURL).toBe("https://upos-sz-estgoss.bilivideo.com/best.m4s?deadline=1784955384");
    expect(stream?.durationSeconds).toBe(60);
    expect(stream?.expiresAt).toBe(new Date(1784955384 * 1000).toISOString());
  });

  it("falls back to audio only when no video track is reachable, and keeps AV1 out of the pick", () => {
    stubWindow({
      __playinfo__: {
        data: {
          durl: [],
          dash: {
            audio: [{ bandwidth: 100, baseUrl: "https://upos-sz-estgoss.bilivideo.com/a.m4s" }],
            video: [
              // 可直连但只有 AV1；以及 H.264 却只在 PCDN 上——两者都不能用。
              { id: 80, codecs: "av01.0.08M.08", baseUrl: "https://cn-a.bilivideo.com/av1.m4s" },
              { id: 80, codecs: "avc1.640033", baseUrl: "https://xy1x2xy.mcdn.bilivideo.cn:8082/v1/resource/avc.m4s" },
            ],
          },
        },
      },
    });

    const stream = readBilibiliStreamInMainWorld();

    expect(stream?.mimeType).toBe("audio/mp4");
    expect(stream?.url).toBe("https://upos-sz-estgoss.bilivideo.com/a.m4s");
    expect(stream?.companionAudioURL).toBeUndefined();
  });

  it("returns null when every candidate is a PCDN node and when playinfo is absent", () => {
    stubWindow({
      __playinfo__: {
        data: { dash: { audio: [{ bandwidth: 1, baseUrl: "https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/a.m4s", backupUrl: ["https://b.edge.mountaintoys.cn:4483/a.m4s"] }] } },
      },
    });
    expect(readBilibiliStreamInMainWorld()).toBeNull();

    stubWindow({});
    expect(readBilibiliStreamInMainWorld()).toBeNull();
  });
});

describe("MAIN-world readers stay self-contained", () => {
  /**
   * 这两个函数是被 `browser.scripting.executeScript` 序列化后注入页面执行的：
   * 只有函数体本身会过去，任何模块级标识符在页面里都是 ReferenceError，而它们
   * 各自的 try/catch 会把这个错误吞成 `null`——线上表现是"抓不到视频"，不报错。
   * 直接 import 调用的测试发现不了（模块作用域能解析），所以这里用 `new Function`
   * 从源码重建，复现浏览器那边的作用域。
   */
  const rebuild = <T extends (...args: never[]) => unknown>(fn: T): T =>
    new Function(`return (${String(fn)})`)() as T;

  it("runs the Bilibili reader with no access to module scope", () => {
    stubWindow({
      __playinfo__: {
        data: {
          timelength: 60000,
          durl: [],
          dash: {
            audio: [{ bandwidth: 100, baseUrl: "https://upos-sz-estgoss.bilivideo.com/a.m4s" }],
            video: [{ id: 80, codecs: "avc1.640033", baseUrl: "https://upos-sz-estgoss.bilivideo.com/v.m4s" }],
          },
        },
      },
    });

    const isolated = rebuild(readBilibiliStreamInMainWorld);
    const stream = isolated();

    // 只要函数体引用了模块级标识符，这里就会退化成 null。
    expect(stream).not.toBeNull();
    expect(stream?.url).toBe("https://upos-sz-estgoss.bilivideo.com/v.m4s");
    expect(stream?.companionAudioURL).toBe("https://upos-sz-estgoss.bilivideo.com/a.m4s");
  });

  it("runs the Xiaohongshu reader with no access to module scope", () => {
    stubWindow(xhsState({
      type: "video",
      video: { capa: { duration: 12 }, media: { stream: { h264: [{ masterUrl: "https://sns-video-v2.xhscdn.com/a.mp4" }] } } },
    }));

    const isolated = rebuild(readXiaohongshuVideoStreamInMainWorld);
    const stream = isolated("6a41bf03000000001101f712");

    expect(stream?.url).toBe("https://sns-video-v2.xhscdn.com/a.mp4");
    expect(stream?.durationSeconds).toBe(12);
  });
});

describe("upgraded media descriptors stay contract-valid", () => {
  const fixture = () => JSON.parse(
    readFileSync(new URL("../../../contracts/fixtures/v2-direct-file.json", import.meta.url), "utf8"),
  );

  it("accepts the Xiaohongshu video and Bilibili audio descriptors the background builds", () => {
    const base = fixture();
    const xiaohongshu = {
      ...base,
      media: {
        kind: "directFile",
        pageURL: "https://www.xiaohongshu.com/explore/6a41bf03000000001101f712?xsec_token=abc",
        canonicalURL: "https://www.xiaohongshu.com/explore/6a41bf03000000001101f712",
        platform: "xiaohongshu",
        ephemeralPlaybackURL: "https://sns-video-v2.xhscdn.com/stream/79/110/259/01ea_259.mp4?sign=abc&t=6a68c2f0",
        mimeType: "video/mp4",
        durationSeconds: 53,
        expiresAt: new Date(0x6a68c2f0 * 1000).toISOString(),
        transcriptionCapability: "supported",
        candidateCount: 1,
        selectionReason: "singleCandidate",
        playbackState: "playing",
      },
    };
    const bilibili = {
      ...base,
      media: {
        ...xiaohongshu.media,
        pageURL: "https://www.bilibili.com/video/BV1nugX6VEgz/",
        canonicalURL: "https://www.bilibili.com/video/BV1nugX6VEgz",
        platform: "bilibili",
        ephemeralPlaybackURL: "https://upos-sz-estgoss.bilivideo.com/best.m4s?deadline=1784955384",
        mimeType: "audio/mp4",
        durationSeconds: 628.836,
        expiresAt: new Date(1784955384 * 1000).toISOString(),
      },
    };

    expect(validateCapture(xiaohongshu)).toBeNull();
    expect(validateCapture(bilibili)).toBeNull();
    // directFile 一旦带上 failureReason 就自相矛盾，schema 必须拒绝。
    expect(validateCapture({ ...xiaohongshu, media: { ...xiaohongshu.media, failureReason: "blob_or_mse" } }))
      .toBe("CAPTURE_SCHEMA_INVALID");
  });
});
