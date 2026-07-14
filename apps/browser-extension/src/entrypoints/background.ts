import { extractPageInIsolatedWorld, type ExtractedPage } from "../content/extract";
import { validateCapture, type CaptureEnvelopeV1, type NativeResponse } from "../contract";
import { mapNativeFailure, withTimeout } from "../native-client";

const HOST_NAME = "com.syc.linkdigest.v01";
const requestId = () => crypto.randomUUID();

export async function captureFromTab(tabId: number): Promise<CaptureEnvelopeV1> {
  const result = await browser.scripting.executeScript({ target: { tabId }, func: extractPageInIsolatedWorld });
  const page = result[0]?.result as ExtractedPage | undefined;
  if (!page) throw new Error("CAPTURE_CONTENT_EMPTY");
  const now = new Date().toISOString();
  return { version: 1, requestId: requestId(), createdAt: now, source: { kind: "browser_capture", url: page.url, title: page.title || null, platform: "generic" }, capture: { method: page.method, text: page.text, characterCount: page.characterCount, completeness: page.method === "selection" ? "selection_only" : "full_article", capturedAt: now }, evidence: { sourceLabel: "Current page DOM", usedCookie: false } };
}

export async function sendCapture(tabId: number): Promise<NativeResponse> {
  const envelope = await captureFromTab(tabId);
  const invalid = validateCapture(envelope);
  if (invalid) return { kind: "error", error: { code: invalid, action: "retry" } };
  try {
    const response = await withTimeout(browser.runtime.sendNativeMessage(HOST_NAME, envelope), 10_000) as NativeResponse;
    return response;
  } catch (error) {
    const failure = mapNativeFailure(error);
    return { kind: "error", error: failure };
  }
}

export default defineBackground(() => {
  browser.runtime.onMessage.addListener(async (message: { type?: string; tabId?: number }) => {
    if (message.type !== "send-current-page" || typeof message.tabId !== "number") return undefined;
    return sendCapture(message.tabId);
  });
});
