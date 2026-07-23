import { describe, expect, it } from "vitest";
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
    expect(markdown.startsWith('---\nauthor: "示例频道"\npublished: "2026-06-01"\nlikes: "1234"\nviews: "56789"\n---')).toBe(true);
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
