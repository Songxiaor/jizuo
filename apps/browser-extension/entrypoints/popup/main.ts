export {};
import {
  popupBuildLabel,
  popupMetadataDiagnostic,
  popupMediaStatus,
  popupMessageForSendResult,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
} from "../../src/popup-presentation";
import type { DouyinSessionDiagnostic } from "../../src/content/douyin-session-detail";
import type { DouyinMetadataDiagnostic } from "../../src/content/douyin-metadata-diagnostic";
type SafeCapturePreview = {
  title: string;
  characterCount: number;
  version: 1 | 2;
  media?: SafeMediaPreview;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
};
const status = document.querySelector<HTMLParagraphElement>("#status")!;
const count = document.querySelector<HTMLParagraphElement>("#count")!;
const mediaStatus = document.querySelector<HTMLParagraphElement>("#media-status")!;
const metadataDiagnostic = document.querySelector<HTMLPreElement>("#metadata-diagnostic")!;
const error = document.querySelector<HTMLPreElement>("#error")!;
const send = document.querySelector<HTMLButtonElement>("#send")!;
const manifest = browser.runtime.getManifest();
const extensionName = manifest.name;
document.title = extensionName;
document.querySelector("#extension-name")!.textContent = extensionName;
document.querySelector("#build-label")!.textContent = popupBuildLabel(manifest);
function renderMetadataDiagnostic(diagnostic: DouyinMetadataDiagnostic | undefined): void {
  const rendered = popupMetadataDiagnostic(diagnostic);
  metadataDiagnostic.hidden = rendered === null;
  metadataDiagnostic.textContent = rendered ?? "";
}
const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
const tabId = tab?.id;
if (tabId === undefined) { status.textContent = "无法读取当前标签页"; send.disabled = true; }
else {
  try {
    const preview = await browser.runtime.sendMessage({
      type: "preview-current-page",
      tabId,
    }) as SafeCapturePreview;
    status.textContent = preview.title;
    count.textContent = `${preview.characterCount} 个字符 · V${preview.version}`;
    mediaStatus.textContent = popupMediaStatus(preview.media, preview.mediaDiagnostic);
    renderMetadataDiagnostic(preview.metadataDiagnostic);
  } catch { status.textContent = "当前页面不可捕获"; send.disabled = true; }
  send.onclick = async () => {
    send.disabled = true;
    error.textContent = "";
    // A send is a new capture: never leave preview-only diagnostic state visible
    // while its fresh result is pending.
    renderMetadataDiagnostic(undefined);
    try {
      // Sending intentionally performs a fresh atomic capture; preview data is
      // never reused as a stale media handoff.
      const result = await browser.runtime.sendMessage({ type: "send-current-page", tabId }) as SafeExtensionSendResult;
      if (result.mediaDiagnostic) {
        mediaStatus.textContent = popupMediaStatus(undefined, result.mediaDiagnostic);
      }
      renderMetadataDiagnostic(result.metadataDiagnostic);
      const message = popupMessageForSendResult(result);
      if (message) error.textContent = message;
      else status.textContent = "已发送";
    } catch {
      renderMetadataDiagnostic(undefined);
      error.textContent = "发送失败，请重试。";
    } finally {
      send.disabled = false;
    }
  };
}
