import { describe, expect, it, vi } from "vitest";
import {
  buildYouTubeMarkdown,
  isYouTubeWatchURL,
  pickCaptionTrack,
  transcriptFromJSON3,
  transcriptFromTimedTextXML,
  youTubeCanonicalURL,
  youTubeVideoID,
} from "../src/content/youtube";

describe("youtube capture", () => {
  it("recognizes watch, shorts, live and youtu.be URLs and canonicalizes to /watch", () => {
    expect(youTubeVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    expect(youTubeVideoID("https://youtu.be/dQw4w9WgXcQ?t=10")).toBe("dQw4w9WgXcQ");
    expect(youTubeVideoID("https://www.youtube.com/shorts/AbCdEf12345")).toBe("AbCdEf12345");
    expect(youTubeVideoID("https://www.youtube.com/live/AbCdEf12345")).toBe("AbCdEf12345");
    expect(youTubeVideoID("https://m.youtube.com/watch?v=dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    // Feed, channel and non-YouTube hosts are not single-video pages.
    expect(isYouTubeWatchURL("https://www.youtube.com/")).toBe(false);
    expect(isYouTubeWatchURL("https://www.youtube.com/@channel")).toBe(false);
    expect(isYouTubeWatchURL("https://example.com/watch?v=dQw4w9WgXcQ")).toBe(false);
    expect(youTubeCanonicalURL("dQw4w9WgXcQ")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  });

  it("prefers zh over en, and authored tracks over ASR within a language", () => {
    const zhASR = { baseUrl: "https://yt.test/zh-asr", languageCode: "zh-Hans", kind: "asr" };
    const zhAuthored = { baseUrl: "https://yt.test/zh", languageCode: "zh-Hans" };
    const en = { baseUrl: "https://yt.test/en", languageCode: "en" };
    expect(pickCaptionTrack([en, zhASR, zhAuthored])).toBe(zhAuthored);
    expect(pickCaptionTrack([en, zhASR])).toBe(zhASR);
    const hant = { baseUrl: "https://example.test/hant", languageCode: "zh-Hant" };
    const hans = { baseUrl: "https://example.test/hans", languageCode: "zh-Hans" };
    expect(pickCaptionTrack([hant, en, hans])).toBe(hans);
    expect(pickCaptionTrack([en, hant])).toBe(hant);
    const bare = { baseUrl: "https://example.test/zh", languageCode: "zh" };
    const cn = { baseUrl: "https://example.test/cn", languageCode: "zh-CN" };
    expect(pickCaptionTrack([en, bare, hant, cn])).toBe(cn);
    expect(pickCaptionTrack([en, hant, bare])).toBe(bare);
    expect(pickCaptionTrack([en])).toBe(en);
    expect(pickCaptionTrack([])).toBeUndefined();
    expect(pickCaptionTrack([{ baseUrl: "", languageCode: "zh" }])).toBeUndefined();
  });

  it("joins json3 caption cues into paragraphs at speech gaps", () => {
    const payload = {
      events: [
        { tStartMs: 0, segs: [{ utf8: "大家好" }, { utf8: "，今天讲" }] },
        { tStartMs: 1500, segs: [{ utf8: "第一个话题" }] },
        { tStartMs: 2000, segs: [{ utf8: "\n" }] },
        { tStartMs: 8000, segs: [{ utf8: "接下来是第二段" }] },
        { tStartMs: 9000, segs: [{ utf8: "with English words" }] },
      ],
    };
    const transcript = transcriptFromJSON3(payload);
    expect(transcript).toBe("大家好，今天讲第一个话题\n\n接下来是第二段 with English words");
    expect(transcriptFromJSON3(undefined)).toBe("");
    expect(transcriptFromJSON3({})).toBe("");
  });

  it("builds frontmatter + description + transcript markdown the App can parse", () => {
    const markdown = buildYouTubeMarkdown({
      title: "如何构建本地优先应用",
      author: "示例频道",
      published: "2026-06-01",
      likes: "1234",
      views: "56789",
      description: "本期讲 local-first 架构。",
      transcript: "大家好，欢迎收看。",
      canonicalURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    });
    expect(markdown.startsWith('---\nauthor: "示例频道"\npublished: "2026-06-01"\ncover_image: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"\nlikes: "1234"\nviews: "56789"\n---')).toBe(true);
    expect(markdown).toContain("# 如何构建本地优先应用");
    // 观看数只进 frontmatter，不再占正文。
    expect(markdown).not.toContain("观看 56789");
    expect(markdown).toContain("## 简介\n\n本期讲 local-first 架构。");
    expect(markdown).toContain("## 字幕\n\n大家好，欢迎收看。");
    // 字幕排在简介之前——口播正文优先。
    expect(markdown.indexOf("## 字幕")).toBeLessThan(markdown.indexOf("## 简介"));
    // Captions missing → explicit notice instead of a silent gap.
    const noTranscript = buildYouTubeMarkdown({
      title: "无字幕视频",
      canonicalURL: "https://www.youtube.com/watch?v=AbCdEf12345",
    });
    expect(noTranscript).not.toContain("## 字幕");
    expect(noTranscript).toContain("该视频未提供字幕");
    expect(noTranscript).not.toContain("## 简介");
    expect(noTranscript).toContain('cover_image: "https://i.ytimg.com/vi/AbCdEf12345/hqdefault.jpg"');
  });

  it("keeps an admitted player thumbnail and ignores a foreign cover URL", () => {
    const player = buildYouTubeMarkdown({
      title: "有封面",
      canonicalURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      coverImage: "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
    });
    expect(player).toContain('cover_image: "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"');
    const ignored = buildYouTubeMarkdown({
      title: "有封面",
      canonicalURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      coverImage: "https://evil.test/cover.jpg",
    });
    expect(ignored).toContain('cover_image: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"');
    expect(ignored).not.toContain("evil.test");
  });
});

describe("timedtext xml fallback", () => {
  it("parses default XML cues into paragraphs with entity decoding", () => {
    const xml = `<?xml version="1.0"?><transcript>
      <text start="0.0" dur="2.0">大家好 &amp; 欢迎</text>
      <text start="2.1" dur="2.0">今天讲 Kimi</text>
      <text start="9.0" dur="2.0">第二段开始了</text>
    </transcript>`;
    expect(transcriptFromTimedTextXML(xml)).toBe("大家好 & 欢迎 今天讲 Kimi\n\n第二段开始了");
    expect(transcriptFromTimedTextXML("")).toBe("");
  });
});

describe("transcript panel fallback", () => {
  it("groups panel segments into paragraphs at long pauses and length caps", async () => {
    const { transcriptFromPanelSegments } = await import("../src/content/youtube");
    const segments = [
      { time: "0:00", text: "I'm up here to say thank you" },
      { time: "0:07", text: "for teaching me, for punishing me" },
      { time: "0:19", text: "I want to thank AFI" },
      { time: "1:30", text: "中文段落开始" },
      { time: "1:33", text: "继续中文" },
    ];
    const transcript = transcriptFromPanelSegments(segments);
    // 0:00→0:07 7s 不换段；0:07→0:19 12s 换段；0:19→1:30 换段；中文相邻不加空格。
    expect(transcript).toBe(
      "I'm up here to say thank you for teaching me, for punishing me\n\nI want to thank AFI\n\n中文段落开始继续中文",
    );
    expect(transcriptFromPanelSegments([])).toBe("");
  });

  it("deduplicates rollup live-caption overlap and breaks paragraphs at >> speaker marks", async () => {
    const { transcriptFromPanelSegments } = await import("../src/content/youtube");
    const segments = [
      { time: "0:00", text: "WE ARE CONSIDERABLY CLOSER TO A REAL" },
      // rollup：下一条 cue 重带上一行，再接新内容。
      { time: "0:03", text: "CONSIDERABLY CLOSER TO A REAL DANGER IN 2026 THAN WE" },
      { time: "0:06", text: "DANGER IN 2026 THAN WE WERE IN 2023." },
      // ">>" 说话人切换 → 换段。
      { time: "0:09", text: ">> YEAH. SO FIRSTLY, REALLY" },
    ];
    expect(transcriptFromPanelSegments(segments)).toBe(
      "WE ARE CONSIDERABLY CLOSER TO A REAL DANGER IN 2026 THAN WE WERE IN 2023.\n\nYEAH. SO FIRSTLY, REALLY",
    );
  });

  it("drops retry-button noise and deduplicates overlap across paragraph breaks", async () => {
    const { transcriptFromPanelSegments } = await import("../src/content/youtube");
    const segments = [
      { time: "0:00", text: "点击重试点击重试" },
      { time: "0:02", text: "点击重试" },
      { time: "0:04", text: "OPENAI FOR SEVERAL YEARS. SO I'VE SEEN. OF THE" },
      // 12s 停顿换段，但 rollup 重带的 "I'VE SEEN. OF THE" 仍须剥掉。
      { time: "0:16", text: "I'VE SEEN. OF THE COMPANIES THAT ARE LEADING" },
    ];
    expect(transcriptFromPanelSegments(segments)).toBe(
      "OPENAI FOR SEVERAL YEARS. SO I'VE SEEN. OF THE\n\nCOMPANIES THAT ARE LEADING",
    );
  });
});

describe("transcript panel language (2026-09-29)", () => {
  it("picks the wanted language in the panel menu before reading", async () => {
    const { collectYouTubeTranscriptFromPanelInPage } = await import("../src/content/youtube");
    let lines = ["這是一個 3"];
    const segment = (text: string) => ({
      querySelector: (selector: string) => selector === ".segment-timestamp" ? { textContent: "0:04" } : selector === ".segment-text" ? { textContent: text } : null,
    });
    let closed = 0;
    const item = (label: string, next: string[]) => ({
      textContent: label,
      getAttribute: () => null,
      click: () => { lines = next; },
    });
    const items = [item("中文", ["這是一個 3"]), item("英语", ["This is a 3."]), item("中文（中国）", ["这是一个 3"])];
    vi.stubGlobal("document", {
      querySelector: (selector: string) => selector.endsWith("#visibility-button button") ? { click: () => { closed += 1; } } : null,
      querySelectorAll: (selector: string) => {
        if (selector === "transcript-segment-view-model") return [];
        if (selector === "ytd-transcript-segment-renderer") return lines.map(segment);
        if (selector.endsWith("ytd-transcript-footer-renderer tp-yt-paper-item")) return items;
        return [];
      },
    });
    vi.useFakeTimers();
    try {
      const pending = collectYouTubeTranscriptFromPanelInPage({ name: "中文（中国）", occurrence: 0 });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(await pending).toEqual([{ time: "0:04", text: "这是一个 3" }]);
      // 面板本来就开着（有内容），读完不替用户关。
      expect(closed).toBe(0);
    } finally {
      vi.useRealTimers();
      vi.unstubAllGlobals();
    }
  });
});

describe("transcript text without translation-extension overlays (2026-09-29)", () => {
  it("keeps only YouTube's own words when a page translator injects <xt-trans>", async () => {
    const { collectYouTubeTranscriptFromPanelInPage } = await import("../src/content/youtube");
    const text = (value: string) => ({ nodeType: 3, textContent: value });
    const el = (tag: string, attrs: Record<string, string>, children: unknown[]) => ({
      nodeType: 1, tagName: tag.toUpperCase(), childNodes: children,
      getAttribute: (name: string) => attrs[name] ?? null,
      textContent: children.map((child) => (child as { textContent: string }).textContent).join(""),
    });
    const bilingual = el("yt-formatted-string", {}, [el("xt-trans", { "xt-origin": "hi everyone" }, [text("大家好")]), text("hi everyone")]);
    const replaced = el("yt-formatted-string", {}, [el("xt-trans", { "xt-origin": "這是一個 3" }, [text("这是一个 3")])]);
    const rows = [bilingual, replaced].map((node, index) => ({
      querySelector: (selector: string) => selector === ".segment-timestamp" ? { textContent: `0:0${index}` } : selector === ".segment-text" ? node : null,
    }));
    vi.stubGlobal("document", {
      querySelector: () => null,
      querySelectorAll: (selector: string) => selector === "ytd-transcript-segment-renderer" ? rows : [],
    });
    vi.useFakeTimers();
    try {
      const pending = collectYouTubeTranscriptFromPanelInPage();
      await vi.advanceTimersByTimeAsync(30_000);
      expect((await pending).map((segment) => segment.text)).toEqual(["hi everyone", "這是一個 3"]);
    } finally {
      vi.useRealTimers();
      vi.unstubAllGlobals();
    }
  });
});

describe("transcript rendered twice on the page (2026-10-02)", () => {
  it("keeps one copy when the same segments appear in two places", async () => {
    const { collectYouTubeTranscriptFromPanelInPage } = await import("../src/content/youtube");
    const text = (value: string) => ({ nodeType: 3, textContent: value });
    const span = (value: string) => ({ nodeType: 1, tagName: "SPAN", childNodes: [text(value)], getAttribute: () => null, textContent: value });
    const row = (time: string, value: string) => ({
      querySelector: (selector: string) => selector === ".segment-timestamp" ? { textContent: time } : selector === ".segment-text" ? span(value) : null,
    });
    const copy = () => [row("0:00", "这是一个3"), row("0:05", "一个字迹歪斜的3")];
    vi.stubGlobal("document", {
      querySelector: () => null,
      querySelectorAll: (selector: string) => selector === "ytd-transcript-segment-renderer" ? [...copy(), ...copy()] : [],
    });
    vi.useFakeTimers();
    try {
      const pending = collectYouTubeTranscriptFromPanelInPage();
      await vi.advanceTimersByTimeAsync(30_000);
      expect((await pending).map((segment) => segment.text)).toEqual(["这是一个3", "一个字迹歪斜的3"]);
    } finally {
      vi.useRealTimers();
      vi.unstubAllGlobals();
    }
  });
});
