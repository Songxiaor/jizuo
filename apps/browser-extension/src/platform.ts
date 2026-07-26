import type { CapturePlatform } from "./contract";
import {
  detectDouyinAwemeIdFromURL,
  isDouyinHost,
  isDouyinSingleVideoURL,
} from "./content/douyin-detect";
import { isBilibiliHost } from "./content/bilibili";
import { isXiaohongshuHost } from "./content/xiaohongshu";

/**
 * Keeps browser-only source recognition at the capture boundary. The desktop
 * app receives this stable, language-neutral value and never has to infer a
 * platform again from a saved private URL.
 */
export function detectCapturePlatform(rawURL: string): CapturePlatform {
  let host: string;
  try {
    host = new URL(rawURL).hostname.toLowerCase();
  } catch {
    return "generic";
  }

  if (host === "mp.weixin.qq.com" || host === "weixin.qq.com") return "wechat";
  if (host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")) return "x";
  if (host === "github.com" || host.endsWith(".github.com")) return "github";
  if (isDouyinHost(rawURL)) return "douyin";
  if (isBilibiliHost(rawURL)) return "bilibili";
  if (isXiaohongshuHost(rawURL)) return "xiaohongshu";
  // A 类文章站：仍走 generic 的 rendered_dom 抽取，这里只贴平台标签，让 popup 与
  // History 侧栏识别来源，并为后续 Readability 式清洗预留 resolver 挂点。
  if (host === "zhihu.com" || host.endsWith(".zhihu.com")) return "zhihu";
  if (host === "medium.com" || host.endsWith(".medium.com")) return "medium";
  if (host === "substack.com" || host.endsWith(".substack.com")) return "substack";
  if (host === "toutiao.com" || host.endsWith(".toutiao.com")) return "toutiao";
  return "generic";
}

/**
 * Surfaces that carry a concrete Douyin video (single item), not a bare feed shell.
 * Includes `/video/{id}`, share paths, short links, and Feed overlays with `modal_id`.
 * Logic aligned with StepAudio DouyinDetector multi-source ID ranking.
 */
export function isDouyinVideoURL(rawURL: string): boolean {
  return isDouyinSingleVideoURL(rawURL);
}

/** Resolve the stable public video page for storage / History. */
export function canonicalizeDouyinVideoURL(rawURL: string): string | null {
  return detectDouyinAwemeIdFromURL(rawURL)?.canonicalURL ?? null;
}

/** Extract aweme id for same-origin detail fetch. */
export function douyinAwemeIdFromURL(rawURL: string): string | null {
  return detectDouyinAwemeIdFromURL(rawURL)?.awemeId ?? null;
}

/** A status URL is the X post surface; profile and search pages remain generic X captures. */
export function isXStatusURL(rawURL: string): boolean {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase();
    if (!(host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com"))) return false;
    return /^\/[^/]+\/status\/\d+(?:\/|$)/u.test(url.pathname);
  } catch {
    return false;
  }
}
