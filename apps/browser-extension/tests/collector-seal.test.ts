import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { collectorSealSVG, savedNoticeMarkup } from "../src/collector-seal";

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
  value: string;
  checked: boolean;
};

const popupHTML = readFileSync(
  fileURLToPath(new URL("../entrypoints/popup/index.html", import.meta.url)),
  "utf8",
);

describe("collector seal markup", () => {
  it("draws a white-on-vermilion 汲 with the water motif and ink texture", () => {
    const svg = collectorSealSVG(40);
    expect(svg).toContain('viewBox="0 0 100 100"');
    expect(svg).toContain('width="40" height="40"');
    expect(svg).toContain(">汲</text>");
    expect(svg).toContain('font-size="50"');
    expect(svg).toContain('dy=".36em"');
    expect(svg).toContain("color:var(--seal-paper)");
    expect(svg).toContain('stroke-opacity=".55"');
    expect(svg).toContain("M10 90 q6.5 -8 13 0");
    expect(svg).toContain("M16.5 83 q6.5 -7 13 0");
    expect(svg).toContain('scale="2.6"');
    expect(svg).toContain('values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  -4 0 0 0 3"');
    expect(svg).toContain('operator="in"');
  });

  it("gives every seal its own filter id", () => {
    const ids = [collectorSealSVG(), collectorSealSVG()].map((svg) => /filter id="([^"]+)"/.exec(svg)?.[1]);
    expect(ids[0]).toBeTruthy();
    expect(ids[0]).not.toBe(ids[1]);
    for (const [index, svg] of [collectorSealSVG(), collectorSealSVG()].entries()) {
      const id = /filter id="([^"]+)"/.exec(svg)?.[1];
      expect(svg, `seal ${index}`).toContain(`filter="url(#${id})"`);
    }
  });

  it("puts the seal before the unchanged message and escapes the message", () => {
    const html = savedNoticeMarkup("已保存到汲作");
    expect(html).toMatch(/^<span class="collector-seal" role="img" aria-label="汲" data-seal="汲">/);
    expect(html.indexOf("collector-seal")).toBeLessThan(html.indexOf("已保存到汲作"));
    expect(html).not.toContain("✓");
    expect(savedNoticeMarkup("<b>&")).toContain("&lt;b&gt;&amp;");
  });
});

describe("collector seal styles", () => {
  it("defines seal colors for light and dark", () => {
    expect(popupHTML).toContain("--seal: #B8321C;");
    expect(popupHTML).toContain("--seal-paper: #FCFCFB;");
    expect(popupHTML).toContain("--seal: #E07A66;");
    expect(popupHTML).toContain("--seal-paper: #1D1E21;");
  });

  it("presses the seal down, and under reduced motion shows it at rest", () => {
    expect(popupHTML).toMatch(/animation: collector-seal-press 0\.32s cubic-bezier\(\.2,\.9,\.3,1\.2\)/);
    expect(popupHTML).toMatch(/from \{ transform: rotate\(-1deg\) scale\(1\.35\); opacity: 0; \}/);
    expect(popupHTML).toMatch(/55% +\{ transform: rotate\(-1deg\) scale\(\.94\)/);
    const reduced = /@media \(prefers-reduced-motion: reduce\) \{([^}]*\})/.exec(popupHTML)?.[1] ?? "";
    expect(reduced).toMatch(/\.collector-seal \{ animation: none; \}/);
    // 关掉动画后落在基础样式上：基础样式必须是最终姿态（不透明、只转 -1°），否则章就看不见。
    const base = /\n  \.collector-seal \{([^}]*)\}/.exec(popupHTML)?.[1] ?? "";
    expect(base).toContain("transform: rotate(-1deg);");
    expect(base).not.toMatch(/opacity:\s*0/);
    expect(base).not.toContain("scale(");
  });
});

afterEach(() => vi.unstubAllGlobals());

describe("popup capture success", () => {
  it("stamps the 汲 seal on the saved card above the success copy", async () => {
    const element = (): FakeElement => {
      const classes = new Set<string>();
      return {
        textContent: "", innerHTML: "", hidden: false, disabled: false, onclick: null,
        dataset: {}, className: "",
        classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
        replaceChildren: () => {}, append: () => {},
        addEventListener: () => {}, querySelectorAll: () => [], value: "", checked: false,
      };
    };
    const elements = new Map<string, FakeElement>();
    const sendMessage = vi.fn(async (message: { type: string }) => {
      if (message.type === "preview-current-page") {
        return { title: "预览", characterCount: 2, version: 1, platform: "generic", completeness: "full_article" };
      }
      if (message.type === "collect-comments") return { ok: false, code: "unsupported" };
      if (message.type === "send-current-page") {
        return { response: { kind: "taskAccepted", version: 1, requestId: "r1", characterCount: 2 } };
      }
      return undefined;
    });
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
      runtime: { getManifest: () => ({ name: "LinkDigest", version: "0.2.0" }), sendMessage },
      tabs: { query: vi.fn().mockResolvedValue([{ id: 7, url: "https://example.com/post" }]) },
    });

    await import("../entrypoints/popup/main");
    await elements.get("#send")!.onclick!();

    const seal = elements.get("#saved-seal")!;
    expect(elements.get("#error")!.textContent).toBe("");
    expect(elements.get("#saved-view")!.hidden).toBe(false);
    expect(seal.innerHTML).toContain('aria-label="汲"');
    expect(seal.innerHTML).toContain('data-seal="汲"');
    expect(seal.innerHTML).toContain("<svg");
    expect(elements.get("#saved-detail")!.textContent).toContain("已保存到汲作");
  });
});
