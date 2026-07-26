import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { extractPageInIsolatedWorld, gitHubRepoSlug } from "../src/content/extract";

/**
 * 两份抽取实现不能漂移。
 *
 * `extractCurrentPage` 是 vitest 用的可测试镜像，`extractPageInIsolatedWorld` 是
 * 经 executeScript 注入、生产实际执行的那一份。这个项目上反复出现的问题是：改动
 * 只落在镜像里，测试全绿，生产行为没变。GitHub 这条尤其隐蔽——仓库根页的 h1 是
 * 搜索对话框的隐藏无障碍标题（"Search code, repositories…"），拿它当标题不报错，
 * 只是每条 GitHub 记录的标题都变成那句话。
 *
 * 这里断言的是「注入版里有这段逻辑」而不是行为，因为注入版要遍历真实 DOM，
 * 在没有 jsdom 的这套测试里手搓 document 的成本远高于收益。行为正确性由
 * gitHubRepoSlug 的纯函数测试覆盖。
 */
describe("injected extractor must not drift from the testable copy", () => {
  const injected = String(extractPageInIsolatedWorld);

  it("carries the GitHub repo-slug title rule", () => {
    expect(injected).toContain('host !== "github.com"');
    // 钉住真正决定行为的那一行，而不只是「repoSlug 这个词出现过」。
    // 第一版断言写成 /repoSlug/，把赋值删掉后测试照样绿——常量还在，词就还在。
    // 断言必须落在「谁被赋给了 title」上。
    expect(injected).toMatch(/if\s*\(\s*repoSlug\s*\)\s*title\s*=\s*repoSlug/);
    // 必须内联：注入后没有模块作用域，引用 gitHubRepoSlug 会抛 ReferenceError
    // 并被外层 try/catch 吞成「没抓到正文」。
    expect(injected).not.toMatch(/\bgitHubRepoSlug\s*\(/);
  });

  it("carries the author and publish-date meta fallbacks", () => {
    expect(injected).toContain("og:article:author");
    expect(injected).toContain("publish_date");
  });

  it("keeps the injected copy free of module-scope helper calls", () => {
    // 注入函数体里出现这些模块级导出名的调用，就是一次必然的生产失败。
    const moduleHelpers = [
      "resolvePageMetadata",
      "pickContentRoot",
      "scrubNoise",
      "buildCaptureFrontmatter",
      "firstProseFromMarkdown",
    ];
    const body = injected.slice(injected.indexOf("{"));
    for (const helper of moduleHelpers) {
      expect(body).not.toMatch(new RegExp(`(?<![\\w.])${helper}\\s*\\(`));
    }
  });

  it("resolves repo roots but not deeper pages", () => {
    expect(gitHubRepoSlug("https://github.com/apple/swift")).toBe("apple/swift");
    expect(gitHubRepoSlug("https://github.com/apple/swift/issues/1")).toBeNull();
    expect(gitHubRepoSlug("https://github.com.evil.test/apple/swift")).toBeNull();
  });

  it("does not regress the source of truth used by the release build", () => {
    // 生产 bundle 里必须真的带上这段——只改源码没重建的情况在这个项目上发生过。
    const source = readFileSync(
      new URL("../src/content/extract.ts", import.meta.url), "utf8");
    const injectedStart = source.indexOf("export function extractPageInIsolatedWorld");
    expect(injectedStart).toBeGreaterThan(0);
    const injectedSource = source.slice(injectedStart);
    expect(injectedSource).toContain('host !== "github.com"');
  });
});
