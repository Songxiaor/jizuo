/**
 * Bilibili single-video recognition. Same safe seam as the Douyin/YouTube
 * adapters: read only the page the user is already watching — no private API,
 * no DASH stream stitching, no login-wall bypass. v1 captures the video's
 * public title / uploader / description as a text record; transcript and media
 * download stay a later, opt-in step.
 */

/** Extract a canonical Bilibili video id (`BV…` or `av…`) from a watch URL. */
export function bilibiliVideoID(rawURL: string): string | undefined {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return undefined;
  }
  const host = url.hostname.toLowerCase().replace(/^www\.|^m\./, "");
  if (host !== "bilibili.com") return undefined;
  // `/video/BV1xx411c7mD` or legacy `/video/av170001`. Trailing segments (parts,
  // query) are ignored; the id itself is the stable handle.
  const match = url.pathname.match(/^\/video\/(BV[0-9A-Za-z]{10}|av\d+)/u);
  return match ? match[1] : undefined;
}

/** True only for a concrete Bilibili video page (not the home feed or a space). */
export function isBilibiliVideoURL(rawURL: string): boolean {
  return bilibiliVideoID(rawURL) !== undefined;
}

/** Stable public watch page for storage / History. */
export function bilibiliCanonicalURL(videoID: string): string {
  return `https://www.bilibili.com/video/${videoID}`;
}

/**
 * 播放地址：页面上的 `<video>` 是 MSE，`src` 是 blob，扩展拿不到真实流。B 站把
 * 本次播放的地址放在 MAIN world 的 `window.__playinfo__` 里，那是页面自己已经
 * 加载好的公开数据，读它不需要 cookie、不调私有接口、不做签名。
 */
export type BilibiliStream = {
  /** 已择优过的直连地址（`*.bilivideo.com`，443）。 */
  url: string;
  /** 同一条流的其它可用地址，主地址失败时按序回退。 */
  backupURLs: string[];
  /** `durl` 与合成后的成品都是完整视频；只取到音轨时才是 `audio/mp4`。 */
  mimeType: "video/mp4" | "audio/mp4";
  /**
   * DASH 的画面与声音是两条独立流。`url` 给画面，这里给对应的音轨，
   * 由 App 下载后在本机合成一个带声音的文件——两条流各自都不完整。
   */
  companionAudioURL?: string;
  durationSeconds?: number;
  expiresAt?: string;
};


/**
 * 自包含（供 `browser.scripting.executeScript` 注入 MAIN world），只读页面已有
 * 的 `__playinfo__`。优先 `durl`（老式整段 mp4，音画俱全）；只有 DASH 时退而取
 * 音轨——DASH 的音视频是分离的 `.m4s`，取视频轨会得到一段没有声音的画面，而
 * 转写要的正是声音。
 */
export function readBilibiliStreamInMainWorld(): BilibiliStream | null {
  try {
    const info = (window as unknown as { __playinfo__?: Record<string, unknown> }).__playinfo__;
    if (!info || typeof info !== "object") return null;
    const data = (info.data ?? info.result) as Record<string, unknown> | undefined;
    if (!data || typeof data !== "object") return null;

    // PCDN 节点（`*.mcdn.bilivideo.cn:8082`）与第三方 edge 域名只在浏览器所在的
    // 网络环境里可达，换到 App 的连接常年超时；只认 B 站自家 443 直连 CDN。
    const directURL = (raw: unknown): string => {
      if (typeof raw !== "string") return "";
      const trimmed = raw.trim();
      if (!trimmed || trimmed.length > 4096) return "";
      try {
        const url = new URL(trimmed);
        if (url.protocol !== "https:") return "";
        if (url.port !== "") return "";
        const host = url.hostname.toLowerCase();
        if (host !== "bilivideo.com" && !host.endsWith(".bilivideo.com")) return "";
        return url.href;
      } catch {
        return "";
      }
    };
    const collect = (primary: unknown, backups: unknown): string[] => {
      const urls: string[] = [];
      const push = (raw: unknown) => {
        const url = directURL(raw);
        if (url && !urls.includes(url)) urls.push(url);
      };
      push(primary);
      if (Array.isArray(backups)) for (const backup of backups.slice(0, 8)) push(backup);
      return urls;
    };
    // 地址带限时签名，`deadline` 是秒级 Unix 时间戳，过期后 403。
    const expiryOf = (url: string): string | undefined => {
      try {
        const deadline = new URL(url).searchParams.get("deadline");
        if (!deadline || !/^\d{9,11}$/u.test(deadline)) return undefined;
        return new Date(Number(deadline) * 1_000).toISOString();
      } catch {
        return undefined;
      }
    };
    const rawLength = data.timelength;
    const durationSeconds = typeof rawLength === "number" && rawLength > 0 && rawLength < 86_400_000
      ? rawLength / 1_000
      : undefined;

    const durl = data.durl;
    if (Array.isArray(durl) && durl.length > 0) {
      const first = durl[0] as Record<string, unknown> | undefined;
      const urls = collect(first?.url, first?.backup_url ?? first?.backupUrl);
      if (urls.length > 0) {
        const expiresAt = expiryOf(urls[0]!);
        return {
          url: urls[0]!,
          backupURLs: urls.slice(1),
          mimeType: "video/mp4",
          ...(durationSeconds ? { durationSeconds } : {}),
          ...(expiresAt ? { expiresAt } : {}),
        };
      }
    }

    const dash = data.dash as Record<string, unknown> | undefined;
    const audio = dash?.audio;
    if (!Array.isArray(audio) || audio.length === 0) return null;
    // 码率最高的一条：整段音轨也就几 MB，转写清晰度比省流重要。
    const rankedAudio = audio
      .filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      .slice()
      .sort((a, b) => (Number(b.bandwidth) || 0) - (Number(a.bandwidth) || 0));
    let audioURLs: string[] = [];
    for (const entry of rankedAudio) {
      const urls = collect(entry.baseUrl ?? entry.base_url, entry.backupUrl ?? entry.backup_url);
      if (urls.length > 0) { audioURLs = urls; break; }
    }
    if (audioURLs.length === 0) return null;

    // 画面轨的取舍。这两个判据必须写在函数体内：整个函数会被序列化后注入页面
    // 的 MAIN world 执行，引用任何模块级标识符在那边都是 ReferenceError。
    // - 清晰度封顶 1080P（id 80）。未登录实测能拿到 1080P60（116），但 4:31 的
    //   片子 avc1 就有 110MB，60 帧那档 212MB，不值这个体积。
    // - 编码优先 H.264（`avc1`）：合成走 passthrough 最稳。HEVC（`hvc1`）次选；
    //   AV1（`av01`）在老机型上解不出来，直接跳过。
    const maximumQualityID = 80;
    const codecRank = (codecs: unknown): number => {
      const value = typeof codecs === "string" ? codecs.toLowerCase() : "";
      if (value.startsWith("avc1") || value.startsWith("avc3")) return 2;
      if (value.startsWith("hvc1") || value.startsWith("hev1")) return 1;
      return 0;
    };
    const video = dash?.video;
    const rankedVideo = (Array.isArray(video) ? video : [])
      .filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      .filter((entry) => {
        const id = Number(entry.id);
        return Number.isFinite(id) && id > 0 && id <= maximumQualityID;
      })
      .filter((entry) => codecRank(entry.codecs) > 0)
      .slice()
      .sort((a, b) => {
        const quality = (Number(b.id) || 0) - (Number(a.id) || 0);
        if (quality !== 0) return quality;
        const codec = codecRank(b.codecs) - codecRank(a.codecs);
        if (codec !== 0) return codec;
        return (Number(b.bandwidth) || 0) - (Number(a.bandwidth) || 0);
      });
    for (const entry of rankedVideo) {
      const urls = collect(entry.baseUrl ?? entry.base_url, entry.backupUrl ?? entry.backup_url);
      if (urls.length === 0) continue;
      const expiresAt = expiryOf(urls[0]!);
      return {
        url: urls[0]!,
        backupURLs: urls.slice(1),
        mimeType: "video/mp4",
        companionAudioURL: audioURLs[0]!,
        ...(durationSeconds ? { durationSeconds } : {}),
        ...(expiresAt ? { expiresAt } : {}),
      };
    }

    // 画面轨一条都不可直连（全是 PCDN 或只有 AV1）时，退回纯音轨：
    // 转写照常可用，播放会是有声无画。
    const expiresAt = expiryOf(audioURLs[0]!);
    return {
      url: audioURLs[0]!,
      backupURLs: audioURLs.slice(1),
      mimeType: "audio/mp4",
      ...(durationSeconds ? { durationSeconds } : {}),
      ...(expiresAt ? { expiresAt } : {}),
    };
  } catch {
    return null;
  }
}

/** Host-level recognition (covers `b23.tv` short links that redirect to a video). */
export function isBilibiliHost(rawURL: string): boolean {
  try {
    const host = new URL(rawURL).hostname.toLowerCase();
    return (
      host === "bilibili.com" ||
      host.endsWith(".bilibili.com") ||
      host === "b23.tv"
    );
  } catch {
    return false;
  }
}
