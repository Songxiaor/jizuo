import { afterEach, describe, expect, it, vi } from "vitest";
import type { DouyinMetadataDiagnostic } from "../src/content/douyin-metadata-diagnostic";

type FakeElement = {
  textContent: string;
  hidden: boolean;
  disabled: boolean;
  onclick: (() => Promise<void>) | null;
  dataset: Record<string, string>;
  className: string;
  classList: { add: (c: string) => void; remove: (c: string) => void };
  replaceChildren: () => void;
  append: (...nodes: unknown[]) => void;
  addEventListener: (type: string, handler: () => void) => void;
  value: string;
  checked: boolean;
};

const diagnostic: DouyinMetadataDiagnostic = {
  missingPublished: true,
  missingStatsMask: 1,
  dom: {
    route: { eligible: true, rejectCode: "none" },
    video: { positiveVisibleCount: 1, dominantVideoCount: 1, rejectCode: "none" },
    scopes: { safeCount: 1, dedicatedCount: 0, rejectCode: "none" },
    dom: { publishedSelectorHit: false, statSelectorHitMask: 1, statAcceptedCount: 1 },
  },
  ssr: { fixedRootPresent: 1, fixedRootParseable: 1, exactHit: false, rejectCode: "no_exact_item", limitCode: "none" },
};

function popupDOM(): Record<string, FakeElement> {
  const element = (): FakeElement => ({
    textContent: "", hidden: false, disabled: false, onclick: null,
    dataset: {}, className: "",
    classList: { add: () => {}, remove: () => {} },
    replaceChildren: () => {}, append: () => {},
    addEventListener: () => {}, value: "", checked: false,
  });
  return {
    "#availability": element(), "#platform": element(), "#status": element(), "#meta": element(),
    "#diag": element(), "#metadata-diagnostic": element(),
    "#error": element(), "#send": element(), "#extension-name": element(), "#build-label": element(),
    "#sync-bookmarks": element(), "#action-card": element(), "#action-detail": element(),
    "#result": element(), "#recovery-action": element(), "#open-app": element(),
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("popup metadata diagnostic fresh-send lifecycle", () => {
  it("shows preview diagnostics, clears before the send await, and keeps them hidden after rejection", async () => {
    const elements = popupDOM();
    elements["#diag"]!.hidden = true;
    let rejectSend: ((reason?: unknown) => void) | undefined;
    const pendingSend = new Promise<never>((_resolve, reject) => { rejectSend = reject; });
    const sendMessage = vi.fn()
      .mockResolvedValueOnce({
        title: "预览", characterCount: 2, version: 1,
        platform: "generic", completeness: "full_article", metadataDiagnostic: diagnostic,
      })
      .mockReturnValueOnce(pendingSend);
    vi.stubGlobal("document", {
      title: "",
      querySelector: (selector: string) => elements[selector] ?? null,
      querySelectorAll: () => [],
      createElement: () => ({ className: "", textContent: "", append: () => {} }),
      createTextNode: (text: string) => ({ textContent: text }),
    });
    vi.stubGlobal("browser", {
      runtime: {
        getManifest: () => ({ name: "LinkDigest", version: "0.2.0", version_name: "diagnostic" }),
        sendMessage,
      },
      tabs: { query: vi.fn().mockResolvedValue([{ id: 7 }]) },
    });

    await import("../entrypoints/popup/main");
    // 诊断折叠容器（#diag）随内容出现；文本进 #metadata-diagnostic。
    const diag = elements["#diag"]!;
    const pre = elements["#metadata-diagnostic"]!;
    expect(diag.hidden).toBe(false);
    expect(pre.textContent).toContain("元数据诊断（仅当前弹窗，不发送、不保存）");

    const click = elements["#send"]!.onclick!();
    expect(diag.hidden).toBe(true);
    expect(pre.textContent).toBe("");
    rejectSend!(new Error("transport sentinel"));
    await click;
    expect(diag.hidden).toBe(true);
    expect(pre.textContent).toBe("");
    expect(elements["#error"]!.textContent).toBe("发送失败，请重试。");
  });
});
