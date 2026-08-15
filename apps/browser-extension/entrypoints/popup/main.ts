export {};
import {
  popupAvailability,
  popupActionPresentation,
  popupBuildLabel,
  popupMetaChips,
  popupRecoveryForSendResult,
  popupMetadataDiagnostic,
  popupPlatformLabel,
  popupPreviewFailure,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
  type PopupCaptureAction,
} from "../../src/popup-presentation";
import type { DouyinSessionDiagnostic } from "../../src/content/douyin-session-detail";
import type { DouyinMetadataDiagnostic } from "../../src/content/douyin-metadata-diagnostic";
import { bookmarksSyncMessage, isXBookmarksURL, type BookmarksSyncOutcome } from "../../src/content/x-bookmarks";

type BookmarksSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome; collected: number; reachedKnown: boolean }
  | { ok: false; code: "not_bookmarks" | "empty" | "native_error" | "injection_failed" };

const bookmarksErrorCopy: Readonly<Record<string, string>> = {
  not_bookmarks: "请在 X 的收藏夹页面（x.com/i/bookmarks）打开后再同步。",
  empty: "没有找到可同步的收藏。请向下滚动确认收藏已加载。",
  native_error: "无法连接汲作，或本次同步未被受理。如果汲作已经打开，请完全退出后重新打开，再重试。",
  injection_failed: "读取收藏夹失败，请刷新页面后重试。",
};

type CapturePlatform =
  | "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github"
  | "zhihu" | "medium" | "substack" | "toutiao";
type Completeness = "full_article" | "visible_only" | "selection_only" | "unknown";

type SafeCapturePreview = {
  title: string;
  characterCount: number;
  version: 1 | 2;
  platform: CapturePlatform;
  completeness: Completeness;
  media?: SafeMediaPreview;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  imageCount?: number;
};

const availability = document.querySelector<HTMLSpanElement>("#availability")!;
const platform = document.querySelector<HTMLDivElement>("#platform")!;
const status = document.querySelector<HTMLHeadingElement>("#status")!;
const meta = document.querySelector<HTMLDivElement>("#meta")!;
const diag = document.querySelector<HTMLDetailsElement>("#diag")!;
const metadataDiagnostic = document.querySelector<HTMLPreElement>("#metadata-diagnostic")!;
const error = document.querySelector<HTMLPreElement>("#error")!;
const send = document.querySelector<HTMLButtonElement>("#send")!;
const syncBookmarks = document.querySelector<HTMLButtonElement>("#sync-bookmarks")!;
const actionCard = document.querySelector<HTMLElement>("#action-card")!;
const actionDetail = document.querySelector<HTMLParagraphElement>("#action-detail")!;
const actionInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name="capture-action"]'));
const resultNotice = document.querySelector<HTMLParagraphElement>("#result")!;
const recoveryAction = document.querySelector<HTMLButtonElement>("#recovery-action")!;
const openApp = document.querySelector<HTMLAnchorElement>("#open-app")!;

let selectedAction: PopupCaptureAction = "save";
let recoveryMode: "retry" | "reload" | null = null;

function applySelectedAction(action: PopupCaptureAction): void {
  selectedAction = action;
  const presentation = popupActionPresentation(action);
  actionDetail.textContent = presentation.detail;
  if (!send.disabled && !send.classList.contains("done")) send.textContent = presentation.button;
}

for (const input of actionInputs) {
  input.addEventListener("change", () => {
    if (input.checked) applySelectedAction(input.value as PopupCaptureAction);
  });
}

const manifest = browser.runtime.getManifest();
const extensionName = manifest.name;
document.title = extensionName;
document.querySelector("#extension-name")!.textContent = extensionName;
document.querySelector("#build-label")!.textContent = popupBuildLabel(manifest);

function setAvailability(tone: string, label: string): void {
  availability.hidden = false;
  availability.dataset.tone = tone;
  availability.textContent = label;
}

function renderPlatform(label: string): void {
  platform.textContent = label;
}

function renderMeta(chips: { text: string; tone?: "video" }[]): void {
  meta.replaceChildren();
  for (const chip of chips) {
    const span = document.createElement("span");
    span.className = chip.tone === "video" ? "chip video" : "chip";
    span.textContent = chip.text;
    meta.append(span);
  }
}

function renderMetadataDiagnostic(diagnostic: DouyinMetadataDiagnostic | undefined): void {
  const rendered = popupMetadataDiagnostic(diagnostic);
  metadataDiagnostic.textContent = rendered ?? "";
  // 诊断区只在有内容时才出现；平时收起，不占用户视线。
  diag.hidden = rendered === null;
}

const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
const tabId = tab?.id;
if (tabId === undefined) {
  status.textContent = "无法读取当前标签页";
  send.disabled = true;
} else if (isXBookmarksURL(tab?.url)) {
  // 收藏夹页面：主操作换成批量同步。普通「发送」在这里只会抓到收藏夹外壳。
  send.hidden = true;
  actionCard.hidden = true;
  syncBookmarks.hidden = false;
  setAvailability("ready", "可同步");
  renderPlatform("X · 收藏夹");
  status.textContent = "同步收藏夹";
  renderMeta([{ text: "滚动收集后交给 App 逐条抓取" }]);

  syncBookmarks.onclick = async () => {
    syncBookmarks.disabled = true;
    syncBookmarks.classList.remove("done");
    error.textContent = "";
    syncBookmarks.textContent = "正在收集收藏…";
    try {
      const result = await browser.runtime.sendMessage({
        type: "sync-x-bookmarks",
        tabId,
      }) as BookmarksSyncResult;
      if (result.ok) {
        syncBookmarks.textContent = "✓ " + bookmarksSyncMessage(result.outcome, result.collected, result.reachedKnown);
        syncBookmarks.classList.add("done");
      } else {
        error.textContent = bookmarksErrorCopy[result.code] ?? "同步未完成，请重试。";
        syncBookmarks.textContent = "同步收藏夹到桌面 App";
        syncBookmarks.disabled = false;
      }
    } catch {
      error.textContent = "同步失败，请重试。";
      syncBookmarks.textContent = "同步收藏夹到桌面 App";
      syncBookmarks.disabled = false;
    }
  };
} else {
  try {
    const preview = await browser.runtime.sendMessage({
      type: "preview-current-page",
      tabId,
    }) as SafeCapturePreview;
    const avail = popupAvailability(preview);
    setAvailability(avail.tone, avail.label);
    renderPlatform(popupPlatformLabel(preview.platform, preview.version, preview.imageCount));
    status.textContent = preview.title;
    renderMeta(popupMetaChips(preview));
    renderMetadataDiagnostic(preview.metadataDiagnostic);
    if (avail.tone === "blocked") {
      send.disabled = true;
      send.textContent = "暂不支持此平台";
    } else {
      // 预览成功才启用。按钮初始 disabled（见 index.html 注释）：onclick 在这段
      // 顶层 await 之后才挂上，提前可点等于点了没反应。
      send.textContent = popupActionPresentation(selectedAction).button;
      send.disabled = false;
    }
  } catch (cause) {
    status.textContent = "当前页面不可捕获";
    setAvailability("blocked", "不可捕获");
    // 这里原本把原因整个吞掉，界面上只剩一句没有信息量的提示，排查时等于没有线索。
    // 把真实 message 亮出来：CAPTURE_CONTENT_EMPTY 是抓到了页面但没有正文，
    // "Cannot access contents of url…" 是注入被拒，两者的修法完全不同。
    const message = cause instanceof Error ? cause.message : String(cause);
    const failure = popupPreviewFailure(message);
    error.textContent = failure.message;
    send.hidden = true;
    if (failure.canReload) {
      recoveryMode = "reload";
      recoveryAction.textContent = "重新读取页面";
      recoveryAction.hidden = false;
    } else {
      recoveryMode = null;
      recoveryAction.hidden = true;
    }
  }

  const submit = async () => {
    send.disabled = true;
    send.classList.remove("done");
    error.textContent = "";
    resultNotice.hidden = true;
    recoveryAction.hidden = true;
    openApp.hidden = true;
    renderMetadataDiagnostic(undefined);
    try {
      const result = await browser.runtime.sendMessage({
        type: "send-current-page",
        tabId,
        requestedAction: selectedAction,
      }) as SafeExtensionSendResult;
      renderMetadataDiagnostic(result.metadataDiagnostic);
      const recovery = popupRecoveryForSendResult(result);
      if (recovery) {
        error.textContent = recovery.message;
        send.hidden = true;
        if (recovery.action === "open_app" || recovery.action === "open_settings") {
          openApp.textContent = recovery.label;
          openApp.hidden = false;
        } else if (recovery.action === "retry" || recovery.action === "reload") {
          recoveryMode = recovery.action;
          recoveryAction.textContent = recovery.label;
          recoveryAction.hidden = false;
        }
      } else {
        actionCard.hidden = true;
        send.hidden = true;
        resultNotice.textContent = "✓ " + popupActionPresentation(selectedAction).success;
        resultNotice.hidden = false;
        openApp.textContent = "打开汲作查看";
        openApp.hidden = false;
      }
    } catch {
      renderMetadataDiagnostic(undefined);
      error.textContent = "发送失败，请重试。";
      send.hidden = true;
      recoveryMode = "retry";
      recoveryAction.textContent = "重试发送";
      recoveryAction.hidden = false;
    }
  };
  send.onclick = submit;
  recoveryAction.onclick = () => {
    if (recoveryMode === "reload") window.location.reload();
    else {
      send.hidden = false;
      void submit();
    }
  };
}
