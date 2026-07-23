import { describe, expect, it } from "vitest";
import {
  sanitizeDouyinMetadataDiagnostic,
  type DouyinMetadataDiagnostic,
} from "../src/content/douyin-metadata-diagnostic";
import { popupMetadataDiagnostic } from "../src/popup-presentation";

const complete: DouyinMetadataDiagnostic = {
  missingPublished: false,
  missingStatsMask: 0,
  dom: {
    route: { eligible: true, rejectCode: "none" },
    video: { positiveVisibleCount: 1, dominantVideoCount: 1, rejectCode: "none" },
    scopes: { safeCount: 1, dedicatedCount: 0, rejectCode: "none" },
    dom: { publishedSelectorHit: true, statSelectorHitMask: 15, statAcceptedCount: 4 },
  },
  ssr: { fixedRootPresent: 2, fixedRootParseable: 2, exactHit: true, rejectCode: "none", limitCode: "none" },
};

describe("Douyin metadata popup diagnostic privacy boundary", () => {
  it("rebuilds only its finite allowlist and redacts every sentinel field", () => {
    const diagnostic = sanitizeDouyinMetadataDiagnostic({
      ...complete,
      pageURL: "https://example.test/private?token=sentinel",
      title: "sentinel title",
      author: "sentinel author",
      rawJSON: "sentinel raw json",
      dom: { ...complete.dom, selector: "sentinel selector", statValue: "999 sentinel" },
      ssr: { ...complete.ssr, raw: "sentinel SSR", cookie: "sentinel cookie" },
    });
    expect(diagnostic).toEqual(complete);
    const audit = JSON.stringify(diagnostic);
    for (const forbidden of ["sentinel", "pageURL", "title", "author", "rawJSON", "selector", "cookie"]) {
      expect(audit).not.toContain(forbidden);
    }
  });

  it("rejects invalid enum, range, and missing shapes instead of clamping or echoing", () => {
    expect(sanitizeDouyinMetadataDiagnostic({ ...complete, missingStatsMask: 16 })).toBeUndefined();
    expect(sanitizeDouyinMetadataDiagnostic({ ...complete, dom: { ...complete.dom, video: { ...complete.dom.video, rejectCode: "sentinel-code" } } })).toBeUndefined();
    expect(sanitizeDouyinMetadataDiagnostic({ ...complete, ssr: { ...complete.ssr, fixedRootPresent: 9 } })).toBeUndefined();
  });

  it("accepts the fixed dominant-video proof code without allowing page data", () => {
    expect(sanitizeDouyinMetadataDiagnostic({
      ...complete,
      dom: { ...complete.dom, scopes: { ...complete.dom.scopes, rejectCode: "dominant_video_proof" } },
      pageURL: "https://example.test/private?token=sentinel",
    })).toMatchObject({ dom: { scopes: { rejectCode: "dominant_video_proof" } } });
  });

  it("uses fixed Chinese for partial states, hides complete states, and never echoes unknown codes", () => {
    expect(popupMetadataDiagnostic(undefined)).toBeNull();
    expect(popupMetadataDiagnostic(complete)).toBeNull();
    expect(popupMetadataDiagnostic({ ...complete, missingPublished: true, missingStatsMask: 5 }))
      .toContain("缺失项：发布时间、点赞、分享");
    for (const code of ["sentinel-raw-route", "constructor", "toString", "__proto__"]) {
      const unknown = popupMetadataDiagnostic({
        ...complete,
        missingPublished: true,
        dom: {
          ...complete.dom,
          route: { eligible: false, rejectCode: code as never },
          video: { ...complete.dom.video, rejectCode: code as never },
          scopes: { ...complete.dom.scopes, rejectCode: code as never },
        },
        ssr: { ...complete.ssr, rejectCode: code as never, limitCode: code as never },
      })!;
      expect(unknown).toContain("未知安全码");
      expect(unknown).not.toContain(code);
      expect(unknown).toContain("元数据诊断（仅当前弹窗，不发送、不保存）");
    }
  });
});
