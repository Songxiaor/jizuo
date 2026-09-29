import { afterEach, describe, expect, it, vi } from "vitest";

/**
 * 弹窗查重与「在汲作里打开」（2026-09-29 第二批）。真机上点不到弹窗里的按钮（浮层失焦即关），
 * 这里用假 DOM 走完「查到已存过 → 点打开」，确认发给后台的 open-app 带着这条的 taskID。
 */
type Handler = (event?: { preventDefault: () => void }) => void;
type FakeElement = Record<string, unknown> & {
  hidden: boolean; textContent: string; handlers: Record<string, Handler[]>;
};

function element(): FakeElement {
  const handlers: Record<string, Handler[]> = {};
  const children: unknown[] = [];
  return {
    textContent: "", innerHTML: "", hidden: false, disabled: false, onclick: null,
    dataset: {}, className: "", title: "", type: "", value: "", checked: false,
    media: "", srcset: "", src: "", alt: "",
    classList: { add: () => {}, remove: () => {}, contains: () => false, toggle: () => {} },
    replaceChildren: (...nodes: unknown[]) => { children.length = 0; children.push(...nodes); },
    append: (...nodes: unknown[]) => { children.push(...nodes); },
    addEventListener: (type: string, handler: Handler) => { (handlers[type] ??= []).push(handler); },
    querySelectorAll: () => [], children, handlers,
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("popup duplicate check", () => {
  it("shows the saved card and opens that exact item in 汲作", async () => {
    const elements = new Map<string, FakeElement>();
    // index.html 里这几块一开始就带 hidden。
    for (const id of ["#saved-view", "#dup-view", "#failure-view", "#result-actions", "#save-again", "#open-app"]) {
      const node = element();
      node.hidden = true;
      elements.set(id, node);
    }
    const messages: Array<Record<string, unknown>> = [];
    const taskID = "40847250-39d8-4983-a3b6-e44c9bd8122c";
    vi.stubGlobal("document", {
      title: "",
      querySelector: (selector: string) => {
        if (!elements.has(selector)) elements.set(selector, element());
        return elements.get(selector);
      },
      querySelectorAll: () => [],
      createElement: () => element(),
      createTextNode: (text: string) => ({ textContent: text }),
    });
    vi.stubGlobal("browser", {
      runtime: {
        getManifest: () => ({ name: "LinkDigest", version: "0.2.0" }),
        sendMessage: vi.fn(async (message: Record<string, unknown>) => {
          messages.push(message);
          if (message.type === "preview-current-page") {
            return { title: "短视频", characterCount: 10, version: 2, platform: "douyin", completeness: "full_article", media: { kind: "directFile" }, pageURL: "https://www.douyin.com/video/7689872724293963058" };
          }
          if (message.type === "page-status") {
            return { kind: "found", taskID, savedAt: 1, steps: [{ step: "record", state: "done" }] };
          }
          if (message.type === "collect-comments") return { ok: false, code: "unsupported" };
          return undefined;
        }),
      },
      tabs: { query: vi.fn().mockResolvedValue([{ id: 7, url: "https://www.douyin.com/video/7689872724293963058" }]) },
    });
    vi.resetModules();
    await import("../entrypoints/popup/main");
    await new Promise((resolve) => setTimeout(resolve, 0));
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messages.find((message) => message.type === "page-status")?.url).toBe("https://www.douyin.com/video/7689872724293963058");
    expect(elements.get("#dup-view")!.hidden).toBe(false);
    expect(elements.get("#action-card")!.hidden).toBe(true);
    expect(elements.get("#send")!.hidden).toBe(true);
    expect(elements.get("#availability")!.textContent).toBe("已存过");

    const click = elements.get("#open-app")!.handlers.click!.at(-1)!;
    click({ preventDefault: () => {} });
    expect(messages.at(-1)).toEqual({ type: "open-app", taskID });
  });
});
