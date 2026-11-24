import { afterEach, describe, expect, it, vi } from "vitest";

afterEach(() => vi.unstubAllGlobals());

describe("live room injection", () => {
  it("reads douyin room data in the MAIN world", async () => {
    const calls: Array<Record<string, unknown>> = [];
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ id: 7, url: "https://live.douyin.com/427518068747" }) },
      scripting: {
        executeScript: vi.fn(async (options: Record<string, unknown>) => {
          calls.push(options);
          return [{
            result: {
              pageURL: "https://live.douyin.com/427518068747",
              roomID: "427518068747",
              anchorName: "示例主播",
              title: "示例直播",
              variants: [
                { quality: "origin", container: "hls", url: "https://pull.example.test/a.m3u8", label: "蓝光" },
                { quality: "hd", container: "flv", url: "https://pull.example.test/a_hd.flv", label: "高清" },
              ],
            },
          }];
        }),
      },
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.resetModules();
    const { liveRoomInfo } = await import("../src/entrypoints/background");
    const info = await liveRoomInfo(7);
    expect(calls[0]?.world).toBe("MAIN");
    expect(calls[0]?.files).toEqual(["/douyin-live.js"]);
    expect(info).toMatchObject({ ok: true, platform: "douyin", roomID: "427518068747" });
  });

  it("reads xiaohongshu room data in the MAIN world", async () => {
    const calls: Array<Record<string, unknown>> = [];
    vi.stubGlobal("browser", {
      tabs: {
        get: vi.fn().mockResolvedValue({
          id: 7,
          url: "https://www.xiaohongshu.com/livestream/570537012912716275",
        }),
      },
      scripting: {
        executeScript: vi.fn(async (options: Record<string, unknown>) => {
          calls.push(options);
          return [{
            result: {
              pageURL: "https://www.xiaohongshu.com/livestream/570537012912716275",
              roomID: "570537012912716275",
              anchorName: "cc",
              variants: [{ quality: "origin", container: "flv", url: "https://pull.example.test/a.flv" }],
            },
          }];
        }),
      },
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.resetModules();
    const { liveRoomInfo } = await import("../src/entrypoints/background");
    const info = await liveRoomInfo(7);
    expect(calls[0]?.world).toBe("MAIN");
    expect(calls[0]?.files).toEqual(["/xiaohongshu-live.js"]);
    expect(info).toMatchObject({ ok: true, platform: "xiaohongshu", roomID: "570537012912716275" });
  });

  it("passes the anchor identity, avatar and profile URL to the native app", async () => {
    let sent: Record<string, unknown> | undefined;
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ id: 7, url: "https://live.douyin.com/427518068747" }) },
      scripting: {
        executeScript: vi.fn(async () => [{
          result: {
            pageURL: "https://live.douyin.com/427518068747",
            roomID: "427518068747",
            anchorName: "示例主播",
            anchorID: "SEC_demo",
            anchorAvatarURL: "https://avatar.example.test/anchor.jpg",
            anchorProfileURL: "https://www.douyin.com/user/SEC_demo",
            title: "示例直播",
            variants: [
              { quality: "origin", container: "hls", url: "https://pull.example.test/a.m3u8", label: "蓝光" },
            ],
          },
        }]),
      },
      runtime: {
        sendNativeMessage: vi.fn(async (_host: string, message: Record<string, unknown>) => {
          sent = message;
          return {
            kind: "liveRecordingAccepted",
            version: 1,
            requestId: message.requestId,
            recordingID: "rec-12345678",
          };
        }),
      },
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.stubGlobal("crypto", { randomUUID: () => "fixed-id" });
    vi.resetModules();
    const { startLiveRecording } = await import("../src/entrypoints/background");
    const result = await startLiveRecording(7, "origin");
    expect(result).toMatchObject({ ok: true, quality: "origin" });
    expect(sent).toMatchObject({
      anchorName: "示例主播",
      anchorID: "SEC_demo",
      anchorAvatarURL: "https://avatar.example.test/anchor.jpg",
      anchorProfileURL: "https://www.douyin.com/user/SEC_demo",
    });
  });
});
