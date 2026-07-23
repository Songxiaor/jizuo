import { describe, expect, it } from "vitest";

import {
  classifyMediaSource,
  detectMediaInPage,
  selectMediaCandidate,
  type MediaCandidate,
} from "../src/content/media-detection";

function candidate(overrides: Partial<MediaCandidate> = {}): MediaCandidate {
  return {
    sourceURL: "https://media.example.test/video.mp4",
    mimeType: "video/mp4",
    playing: false,
    recentlyInteracted: false,
    visibleArea: 100,
    viewportCenterDistance: 20,
    playbackState: "paused",
    ...overrides,
  };
}

describe("generic media detection", () => {
  it("classifies direct files, HLS, blob/MSE, unloaded and unsupported media", () => {
    expect(classifyMediaSource("https://media.example.test/a.mp4", "video/mp4"))
      .toMatchObject({ kind: "directFile", transcriptionCapability: "supported" });
    expect(classifyMediaSource("https://media.example.test/master.m3u8", "application/vnd.apple.mpegurl"))
      .toMatchObject({ kind: "hls", transcriptionCapability: "conditional" });
    expect(classifyMediaSource("blob:https://example.test/session", "video/mp4"))
      .toEqual({ kind: "browserSessionOnly", transcriptionCapability: "unavailable", failureReason: "blob_or_mse" });
    expect(classifyMediaSource(undefined, undefined, { readyState: 0 }))
      .toEqual({ kind: "browserSessionOnly", transcriptionCapability: "unavailable", failureReason: "video_not_loaded" });
    expect(classifyMediaSource("https://media.example.test/a.webm", "video/webm"))
      .toEqual({ kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "unsupported_media_type" });
  });

  it("accepts bounded Douyin VOD hosts/play paths without extensions and rejects lookalike hosts", () => {
    expect(classifyMediaSource("https://video.douyinvod.com/signed-resource", undefined))
      .toMatchObject({ kind: "directFile", transcriptionCapability: "supported" });
    expect(classifyMediaSource("https://media.example.test/aweme/v1/web/play?video_id=fixture", undefined))
      .toMatchObject({ kind: "directFile", transcriptionCapability: "supported" });
    expect(classifyMediaSource("https://douyinvod.com.evil.example.test/signed-resource", undefined))
      .toEqual({ kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "unsupported_media_type" });
    expect(classifyMediaSource("https://evil-douyinvod.com.example.test/signed-resource", undefined))
      .toEqual({ kind: "unsupported", transcriptionCapability: "unavailable", failureReason: "unsupported_media_type" });
  });

  it("selects playing, then proven interaction, visible area, and viewport center", () => {
    expect(selectMediaCandidate([
      candidate({ visibleArea: 999, viewportCenterDistance: 1 }),
      candidate({ playing: true, playbackState: "playing", visibleArea: 10, viewportCenterDistance: 100 }),
    ])).toMatchObject({ index: 1, selectionReason: "playing" });

    expect(selectMediaCandidate([
      candidate({ visibleArea: 999 }),
      candidate({ recentlyInteracted: true, visibleArea: 1 }),
    ])).toMatchObject({ index: 1, selectionReason: "recentInteraction" });

    expect(selectMediaCandidate([
      candidate({ visibleArea: 10, viewportCenterDistance: 1 }),
      candidate({ visibleArea: 20, viewportCenterDistance: 100 }),
    ])).toMatchObject({ index: 1, selectionReason: "largestVisibleArea" });

    expect(selectMediaCandidate([
      candidate({ visibleArea: 20, viewportCenterDistance: 30 }),
      candidate({ visibleArea: 20, viewportCenterDistance: 5 }),
    ])).toMatchObject({ index: 1, selectionReason: "nearestViewportCenter" });
  });

  it("returns an explicit ambiguity instead of silently taking DOM order", () => {
    expect(selectMediaCandidate([
      candidate({ visibleArea: 20, viewportCenterDistance: 5 }),
      candidate({ visibleArea: 20, viewportCenterDistance: 5 }),
    ])).toEqual({ failureReason: "multiple_candidates", selectionReason: "ambiguous" });
  });

  it("rejects hostile oversized video collections before reading candidate geometry", () => {
    const hostileVideos = { length: 150_000 };
    const documentLike = {
      location: { href: "https://example.test/watch" },
      querySelectorAll: () => hostileVideos,
      querySelector: () => null,
    } as unknown as Document;
    expect(detectMediaInPage(documentLike)).toMatchObject({
      failureReason: "multiple_candidates",
      selectionReason: "ambiguous",
    });
    expect(detectMediaInPage(documentLike)?.candidateCount).toBeUndefined();
  });
});
