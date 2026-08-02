import { describe, expect, it } from "vitest";
import { makeAppError, type NativeResponse } from "../src/contract";
import {
  popupAvailability,
  popupBuildLabel,
  popupDiagnosticStatus,
  popupMediaStatus,
  popupMessageForResponse,
  popupMessageForSendResult,
  popupMetaChips,
  popupPlatformLabel,
  popupScaleLabel,
} from "../src/popup-presentation";
import type { DouyinSessionDiagnosticCode } from "../src/content/douyin-session-detail";

const knownCodes = [
  "PROTOCOL_VERSION_UNSUPPORTED", "CAPTURE_SCHEMA_INVALID", "CAPTURE_URL_UNSUPPORTED",
  "CAPTURE_CONTENT_EMPTY", "CAPTURE_PAYLOAD_TOO_LARGE", "CAPTURE_COUNT_MISMATCH",
  "NATIVE_RESPONSE_INVALID", "APP_UNAVAILABLE", "NATIVE_HOST_NOT_FOUND",
  "NATIVE_HOST_START_FAILED", "NATIVE_MESSAGE_TIMEOUT", "NATIVE_MESSAGE_FAILED",
  "STORAGE_UNAVAILABLE", "STORAGE_WRITE_FAILED", "STORAGE_FUTURE_SCHEMA",
  "STORAGE_MIGRATION_FAILED", "STORAGE_READ_ONLY", "STORAGE_INTEGRITY_FAILED",
  "STORAGE_STATE_CONFLICT", "CAPTURE_IDEMPOTENCY_CONFLICT", "RUN_IDEMPOTENCY_CONFLICT",
];

describe("popup error presentation", () => {
  it("uses fixed allowlisted layer-specific copy without raw wire fields", () => {
    for (const code of knownCodes) {
      const response: NativeResponse = { kind: "error", error: { ...makeAppError("req", "storage", code, true, "retry"), safeDetail: "sentinel-secret-path" } };
      const message = popupMessageForResponse(response)!;
      expect(message).not.toBe("操作未完成，请重试。");
      expect(message).not.toContain(code);
      expect(message).not.toContain("retry");
      expect(message).not.toContain("sentinel-secret-path");
    }
  });

  it("uses a generic fallback for unknown input", () => {
    const response: NativeResponse = { kind: "error", error: makeAppError("req", "unknown", "SENTINEL_RAW_CODE", false, "none") };
    expect(popupMessageForResponse(response)).toBe("操作未完成，请重试。");
  });

  it.each([
    ["extension_validation", "扩展校验"],
    ["native_response", "桌面响应"],
    ["native_transport", "原生通信"],
  ] as const)("shows only the safe code and fixed %s stage", (errorStage, stageLabel) => {
    const result = {
      response: {
        kind: "error" as const,
        error: {
          ...makeAppError("req", "network", "NATIVE_MESSAGE_FAILED", true, "retry"),
          safeDetail: "sentinel-private-path",
        },
      },
      errorStage,
    };
    const message = popupMessageForSendResult(result)!;
    expect(message).toContain(stageLabel);
    expect(message).toContain("NATIVE_MESSAGE_FAILED");
    expect(message).not.toContain("sentinel-private-path");
    expect(message).not.toContain("retry");
  });

  it("shows a human message for unsupported platforms (xhs / bilibili)", () => {
    const message = popupMessageForSendResult({
      response: {
        kind: "error",
        error: makeAppError("req", "protocol", "PLATFORM_NOT_SUPPORTED", false, "open_in_browser"),
      },
      errorStage: "extension_validation",
    })!;
    expect(message).toContain("PLATFORM_NOT_SUPPORTED");
    expect(message).toContain("暂不支持");
    expect(message).toContain("小红书");
  });

  it("does not echo an unknown wire code", () => {
    const message = popupMessageForSendResult({
      response: {
        kind: "error",
        error: makeAppError("req", "unknown", "SENTINEL_RAW_CODE", false, "none"),
      },
    })!;
    expect(message).toContain("UNKNOWN_SAFE_ERROR");
    expect(message).not.toContain("SENTINEL_RAW_CODE");
  });
});

describe("popup media preview", () => {
  it("shows capability and playback state using fixed safe labels", () => {
    expect(popupMediaStatus({ kind: "directFile", playbackState: "playing" })).toBe("已识别直连视频 · 正在播放");
    expect(popupMediaStatus({ kind: "hls", playbackState: "paused" })).toBe("已识别 HLS 视频 · 已暂停");
    expect(popupMediaStatus({ kind: "browserSessionOnly", failureReason: "blob_or_mse" })).toBe("仅浏览器可播：blob/MSE");
    expect(popupMediaStatus({ kind: "unsupported", failureReason: "multiple_candidates", candidateCount: 2 })).toBe("多个视频无法确定");
  });

  it("never interpolates unknown media data", () => {
    const status = popupMediaStatus({ kind: "unsupported", failureReason: "unknown" });
    expect(status).toBe("暂时无法移交此视频");
    expect(status).not.toContain("unknown");
  });

  it("uses a fixed Chinese label for every safe diagnostic code", () => {
    const codes: DouyinSessionDiagnosticCode[] = [
      "invalid_context", "id_before_after", "main_fetch_timeout", "main_fetch_network",
      "main_injection_failed", "http_403", "http_429", "http_other", "body_too_large",
      "body_unavailable", "json_invalid", "api_status", "detail_missing",
      "aweme_id_missing_or_nonstring", "aweme_id_mismatch", "video_missing", "no_candidates",
      "candidate_limit", "no_allowed_host",
    ];
    for (const code of codes) {
      const status = popupDiagnosticStatus({ code })!;
      expect(status.length).toBeGreaterThan(4);
      expect(status).not.toContain("undefined");
    }
  });

  it("shows a sanitized host only for no_allowed_host", () => {
    expect(popupDiagnosticStatus({ code: "no_allowed_host", blockedHost: "blocked.example" }))
      .toContain("blocked.example");
    expect(popupDiagnosticStatus({ code: "http_403", blockedHost: "must-not-render.example" }))
      .not.toContain("must-not-render.example");
    expect(popupDiagnosticStatus({ code: "no_allowed_host", blockedHost: "User@Blocked.Example/path?token=sentinel" }))
      .not.toContain("sentinel");
  });
});

describe("popup build label", () => {
  it("prefers version_name and falls back to stable version", () => {
    expect(popupBuildLabel({ version: "0.2.0", version_name: "0.2.0-session-diagnostic-r1" }))
      .toBe("构建 0.2.0-session-diagnostic-r1");
    expect(popupBuildLabel({ version: "0.2.0" })).toBe("构建 0.2.0");
  });
});

describe("popup availability", () => {
  it("no longer blocks Bilibili / Xiaohongshu now that they capture a text record", () => {
    expect(popupAvailability({ platform: "bilibili", completeness: "full_article" }).tone).not.toBe("blocked");
    expect(popupAvailability({ platform: "xiaohongshu", completeness: "full_article" }).tone).not.toBe("blocked");
  });

  it("marks a downloadable video capture", () => {
    const a = popupAvailability({
      platform: "douyin", completeness: "unknown",
      media: { kind: "directFile" },
    });
    expect(a.tone).toBe("video");
    expect(a.label).toContain("视频");
  });

  it("warns when the video is present but restricted", () => {
    expect(popupAvailability({
      platform: "douyin", completeness: "unknown",
      media: { kind: "browserSessionOnly", failureReason: "browser_session_required" },
    }).tone).toBe("warn");
  });

  it("distinguishes full / visible-only / selection", () => {
    expect(popupAvailability({ platform: "wechat", completeness: "full_article" }).tone).toBe("ready");
    expect(popupAvailability({ platform: "generic", completeness: "visible_only" }).tone).toBe("warn");
    expect(popupAvailability({ platform: "generic", completeness: "selection_only" }).label).toContain("选中");
  });
});

describe("popup scale label", () => {
  it("renders human word counts and reading time", () => {
    expect(popupScaleLabel(320, "full_article")).toBe("约 320 字 · 预计 1 分钟读完");
    expect(popupScaleLabel(3200, "full_article")).toBe("约 3.2k 字 · 预计 8 分钟读完");
    expect(popupScaleLabel(24000, "full_article")).toBe("约 24k 字 · 预计 60 分钟读完");
    expect(popupScaleLabel(500, "selection_only")).toBe("选中约 500 字");
  });
});

describe("popup platform label", () => {
  it("names the platform and content kind", () => {
    expect(popupPlatformLabel("wechat", 1)).toBe("微信公众号 · 文章");
    expect(popupPlatformLabel("douyin", 2)).toBe("抖音 · 视频");
    expect(popupPlatformLabel("generic", 1)).toBe("网页 · 文章");
  });
});

describe("popup meta chips", () => {
  it("splits word count and reading time into separate chips", () => {
    const chips = popupMetaChips({ characterCount: 3200, completeness: "full_article", version: 1 });
    expect(chips.map((c) => c.text)).toEqual(["约 3.2k 字", "约 8 分钟"]);
  });
  it("uses a single selection chip", () => {
    const chips = popupMetaChips({ characterCount: 500, completeness: "selection_only", version: 1 });
    expect(chips).toEqual([{ text: "选中约 500 字" }]);
  });
  it("appends a video chip toned as video", () => {
    const chips = popupMetaChips({
      characterCount: 100, completeness: "unknown", version: 2,
      media: { kind: "directFile" },
    });
    expect(chips.at(-1)).toEqual({ text: "🎬 可下载视频", tone: "video" });
  });
  it("marks a restricted video without claiming it is downloadable", () => {
    const chips = popupMetaChips({
      characterCount: 100, completeness: "unknown", version: 2,
      media: { kind: "browserSessionOnly", failureReason: "browser_session_required" },
    });
    expect(chips.at(-1)).toEqual({ text: "🎬 仅浏览器可播", tone: "video" });
  });
  it("shows an image-post chip instead of a video chip", () => {
    const chips = popupMetaChips({
      characterCount: 100, completeness: "unknown", version: 2,
      media: { kind: "browserSessionOnly", failureReason: "blob_or_mse" },
      imageCount: 5,
    });
    expect(chips.at(-1)).toEqual({ text: "🖼 5 张图" });
    expect(chips.some((chip) => chip.text.includes("视频"))).toBe(false);
  });
});

describe("X videos resolved by the desktop app", () => {
  it("does not call a blob/MSE X video restricted, because the app fetches it", () => {
    const preview = {
      platform: "x" as const,
      completeness: "full_article" as const,
      media: { kind: "browserSessionOnly" as const, failureReason: "blob_or_mse" as const },
    };
    expect(popupAvailability(preview)).toEqual({ tone: "video", label: "可捕获 · 视频由 App 获取" });
    const chips = popupMetaChips({ ...preview, characterCount: 525, version: 2 });
    expect(chips.at(-1)).toEqual({ text: "🎬 视频由 App 获取", tone: "video" });
    expect(chips.some((chip) => chip.text.includes("受限"))).toBe(false);
  });

  it("keeps other platforms and other failure reasons on the restricted wording", () => {
    // 抖音的 blob/MSE 没有这条补救路径，仍旧如实说受限。
    expect(popupAvailability({
      platform: "douyin", completeness: "full_article",
      media: { kind: "browserSessionOnly", failureReason: "blob_or_mse" },
    })).toEqual({ tone: "warn", label: "可捕获正文 · 视频受限" });
    // X 的其它失败原因（如 DRM）不在补救范围内。
    expect(popupAvailability({
      platform: "x", completeness: "full_article",
      media: { kind: "unsupported", failureReason: "drm_or_encrypted" },
    })).toEqual({ tone: "warn", label: "可捕获正文 · 视频受限" });
  });
});

describe("douyin image posts (图文帖)", () => {
  it("names the post 图文 rather than 视频 or 文章", () => {
    expect(popupPlatformLabel("douyin", 2, 5)).toBe("抖音 · 图文");
    expect(popupPlatformLabel("douyin", 1, 3)).toBe("抖音 · 图文");
    // Zero images is a video post, not an empty gallery.
    expect(popupPlatformLabel("douyin", 2, 0)).toBe("抖音 · 视频");
    expect(popupPlatformLabel("douyin", 2)).toBe("抖音 · 视频");
  });
  it("reports an image post as ready, never as a restricted video", () => {
    const availability = popupAvailability({
      platform: "douyin",
      completeness: "full_article",
      media: { kind: "browserSessionOnly", failureReason: "blob_or_mse" },
      imageCount: 4,
    });
    expect(availability).toEqual({ tone: "ready", label: "可捕获 · 图文 4 张" });
  });
});
