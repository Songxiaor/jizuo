import { isXStatusURL } from "./extract";

/**
 * X 自动翻译：先把帖子切回原文再提取，提取完切回去（2026-10-02 Syc：「存原文」）。
 *
 * Syc 的 X 开着「自动翻译帖子」，英文帖子显示成中文，扩展原来存下的是 X 的机器译文。
 * 帖子上有现成的「显示原文 / 显示翻译」按钮（只切换显示，不改任何账号设置），这里点
 * 「显示原文」，等正文真的换成原文，返回一个把显示切回去的函数。帖子串、引用帖里被翻译的
 * 每一条都切；切不动（按钮不见、等不到变化）就原样提取，弹窗仍会提醒。
 */
const SHOW_ORIGINAL = /^(?:显示原文|Show original)$/iu;
const SHOW_TRANSLATION = /^(?:显示翻译|Show translation)$/iu;

function buttons(documentLike: Document, pattern: RegExp): HTMLElement[] {
  return Array.from(documentLike.querySelectorAll<HTMLElement>("article button, article [role='button']"))
    .filter((node) => pattern.test((node.textContent ?? "").trim()));
}

export async function showXOriginal(
  documentLike: Document = document,
  waitMs = 3_000,
): Promise<(() => Promise<void>) | undefined> {
  if (!isXStatusURL(documentLike.location?.href ?? "")) return undefined;
  const translated = buttons(documentLike, SHOW_ORIGINAL);
  if (translated.length === 0) return undefined;
  for (const button of translated) button.click();
  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline && buttons(documentLike, SHOW_ORIGINAL).length > 0) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const switched = translated.length - buttons(documentLike, SHOW_ORIGINAL).length;
  if (switched <= 0) return undefined;
  return async () => {
    for (const button of buttons(documentLike, SHOW_TRANSLATION).slice(0, switched)) button.click();
  };
}
