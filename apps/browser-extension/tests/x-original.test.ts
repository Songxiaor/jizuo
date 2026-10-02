import { describe, expect, it } from "vitest";
import { showXOriginal } from "../src/content/x-original";

/** 一个会被点切换的「显示原文 / 显示翻译」按钮，和它控制的正文。 */
function translatedPost() {
  const post = { text: "我们给Jev提供了2,029个真实的电话呼叫。" };
  const button = {
    textContent: "显示原文",
    click() {
      if (this.textContent === "显示原文") {
        this.textContent = "显示翻译";
        post.text = "We gave Jev 2,029 real phone calls.";
      } else {
        this.textContent = "显示原文";
        post.text = "我们给Jev提供了2,029个真实的电话呼叫。";
      }
    },
  };
  const documentLike = {
    location: { href: "https://x.com/muratcan/status/2104959648482701686" },
    querySelectorAll: () => [button],
  } as unknown as Document;
  return { documentLike, post, button };
}

describe("X auto-translation: save the original (2026-10-02 Syc：存原文)", () => {
  it("switches a translated post to the original and switches it back afterwards", async () => {
    const { documentLike, post, button } = translatedPost();
    const restore = await showXOriginal(documentLike, 500);
    expect(post.text).toBe("We gave Jev 2,029 real phone calls.");
    expect(button.textContent).toBe("显示翻译");
    await restore?.();
    expect(post.text).toBe("我们给Jev提供了2,029个真实的电话呼叫。");
  });

  it("does nothing on posts that are not translated or pages that are not X posts", async () => {
    const { documentLike, button } = translatedPost();
    button.textContent = "显示翻译";
    expect(await showXOriginal(documentLike, 100)).toBeUndefined();
    const other = { location: { href: "https://example.com/post" }, querySelectorAll: () => [] } as unknown as Document;
    expect(await showXOriginal(other, 100)).toBeUndefined();
  });
});
