import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { GENERIC_CONTENT_ROOTS, SITE_PROFILES, siteProfile, siteProfileForDocument } from "../src/content/site-profiles";

/**
 * 站点差异只许住在档案表里。
 *
 * 改这套之前，通用路径的站点特化散在六处：HOST_CONTENT_ROOT 表、pickContentRoot
 * 的选择器清单、resolveTitle 的公众号分支、resolvePageMetadata 的作者与时间兜底。
 * 加一个站点要在这几处分别下手，漏掉一处不报错——只表现为「这个站抓出来少一块」。
 */
describe("site profiles", () => {
  it("matches hosts and their subdomains", () => {
    expect(siteProfile("mp.weixin.qq.com")?.id).toBe("wechat");
    expect(siteProfile("www.toutiao.com")?.id).toBe("toutiao");
    expect(siteProfile("zhuanlan.zhihu.com")?.id).toBe("zhihu");
    expect(siteProfile("linux.do")?.id).toBe("linux-do");
    expect(siteProfile("publication.substack.com")?.id).toBe("substack");
    // 末尾点是合法 FQDN 写法，不该因此匹配失败。
    expect(siteProfile("mp.weixin.qq.com.")?.id).toBe("wechat");
  });

  it("does not match unrelated hosts that merely contain the name", () => {
    expect(siteProfile("zhihu.com.evil.test")).toBeUndefined();
    expect(siteProfile("fake-toutiao.com")).toBeUndefined();
    expect(siteProfile("example.com")).toBeUndefined();
    expect(siteProfile("letters.custom-publisher.test")).toBeUndefined();
    expect(siteProfile("letters.thedankoe.com")).toBeUndefined();
  });

  it("recognizes a custom-domain Substack page by CDN preconnect and post-header", () => {
    const matches = SITE_PROFILES.find((profile) => profile.id === "substack")?.matchesDocument;
    expect(matches).toBeTypeOf("function");
    const documentLike = {
      location: { href: "https://letters.custom-publisher.test/p/fixture" },
      querySelector: (selector: string) => {
        if (selector === ".post-header") return { tagName: "DIV" };
        return null;
      },
      querySelectorAll: (selector: string) => {
        if (selector === "link[rel]") {
          return [{
            getAttribute: (name: string) => (name === "rel" ? "preconnect" : name === "href" ? "https://substackcdn.com" : null),
          }];
        }
        return [];
      },
    } as unknown as Document;
    expect(siteProfileForDocument(documentLike)?.id).toBe("substack");
  });

  it("does not fingerprint a page that only has a post-header or only a CDN link", () => {
    const headerOnly = {
      location: { href: "https://notes.example.test/post" },
      querySelector: (selector: string) => (selector === ".post-header" ? { tagName: "DIV" } : null),
      querySelectorAll: () => [],
    } as unknown as Document;
    const cdnOnly = {
      location: { href: "https://notes.example.test/post" },
      querySelector: () => null,
      querySelectorAll: (selector: string) => {
        if (selector === "link[rel]") {
          return [{
            getAttribute: (name: string) => (name === "rel" ? "preconnect" : name === "href" ? "https://substackcdn.com" : null),
          }];
        }
        return [];
      },
    } as unknown as Document;
    expect(siteProfileForDocument(headerOnly)).toBeUndefined();
    expect(siteProfileForDocument(cdnOnly)).toBeUndefined();
  });

  it("only fingerprints http(s) pages and https Substack CDN preconnects", () => {
    const withCdn = (href: string, cdnHref: string) => ({
      location: { href },
      querySelector: (selector: string) => (selector === ".post-header" ? { tagName: "DIV" } : null),
      querySelectorAll: (selector: string) => {
        if (selector === "link[rel]") {
          return [{
            getAttribute: (name: string) => (name === "rel" ? "preconnect" : name === "href" ? cdnHref : null),
          }];
        }
        return [];
      },
    } as unknown as Document);

    expect(siteProfileForDocument(withCdn("https://letters.custom-publisher.test/p/fixture", "https://substackcdn.com"))?.id).toBe("substack");
    expect(siteProfileForDocument(withCdn("http://letters.custom-publisher.test/p/fixture", "https://substackcdn.com"))?.id).toBe("substack");
    expect(siteProfileForDocument(withCdn("ftp://letters.custom-publisher.test/p/fixture", "https://substackcdn.com"))).toBeUndefined();
    expect(siteProfileForDocument(withCdn("not a url", "https://substackcdn.com"))).toBeUndefined();
    expect(siteProfileForDocument(withCdn("https://letters.custom-publisher.test/p/fixture", "ftp://substackcdn.com"))).toBeUndefined();
    expect(siteProfileForDocument(withCdn("https://letters.custom-publisher.test/p/fixture", "http://substackcdn.com"))).toBeUndefined();
    expect(siteProfileForDocument(withCdn("https://letters.custom-publisher.test/p/fixture", "not a url"))).toBeUndefined();
  });

  /// 带站点色彩的类名混进通用清单，就等于通用路径又认识具体站点了。
  it("keeps site-specific selectors out of the generic candidates", () => {
    for (const selector of GENERIC_CONTENT_ROOTS) {
      expect(selector).not.toMatch(/js_content|ztext|Post-RichText|available-content|activity-name|post_1|topic-post|cooked/);
    }
    // 通用候选只该是跨站点的语义标记。
    expect(GENERIC_CONTENT_ROOTS).toEqual([
      "[itemprop='articleBody']",
      ".article-content",
      "article",
      "main",
    ]);
  });

  it("gives every profile a distinct id", () => {
    const ids = SITE_PROFILES.map((profile) => profile.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

/**
 * 抽取器不再自己认识具体站点——那些选择器必须来自档案表。
 *
 * 这条是这次重构唯一的护栏：下次有人图快，直接在 pickContentRoot 里加一个
 * `.some-site-class`，这里会失败。
 */
describe("extractor holds no hardcoded site selectors", () => {
  /// 只看代码，不看注释——注释里举例说明「公众号的 #activity-name」是有价值的，
  /// 把它一并禁掉会逼人把解释删掉，那是反效果。
  const source = readFileSync("src/content/extract.ts", "utf8")
    .split("\n")
    .filter((line) => {
      const trimmed = line.trim();
      return !trimmed.startsWith("//") && !trimmed.startsWith("*") && !trimmed.startsWith("/*");
    })
    .join("\n");

  it("no longer carries the per-host content-root table", () => {
    expect(source).not.toContain("HOST_CONTENT_ROOT");
  });

  it("reads article-page site selectors from the profile registry", () => {
    for (const selector of ["#js_content", "#img-content", "#activity-name", "#js_name", "#publish_time", ".RichText.ztext", ".available-content", ".body.markup", ".post-header", "#post_1 .cooked", ".topic-post:first-of-type .cooked"]) {
      expect(source).not.toContain(selector);
    }
  });
});
