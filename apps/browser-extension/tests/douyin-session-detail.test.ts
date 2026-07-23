import { afterEach, describe, expect, it, vi } from "vitest";

import {
  fetchDouyinSessionDetailInMainWorld,
  isAllowedDouyinPlaybackURL,
} from "../src/content/douyin-session-detail";

const awemeId = "7655224917603994914";
const highURL = "https://v3.douyinvod.com/video/high.mp4?token=temporary";
const lowURL = "https://cdn.douyincdn.com/video/low.mp4";

function stubLocation(rawURL = `https://www.douyin.com/video/${awemeId}`) {
  const parsed = new URL(rawURL);
  const value = { href: parsed.href, origin: parsed.origin };
  vi.stubGlobal("location", value);
  return value;
}

function detailPayload(overrides: Record<string, unknown> = {}) {
  return {
    status_code: 0,
    aweme_detail: {
      aweme_id: awemeId,
      video: {
        bit_rate: [
          { bit_rate: 800, play_addr: { url_list: [lowURL] } },
          { bit_rate: 1800, play_addr: { url_list: [highURL, highURL] } },
        ],
        play_addr: { url_list: [lowURL] },
      },
    },
    ...overrides,
  };
}

function jsonResponse(value: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(value), { status: 200, ...init });
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("Douyin MAIN-world session detail fallback", () => {
  it("uses one exact same-origin request and returns only the best safe URL", async () => {
    stubLocation();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(detailPayload()));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({
      ok: true,
      playbackURL: highURL,
      candidateCount: 2,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [rawURL, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    const requestURL = new URL(rawURL);
    expect(`${requestURL.origin}${requestURL.pathname}`).toBe("https://www.douyin.com/aweme/v1/web/aweme/detail/");
    expect([...requestURL.searchParams.entries()]).toEqual([
      ["aweme_id", awemeId],
      ["aid", "6383"],
      ["device_platform", "webapp"],
      ["version_name", "23.5.0"],
      ["os_name", "mac"],
    ]);
    expect(options).toMatchObject({
      method: "GET",
      headers: { Accept: "application/json, text/plain, */*" },
      credentials: "same-origin",
      mode: "same-origin",
      redirect: "error",
      cache: "no-store",
    });
    expect(options.signal).toBeInstanceOf(AbortSignal);
  });

  it("aborts after five seconds and returns no error detail", async () => {
    vi.useFakeTimers();
    stubLocation();
    vi.stubGlobal("fetch", vi.fn((_url: string, options: RequestInit) => new Promise((_resolve, reject) => {
      options.signal?.addEventListener("abort", () => reject(new DOMException("private sentinel", "AbortError")));
    })));

    const result = fetchDouyinSessionDetailInMainWorld(awemeId);
    await vi.advanceTimersByTimeAsync(5_000);
    await expect(result).resolves.toEqual({ ok: false, code: "main_fetch_timeout" });
  });

  it("keeps the timeout code when headers arrive but the response body stalls", async () => {
    vi.useFakeTimers();
    stubLocation();
    vi.stubGlobal("fetch", vi.fn(async (_url: string, options: RequestInit) => new Response(
      new ReadableStream({
        start(streamController) {
          options.signal?.addEventListener("abort", () => {
            streamController.error(new DOMException("private body timeout sentinel", "AbortError"));
          });
        },
      }),
      { status: 200 },
    )));

    const result = fetchDouyinSessionDetailInMainWorld(awemeId);
    await vi.advanceTimersByTimeAsync(5_000);
    await expect(result).resolves.toEqual({ ok: false, code: "main_fetch_timeout" });
  });

  it("rejects declared and streamed bodies above two MiB", async () => {
    stubLocation();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(jsonResponse(detailPayload(), {
      headers: { "content-length": String(2 * 1024 * 1024 + 1) },
    })).mockResolvedValueOnce(new Response(new Uint8Array(2 * 1024 * 1024 + 1), { status: 200 })));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "body_too_large" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "body_too_large" });
  });

  it("fails closed on non-200, malformed JSON, and nonzero status_code", async () => {
    stubLocation();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response("{}", { status: 403 }))
      .mockResolvedValueOnce(new Response("not-json", { status: 200 }))
      .mockResolvedValueOnce(jsonResponse(detailPayload({ status_code: 1 }))));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "http_403" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "json_invalid" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "api_status" });
  });

  it("requires the locked string aweme_id in the response", async () => {
    stubLocation();
    const wrong = detailPayload();
    (wrong.aweme_detail as Record<string, unknown>).aweme_id = "7123456789012345678";
    const numeric = detailPayload();
    (numeric.aweme_detail as Record<string, unknown>).aweme_id = Number(awemeId);
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(jsonResponse(wrong))
      .mockResolvedValueOnce(jsonResponse(numeric)));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "aweme_id_mismatch" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "aweme_id_missing_or_nonstring" });
  });

  it("requires the same current URL identity before and after fetch", async () => {
    const locationValue = stubLocation();
    const fetchMock = vi.fn().mockImplementation(async () => {
      locationValue.href = "https://www.douyin.com/video/7123456789012345678";
      return jsonResponse(detailPayload());
    });
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "id_before_after" });
    locationValue.href = "https://www.douyin.com/video/7123456789012345678";
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "id_before_after" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("caps raw candidates at 256 before returning a single URL", async () => {
    stubLocation();
    const tooMany = detailPayload();
    const video = (tooMany.aweme_detail as { video: Record<string, unknown> }).video;
    video.bit_rate = [{
      bit_rate: 1,
      play_addr: { url_list: Array.from({ length: 257 }, (_, index) => `https://v3.douyinvod.com/${index}.mp4`) },
    }];
    video.play_addr = { url_list: [] };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(tooMany)));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "candidate_limit" });
  });

  it("uses descending bitrate with stable URL order and de-duplication", async () => {
    stubLocation();
    const payload = detailPayload();
    const video = (payload.aweme_detail as { video: Record<string, unknown> }).video;
    video.bit_rate = [
      { bit_rate: 1000, play_addr: { url_list: [lowURL] } },
      { bit_rate: 2000, play_addr: { url_list: [highURL, lowURL] } },
      { bit_rate: 2000, play_addr: { url_list: ["https://v6.douyinvod.com/equal.mp4"] } },
    ];
    video.play_addr = { url_list: [highURL] };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(payload)));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({
      ok: true,
      playbackURL: highURL,
      candidateCount: 3,
    });
  });

  it("accepts every observed safe detail wrapper with missing or zero status_code", async () => {
    stubLocation();
    const detail = (detailPayload().aweme_detail as Record<string, unknown>);
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(jsonResponse({ aweme_detail: detail }))
      .mockResolvedValueOnce(jsonResponse({ status_code: 0, aweme: detail }))
      .mockResolvedValueOnce(jsonResponse({ data: { aweme_detail: detail } }))
      .mockResolvedValueOnce(jsonResponse({ status_code: 0, data: detail })));

    for (let index = 0; index < 4; index += 1) {
      await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toMatchObject({
        ok: true,
        playbackURL: highURL,
      });
    }
  });

  it("rejects a nested nonzero status and skips an empty earlier wrapper", async () => {
    stubLocation();
    const detail = detailPayload().aweme_detail as Record<string, unknown>;
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(jsonResponse({ data: { ...detail, status_code: 1 } }))
      .mockResolvedValueOnce(jsonResponse({ aweme_detail: {}, aweme: detail })));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "api_status" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toMatchObject({
      ok: true,
      playbackURL: highURL,
    });
  });

  it("returns fixed context, network, HTTP, body, and missing-detail codes", async () => {
    stubLocation("https://example.test/video/7655224917603994914");
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({
      ok: false, code: "invalid_context",
    });

    stubLocation();
    vi.stubGlobal("fetch", vi.fn()
      .mockRejectedValueOnce(new Error("private network error"))
      .mockResolvedValueOnce(new Response("{}", { status: 429 }))
      .mockResolvedValueOnce(new Response("{}", { status: 500 }))
      .mockResolvedValueOnce({ status: 200, headers: new Headers(), body: null } as Response)
      .mockResolvedValueOnce(jsonResponse({ status_code: 0 }))
      .mockResolvedValueOnce(jsonResponse({ aweme_detail: { aweme_id: awemeId } })));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "main_fetch_network" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "http_429" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "http_other" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "body_unavailable" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "detail_missing" });
    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "video_missing" });
  });

  it("distinguishes no candidates from a blocked host and returns at most one sanitized hostname", async () => {
    stubLocation();
    const noCandidates = detailPayload();
    const noCandidateVideo = (noCandidates.aweme_detail as { video: Record<string, unknown> }).video;
    noCandidateVideo.bit_rate = [];
    noCandidateVideo.play_addr = { url_list: [] };
    const blocked = detailPayload();
    const blockedVideo = (blocked.aweme_detail as { video: Record<string, unknown> }).video;
    blockedVideo.bit_rate = [{
      bit_rate: 1,
      play_addr: { url_list: [
        "https://DouyinVod.com.evil.test/private/path.mp4?token=do-not-return",
        "https://other.evil.test/second.mp4",
      ] },
    }];
    blockedVideo.play_addr = { url_list: [] };
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(jsonResponse(noCandidates))
      .mockResolvedValueOnce(jsonResponse(blocked)));

    await expect(fetchDouyinSessionDetailInMainWorld(awemeId)).resolves.toEqual({ ok: false, code: "no_candidates" });
    const diagnostic = await fetchDouyinSessionDetailInMainWorld(awemeId);
    expect(diagnostic).toEqual({ ok: false, code: "no_allowed_host", blockedHost: "douyinvod.com.evil.test" });
    expect(JSON.stringify(diagnostic)).not.toContain("private/path");
    expect(JSON.stringify(diagnostic)).not.toContain("token");
    expect(JSON.stringify(diagnostic)).not.toContain("second.mp4");
  });
});

describe("Douyin playback URL allowlist", () => {
  it.each([
    "https://douyinvod.com/a.mp4",
    "https://v3.douyinvod.com/a.mp4?token=temporary",
    "https://douyincdn.com/a.mp4",
    "https://cdn.douyincdn.com/a.mp4",
    "https://www.douyin.com/aweme/v1/play/?video_id=1",
    "https://douyin.com/aweme/v1/web/play/?video_id=1",
  ])("allows %s", (url) => expect(isAllowedDouyinPlaybackURL(url)).toBe(true));

  it.each([
    "http://v3.douyinvod.com/a.mp4",
    "https://douyinvod.com.evil.test/a.mp4",
    "https://evil-douyinvod.com/a.mp4",
    "https://user@v3.douyinvod.com/a.mp4",
    "https://v3.douyinvod.com:444/a.mp4",
    "https://v3.douyinvod.com/a.mp4#fragment",
    "https://127.0.0.1/a.mp4",
    "https://localhost/a.mp4",
    "https://www.douyin.com/aweme/v1/web/aweme/detail/",
    "https://www.douyin.com/aweme/v1/play/extra",
  ])("rejects %s", (url) => expect(isAllowedDouyinPlaybackURL(url)).toBe(false));
});
