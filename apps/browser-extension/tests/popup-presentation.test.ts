import { describe, expect, it } from "vitest";
import { makeAppError, type NativeResponse } from "../src/contract";
import {
  popupBuildLabel,
  popupDiagnosticStatus,
  popupMediaStatus,
  popupMessageForResponse,
  popupMessageForSendResult,
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
