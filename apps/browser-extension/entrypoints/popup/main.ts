export {};
import { extractPageInIsolatedWorld } from "../../src/content/extract";
import { popupMessageForResponse } from "../../src/popup-presentation";
import type { NativeResponse } from "../../src/contract";
const status = document.querySelector<HTMLParagraphElement>("#status")!;
const count = document.querySelector<HTMLParagraphElement>("#count")!;
const error = document.querySelector<HTMLPreElement>("#error")!;
const send = document.querySelector<HTMLButtonElement>("#send")!;
const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
const tabId = tab?.id;
if (tabId === undefined) { status.textContent = "无法读取当前标签页"; send.disabled = true; }
else {
  try {
    const [result] = await browser.scripting.executeScript({ target: { tabId }, func: extractPageInIsolatedWorld });
    const page = result?.result; status.textContent = page?.title ?? "当前页面"; count.textContent = `${page?.characterCount ?? 0} 个字符`;
  } catch { status.textContent = "当前页面不可捕获"; send.disabled = true; }
  send.onclick = async () => {
    send.disabled = true;
    error.textContent = "";
    const response = await browser.runtime.sendMessage({ type: "send-current-page", tabId }) as NativeResponse;
    const message = popupMessageForResponse(response);
    if (message) error.textContent = message;
    else status.textContent = "已发送";
    send.disabled = false;
  };
}
