import type { ExtractedPage } from "./extract";
import {
  buildYouTubeMarkdown,
  collectYouTubeTranscriptFromPanelInPage,
  extractYouTubeWatchDOMFallbackInPage,
  fetchYouTubeTranscriptPayloadInPage,
  pickCaptionTrack,
  readYouTubePlayerSnapshotInMainWorld,
  restoreYouTubeCaptionTrackInMainWorld,
  setYouTubeCaptionTrackInMainWorld,
  transcriptFromJSON3,
  transcriptFromPanelSegments,
  transcriptFromTimedTextXML,
  youTubeCanonicalURL,
  youTubeThumbnailURL,
  youTubeVideoID,
  type YouTubePanelSegment,
} from "./youtube";

/**
 * YouTube 单条视频的完整抓取流程，在页面主世界里一次跑完。
 *
 * 扩展（`extract-youtube.js` 注入 MAIN world）和 App「添加链接」（隐藏网页里执行同一个
 * 打包文件）共用这一份：播放器快照 → 选字幕轨 → 页面同源拉字幕 → 被拦时走页面自己的
 * 文字记录面板 → 拼 Markdown。原来这串步骤散在 background 里，App 那边只能抓到
 * 整页外壳（推荐列表、商店、评论区，2026-10-02 抓取完整度测试）。
 */
export async function captureYouTubeVideoInPage(pageURL: string = location.href): Promise<ExtractedPage> {
  const urlVideoID = youTubeVideoID(pageURL);
  if (!urlVideoID) throw new Error("CAPTURE_CONTENT_EMPTY");
  const canonical = youTubeCanonicalURL(urlVideoID);

  let snapshot = readYouTubePlayerSnapshotInMainWorld();
  // SPA 在页内跳转后会留着上一条的播放器数据，只信和地址栏同一条视频的快照。
  if (snapshot?.videoId && snapshot.videoId !== urlVideoID) snapshot = undefined;

  if (!snapshot?.title) {
    const dom = extractYouTubeWatchDOMFallbackInPage();
    if (!dom?.title) throw new Error("CAPTURE_CONTENT_EMPTY");
    const fallbackText = buildYouTubeMarkdown({
      title: dom.title,
      ...(dom.author ? { author: dom.author } : {}),
      ...(dom.description ? { description: dom.description } : {}),
      canonicalURL: canonical,
      coverImage: youTubeThumbnailURL(urlVideoID),
    });
    return { title: dom.title, url: canonical, text: fallbackText, characterCount: [...fallbackText].length, method: "rendered_dom" };
  }

  let transcript = "";
  const tracks = snapshot.captionTracks ?? [];
  const track = pickCaptionTrack(tracks);
  if (track) {
    const payload = await fetchYouTubeTranscriptPayloadInPage(track.baseUrl).catch(() => undefined);
    if (payload?.format === "json3") transcript = transcriptFromJSON3(payload.json);
    else if (payload?.format === "xml") transcript = transcriptFromTimedTextXML(payload.text);
  }
  if (!transcript && track) {
    // timedtext 被 pot 令牌拦截时（2025 起常态），走页面自己的文字记录面板；
    // 先切到原始字幕轨，抓完恢复用户原状。
    const previous = setYouTubeCaptionTrackInMainWorld(track.languageCode);
    const wanted = track.name
      ? { name: track.name, occurrence: tracks.slice(0, tracks.indexOf(track)).filter((other) => other.name === track.name).length }
      : undefined;
    let segments: YouTubePanelSegment[] = [];
    try {
      segments = await collectYouTubeTranscriptFromPanelInPage(wanted);
    } catch {
      segments = [];
    } finally {
      restoreYouTubeCaptionTrackInMainWorld(previous);
    }
    transcript = transcriptFromPanelSegments(segments);
  }

  const text = buildYouTubeMarkdown({
    title: snapshot.title,
    ...(snapshot.author ? { author: snapshot.author } : {}),
    ...(snapshot.publishDate ? { published: snapshot.publishDate } : {}),
    ...(snapshot.likeCount ? { likes: snapshot.likeCount } : {}),
    ...(snapshot.viewCount ? { views: snapshot.viewCount } : {}),
    ...(snapshot.shortDescription ? { description: snapshot.shortDescription } : {}),
    ...(transcript ? { transcript } : {}),
    canonicalURL: canonical,
    coverImage: snapshot.thumbnailURL ?? youTubeThumbnailURL(urlVideoID),
  });
  return { title: snapshot.title, url: canonical, text, characterCount: [...text].length, method: "rendered_dom" };
}
