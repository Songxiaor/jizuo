import { collectCommentsFromDocument } from "../src/content/comments";

/**
 * 注入到页面里收集评论的入口，与 extract-page 同样走 `executeScript({ files })`，
 * 让页面里跑的就是可单测的 `collectCommentsFromDocument` 本身。
 *
 * `files` 注入带不了参数：background 先用一次 `func` 注入把条数写到同一隔离世界
 * 的 `__linkdigestCommentLimit`，这里读出来。返回 Promise，Chrome 会等它完成。
 */
export default defineUnlistedScript(() =>
  collectCommentsFromDocument(
    document,
    (globalThis as { __linkdigestCommentLimit?: unknown }).__linkdigestCommentLimit,
  ));
