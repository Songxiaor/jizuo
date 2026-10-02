import { collectCommentsFromDocument } from "../src/content/comments";
import { showXOriginal } from "../src/content/x-original";

/**
 * 注入到页面里收集评论的入口，与 extract-page 同样走 `executeScript({ files })`，
 * 让页面里跑的就是可单测的 `collectCommentsFromDocument` 本身。
 *
 * `files` 注入带不了参数：background 先用一次 `func` 注入把条数写到同一隔离世界
 * 的 `__linkdigestCommentLimit`，这里读出来。返回 Promise，Chrome 会等它完成。
 *
 * X 自动翻译的回复同样先切回原文再收，收完切回去（2026-10-02 Syc：存原文）；
 * 往下翻时新加载的回复 X 可能又翻译，那部分按页面显示的存。
 */
export default defineUnlistedScript(async () => {
  const restoreTranslation = await showXOriginal(document);
  try {
    return await collectCommentsFromDocument(
      document,
      (globalThis as { __linkdigestCommentLimit?: unknown }).__linkdigestCommentLimit,
    );
  } finally {
    await restoreTranslation?.();
  }
});
