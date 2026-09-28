import { afterEach, describe, expect, it, vi } from "vitest";

type FakeElement = {
  textContent: string;
  innerHTML: string;
  hidden: boolean;
  disabled: boolean;
  onclick: (() => Promise<void>) | null;
  dataset: Record<string, string>;
  className: string;
  classList: { add: (c: string) => void; remove: (c: string) => void; contains: (c: string) => boolean };
  replaceChildren: () => void;
  append: (...nodes: unknown[]) => void;
  addEventListener: (type: string, handler: () => void) => void;
  querySelectorAll: () => unknown[];
  children: unknown[];
};

function popupDOM(): Record<string, FakeElement> {
  const element = (): FakeElement => {
    const children: unknown[] = [];
    return {
      textContent: "", innerHTML: "", hidden: false, disabled: false, onclick: null,
      dataset: {}, className: "",
      classList: { add: () => {}, remove: () => {}, contains: () => false },
      replaceChildren: () => { children.length = 0; },
      append: (...nodes: unknown[]) => { children.push(...nodes); },
      addEventListener: () => {}, querySelectorAll: () => [], children,
    };
  };
  const ids = [
    "#availability", "#platform", "#status", "#meta", "#diag", "#metadata-diagnostic", "#error", "#send",
    "#extension-name", "#build-label", "#sync-bookmarks", "#sync-selected", "#read-x-profile",
    "#bookmarks-picker", "#picker-list", "#picker-count", "#picker-select-all", "#picker-select-none",
    "#picker-select-new", "#action-card", "#action-detail", "#result", "#recovery-action", "#open-app",
    "#comments-picker", "#comments-count", "#comments-list", "#comments-note",
    "#comments-select-all", "#comments-select-none",
  ];
  return Object.fromEntries(ids.map((id) => [id, element()]));
}

afterEach(() => vi.unstubAllGlobals());

async function openPopup(collectResult: unknown) {
  const elements = popupDOM();
  const messages: Array<Record<string, unknown>> = [];
  const sendMessage = vi.fn(async (message: Record<string, unknown>) => {
    messages.push(message);
    if (message.type === "preview-current-page") {
      return { title: "帖子", characterCount: 10, version: 1, platform: "generic", completeness: "full_article" };
    }
    if (message.type === "collect-comments") return collectResult;
    if (message.type === "send-current-page") {
      return { response: { kind: "taskAccepted", version: 1, requestId: "r", characterCount: 10 } };
    }
    return undefined;
  });
  vi.stubGlobal("document", {
    title: "",
    querySelector: (selector: string) => elements[selector] ?? null,
    querySelectorAll: () => [],
    createElement: () => ({ className: "", textContent: "", append: () => {} }),
    createTextNode: (text: string) => ({ textContent: text }),
  });
  vi.stubGlobal("browser", {
    runtime: { getManifest: () => ({ name: "LinkDigest", version: "0.2.0" }), sendMessage },
    tabs: { query: vi.fn().mockResolvedValue([{ id: 7, url: "https://www.reddit.com/r/x/comments/abc/t/" }]) },
  });
  vi.resetModules();
  await import("../entrypoints/popup/main");
  // 让 collect-comments 的异步结果落地。
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { elements, messages };
}

describe("popup comment modes", () => {
  it("auto-save shows a one-line status, no checklist, and sends the auto mode", async () => {
    const { elements, messages } = await openPopup({ ok: false, code: "auto", platform: "reddit", limit: 20 });
    expect(elements["#comments-note"]!.textContent).toBe("将自动保存前 20 条评论");
    expect(elements["#comments-list"]!.children).toHaveLength(0);
    expect(elements["#comments-select-all"]!.hidden).toBe(true);
    await elements["#send"]!.onclick!();
    const send = messages.find((message) => message.type === "send-current-page")!;
    expect(send.commentMode).toEqual({ kind: "auto", limit: 20 });
    expect(send.selectedCommentIDs).toBeUndefined();
    expect(elements["#result"]!.hidden).toBe(false);
  });

  it("不抓 shows the neutral note and still saves the page", async () => {
    const { elements, messages } = await openPopup({ ok: false, code: "disabled", platform: "reddit" });
    expect(elements["#comments-note"]!.textContent).toBe("这个平台设为不抓评论（可在汲作设置 → 评 · 评论 里改）");
    await elements["#send"]!.onclick!();
    const send = messages.find((message) => message.type === "send-current-page")!;
    expect(send.commentMode).toEqual({ kind: "disabled" });
    expect(elements["#result"]!.hidden).toBe(false);
  });

  it("old flow (failed read) sends no comment mode", async () => {
    const { elements, messages } = await openPopup({ ok: false, code: "failed", limit: 20 });
    expect(elements["#comments-count"]!.textContent).toBe("评论读取失败");
    await elements["#send"]!.onclick!();
    const send = messages.find((message) => message.type === "send-current-page")!;
    expect(send).not.toHaveProperty("commentMode");
  });
});
