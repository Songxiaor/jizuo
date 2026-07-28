import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

/**
 * 抽取逻辑只许有一份实现。
 *
 * 这个文件原来的职责是「盯住两份拷贝不要漂移」：生产走
 * `executeScript({ func: extractPageInIsolatedWorld })`，而 `func` 会被 toString
 * 后注入、够不着模块作用域，所以那份必须把每个平台的逻辑各自内联一遍，与可测试的
 * `extractCurrentPage` 形成两份实现。
 *
 * 这个项目上反复出现的失败就是「改动只落在其中一份，测试全绿，生产行为没变」——
 * GitHub 仓库标题、抖音抓取、标题层级重基都踩过。
 *
 * 改用 `executeScript({ files: ["/extract-page.js"] })` 之后，注入的是构建产物，
 * 模块导入照常工作，那份拷贝已删除（-1198 行）。这里的职责随之变成：**防止它
 * 以任何形式回来**。
 */
describe("extraction must have exactly one implementation", () => {
  const source = readFileSync("src/content/extract.ts", "utf8");
  const background = readFileSync("src/entrypoints/background.ts", "utf8");

  it("keeps no self-contained injected copy", () => {
    expect(source).not.toContain("extractPageInIsolatedWorld");
    // 「self-contained」这个词在这份文件里出现，基本等于有人又开始内联一份。
    expect(source.toLowerCase()).not.toContain("self-contained — no module imports");
  });

  /// `func:` 一旦回来，自包含拷贝就必然跟着回来——那是它的直接成因。
  it("injects a built file instead of a serialized function", () => {
    expect(background).toContain('files: ["/extract-page.js"]');
    expect(background).not.toMatch(/func:\s*extractPageInIsolatedWorld/);
  });

  it("routes the injected entry through the shared module extractor", () => {
    const entry = readFileSync("entrypoints/extract-page.ts", "utf8");
    expect(entry).toContain("extractCurrentPage");
    expect(entry).toContain("defineUnlistedScript");
  });
});
