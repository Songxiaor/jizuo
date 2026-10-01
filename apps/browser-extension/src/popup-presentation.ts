import type { MediaDescriptor, NativeResponse } from "./contract";
import { connectionCopy, isSendConnectionFailure } from "./popup-connection";
import type { DouyinSessionDiagnostic, DouyinSessionDiagnosticCode } from "./content/douyin-session-detail";
import type {
  DouyinMetadataDiagnostic,
  DouyinMetadataRouteRejectCode,
  DouyinMetadataScopeRejectCode,
  DouyinMetadataSSRLimitCode,
  DouyinMetadataSSRRejectCode,
  DouyinMetadataVideoRejectCode,
} from "./content/douyin-metadata-diagnostic";

export type PopupCaptureAction = "save" | "summarize" | "translate";

const actionPresentation: Readonly<Record<PopupCaptureAction, {
  title: string;
  detail: string;
  button: string;
  success: string;
}>> = {
  save: {
    title: "只保存",
    detail: "保留原文与来源，稍后再处理。",
    button: "保存到汲作",
    success: "已保存到汲作",
  },
  summarize: {
    title: "总结",
    detail: "保存后马上用当前模型写一份总结。",
    button: "保存并总结",
    success: "已保存，正在汲作中准备总结",
  },
  translate: {
    title: "翻译",
    detail: "保存后马上翻译成设置里的输出语言。",
    button: "保存并翻译",
    success: "已保存，正在汲作中准备翻译",
  },
};

export function popupActionPresentation(action: PopupCaptureAction) {
  return actionPresentation[action];
}

export type PopupRecovery = {
  message: string;
  /** open_app_retry：连不上汲作，自动重试已用完，给「打开汲作并重试」（2026-10-01）。 */
  action: "retry" | "open_app" | "open_app_retry" | "open_settings" | "reload" | "none";
  label: string;
};

export type PopupPreviewFailure = {
  /** 失败卡片的标题：一句话说清读到了什么。 */
  title: string;
  message: string;
  /** 「可以这样做」：按先后给出的办法。 */
  steps: string[];
  canReload: boolean;
};

/** Safe user copy for errors thrown before a capture envelope exists. */
export function popupPreviewFailure(rawMessage: string): PopupPreviewFailure {
  if (rawMessage.includes("CAPTURE_APP_SHELL")) {
    return {
      title: "这是网页应用的界面，不是一篇文章",
      steps: ["打开具体的一篇文章或一条内容再点扩展", "或者先选中要保存的文字，再点扩展"],
      message: "当前页面是已登录的网页应用界面，不是独立文章。请选中需要保存的正文后再打开扩展。",
      canReload: false,
    };
  }
  if (rawMessage.includes("CAPTURE_PAGE_LOAD_FAILED")) {
    return {
      title: "正文还没加载出来",
      steps: ["等页面内容完全出现", "点下面「重新读取」"],
      message: "正文尚未加载成功。请刷新页面，等待文件内容出现后重新读取。",
      canReload: true,
    };
  }
  if (rawMessage.includes("CAPTURE_LOGIN_WALL")) {
    return {
      title: "页面挡了一层登录",
      steps: ["在这个网页上登录，打开具体内容后再点扩展", "或在汲作「设置 → 站点登录」里登录一次，以后添加链接也能读全文"],
      message: "当前只读取到了登录页。请先完成登录，再打开具体内容。",
      canReload: false,
    };
  }
  if (rawMessage.includes("CAPTURE_SECURITY_CHALLENGE")) {
    return {
      title: "页面要先做安全验证",
      steps: ["在网页上完成验证，等内容显示出来", "点下面「重新读取」"],
      message: "当前只读取到了网站的安全验证或限流页面。请在浏览器中完成验证，确认具体内容已显示后再读取。",
      canReload: true,
    };
  }
  if (rawMessage.includes("CAPTURE_NAVIGATION_ONLY")) {
    return {
      title: "这一页只有导航，没有正文",
      steps: ["打开具体的一篇文章再点扩展", "或者先选中要保存的文字，再点扩展"],
      message: "当前只读取到了导航内容。请打开具体文章，或选中需要保存的文字。",
      canReload: false,
    };
  }
  if (rawMessage.includes("CAPTURE_CONTENT_EMPTY")) {
    return {
      title: "没读到正文",
      steps: ["等页面加载完", "点下面「重新读取」"],
      message: "当前页面没有读到可保存的正文。请等待页面加载完成后重新读取。",
      canReload: true,
    };
  }
  return {
    title: "这一页暂时读不了",
    message: "当前页面暂时不可读取。请刷新页面后再试。",
    steps: ["刷新页面，等内容加载完", "点下面「重新读取」"],
    canReload: true,
  };
}

/**
 * 浏览器自己的页面（设置、扩展、新标签页、ego:// 之类）扩展根本读不了，刷新也没用：
 * 直接说清楚，不给「重新读取」（2026-09-29 真机走查：原来会叫人刷新重试）。
 * 不是这类页面时返回 null。
 */
export function popupBrowserPageFailure(url: string | undefined): PopupPreviewFailure | null {
  if (!url) return null;
  let scheme = "";
  try { scheme = new URL(url).protocol; } catch { return null; }
  if (scheme === "http:" || scheme === "https:") return null;
  return {
    title: "浏览器自己的页面读不了",
    message: "设置、扩展、新标签页这类浏览器自带页面，不允许扩展读取内容。",
    steps: ["换到一篇文章、一条帖子或视频页", "再点一次「汲」图标"],
    canReload: false,
  };
}

export function popupRecoveryForSendResult(result: SafeExtensionSendResult): PopupRecovery | null {
  if (result.response.kind !== "error") return null;
  const message = popupMessageForResponse(result.response) ?? "操作未完成。";
  const requested = result.response.error.action;
  // 连接类失败先于 Host 给的 open_app：只打开汲作不再试，用户还得回来再点一次。
  if (isSendConnectionFailure(result)) {
    return { message, action: "open_app_retry", label: connectionCopy.openRetryLabel };
  }
  if (requested === "upgrade_app") return { message, action: "open_app", label: "打开汲作检查更新" };
  if (requested === "open_app") return { message, action: "open_app", label: "前往汲作处理" };
  if (requested === "open_install_guide") {
    return { message, action: "open_settings", label: "打开汲作安装浏览器支持" };
  }
  if (result.response.error.code === "CAPTURE_CONTENT_EMPTY") {
    return { message, action: "reload", label: "重新读取页面" };
  }
  if (result.response.error.retryable || requested === "retry") {
    return { message, action: "retry", label: "重试保存" };
  }
  return { message, action: "none", label: "" };
}

const knownErrorMessages: Readonly<Record<string, string>> = {
  PROTOCOL_VERSION_UNSUPPORTED: "扩展与汲作版本不兼容。请打开汲作检查更新。",
  CAPTURE_SCHEMA_INVALID: "当前页面数据格式无效，请刷新页面后重试。",
  CAPTURE_URL_UNSUPPORTED: "当前页面地址不受支持，请打开 HTTP 或 HTTPS 页面。",
  CAPTURE_CONTENT_EMPTY: "当前页面没有可保存的内容。",
  CAPTURE_DOUYIN_NO_SINGLE_ITEM: "没有定位到具体的抖音视频。请打开视频详情页，或在精选里点开弹层后再保存。",
  PLATFORM_NOT_SUPPORTED: "暂不支持该平台的智能抓取（小红书 / B站适配开发中）。可先在浏览器打开，或复制链接到桌面 App。",
  CAPTURE_PAYLOAD_TOO_LARGE: "当前页面内容过大，无法保存。",
  CAPTURE_COUNT_MISMATCH: "当前页面内容校验失败，请重新捕获。",
  NATIVE_RESPONSE_INVALID: "汲作返回了无效响应，请重启汲作后重试。",
  STORAGE_UNAVAILABLE: "本地存储暂时不可用，请打开汲作后重试。",
  STORAGE_WRITE_FAILED: "本地历史保存失败，请稍后重试。",
  STORAGE_FUTURE_SCHEMA: "本地历史由更新版本创建，请升级汲作。",
  STORAGE_MIGRATION_FAILED: "本地历史升级未完成，请重新打开汲作。",
  STORAGE_READ_ONLY: "本地历史当前只读，无法保存新内容。",
  STORAGE_INTEGRITY_FAILED: "本地历史完整性检查失败，请停止写入。",
  STORAGE_STATE_CONFLICT: "本地历史状态已变化，请重新保存。",
  CAPTURE_IDEMPOTENCY_CONFLICT: "本次页面传输与原请求不一致，请重新保存。",
  RUN_IDEMPOTENCY_CONFLICT: "本次运行与原请求不一致，请重新操作。",
  // 连接类三条只在自动重试用完后才出现，下面有「打开汲作并重试」按钮，不再叫用户自己排查（2026-10-01）。
  APP_UNAVAILABLE: connectionCopy.needsApp,
  NATIVE_HOST_NOT_FOUND: "未找到浏览器支持组件，请在汲作设置里安装浏览器支持。",
  NATIVE_HOST_START_FAILED: "浏览器支持组件启动失败，请重新安装浏览器支持或重启浏览器。",
  NATIVE_MESSAGE_TIMEOUT: "汲作这次没有及时回应。点「打开汲作并重试」再试一次。",
  NATIVE_MESSAGE_FAILED: connectionCopy.needsApp,
};

export function popupMessageForResponse(response: NativeResponse): string | null {
  if (response.kind !== "error") return null;
  return knownErrorMessages[response.error.code] ?? "操作未完成，请重试。";
}

/** 裸 catch 不得静默吞错，也不得把原始 URL/堆栈亮给用户。 */
export function popupCaughtFailure(raw: unknown, fallback: string): string {
  const message = raw instanceof Error ? raw.message : String(raw);
  for (const code of Object.keys(knownErrorMessages)) {
    const mapped = knownErrorMessages[code];
    if (mapped && message.includes(code)) return mapped;
  }
  return fallback;
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

type CapturePlatform =
  | "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github"
  | "zhihu" | "medium" | "substack" | "toutiao";
type Completeness = "full_article" | "visible_only" | "selection_only" | "unknown";

const platformLabels: Readonly<Record<CapturePlatform, string>> = {
  generic: "网页", x: "X", youtube: "YouTube", wechat: "微信公众号",
  xiaohongshu: "小红书", douyin: "抖音", bilibili: "B站", github: "GitHub",
  zhihu: "知乎", medium: "Medium", substack: "Substack", toutiao: "今日头条",
};

// 这里原本还有一套 emoji 平台图标,和 `platformLabels` 并排渲染。删掉了:
// 它和文字说的是同一件事(X 页面上会显示「𝕏 X · 视频」,两个 X),而在 11px 下
// 📕/📘/📰/📮 彼此分不出来——一个既重复又认不准的东西,不如没有。
// 平台身份只留文字这一处。

const unsupportedPlatforms: ReadonlySet<CapturePlatform> = new Set<CapturePlatform>();

export type PopupAvailability = { tone: "ready" | "video" | "warn" | "blocked"; label: string };

/** 顶部一句话可用性：进 popup 立刻知道这页能不能抓、抓到什么。 */
/**
 * X 用 MSE 播放，页面里只有 blob: 地址，扩展侧确实拿不到可下载的源；但桌面
 * App 会用嵌入式推文的公开端点换回真实直链并存下来。对用户来说这条视频是
 * 拿得到的，所以不该在这里说「受限」。
 */
function resolvesVideoAfterSending(
  platform: CapturePlatform | undefined,
  media: SafeMediaPreview | undefined,
): boolean {
  return platform === "x" && media?.failureReason === "blob_or_mse";
}

export function popupAvailability(preview: {
  platform: CapturePlatform;
  completeness: Completeness;
  media?: SafeMediaPreview;
  imageCount?: number;
}): PopupAvailability {
  if (unsupportedPlatforms.has(preview.platform)) {
    return { tone: "blocked", label: "暂不支持此平台" };
  }
  if (preview.imageCount !== undefined && preview.imageCount > 0) {
    return { tone: "ready", label: `可以保存 · 图文 ${preview.imageCount} 张` };
  }
  if (resolvesVideoAfterSending(preview.platform, preview.media)) {
    return { tone: "video", label: "可以保存 · 视频由汲作获取" };
  }
  if (preview.media) {
    if (!preview.media.failureReason
        && (preview.media.kind === "directFile" || preview.media.kind === "hls")) {
      return { tone: "video", label: "可以保存 · 含视频" };
    }
    if (preview.media.failureReason) {
      return { tone: "warn", label: "只能存正文 · 视频受限" };
    }
  }
  if (preview.completeness === "selection_only") {
    return { tone: "ready", label: "可以保存选中内容" };
  }
  if (preview.completeness === "visible_only") {
    return { tone: "warn", label: "只读到可见部分" };
  }
  return { tone: "ready", label: "可以保存" };
}

export function popupPlatformLabel(
  platform: CapturePlatform,
  version: 1 | 2,
  imageCount?: number,
): string {
  // 图文帖既不是视频也不是文章。它没有正片视频（页面上那个 <video> 只是
  // 背景音乐轨），落到"文章"上会让人以为抓的是一篇字。
  const kind = imageCount !== undefined && imageCount > 0
    ? "图文"
    : version === 2 ? "视频" : "文章";
  return `${platformLabels[platform] ?? "网页"} · ${kind}`;
}

/** 字符数 → 人话规模：约 N 字 + 预计阅读时长（中文按 400 字/分钟）。 */
export function popupScaleLabel(characterCount: number, completeness: Completeness): string {
  if (completeness === "selection_only") {
    return `选中约 ${roundCount(characterCount)} 字`;
  }
  const minutes = Math.max(1, Math.round(characterCount / 400));
  return `约 ${roundCount(characterCount)} 字 · 预计 ${minutes} 分钟读完`;
}

export type PopupMetaChip = { text: string; tone?: "video" };

/** 规模拆成独立 chip：字数 / 时长 / 视频状态，供 popup 并排渲染。 */
export function popupMetaChips(preview: {
  characterCount: number;
  completeness: Completeness;
  version: 1 | 2;
  platform?: CapturePlatform;
  media?: SafeMediaPreview;
  imageCount?: number;
}): PopupMetaChip[] {
  const chips: PopupMetaChip[] = [];
  if (preview.completeness === "selection_only") {
    chips.push({ text: `选中约 ${roundCount(preview.characterCount)} 字` });
  } else if (preview.characterCount > 0) {
    chips.push({ text: `约 ${roundCount(preview.characterCount)} 字` });
    chips.push({ text: `约 ${Math.max(1, Math.round(preview.characterCount / 400))} 分钟` });
  }
  if (preview.imageCount !== undefined && preview.imageCount > 0) {
    chips.push({ text: `🖼 ${preview.imageCount} 张图` });
    return chips;
  }
  if (resolvesVideoAfterSending(preview.platform, preview.media)) {
    chips.push({ text: "🎬 视频由 App 获取", tone: "video" });
    return chips;
  }
  const videoChip = popupVideoChip(preview.media);
  if (videoChip) chips.push(videoChip);
  return chips;
}

function popupVideoChip(media: SafeMediaPreview | undefined): PopupMetaChip | null {
  if (!media) return null;
  if (media.failureReason) {
    if (media.failureReason === "browser_session_required") return { text: "🎬 仅浏览器可播", tone: "video" };
    if (media.failureReason === "drm_or_encrypted") return { text: "🎬 受保护视频", tone: "video" };
    return { text: "🎬 视频受限", tone: "video" };
  }
  if (media.kind === "directFile" || media.kind === "hls") return { text: "🎬 可下载视频", tone: "video" };
  if (media.kind === "embed") return { text: "🎬 嵌入视频", tone: "video" };
  return null;
}

export type PopupStat = { value: string; label: string };

/**
 * 来源卡底部那一排数字（2026-09-29 弹窗重构）：文章给字数 / 图 / 读完时长 / 读取范围，
 * 视频给时长 / 视频状态 / 字数。最多四格。
 */
export function popupStats(preview: {
  characterCount: number;
  wordCount?: number;
  completeness: Completeness;
  version: 1 | 2;
  platform?: CapturePlatform;
  media?: SafeMediaPreview;
  imageCount?: number;
  mediaDurationSeconds?: number;
  engagement?: Partial<Record<"likes" | "comments" | "shares" | "collects" | "views", string>>;
}): PopupStat[] {
  const stats: PopupStat[] = [];
  const engagement = engagementStats(preview.engagement);
  const isVideo = preview.version === 2 && !(preview.imageCount && preview.imageCount > 0);
  if (isVideo) {
    if (preview.mediaDurationSeconds) stats.push({ value: popupDuration(preview.mediaDurationSeconds), label: "视频时长" });
    stats.push(popupVideoStat(preview.platform, preview.media));
    stats.push(...engagement);
    if (stats.length < 4 && preview.characterCount > 0) stats.push({ value: roundCount(preview.characterCount), label: "字正文" });
    return stats.slice(0, 4);
  }
  // 图文只配了一两句话时，「8 字 · 1 分钟读完」没有意义：让位给图数和互动。
  const countsText = preview.characterCount > 0 && !(preview.imageCount && preview.imageCount > 0 && preview.characterCount < 40);
  // 英文按词：约每分钟 230 词；中文按字：约每分钟 400 字。
  const words = preview.wordCount && preview.wordCount > 0 ? preview.wordCount : undefined;
  if (countsText) {
    stats.push(words
      ? { value: roundCount(words), label: "词" }
      : { value: roundCount(preview.characterCount), label: preview.completeness === "selection_only" ? "字（选中）" : "字" });
  }
  if (preview.imageCount && preview.imageCount > 0) stats.push({ value: String(preview.imageCount), label: "张图" });
  if (countsText && preview.completeness !== "selection_only") {
    const minutes = Math.max(1, Math.round(words ? words / 230 : preview.characterCount / 400));
    stats.push({ value: `${minutes} 分钟`, label: "读完" });
  }
  // 读完整了就不占格子（顶部状态已经说了「可以保存」），把位置让给赞和评论。
  if (preview.completeness !== "full_article" || engagement.length === 0) {
    stats.push({ value: completenessValue(preview.completeness), label: "读取" });
  }
  stats.push(...engagement);
  return stats.slice(0, 4);
}

function engagementStats(engagement: Partial<Record<"likes" | "comments" | "shares" | "collects" | "views", string>> | undefined): PopupStat[] {
  if (!engagement) return [];
  const labels = [["likes", "赞"], ["comments", "评论"], ["collects", "收藏"], ["shares", "转发"], ["views", "浏览"]] as const;
  return labels.flatMap(([key, label]) => (engagement[key] ? [{ value: popupCountLabel(engagement[key]!), label }] : []));
}

/** 「24543329」→「2454万」、「563472」→「56.3万」；平台已写好的「1.2万」「3k」原样。 */
export function popupCountLabel(raw: string): string {
  const digits = raw.replace(/[,，\s]/gu, "");
  if (!/^\d+$/u.test(digits)) return raw;
  const n = Number(digits);
  const trim = (value: number) => value.toFixed(1).replace(/\.0$/u, "");
  if (n >= 100_000_000) return `${trim(n / 100_000_000)}亿`;
  if (n >= 1_000_000) return `${Math.round(n / 10_000)}万`;
  if (n >= 10_000) return `${trim(n / 10_000)}万`;
  return digits;
}

/**
 * 作者行：「数字生命卡兹克 (@Khazix0918) · 9月28日 20:53」。ISO 时间按本地时区写成月日，
 * 其它写法（「2026-01-07 21:53・北京」）原样保留。
 */
export function popupBylineText(author: string | undefined, published: string | undefined, now = new Date()): string {
  const parts: string[] = [];
  // X 的作者写成「名字 (@账号)」，括号去掉读起来更顺。
  if (author) parts.push(author.replace(/\s*\((@[^)]+)\)/u, " $1"));
  if (published) parts.push(popupPublishedLabel(published, now));
  return parts.join(" · ");
}

export function popupPublishedLabel(published: string, now = new Date()): string {
  // B 站、抖音给的是不带时区的「2026-09-27 18:54:11」：按原样的墙上时间改写，和 ISO 的显示一致。
  // 知乎在后面带 IP 属地：「2026-01-07 21:53・北京」，属地照留。
  const wall = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::\d{2})?)?(?:\s*[・·]\s*(\S.*))?$/u.exec(published.trim());
  if (wall) {
    const [, year, month, dayOfMonth, hour, minute, place] = wall;
    const day = `${Number(month)}月${Number(dayOfMonth)}日`;
    const when = Number(year) !== now.getFullYear()
      ? `${year}年${day}`
      : hour !== undefined ? `${day} ${Number(hour)}:${minute}` : day;
    return place ? `${when} · ${place}` : when;
  }
  if (!/^\d{4}-\d{2}-\d{2}T/u.test(published)) return published;
  const date = new Date(published);
  if (Number.isNaN(date.getTime())) return published;
  const pad = (n: number) => String(n).padStart(2, "0");
  const time = `${date.getHours()}:${pad(date.getMinutes())}`;
  const day = `${date.getMonth() + 1}月${date.getDate()}日`;
  return date.getFullYear() === now.getFullYear() ? `${day} ${time}` : `${date.getFullYear()}年${day}`;
}

function completenessValue(completeness: Completeness): string {
  switch (completeness) {
    case "full_article": return "完整";
    case "visible_only": return "可见部分";
    case "selection_only": return "选中";
    default: return "已读取";
  }
}

function popupVideoStat(platform: CapturePlatform | undefined, media: SafeMediaPreview | undefined): PopupStat {
  if (resolvesVideoAfterSending(platform, media)) return { value: "汲作获取", label: "视频" };
  if (!media) return { value: "无", label: "视频" };
  if (media.failureReason === "browser_session_required") return { value: "仅浏览器可播", label: "视频" };
  if (media.failureReason === "drm_or_encrypted") return { value: "受保护", label: "视频" };
  if (media.failureReason) return { value: "受限", label: "视频" };
  if (media.kind === "directFile" || media.kind === "hls") return { value: "可转写", label: "视频" };
  if (media.kind === "embed") return { value: "嵌入", label: "视频" };
  return { value: "无", label: "视频" };
}

/** 秒 → 「4:12」「1:02:05」。 */
export function popupDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const sec = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

/** 来源行：「X · 文章 · x.com」。 */
export function popupSourceLine(platform: CapturePlatform, version: 1 | 2, imageCount?: number, host?: string): string {
  let label = popupPlatformLabel(platform, version, imageCount);
  // 「文章」只对真正的文章成立：X 上是一条帖子，知乎问答页是一个回答（专栏才是文章）。
  if (label.endsWith(" · 文章")) {
    if (platform === "x") label = label.replace(/文章$/u, "帖子");
    // YouTube 走字幕抓取，信封是 v1，但它是一条视频。
    else if (platform === "youtube") label = label.replace(/文章$/u, "视频");
    else if (platform === "zhihu" && host && host !== "zhuanlan.zhihu.com") label = label.replace(/文章$/u, "回答");
  }
  return host ? `${label} · ${host}` : label;
}

function roundCount(n: number): string {
  if (n < 1000) return String(n);
  return `${(n / 1000).toFixed(n < 10000 ? 1 : 0)}k`;
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

// ── 工序印（2026-09-29 弹窗重构第二批）──────────────────────────────────────────

export type ProcessKey = "record" | "proof" | "comments" | "summary" | "translation" | "mindMap";
export type ChainKey = "ji" | ProcessKey;

const stepTitles: Readonly<Record<ProcessKey, string>> = {
  record: "转写", proof: "校对", comments: "评论", summary: "总结", translation: "翻译", mindMap: "脑图",
};
const stepGlyphs: Readonly<Record<ChainKey, string>> = {
  ji: "汲", record: "录", proof: "校", comments: "评", summary: "摘", translation: "译", mindMap: "图",
};

export function popupStepTitle(key: ProcessKey): string { return stepTitles[key]; }
export function popupStepGlyph(key: ChainKey): string { return stepGlyphs[key]; }

/** 一枚链上的印：盖好（会自动做 / 这次做）、印位（手动）、灰（这页用不上）。 */
export type ChainSeal = {
  key: ChainKey;
  style: "stamped" | "pending" | "na";
  label: string;
  /** 点一下切换「这次也做」：只有总结和翻译能随保存一起请求。 */
  toggles?: PopupCaptureAction;
};

export type CommentPlan = "auto" | "picker" | "disabled" | "unsupported" | "unknown";

export function popupStepChain(input: {
  autoSteps?: readonly string[] | undefined;
  /** undefined = 页面还没读完：先别说「无视频」，YouTube 要读十几秒。 */
  hasVideo: boolean | undefined;
  /** 直接用平台字幕（YouTube）：不用转写，也就不用校对。 */
  usesCaptions?: boolean;
  comments: CommentPlan;
  selectedAction: PopupCaptureAction;
}): ChainSeal[] {
  const auto = new Set(input.autoSteps ?? []);
  const chain: ChainSeal[] = [{ key: "ji", style: "stamped", label: "收集" }];
  if (input.hasVideo === undefined) {
    chain.push({ key: "record", style: "na", label: "待确认" }, { key: "proof", style: "na", label: "待确认" });
  } else chain.push(input.hasVideo
    ? { key: "record", style: auto.has("record") ? "stamped" : "pending", label: "转写" }
    : { key: "record", style: "na", label: input.usesCaptions ? "用字幕" : "无视频" });
  if (input.hasVideo !== undefined) chain.push(input.hasVideo
    ? { key: "proof", style: auto.has("proof") && auto.has("record") ? "stamped" : "pending", label: "校对" }
    : { key: "proof", style: "na", label: "无需" });
  switch (input.comments) {
    case "unsupported": chain.push({ key: "comments", style: "na", label: "无评论区" }); break;
    case "disabled": chain.push({ key: "comments", style: "pending", label: "不存" }); break;
    case "auto": chain.push({ key: "comments", style: "stamped", label: "评论" }); break;
    case "picker": chain.push({ key: "comments", style: "stamped", label: "手挑" }); break;
    default: chain.push({ key: "comments", style: "pending", label: "评论" });
  }
  if (auto.has("summary")) chain.push({ key: "summary", style: "stamped", label: "总结" });
  else if (input.selectedAction === "summarize") chain.push({ key: "summary", style: "stamped", label: "这次做", toggles: "summarize" });
  else chain.push({ key: "summary", style: "pending", label: "总结", toggles: "summarize" });
  if (input.selectedAction === "translate") chain.push({ key: "translation", style: "stamped", label: "译全文", toggles: "translate" });
  else if (auto.has("translation")) chain.push({ key: "translation", style: "stamped", label: "译标题", toggles: "translate" });
  else chain.push({ key: "translation", style: "pending", label: "翻译", toggles: "translate" });
  chain.push({ key: "mindMap", style: auto.has("mindMap") ? "stamped" : "pending", label: "脑图" });
  return chain;
}

/** 链下面那一句：说清这次保存后会自动做什么。 */
export function popupChainSummary(chain: readonly ChainSeal[], knowsSettings: boolean): string {
  if (!knowsSettings) return "盖好的章会自动做。点「摘」「译」，这次也做（汲作更新后会显示你的自动设置）。";
  const doing = chain.filter((seal) => seal.key !== "ji" && seal.style === "stamped").map((seal) => (seal.key === "ji" ? "" : seal.label));
  const text = doing.length > 0 ? `保存后自动：${doing.join("、")}。` : "保存后只存原文。";
  return `${text}点空心的「摘」「译」，这次也做。`;
}

export type StepProgressRow = {
  key: ProcessKey;
  title: string;
  state: "done" | "running" | "failed" | "waiting" | "manual" | "na";
  text: string;
};

/**
 * 「做到哪了」列表。`expected` 是这次会做的工序（自动开着的 + 这次请求的）：没状态时写「等着做」；
 * 其余没做的写「还没做」。用不上的转写 / 校对不列。App 说翻译用不上（原文已是中文）时写灰字，
 * 但视频还没转写时不信它：B 站常见中文标题配外语原声，转写出来才知道要不要译。
 */
export function popupStepProgress(input: {
  steps: readonly { step: string; state: "done" | "running" | "failed" | "notNeeded"; detail?: string }[];
  expected: ReadonlySet<string>;
  hasVideo: boolean;
}): StepProgressRow[] {
  const byKey = new Map(input.steps.map((row) => [row.step, row]));
  const rows: StepProgressRow[] = [];
  for (const key of ["record", "proof", "comments", "summary", "translation", "mindMap"] as const) {
    const status = byKey.get(key);
    if (!status && (key === "record" || key === "proof") && !input.hasVideo) continue;
    const title = stepTitles[key];
    if (status?.state === "done") rows.push({ key, title, state: "done", text: status.detail ?? "已完成" });
    else if (status?.state === "running") rows.push({ key, title, state: "running", text: status.detail ?? "进行中" });
    else if (status?.state === "failed") rows.push({ key, title, state: "failed", text: status.detail ?? "没做完" });
    else if (status?.state === "notNeeded" && !(input.hasVideo && byKey.get("record")?.state !== "done")) {
      rows.push({ key, title, state: "na", text: `${status.detail ?? "这条"} · 用不上` });
    }
    else if (input.expected.has(key)) rows.push({ key, title, state: "waiting", text: "等着做" });
    else rows.push({ key, title, state: "manual", text: "还没做 · 在汲作里点" });
  }
  return rows;
}

/** 「9月27日 20:39 存的」。 */
export function popupSavedAtLabel(milliseconds: number | undefined, now = new Date()): string {
  if (!milliseconds) return "";
  const date = new Date(milliseconds);
  const pad = (n: number) => String(n).padStart(2, "0");
  const time = `${date.getHours()}:${pad(date.getMinutes())}`;
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return `今天 ${time} 存的`;
  const day = `${date.getMonth() + 1}月${date.getDate()}日`;
  return date.getFullYear() === now.getFullYear() ? `${day} ${time} 存的` : `${date.getFullYear()}年${day}存的`;
}

/**
 * X 主页弹窗的标题：「数字生命卡兹克 (@Khazix0918) / X」→ 名字 + 账号。
 * 标签页标题读不出来时退回地址里的账号。
 */
export function popupXProfileHeading(tabTitle: string | undefined, rawURL: string | undefined): { name: string; handle: string } {
  let handle = "";
  try {
    handle = new URL(rawURL ?? "").pathname.split("/").filter(Boolean)[0] ?? "";
  } catch {
    // 没有地址时只用标题。
  }
  const match = /^(?:\(\d+\)\s*)?(.+?)\s*\((@[A-Za-z0-9_]{1,15})\)\s*\/\s*(?:X|Twitter)\s*$/u.exec(tabTitle ?? "");
  if (match) return { name: match[1]!.trim(), handle: match[2]! };
  return { name: handle ? `@${handle}` : "这个博主", handle: handle ? `@${handle}` : "" };
}
