export {};
import {
  popupAvailability,
  popupBuildLabel,
  popupMetaChips,
  popupMessageForSendResult,
  popupMetadataDiagnostic,
  popupPlatformIcon,
  popupPlatformLabel,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
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
  native_error: "无法连接 LinkDigest，或本次同步未被受理，请确认 App 已打开后重试。",
  injection_failed: "读取收藏夹失败，请刷新页面后重试。",
};

type CapturePlatform =
  | "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github";
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

function renderPlatform(icon: string, label: string): void {
  platform.replaceChildren();
  const dot = document.createElement("span");
  dot.className = "dot";
  dot.textContent = icon;
  platform.append(dot, document.createTextNode(label));
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
  syncBookmarks.hidden = false;
  setAvailability("ready", "X 收藏夹");
  renderPlatform(popupPlatformIcon("x"), "X · 收藏夹");
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
    renderPlatform(
      popupPlatformIcon(preview.platform),
      popupPlatformLabel(preview.platform, preview.version, preview.imageCount),
    );
    status.textContent = preview.title;
    renderMeta(popupMetaChips(preview));
    renderMetadataDiagnostic(preview.metadataDiagnostic);
    if (avail.tone === "blocked") {
      send.disabled = true;
      send.textContent = "暂不支持此平台";
    }
  } catch {
    status.textContent = "当前页面不可捕获";
    setAvailability("blocked", "不可捕获");
    send.disabled = true;
  }

  send.onclick = async () => {
    send.disabled = true;
    send.classList.remove("done");
    error.textContent = "";
    renderMetadataDiagnostic(undefined);
    try {
      const result = await browser.runtime.sendMessage({
        type: "send-current-page",
        tabId,
      }) as SafeExtensionSendResult;
      renderMetadataDiagnostic(result.metadataDiagnostic);
      const message = popupMessageForSendResult(result);
      if (message) {
        error.textContent = message;
        send.disabled = false;
      } else {
        send.textContent = "✓ 已发送到 App";
        send.classList.add("done");
      }
    } catch {
      renderMetadataDiagnostic(undefined);
      error.textContent = "发送失败，请重试。";
      send.disabled = false;
    }
  };
}
