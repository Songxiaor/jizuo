export {};
import {
  popupAvailability,
  popupBuildLabel,
  popupMediaStatus,
  popupMessageForSendResult,
  popupMetadataDiagnostic,
  popupPlatformLabel,
  popupScaleLabel,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
} from "../../src/popup-presentation";
import type { DouyinSessionDiagnostic } from "../../src/content/douyin-session-detail";
import type { DouyinMetadataDiagnostic } from "../../src/content/douyin-metadata-diagnostic";

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
};

const availability = document.querySelector<HTMLSpanElement>("#availability")!;
const platform = document.querySelector<HTMLDivElement>("#platform")!;
const status = document.querySelector<HTMLHeadingElement>("#status")!;
const scale = document.querySelector<HTMLParagraphElement>("#scale")!;
const mediaStatus = document.querySelector<HTMLParagraphElement>("#media-status")!;
const diag = document.querySelector<HTMLDetailsElement>("#diag")!;
const metadataDiagnostic = document.querySelector<HTMLPreElement>("#metadata-diagnostic")!;
const error = document.querySelector<HTMLPreElement>("#error")!;
const send = document.querySelector<HTMLButtonElement>("#send")!;

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
} else {
  try {
    const preview = await browser.runtime.sendMessage({
      type: "preview-current-page",
      tabId,
    }) as SafeCapturePreview;
    const avail = popupAvailability(preview);
    setAvailability(avail.tone, avail.label);
    platform.textContent = popupPlatformLabel(preview.platform, preview.version);
    status.textContent = preview.title;
    scale.textContent = popupScaleLabel(preview.characterCount, preview.completeness);
    mediaStatus.textContent = preview.version === 2
      ? popupMediaStatus(preview.media, preview.mediaDiagnostic)
      : "";
    renderMetadataDiagnostic(preview.metadataDiagnostic);
    send.disabled = avail.tone === "blocked";
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
      if (result.mediaDiagnostic) {
        mediaStatus.textContent = popupMediaStatus(undefined, result.mediaDiagnostic);
      }
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
