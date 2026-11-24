/**
 * 小红书直播取流。地址来自页面运行时状态里的 `roomInfo.pullConfig`（字符串
 * JSON），不是首屏 HTML：页面跑起来约 6 秒才填好。地址没有签名，只有 FLV，
 * 原画是 H.264，其余档通常是 HEVC。
 */
import type { LiveQualityKey, LiveVariant } from "./douyin-live";

export const XIAOHONGSHU_LIVE_REFERER = "https://www.xiaohongshu.com/";

export type XiaohongshuLiveAnchor = {
  anchorName?: string;
  anchorID?: string;
  anchorAvatarURL?: string;
  anchorProfileURL?: string;
};

export function xiaohongshuRoomID(rawURL: string): string | null {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase();
    if (host !== "www.xiaohongshu.com" && host !== "xiaohongshu.com") return null;
    const match = url.pathname.match(/^\/live(?:stream)?\/(\d{6,25})\/?$/u);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

export function isXiaohongshuLiveURL(rawURL: string): boolean {
  return xiaohongshuRoomID(rawURL) !== null;
}

type PullStream = {
  quality_type?: unknown;
  quality_type_name?: unknown;
  codec_v2?: unknown;
  protocol?: unknown;
  max_bitrate?: unknown;
  master_url?: unknown;
};

function httpsURL(raw: string): string {
  return raw.replace(/^http:\/\//u, "https://");
}

/**
 * `pullConfig` → 档位。档位名不固定、id 更不固定，按「原画」和其它档的码率排序
 * 映射，不用 id 硬编码。roomId 超过 2^53，绝不从解析结果重建地址，只用 master_url。
 */
export function parseXiaohongshuPullConfig(raw: string, fallbackFLVURL?: string): LiveVariant[] {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return fallbackFLVURL ? [{ quality: "origin", container: "flv", url: httpsURL(fallbackFLVURL) }] : [];
  }
  const streams = Array.isArray(parsed.streams) ? parsed.streams as PullStream[] : [];
  const rows: Array<{ variant: LiveVariant; bitrate: number }> = [];
  for (const stream of streams) {
    const url = typeof stream.master_url === "string" ? stream.master_url.trim() : "";
    const protocol = typeof stream.protocol === "string" ? stream.protocol.toLowerCase() : "flv";
    if (!url || protocol !== "flv" || !/^https?:\/\//u.test(url)) continue;
    const name = typeof stream.quality_type_name === "string" ? stream.quality_type_name : "";
    const type = typeof stream.quality_type === "string" ? stream.quality_type : "";
    const isOrigin = /原画/u.test(name) || /^FLV$/u.test(type);
    const bitrate = typeof stream.max_bitrate === "number" ? stream.max_bitrate : 0;
    rows.push({
      bitrate,
      variant: {
        quality: isOrigin ? "origin" : "hd",
        container: "flv",
        url: httpsURL(url),
        ...(name ? { label: name } : {}),
      },
    });
  }
  const origin = rows.find((row) => row.variant.quality === "origin")?.variant
    ?? (fallbackFLVURL ? { quality: "origin" as const, container: "flv" as const, url: httpsURL(fallbackFLVURL) } : undefined);
  const others = rows
    .filter((row) => row.variant.quality !== "origin")
    .sort((a, b) => b.bitrate - a.bitrate)
    .map((row, index) => ({
      ...row.variant,
      quality: (["hd", "sd", "ld"] as LiveQualityKey[])[Math.min(index, 2)]!,
    }));
  const variants = [
    ...(origin ? [origin] : []),
    ...others,
  ];
  return variants;
}

/** 页面里的原始状态路径；注入脚本和 App 共用同一段取值逻辑（这份是文字说明）。 */
export const XIAOHONGSHU_STATE_PATH =
  "window.__INITIAL_STATE__.liveStream.roomData._rawValue.roomInfo";

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function textValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function imageURL(value: unknown): string | undefined {
  const direct = textValue(value);
  if (direct && /^https?:\/\//u.test(direct)) return direct;
  const record = asRecord(value);
  if (!record) return undefined;
  for (const key of ["url", "urlDefault", "url_default", "avatar", "src"]) {
    const item = imageURL(record[key]);
    if (item) return item;
  }
  if (Array.isArray(record.images)) {
    for (const item of record.images) {
      const found = imageURL(item);
      if (found) return found;
    }
  }
  if (Array.isArray(record.url_list)) {
    for (const item of record.url_list) {
      const found = imageURL(item);
      if (found) return found;
    }
  }
  return undefined;
}

/**
 * `roomInfo.host` 在不同版本里是字符串或对象，字段名也不统一。昵称、主播 id、
 * 头像都只是页面公开展示的信息；取不到就留空，不猜。
 */
export function xiaohongshuAnchorInfo(
  host: unknown,
  fallbackName?: unknown,
): XiaohongshuLiveAnchor {
  const row = asRecord(host);
  const anchorName = (textValue(host)
    ?? textValue(row?.nickname)
    ?? textValue(row?.nickName)
    ?? textValue(row?.nick_name)
    ?? textValue(row?.name)
    ?? textValue(row?.hostName)
    ?? textValue(fallbackName))?.slice(0, 80);
  const anchorID = (textValue(row?.hostId)
    ?? textValue(row?.host_id)
    ?? textValue(row?.userId)
    ?? textValue(row?.user_id)
    ?? textValue(row?.id))?.slice(0, 256);
  const avatar = imageURL(row?.avatar)
    ?? imageURL(row?.avatarUrl)
    ?? imageURL(row?.avatar_url)
    ?? imageURL(row?.image)
    ?? imageURL(row?.images);
  return {
    ...(anchorName ? { anchorName } : {}),
    ...(anchorID ? { anchorID } : {}),
    ...(avatar ? { anchorAvatarURL: avatar } : {}),
    ...(anchorID ? { anchorProfileURL: `https://www.xiaohongshu.com/user/profile/${encodeURIComponent(anchorID)}` } : {}),
  };
}
