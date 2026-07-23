import type { MediaDescriptor, NativeResponse } from "./contract";
import type { DouyinSessionDiagnostic, DouyinSessionDiagnosticCode } from "./content/douyin-session-detail";
import type {
  DouyinMetadataDiagnostic,
  DouyinMetadataRouteRejectCode,
  DouyinMetadataScopeRejectCode,
  DouyinMetadataSSRLimitCode,
  DouyinMetadataSSRRejectCode,
  DouyinMetadataVideoRejectCode,
} from "./content/douyin-metadata-diagnostic";

const knownErrorMessages: Readonly<Record<string, string>> = {
  PROTOCOL_VERSION_UNSUPPORTED: "扩展与 LinkDigest 版本不兼容，请升级后重试。",
  CAPTURE_SCHEMA_INVALID: "当前页面数据格式无效，请刷新页面后重试。",
  CAPTURE_URL_UNSUPPORTED: "当前页面地址不受支持，请打开 HTTP 或 HTTPS 页面。",
  CAPTURE_CONTENT_EMPTY: "当前页面没有可发送的内容。",
  PLATFORM_NOT_SUPPORTED: "暂不支持该平台的智能抓取（小红书 / B站适配开发中）。可先在浏览器打开，或复制链接到桌面 App。",
  CAPTURE_PAYLOAD_TOO_LARGE: "当前页面内容过大，无法发送。",
  CAPTURE_COUNT_MISMATCH: "当前页面内容校验失败，请重新捕获。",
  NATIVE_RESPONSE_INVALID: "LinkDigest 返回了无效响应，请重启 App 后重试。",
  STORAGE_UNAVAILABLE: "本地存储暂时不可用，请打开 LinkDigest 后重试。",
  STORAGE_WRITE_FAILED: "本地历史保存失败，请稍后重试。",
  STORAGE_FUTURE_SCHEMA: "本地历史由更新版本创建，请升级 LinkDigest。",
  STORAGE_MIGRATION_FAILED: "本地历史升级未完成，请重新打开 LinkDigest。",
  STORAGE_READ_ONLY: "本地历史当前只读，无法保存新内容。",
  STORAGE_INTEGRITY_FAILED: "本地历史完整性检查失败，请停止写入。",
  STORAGE_STATE_CONFLICT: "本地历史状态已变化，请重新发送。",
  CAPTURE_IDEMPOTENCY_CONFLICT: "本次页面传输与原请求不一致，请重新发送。",
  RUN_IDEMPOTENCY_CONFLICT: "本次运行与原请求不一致，请重新操作。",
  APP_UNAVAILABLE: "无法连接 LinkDigest。扩展会尝试自动打开应用；若仍失败，请手动打开 App 后再发送。",
  NATIVE_HOST_NOT_FOUND: "未找到浏览器支持组件，请在 LinkDigest 设置里安装浏览器支持。",
  NATIVE_HOST_START_FAILED: "浏览器支持组件启动失败，请重新安装浏览器支持或重启浏览器。",
  NATIVE_MESSAGE_TIMEOUT: "发送超时。若 App 刚启动，请再试一次。",
  NATIVE_MESSAGE_FAILED: "与 LinkDigest 通信失败，请确认 App 已安装并重试。",
};

export function popupMessageForResponse(response: NativeResponse): string | null {
  if (response.kind !== "error") return null;
  return knownErrorMessages[response.error.code] ?? "操作未完成，请重试。";
}

export type SafeExtensionSendResult = {
  response: NativeResponse;
  errorStage?: "extension_validation" | "native_response" | "native_transport";
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
};

const stageLabels: Readonly<Record<NonNullable<SafeExtensionSendResult["errorStage"]>, string>> = {
  extension_validation: "扩展校验",
  native_response: "桌面响应",
  native_transport: "原生通信",
};

export function popupMessageForSendResult(result: SafeExtensionSendResult): string | null {
  const message = popupMessageForResponse(result.response);
  if (!message) return null;
  const stage = result.errorStage ? stageLabels[result.errorStage] : "未知阶段";
  const code = result.response.kind === "error" && result.response.error.code in knownErrorMessages
    ? result.response.error.code
    : "UNKNOWN_SAFE_ERROR";
  return `${stage} · ${code}\n${message}`;
}

export function popupBuildLabel(manifest: { version: string; version_name?: string | undefined }): string {
  return `构建 ${manifest.version_name || manifest.version}`;
}

export type SafeMediaPreview = Pick<
  MediaDescriptor,
  "kind" | "failureReason" | "selectionReason" | "playbackState" | "candidateCount"
>;

function playbackLabel(state: SafeMediaPreview["playbackState"]): string | null {
  switch (state) {
    case "playing": return "正在播放";
    case "paused": return "已暂停";
    case "ended": return "播放已结束";
    case "notLoaded": return "尚未加载";
    default: return null;
  }
}

const diagnosticLabels: Readonly<Record<DouyinSessionDiagnosticCode, string>> = {
  invalid_context: "当前页面上下文不符合会话详情条件",
  id_before_after: "请求前后的视频 ID 已变化",
  main_fetch_timeout: "会话详情请求超时",
  main_fetch_network: "会话详情网络请求失败",
  main_injection_failed: "无法进入当前页面会话",
  http_403: "会话详情接口返回 HTTP 403",
  http_429: "会话详情接口请求过于频繁",
  http_other: "会话详情接口返回其它 HTTP 状态",
  body_too_large: "会话详情响应超过安全大小",
  body_unavailable: "无法安全读取会话详情响应",
  json_invalid: "会话详情不是有效 JSON",
  api_status: "会话详情接口报告失败状态",
  detail_missing: "响应中没有可识别的视频详情",
  aweme_id_missing_or_nonstring: "响应中的视频 ID 缺失或格式不安全",
  aweme_id_mismatch: "响应视频 ID 与当前视频不一致",
  video_missing: "响应中缺少视频播放信息",
  no_candidates: "响应中没有播放地址候选",
  candidate_limit: "播放地址候选数量超过安全上限",
  no_allowed_host: "播放地址域名不在安全白名单",
};

export function popupDiagnosticStatus(diagnostic: DouyinSessionDiagnostic | undefined): string | null {
  if (!diagnostic) return null;
  const label = diagnosticLabels[diagnostic.code];
  const safeHost = diagnostic.blockedHost
    && diagnostic.blockedHost === diagnostic.blockedHost.toLowerCase()
    && diagnostic.blockedHost.length <= 253
    && /^[a-z0-9.-]+$/u.test(diagnostic.blockedHost)
    ? diagnostic.blockedHost
    : undefined;
  if (diagnostic.code === "no_allowed_host" && safeHost) {
    return `${label}：${safeHost}`;
  }
  return label;
}

/** Fixed labels only: never render raw failure detail, body text, or URLs. */
export function popupMediaStatus(
  media: SafeMediaPreview | undefined,
  diagnostic?: DouyinSessionDiagnostic,
): string {
  const diagnosticStatus = popupDiagnosticStatus(diagnostic);
  const withDiagnostic = (label: string) => [label, diagnosticStatus].filter(Boolean).join(" · ");
  if (!media) return withDiagnostic("未识别到可移交视频");
  if (media.failureReason === "multiple_candidates") return withDiagnostic("多个视频无法确定");
  if (media.failureReason === "blob_or_mse") return withDiagnostic("仅浏览器可播：blob/MSE");
  if (media.failureReason === "drm_or_encrypted") return withDiagnostic("视频受 DRM 或加密保护");
  if (media.failureReason === "video_not_loaded") return withDiagnostic("视频尚未加载");
  if (media.failureReason === "browser_session_required") return withDiagnostic("仅当前浏览器会话可播");
  if (media.failureReason === "no_transferable_source") return withDiagnostic("未找到可移交的视频源");
  if (media.failureReason === "unsupported_media_type") return withDiagnostic("暂不支持此视频格式");

  const state = playbackLabel(media.playbackState);
  if (media.kind === "directFile") return withDiagnostic(["已识别直连视频", state].filter(Boolean).join(" · "));
  if (media.kind === "hls") return withDiagnostic(["已识别 HLS 视频", state].filter(Boolean).join(" · "));
  if (media.kind === "embed") return withDiagnostic("已识别嵌入式视频");
  if (media.kind === "browserSessionOnly") return withDiagnostic("仅浏览器可播");
  return withDiagnostic("暂时无法移交此视频");
}

function nullPrototypeLabels<T extends string>(entries: Record<T, string>): Readonly<Record<T, string>> {
  return Object.assign(Object.create(null) as Record<T, string>, entries);
}

function popupMetadataLabel<T extends string>(labels: Readonly<Record<T, string>>, code: unknown): string {
  return typeof code === "string" && Object.hasOwn(labels, code) ? labels[code as T] : "未知安全码";
}

const routeLabels = nullPrototypeLabels<DouyinMetadataRouteRejectCode>({
  none: "符合当前视频路由条件", invalid_url: "页面地址无效", missing_aweme_id: "未锁定视频 ID",
  non_canonical_route: "路由无法证明当前视频", query_item_id: "路由视频参数不一致",
});
const videoLabels = nullPrototypeLabels<DouyinMetadataVideoRejectCode>({
  none: "通过", video_node_limit: "视频节点超过安全上限", no_visible_video: "没有可见视频", not_uniquely_dominant: "没有唯一主视频",
});
const scopeLabels = nullPrototypeLabels<DouyinMetadataScopeRejectCode>({
  none: "通过", identity_limit: "身份节点超过安全上限", identity_conflict: "视频身份不一致",
  dominant_video_proof: "由唯一主视频证明归属",
  identity_conflict_stopped: "遇邻近视频已提前停止，保留本条作用域",
  scope_limit: "元数据范围超过安全上限", not_dedicated: "没有专用元数据范围",
});
const ssrRejectLabels = nullPrototypeLabels<DouyinMetadataSSRRejectCode>({
  none: "通过", invalid_aweme_id: "锁定视频 ID 无效", no_roots: "没有允许的页面状态根",
  no_exact_item: "未找到精确视频项", main_injection_failed: "无法进入页面状态",
});
const ssrLimitLabels = nullPrototypeLabels<DouyinMetadataSSRLimitCode>({
  none: "无", root_limit: "状态根上限", script_limit: "单个状态脚本上限", total_script_limit: "状态脚本总上限",
  depth_limit: "遍历深度上限", node_limit: "遍历节点上限", child_limit: "子节点检查上限",
});

/** Fixed Chinese presentation for the popup-only metadata diagnostic. */
export function popupMetadataDiagnostic(diagnostic: DouyinMetadataDiagnostic | undefined): string | null {
  if (!diagnostic || (!diagnostic.missingPublished && diagnostic.missingStatsMask === 0)) return null;
  const missing = [
    ...(diagnostic.missingPublished ? ["发布时间"] : []),
    ...(diagnostic.missingStatsMask & 1 ? ["点赞"] : []),
    ...(diagnostic.missingStatsMask & 2 ? ["评论"] : []),
    ...(diagnostic.missingStatsMask & 4 ? ["分享"] : []),
    ...(diagnostic.missingStatsMask & 8 ? ["收藏"] : []),
  ];
  const route = popupMetadataLabel(routeLabels, diagnostic.dom.route.rejectCode);
  const video = popupMetadataLabel(videoLabels, diagnostic.dom.video.rejectCode);
  const scopes = popupMetadataLabel(scopeLabels, diagnostic.dom.scopes.rejectCode);
  const ssrReject = popupMetadataLabel(ssrRejectLabels, diagnostic.ssr.rejectCode);
  const ssrLimit = popupMetadataLabel(ssrLimitLabels, diagnostic.ssr.limitCode);
  return [
    "元数据诊断（仅当前弹窗，不发送、不保存）",
    `缺失项：${missing.length > 0 ? missing.join("、") : "无"}`,
    `路由：${diagnostic.dom.route.eligible ? "可用" : "不适用"}；${route}`,
    `视频：可见 ${diagnostic.dom.video.positiveVisibleCount}；主视频 ${diagnostic.dom.video.dominantVideoCount}；${video}`,
    `范围：安全 ${diagnostic.dom.scopes.safeCount}；专用 ${diagnostic.dom.scopes.dedicatedCount}；${scopes}`,
    `DOM：时间命中 ${diagnostic.dom.dom.publishedSelectorHit ? "是" : "否"}；统计命中 ${diagnostic.dom.dom.statSelectorHitMask}；统计接受 ${diagnostic.dom.dom.statAcceptedCount}`,
    `SSR：存在 ${diagnostic.ssr.fixedRootPresent}；可解析 ${diagnostic.ssr.fixedRootParseable}；精确命中 ${diagnostic.ssr.exactHit ? "是" : "否"}；${ssrReject}；限制 ${ssrLimit}`,
  ].join("\n");
}
