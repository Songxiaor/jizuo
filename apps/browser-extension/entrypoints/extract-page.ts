import { extractCurrentPage } from "@/src/content/extract";

/**
 * 注入到页面里执行抽取的入口。
 *
 * 存在的唯一理由是消掉那份自包含拷贝。
 *
 * 原来生产走 `executeScript({ func: extractPageInIsolatedWorld })`——`func` 会被
 * 序列化后注入，够不着模块作用域，所以那个函数里把每个平台的逻辑各自内联了一遍，
 * 与可测试版 `extractCurrentPage` 形成两份实现。这个项目上反复出现的失败就是
 * 「改动只落在其中一份，测试全绿，生产行为没变」——GitHub 标题、抖音抓取、
 * 标题层级重基都踩过。
 *
 * `executeScript({ files })` 注入的是打好包的文件，模块导入照常工作，于是同一份
 * `extractCurrentPage` 既能被单测直接调用，也能在页面里跑。
 *
 * 返回值即脚本的求值结果，由 `InjectionResult.result` 带回 background。
 */
export default defineUnlistedScript(() => extractCurrentPage());
