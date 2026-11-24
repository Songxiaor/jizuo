/**
 * 抖音直播间的取流解析。只读页面已经渲染出来的房间数据，不调用隐藏接口，
 * 也不读取 Cookie。所有函数都是纯函数，可以在单测里用脱敏片段直接跑。
 *
 * 页面里的房间数据不在一个完整 JSON 里：它被拆成若干
 * `self.__pace_f.push([1,"…"])` 的字符串片段，执行时由页面的 React Server
 * Components 运行时拼起来。这里按同样的顺序把片段解成文本，再从文本里取出
 * 第一个 `stream_url` 对象。
 */

export type LiveQualityKey = "origin" | "hd" | "sd" | "ld";
export type LiveContainer = "flv" | "hls";

export type LiveVariant = {
  quality: LiveQualityKey;
  container: LiveContainer;
  url: string;
  resolution?: string;
  label?: string;
};

export type DouyinLiveRoom = {
  pageURL: string;
  roomID: string;
  anchorName?: string;
  anchorID?: string;
  anchorAvatarURL?: string;
  anchorProfileURL?: string;
  title?: string;
  variants: LiveVariant[];
};

export const DOUYIN_LIVE_REFERER = "https://live.douyin.com/";

/** 与 App 侧 `LiveRecordingHTTP.userAgent` 保持一致：只在请求头里声明身份，不做任何伪装式的轮换。 */
export const LIVE_BROWSER_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

/** `live.douyin.com/<数字>` 才是直播间；`www.douyin.com` 下的直播是另一个入口，本期不接。 */
export function isDouyinLiveURL(rawURL: string): boolean {
  return douyinRoomID(rawURL) !== null;
}

export function douyinRoomID(rawURL: string): string | null {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase();
    if (host !== "live.douyin.com") return null;
    const match = url.pathname.match(/^\/(\d{6,25})\/?$/u);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

/** 把页面里的 `self.__pace_f.push([1,"…"])` 片段按出现顺序拼成一段文本。 */
export function joinPaceChunks(html: string): string {
  // 不能用一个「字符串内容」正则：真实页面里房间数据被套了两层转义，
  // 嵌套的 \\\" 会让贪婪匹配提前收尾，几百 KB 的那一块整段丢掉。
  // 这里按 JS 字符串字面量的规则逐字符找闭引号，和浏览器执行时一致。
  const marker = "self.__pace_f.push([1,";
  let index = 0;
  let output = "";
  while (index < html.length) {
    const start = html.indexOf(marker, index);
    if (start < 0) break;
    let cursor = start + marker.length;
    if (html[cursor] !== "\"") { index = cursor; continue; }
    const literalStart = cursor;
    cursor += 1;
    let escaped = false;
    for (; cursor < html.length; cursor += 1) {
      const char = html[cursor];
      if (escaped) { escaped = false; continue; }
      if (char === "\\") { escaped = true; continue; }
      if (char === "\"") break;
    }
    if (cursor >= html.length) break;
    const literal = html.slice(literalStart, cursor + 1);
    try {
      output += JSON.parse(literal) as string;
    } catch {
      output += unescapeJavaScriptString(literal.slice(1, -1));
    }
    index = cursor + 1;
  }
  return output;
}

function unescapeJavaScriptString(value: string): string {
  return value.replace(/\\(u[0-9a-fA-F]{4}|.)/gu, (_all, code: string) => {
    if (code.length === 5 && code[0]?.toLowerCase() === "u") {
      return String.fromCharCode(Number.parseInt(code.slice(1), 16));
    }
    switch (code) {
      case "n": return "\n";
      case "r": return "\r";
      case "t": return "\t";
      default: return code;
    }
  });
}

/** 从任意文本里取出第一个平衡的 JSON 对象；字符串里的括号不算。 */
export function firstJSONObject(text: string, start: number): Record<string, unknown> | null {
  if (text[start] !== "{") return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const char = text[index];
    if (escaped) { escaped = false; continue; }
    if (char === "\\") { escaped = true; continue; }
    if (char === "\"") { inString = !inString; continue; }
    if (inString) continue;
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        try {
          const value = JSON.parse(text.slice(start, index + 1));
          return value && typeof value === "object" && !Array.isArray(value)
            ? value as Record<string, unknown>
            : null;
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}

type QualityDescriptor = { name: string; sdkKey: LiveQualityKey; resolution?: string };

const SDK_KEY_TO_MAP_KEY: Record<LiveQualityKey, string> = {
  origin: "FULL_HD1",
  hd: "HD1",
  sd: "SD2",
  ld: "SD1",
};

const QUALITY_ORDER: LiveQualityKey[] = ["origin", "hd", "sd", "ld"];

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function stringMap(value: unknown): Record<string, string> {
  const record = asRecord(value);
  if (!record) return {};
  const output: Record<string, string> = {};
  for (const [key, item] of Object.entries(record)) {
    if (typeof item === "string" && isStreamURL(item)) output[key] = item;
  }
  return output;
}

function isStreamURL(value: string): boolean {
  return /^https?:\/\//u.test(value) && /\.(?:flv|m3u8)(?:[?#]|$)/u.test(value);
}

function qualitiesFromStream(stream: Record<string, unknown>): QualityDescriptor[] {
  const core = asRecord(stream.live_core_sdk_data);
  const pull = asRecord(core?.pull_data);
  const options = asRecord(pull?.options);
  const raw = Array.isArray(options?.qualities) ? options.qualities : [];
  const seen = new Set<LiveQualityKey>();
  const output: QualityDescriptor[] = [];
  for (const item of raw) {
    const row = asRecord(item);
    const sdkKey = row?.sdk_key;
    if (typeof sdkKey !== "string" || !QUALITY_ORDER.includes(sdkKey as LiveQualityKey)) continue;
    if (seen.has(sdkKey as LiveQualityKey)) continue;
    seen.add(sdkKey as LiveQualityKey);
    output.push({
      name: typeof row?.name === "string" ? row.name : "",
      sdkKey: sdkKey as LiveQualityKey,
      ...(typeof row?.resolution === "string" ? { resolution: row.resolution } : {}),
    });
  }
  return output;
}

export function variantsFromStreamObject(stream: Record<string, unknown>): LiveVariant[] {
  const flv = stringMap(stream.flv_pull_url);
  const hls = stringMap(stream.hls_pull_url_map);
  const qualities = qualitiesFromStream(stream);
  const descriptors: QualityDescriptor[] = qualities.length > 0
    ? qualities
    : QUALITY_ORDER.map((quality) => ({ name: "", sdkKey: quality }));
  descriptors.sort(
    (a, b) => QUALITY_ORDER.indexOf(a.sdkKey) - QUALITY_ORDER.indexOf(b.sdkKey),
  );

  const variants: LiveVariant[] = [];
  const seen = new Set<string>();
  for (const descriptor of descriptors) {
    const mapKey = SDK_KEY_TO_MAP_KEY[descriptor.sdkKey];
    const candidates: Array<{ container: LiveContainer; url: string }> = [
      // 原画优先 HLS：抖音原画 FLV 是私有 H.265 封装，ffmpeg 只能读出声音。
      ...(descriptor.sdkKey === "origin"
        ? [{ container: "hls" as const, url: hls[mapKey] ?? "" }, { container: "flv" as const, url: flv[mapKey] ?? "" }]
        : [{ container: "flv" as const, url: flv[mapKey] ?? "" }, { container: "hls" as const, url: hls[mapKey] ?? "" }]),
    ];
    for (const candidate of candidates) {
      if (!candidate.url || !isStreamURL(candidate.url)) continue;
      const identity = `${descriptor.sdkKey}:${candidate.container}`;
      if (seen.has(identity)) continue;
      seen.add(identity);
      variants.push({
        quality: descriptor.sdkKey,
        container: candidate.container,
        url: candidate.url,
        ...(descriptor.resolution ? { resolution: descriptor.resolution } : {}),
        ...(descriptor.name ? { label: descriptor.name } : {}),
      });
    }
  }
  return variants;
}

function qualityFromStreamURL(rawURL: string): LiveQualityKey | null {
  const file = (() => {
    try { return new URL(rawURL).pathname.split("/").pop() ?? ""; } catch { return ""; }
  })();
  if (!file) return null;
  const match = file.match(/(?:_(or4|origin|hd5?|sd5?|ld5?))?\.(?:flv|m3u8)$/u);
  if (!match) return null;
  const suffix = match[1] ?? "";
  if (suffix === "" || suffix === "or4" || suffix === "origin") return "origin";
  if (suffix.startsWith("hd")) return "hd";
  if (suffix.startsWith("sd")) return "sd";
  return "ld";
}

/** 页面数据读不到时的兜底：播放器实际请求过的地址。只能拿到正在播的那一档。 */
export function variantsFromResourceURLs(urls: readonly string[]): LiveVariant[] {
  const variants: LiveVariant[] = [];
  const seen = new Set<string>();
  for (const url of urls) {
    if (!isStreamURL(url)) continue;
    const quality = qualityFromStreamURL(url);
    if (!quality) continue;
    const container: LiveContainer = /\.m3u8(?:[?#]|$)/u.test(url) ? "hls" : "flv";
    if (seen.has(url)) continue;
    seen.add(url);
    variants.push({ quality, container, url });
  }
  return variants;
}

function anchorNameFromPayload(payload: string): string | undefined {
  const match = payload.match(/"owner":\{"id_str":"[^"]*","sec_uid":"[^"]*","nickname":"([^"]{1,80})"/u);
  return match?.[1]?.trim() || undefined;
}

function firstStringURL(value: unknown): string | undefined {
  if (typeof value === "string") {
    return /^https?:\/\//u.test(value) ? value : undefined;
  }
  const record = asRecord(value);
  if (!record) return undefined;
  const list = Array.isArray(record.url_list) ? record.url_list : [];
  for (const item of list) {
    if (typeof item === "string" && /^https?:\/\//u.test(item)) return item;
  }
  for (const key of ["url", "urlDefault", "url_default"]) {
    const item = record[key];
    if (typeof item === "string" && /^https?:\/\//u.test(item)) return item;
  }
  return undefined;
}

type DouyinAnchorInfo = {
  anchorName?: string;
  anchorID?: string;
  anchorAvatarURL?: string;
  anchorProfileURL?: string;
};

/**
 * `owner` 是页面房间数据里的主播对象。昵称优先从它取；取不到时退回原来的
 * 正则（页面结构变化时不至于连名字一起丢）。头像与主页只用于入库时挂到博主，
 * 进正文前会由 App 侧再做一次域名与 https 校验。
 */
function anchorInfoFromPayload(payload: string): DouyinAnchorInfo {
  const marker = payload.indexOf("\"owner\":");
  let owner: Record<string, unknown> | null = null;
  if (marker >= 0) {
    const brace = payload.indexOf("{", marker);
    if (brace >= 0) owner = firstJSONObject(payload, brace);
  }
  const nickname = typeof owner?.nickname === "string" ? owner.nickname.trim() : "";
  const anchorName = (nickname || anchorNameFromPayload(payload))?.slice(0, 80) || undefined;
  const anchorID = typeof owner?.sec_uid === "string" ? owner.sec_uid.trim().slice(0, 256) : "";
  const avatar = firstStringURL(owner?.avatar_thumb)
    ?? firstStringURL(owner?.avatar_medium)
    ?? firstStringURL(owner?.avatar_larger);
  return {
    ...(anchorName ? { anchorName } : {}),
    ...(anchorID ? { anchorID } : {}),
    ...(avatar ? { anchorAvatarURL: avatar } : {}),
    ...(anchorID ? { anchorProfileURL: `https://www.douyin.com/user/${encodeURIComponent(anchorID)}` } : {}),
  };
}

/**
 * 解析一份直播间 HTML。`resourceURLs` 是播放器已经请求过的地址，只在页面数据
 * 缺少 `stream_url` 时使用。
 */
export function parseDouyinLiveRoom(
  html: string,
  options: { pageURL: string; title?: string | null; resourceURLs?: readonly string[] },
): DouyinLiveRoom | null {
  const roomID = douyinRoomID(options.pageURL);
  if (!roomID) return null;
  const payload = joinPaceChunks(html);
  const anchor = anchorInfoFromPayload(payload);
  let variants: LiveVariant[] = [];
  const index = payload.indexOf("\"stream_url\"");
  if (index >= 0) {
    const brace = payload.indexOf("{", index);
    const stream = brace >= 0 ? firstJSONObject(payload, brace) : null;
    if (stream) variants = variantsFromStreamObject(stream);
  }
  if (variants.length === 0) {
    variants = variantsFromResourceURLs(options.resourceURLs ?? []);
  }
  if (variants.length === 0) return null;
  const title = (options.title ?? "").trim();
  return {
    pageURL: options.pageURL,
    roomID,
    ...anchor,
    ...(title ? { title } : {}),
    variants,
  };
}

/** 下拉框的选项：每个清晰度一条，优先展示原画档的地址。 */
export function pickQualityOptions(variants: readonly LiveVariant[]): LiveVariant[] {
  const byQuality = new Map<LiveQualityKey, LiveVariant>();
  for (const variant of variants) {
    const existing = byQuality.get(variant.quality);
    if (!existing) { byQuality.set(variant.quality, variant); continue; }
    const preferred: LiveContainer = variant.quality === "origin" ? "hls" : "flv";
    if (existing.container !== preferred && variant.container === preferred) {
      byQuality.set(variant.quality, variant);
    }
  }
  return QUALITY_ORDER.flatMap((quality) => {
    const variant = byQuality.get(quality);
    return variant ? [variant] : [];
  });
}

const QUALITY_FALLBACK_LABEL: Record<LiveQualityKey, string> = {
  origin: "原画",
  hd: "高清",
  sd: "标清",
  ld: "流畅",
};

export function liveQualityLabel(variant: Pick<LiveVariant, "quality" | "label" | "resolution">): string {
  const name = variant.label?.trim() || QUALITY_FALLBACK_LABEL[variant.quality];
  const resolution = variant.resolution?.trim();
  return resolution ? `${name} · ${resolution}` : name;
}

/**
 * 按用户选的档位挑地址。原画只认 HLS；其他档优先 FLV，缺了就退到 HLS，
 * 再缺就往下一档降，最后才回到原画。返回的档位可能与请求不同，界面要如实显示。
 */
export function selectLiveVariant(
  variants: readonly LiveVariant[],
  requested: LiveQualityKey,
  platform: "douyin" | "xiaohongshu" = "douyin",
): LiveVariant | null {
  const order: LiveQualityKey[] = (() => {
    const index = QUALITY_ORDER.indexOf(requested);
    const descending = QUALITY_ORDER.slice(index);
    const ascending = QUALITY_ORDER.slice(0, Math.max(0, index)).reverse();
    return [...descending, ...ascending];
  })();
  for (const quality of order) {
    const matching = variants.filter((variant) => variant.quality === quality);
    if (matching.length === 0) continue;
    if (quality === "origin") {
      // 小红书原画是 H.264 FLV，可直接录；抖音原画走 HLS。
      if (platform === "xiaohongshu") {
        const flv = matching.find((variant) => variant.container === "flv");
        if (flv) return flv;
        const hls = matching.find((variant) => variant.container === "hls");
        if (hls) return hls;
        continue;
      }
      const hls = matching.find((variant) => variant.container === "hls");
      if (hls) return hls;
      // 原画 FLV 录不出画面，宁可降一档也不给一个坏文件。
      continue;
    }
    const flv = matching.find((variant) => variant.container === "flv");
    if (flv) return flv;
    const hls = matching.find((variant) => variant.container === "hls");
    if (hls) return hls;
  }
  return null;
}
