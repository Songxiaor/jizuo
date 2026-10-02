import { describe, expect, it } from "vitest";
import { makeAppError, type NativeResponse } from "../src/contract";
import {
  popupAvailability,
  popupActionPresentation,
  popupBuildLabel,
  popupDiagnosticStatus,
  popupMediaStatus,
  popupMessageForResponse,
  popupMessageForSendResult,
  popupPreviewFailure,
  popupRecoveryForSendResult,
  popupMetaChips,
  popupPlatformLabel,
  popupStats,
  popupDuration,
  popupSourceLine,
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
  it("explains pre-envelope quality failures without exposing page text", () => {
    expect(popupPreviewFailure("Error: CAPTURE_APP_SHELL")).toEqual({
      title: "这是网页应用的界面，不是一篇文章",
      message: "当前页面是已登录的网页应用界面，不是独立文章。请选中需要保存的正文后再打开扩展。",
      steps: ["打开具体的一篇文章或一条内容再点扩展", "或者先选中要保存的文字，再点扩展"],
      canReload: false,
    });
    expect(popupPreviewFailure("CAPTURE_LOGIN_WALL").steps.join("")).toContain("站点登录");
    expect(popupPreviewFailure("unknown").steps.length).toBeGreaterThan(0);
    expect(popupPreviewFailure("CAPTURE_PAGE_LOAD_FAILED")).toMatchObject({ canReload: true });
    expect(popupPreviewFailure("CAPTURE_LOGIN_WALL").message).toContain("登录页");
    expect(popupPreviewFailure("CAPTURE_SECURITY_CHALLENGE").message).toContain("安全验证");
    expect(popupPreviewFailure("CAPTURE_NAVIGATION_ONLY").message).toContain("导航内容");
    expect(popupPreviewFailure("CAPTURE_CONTENT_EMPTY").canReload).toBe(true);
    expect(popupPreviewFailure("sentinel-private-page-text").message)
      .not.toContain("sentinel-private-page-text");
  });

  it("maps every action to explicit outcome copy", () => {
    expect(popupActionPresentation("save").button).toBe("保存到汲作");
    expect(popupActionPresentation("summarize").detail).toContain("写一份总结");
    expect(popupActionPresentation("translate").success).toContain("准备翻译");
  });

  it("reduces native failures to one primary recovery action", () => {
    const openApp = popupRecoveryForSendResult({
      response: { kind: "error", error: makeAppError("req", "network", "APP_UNAVAILABLE", true, "open_app") },
    });
    // 连不上汲作：自动重试用完后给「打开汲作并重试」，不再叫用户自己完全退出重开（2026-10-01）。
    expect(openApp).toMatchObject({ action: "open_app_retry", label: "打开汲作并重试" });
    expect(openApp?.message).not.toContain("完全退出");

    const appAsks = popupRecoveryForSendResult({
      response: { kind: "error", error: makeAppError("req", "storage", "STORAGE_UNAVAILABLE", true, "open_app") },
    });
    expect(appAsks).toMatchObject({ action: "open_app", label: "前往汲作处理" });

    for (const code of ["NATIVE_MESSAGE_FAILED", "NATIVE_MESSAGE_TIMEOUT"]) {
      const transport = popupRecoveryForSendResult({
        response: { kind: "error", error: makeAppError("req", "network", code, true, "retry") },
      });
      expect(transport).toMatchObject({ action: "open_app_retry" });
    }

    const install = popupRecoveryForSendResult({
      response: { kind: "error", error: makeAppError("req", "network", "NATIVE_HOST_NOT_FOUND", false, "open_install_guide") },
    });
    expect(install).toMatchObject({ action: "open_settings" });

    const upgrade = popupRecoveryForSendResult({
      response: { kind: "error", error: makeAppError("req", "protocol", "PROTOCOL_VERSION_UNSUPPORTED", false, "upgrade_app") },
    });
    expect(upgrade).toMatchObject({ action: "open_app", label: "打开汲作检查更新" });
    expect(upgrade?.message).toContain("检查更新");
  });
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
    // 小红书、B 站早已支持，提示里不能再说它们「开发中」（2026-10-01）。
    expect(message).not.toContain("小红书");
    expect(message).toContain("添加链接");
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
      .toBe("版本 0.2.0-session-diagnostic-r1");
    expect(popupBuildLabel({ version: "0.2.0" })).toBe("版本 0.2.0");
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
    expect(popupPlatformLabel("wechat", 1)).toBe("公众号 · 文章");
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
    expect(popupAvailability(preview)).toEqual({ tone: "video", label: "可以保存 · 视频由汲作获取" });
    const chips = popupMetaChips({ ...preview, characterCount: 525, version: 2 });
    expect(chips.at(-1)).toEqual({ text: "🎬 视频由汲作获取", tone: "video" });
    expect(chips.some((chip) => chip.text.includes("受限"))).toBe(false);
  });

  it("keeps other platforms and other failure reasons on the restricted wording", () => {
    // 抖音的 blob/MSE 没有这条补救路径，仍旧如实说受限。
    expect(popupAvailability({
      platform: "douyin", completeness: "full_article",
      media: { kind: "browserSessionOnly", failureReason: "blob_or_mse" },
    })).toEqual({ tone: "warn", label: "只能存正文 · 视频受限" });
    // X 的其它失败原因（如 DRM）不在补救范围内。
    expect(popupAvailability({
      platform: "x", completeness: "full_article",
      media: { kind: "unsupported", failureReason: "drm_or_encrypted" },
    })).toEqual({ tone: "warn", label: "只能存正文 · 视频受限" });
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
    expect(availability).toEqual({ tone: "ready", label: "可以保存 · 图文 4 张" });
  });
});

describe("popup source card (2026-09-29 重构)", () => {
  it("lists article stats: characters, images, reading time and completeness", () => {
    expect(popupStats({ characterCount: 778, completeness: "full_article", version: 1, imageCount: 3 })).toEqual([
      { value: "778", label: "字" },
      { value: "3", label: "张图" },
      { value: "2 分钟", label: "读完" },
      { value: "完整", label: "读取" },
    ]);
    expect(popupStats({ characterCount: 500, completeness: "selection_only", version: 1 })).toEqual([
      { value: "500", label: "字（选中）" },
      { value: "选中", label: "读取" },
    ]);
  });

  it("lists video stats: duration, video state and text", () => {
    expect(popupStats({
      characterCount: 312, completeness: "full_article", version: 2, platform: "douyin",
      media: { kind: "directFile" }, mediaDurationSeconds: 252,
    })).toEqual([
      { value: "4:12", label: "视频时长" },
      { value: "可转写", label: "视频" },
      { value: "312", label: "字正文" },
    ]);
  });

  it("formats durations and the source line", () => {
    expect(popupDuration(56)).toBe("0:56");
    expect(popupDuration(3725)).toBe("1:02:05");
    expect(popupSourceLine("x", 1, undefined, "x.com")).toBe("X · 帖子 · x.com");
    expect(popupSourceLine("x", 2, undefined, "x.com")).toBe("X · 视频 · x.com");
    expect(popupSourceLine("zhihu", 1, undefined, "zhihu.com")).toBe("知乎 · 回答 · zhihu.com");
    expect(popupSourceLine("zhihu", 1, undefined, "zhuanlan.zhihu.com")).toBe("知乎 · 文章 · zhuanlan.zhihu.com");
    expect(popupSourceLine("douyin", 2)).toBe("抖音 · 视频");
  });
});

describe("popup byline and engagement (2026-09-29 frontmatter)", () => {
  it("writes ISO publish time as a local month-day and keeps other formats", async () => {
    const { popupBylineText, popupPublishedLabel } = await import("../src/popup-presentation");
    const now = new Date("2026-09-29T10:00:00");
    expect(popupPublishedLabel("2026-01-07 21:53・北京", now)).toBe("1月7日 21:53 · 北京");
    expect(popupPublishedLabel("发布于 3 天前", now)).toBe("发布于 3 天前");
    expect(popupPublishedLabel(new Date(2026, 8, 28, 20, 53).toISOString(), now)).toBe("9月28日 20:53");
    expect(popupPublishedLabel(new Date(2025, 0, 2, 8, 0).toISOString(), now)).toBe("2025年1月2日");
    expect(popupPublishedLabel("2026-09-27 18:54:11", now)).toBe("9月27日 18:54");
    expect(popupPublishedLabel("2026-09-27 06:00", now)).toBe("9月27日 6:00");
    expect(popupPublishedLabel("2025-03-01", now)).toBe("2025年3月1日");
    expect(popupBylineText("卡兹克", undefined)).toBe("卡兹克");
    expect(popupBylineText(undefined, undefined)).toBe("");
  });

  it("gives likes and comments the completeness cell when the read was complete", () => {
    expect(popupStats({
      characterCount: 779, completeness: "full_article", version: 1,
      engagement: { likes: "437", comments: "100", shares: "71" },
    })).toEqual([
      { value: "779", label: "字" },
      { value: "2 分钟", label: "读完" },
      { value: "437", label: "赞" },
      { value: "100", label: "评论" },
    ]);
  });
});

describe("process seal chain (2026-09-29 第二批)", () => {
  it("lights the steps the App runs automatically and greys out what this page cannot use", async () => {
    const { popupStepChain, popupChainSummary } = await import("../src/popup-presentation");
    const chain = popupStepChain({ autoSteps: ["record", "summary", "translation"], hasVideo: false, comments: "auto", selectedAction: "save" });
    expect(chain.map((seal) => [seal.key, seal.style, seal.label])).toEqual([
      ["ji", "stamped", "收集"],
      ["record", "na", "无视频"],
      ["proof", "na", "无需"],
      ["comments", "stamped", "评论"],
      ["summary", "stamped", "总结"],
      ["translation", "stamped", "译标题"],
      ["mindMap", "pending", "脑图"],
    ]);
    expect(popupChainSummary(chain, true)).toBe("保存后自动：评论、总结、译标题。点空心的「摘」「译」，这次也做。");
  });

  it("lets 摘 and 译 be requested for this save only", async () => {
    const { popupStepChain } = await import("../src/popup-presentation");
    const summarize = popupStepChain({ hasVideo: true, comments: "unsupported", selectedAction: "summarize" });
    expect(summarize.find((seal) => seal.key === "summary")).toEqual({ key: "summary", style: "stamped", label: "这次做", toggles: "summarize" });
    expect(summarize.find((seal) => seal.key === "record")?.style).toBe("pending");
    expect(summarize.find((seal) => seal.key === "comments")?.style).toBe("na");
    const translate = popupStepChain({ autoSteps: ["translation"], hasVideo: true, comments: "picker", selectedAction: "translate" });
    expect(translate.find((seal) => seal.key === "translation")?.label).toBe("译全文");
    expect(translate.find((seal) => seal.key === "comments")?.label).toBe("手挑");
  });

  it("lists progress with waiting and manual steps, skipping transcription without video", async () => {
    const { popupStepProgress, popupSavedAtLabel } = await import("../src/popup-presentation");
    const rows = popupStepProgress({
      steps: [{ step: "comments", state: "done", detail: "存了 20 条" }, { step: "summary", state: "running" }],
      expected: new Set(["comments", "summary", "translation"]),
      hasVideo: false,
    });
    expect(rows.map((row) => [row.key, row.state, row.text])).toEqual([
      ["comments", "done", "存了 20 条"],
      ["summary", "running", "进行中"],
      ["translation", "waiting", "等着做"],
      ["mindMap", "manual", "还没做 · 在汲作里点"],
    ]);
    const now = new Date(2026, 8, 29, 12, 0);
    expect(popupSavedAtLabel(new Date(2026, 8, 29, 9, 5).getTime(), now)).toBe("今天 9:05 存的");
    expect(popupSavedAtLabel(new Date(2026, 8, 27, 20, 39).getTime(), now)).toBe("9月27日 20:39 存的");
    expect(popupSavedAtLabel(undefined, now)).toBe("");
  });
});

describe("image posts with little text (2026-09-29)", () => {
  it("drops the word count and reading time when an image post has only a line or two", () => {
    const stats = popupStats({ characterCount: 4, completeness: "full_article", version: 2, imageCount: 4, engagement: { likes: "135", comments: "3" } });
    expect(stats.map((stat) => stat.label)).toEqual(["张图", "赞", "评论"]);
  });
});

describe("youtube and big numbers (2026-09-29)", () => {
  it("calls a YouTube capture a video that uses captions, and shortens big counts", async () => {
    const { popupCountLabel, popupStepChain } = await import("../src/popup-presentation");
    expect(popupSourceLine("youtube", 1, undefined, "youtube.com")).toBe("YouTube · 视频 · youtube.com");
    const chain = popupStepChain({ hasVideo: false, usesCaptions: true, comments: "auto", selectedAction: "save" });
    expect(chain.find((seal) => seal.key === "record")?.label).toBe("用字幕");
    const loading = popupStepChain({ hasVideo: undefined, comments: "unknown", selectedAction: "save" });
    expect(loading.filter((seal) => seal.key === "record" || seal.key === "proof").map((seal) => seal.label)).toEqual(["待确认", "待确认"]);
    expect(popupCountLabel("563472")).toBe("56.3万");
    expect(popupCountLabel("24543329")).toBe("2454万");
    expect(popupCountLabel("120000000")).toBe("1.2亿");
    expect(popupCountLabel("8853")).toBe("8853");
    expect(popupCountLabel("1.2万")).toBe("1.2万");
  });
});

describe("x profile heading (2026-09-29)", () => {
  it("names whose profile it is from the tab title", async () => {
    const { popupXProfileHeading } = await import("../src/popup-presentation");
    expect(popupXProfileHeading("(1) 数字生命卡兹克 (@Khazix0918) / X", "https://x.com/Khazix0918")).toEqual({ name: "数字生命卡兹克", handle: "@Khazix0918" });
    expect(popupXProfileHeading("X", "https://x.com/Khazix0918")).toEqual({ name: "@Khazix0918", handle: "@Khazix0918" });
  });
});

describe("english word counts (2026-09-29)", () => {
  it("shows words and an English reading pace instead of characters", () => {
    const stats = popupStats({ characterCount: 48_000, wordCount: 8_100, completeness: "full_article", version: 1 });
    expect(stats.slice(0, 2)).toEqual([{ value: "8.1k", label: "词" }, { value: "35 分钟", label: "读完" }]);
  });
});

describe("translation not needed (2026-09-29)", () => {
  it("greys out translation for Chinese items, but not for videos still waiting for a transcript", async () => {
    const { popupStepProgress } = await import("../src/popup-presentation");
    const steps = [{ step: "translation", state: "notNeeded" as const, detail: "原文已是中文" }];
    const article = popupStepProgress({ steps, expected: new Set(), hasVideo: false });
    expect(article.find((row) => row.key === "translation")).toMatchObject({ state: "na", text: "原文已是中文 · 用不上" });
    const untranscribed = popupStepProgress({ steps, expected: new Set(), hasVideo: true });
    expect(untranscribed.find((row) => row.key === "translation")?.state).toBe("manual");
    const transcribed = popupStepProgress({ steps: [{ step: "record", state: "done" }, ...steps], expected: new Set(), hasVideo: true });
    expect(transcribed.find((row) => row.key === "translation")?.state).toBe("na");
  });
});

describe("browser-internal pages (2026-09-29)", () => {
  it("explains browser pages without offering a pointless reload", async () => {
    const { popupBrowserPageFailure } = await import("../src/popup-presentation");
    expect(popupBrowserPageFailure("ego://version")).toMatchObject({ title: "浏览器自己的页面读不了", canReload: false });
    expect(popupBrowserPageFailure("chrome://extensions")?.steps).toHaveLength(2);
    expect(popupBrowserPageFailure("https://x.com/a")).toBeNull();
    expect(popupBrowserPageFailure(undefined)).toBeNull();
    // 拿不到网址时靠注入失败的原话认出浏览器页面，不叫人刷新重试。
    expect(popupPreviewFailure("Cannot access a chrome:// URL")).toMatchObject({ title: "浏览器自己的页面读不了", canReload: false });
    expect(popupPreviewFailure("The extensions gallery cannot be scripted.").canReload).toBe(false);
    expect(popupPreviewFailure("unknown").message).not.toContain("刷新");
  });
});

describe("page translation notice (2026-10-02)", () => {
  it("names the translator and gives a way to keep the original", async () => {
    const { popupTranslationNote } = await import("../src/popup-presentation");
    const note = popupTranslationNote("X 自动翻译");
    expect(note).toContain("X 自动翻译");
    expect(note).toContain("显示原文");
    expect(note).toContain("译文");
    expect(note).toContain("原文");
  });
});

describe("comment login wall note (2026-10-02)", () => {
  it("says only the logged-out part was read, and explains Xiaohongshu's one-login rule", async () => {
    const { commentLoginWallNote } = await import("../src/popup-presentation");
    const xhs = commentLoginWallNote("xiaohongshu", 11, 20);
    expect(xhs).toContain("未登录可见的 11 条");
    expect(xhs).toContain("读满 20 条");
    expect(xhs).toContain("只保留一处登录");
    expect(commentLoginWallNote("reddit", 5, 20)).not.toContain("小红书");
  });
});
