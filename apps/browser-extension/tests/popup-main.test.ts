import { afterEach, describe, expect, it, vi } from "vitest";
import type { DouyinMetadataDiagnostic } from "../src/content/douyin-metadata-diagnostic";

type FakeElement = {
  textContent: string;
  hidden: boolean;
  disabled: boolean;
  onclick: (() => Promise<void>) | null;
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
  const element = (): FakeElement => ({ textContent: "", hidden: false, disabled: false, onclick: null });
  return {
    "#status": element(), "#count": element(), "#media-status": element(), "#metadata-diagnostic": element(),
    "#error": element(), "#send": element(), "#extension-name": element(), "#build-label": element(),
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("popup metadata diagnostic fresh-send lifecycle", () => {
  it("shows preview diagnostics, clears before the send await, and keeps them hidden after rejection", async () => {
    const elements = popupDOM();
    elements["#metadata-diagnostic"]!.hidden = true;
    let rejectSend: ((reason?: unknown) => void) | undefined;
    const pendingSend = new Promise<never>((_resolve, reject) => { rejectSend = reject; });
    const sendMessage = vi.fn()
      .mockResolvedValueOnce({ title: "预览", characterCount: 2, version: 1, metadataDiagnostic: diagnostic })
      .mockReturnValueOnce(pendingSend);
    vi.stubGlobal("document", {
      title: "",
      querySelector: (selector: string) => elements[selector] ?? null,
    });
    vi.stubGlobal("browser", {
      runtime: {
        getManifest: () => ({ name: "LinkDigest", version: "0.2.0", version_name: "diagnostic" }),
        sendMessage,
      },
      tabs: { query: vi.fn().mockResolvedValue([{ id: 7 }]) },
    });

    await import("../entrypoints/popup/main");
    const pre = elements["#metadata-diagnostic"]!;
    expect(pre.hidden).toBe(false);
    expect(pre.textContent).toContain("元数据诊断（仅当前弹窗，不发送、不保存）");

    const click = elements["#send"]!.onclick!();
    expect(pre.hidden).toBe(true);
    expect(pre.textContent).toBe("");
    rejectSend!(new Error("transport sentinel"));
    await click;
    expect(pre.hidden).toBe(true);
    expect(pre.textContent).toBe("");
    expect(elements["#error"]!.textContent).toBe("发送失败，请重试。");
  });
});
