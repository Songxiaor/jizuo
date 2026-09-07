/**
 * X 博主主页作品候选：扩展只在用户已打开的主页上滚动采集本人主帖预览，
 * 交给 App 的选择页。不入库、不总结、不读 Cookie。
 */

export const MAX_X_PROFILE_CANDIDATES = 100;
export const X_PROFILE_CANDIDATES_KIND = "xProfileCandidates" as const;
export const X_PROFILE_CANDIDATES_PRESENTED_KIND = "profileCandidatesPresented" as const;

const RESERVED_HANDLES = new Set([
  "home", "explore", "search", "i", "settings", "login", "logout", "intent",
  "signup", "notifications", "messages", "compose", "tos", "privacy",
]);

export function isValidTweetID(value: unknown): value is string {
  return typeof value === "string" && /^\d{8,25}$/u.test(value);
}

export function isXHandle(value: string): boolean {
  const handle = value.toLowerCase();
  return /^[a-z0-9_]{1,15}$/u.test(handle) && !RESERVED_HANDLES.has(handle);
}

function registeredHost(hostname: string): string {
  return hostname.toLowerCase().replace(/^www\./u, "");
}

export function isXProfileURL(rawURL: string | undefined): boolean {
  if (!rawURL) return false;
  try {
    const url = new URL(rawURL);
    if (url.protocol !== "https:") return false;
    if (url.username || url.password) return false;
    if (url.port && url.port !== "443") return false;
    const host = registeredHost(url.hostname);
    if (host !== "x.com" && host !== "twitter.com" && host !== "mobile.twitter.com" && host !== "m.twitter.com") {
      return false;
    }
    const parts = url.pathname.split("/").filter(Boolean);
    return parts.length === 1 && isXHandle(parts[0] ?? "");
  } catch {
    return false;
  }
}

export function profileHandleFromURL(rawURL: string | undefined): string | null {
  if (!isXProfileURL(rawURL) || !rawURL) return null;
  try {
    const parts = new URL(rawURL).pathname.split("/").filter(Boolean);
    return (parts[0] ?? "").toLowerCase();
  } catch {
    return null;
  }
}

export function canonicalXProfileURL(handle: string): string {
  return `https://x.com/${handle.toLowerCase()}`;
}

export function canonicalXStatusURL(handle: string, id: string): string {
  return `https://x.com/${handle.toLowerCase()}/status/${id}`;
}

/** Strip only a trailing @handle / (@handle). Never cut the same text in the middle of a name. */
export function xProfileDisplayName(raw: string, handle: string): string {
  const token = `@${handle.toLowerCase()}`;
  const paren = `(${token})`;
  let text = raw.replace(/\s+/gu, " ").trim();
  for (;;) {
    const lower = text.toLowerCase();
    if (lower.endsWith(paren)) {
      text = text.slice(0, text.length - paren.length).trim();
      continue;
    }
    if (lower.endsWith(token)) {
      text = text.slice(0, text.length - token.length).trim();
      continue;
    }
    break;
  }
  return text || token;
}

/** Handle is not a display name. Empty / @handle-only headers must not be sent. */
export function resolvedXProfileDisplayName(raw: string, handle: string): string | null {
  const name = xProfileDisplayName(raw, handle);
  const stripped = name.replace(/^@/u, "");
  if (!name || stripped.toLowerCase() === handle.toLowerCase()) return null;
  return name.slice(0, 80);
}

/** Public profile photo only. Tweet `media/` and non-twimg hosts are rejected. */
export function isPublicTwimgProfileImageURL(raw: string | undefined | null): boolean {
  if (!raw) return false;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:") return false;
    if (url.username || url.password) return false;
    if (url.port && url.port !== "443") return false;
    const host = url.hostname.toLowerCase();
    if (host !== "twimg.com" && !host.endsWith(".twimg.com")) return false;
    return url.pathname.toLowerCase().includes("/profile_images/");
  } catch {
    return false;
  }
}

export type XProfilePreviewItem = {
  id: string;
  url: string;
  previewText?: string;
  publishedText?: string;
};

export type XProfileCollectResult = {
  authorID: string;
  profileURL: string;
  profileName: string;
  profileAvatarURL?: string;
  items: XProfilePreviewItem[];
  loginRequired: boolean;
};

export function normalizeXProfileItems(raw: unknown, authorID: string): XProfilePreviewItem[] {
  if (!Array.isArray(raw) || !isXHandle(authorID)) return [];
  const out: XProfilePreviewItem[] = [];
  const seen = new Set<string>();
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    if (!isValidTweetID(row.id) || seen.has(row.id)) continue;
    const url = typeof row.url === "string" ? row.url : canonicalXStatusURL(authorID, row.id);
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "https:" || parsed.username || parsed.password) continue;
      if (parsed.port && parsed.port !== "443") continue;
      const host = registeredHost(parsed.hostname);
      if (host !== "x.com" && host !== "twitter.com") continue;
      const parts = parsed.pathname.split("/").filter(Boolean);
      if (parts.length !== 3 || parts[0]?.toLowerCase() !== authorID.toLowerCase() || parts[1] !== "status" || parts[2] !== row.id) {
        continue;
      }
    } catch {
      continue;
    }
    seen.add(row.id);
    const item: XProfilePreviewItem = {
      id: row.id,
      url: canonicalXStatusURL(authorID, row.id),
    };
    if (typeof row.previewText === "string" && row.previewText.trim()) {
      item.previewText = row.previewText.slice(0, 200);
    }
    if (typeof row.publishedText === "string" && row.publishedText.trim()) {
      item.publishedText = row.publishedText.slice(0, 40);
    }
    out.push(item);
    if (out.length >= MAX_X_PROFILE_CANDIDATES) break;
  }
  return out;
}

export function parseProfileCandidatesPresented(value: unknown): { acceptedCount: number; requestId: string } | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.kind === "bookmarksAccepted" || candidate.kind === "taskAccepted" || candidate.kind === "bookmarksLookup") {
    return null;
  }
  if (candidate.kind !== X_PROFILE_CANDIDATES_PRESENTED_KIND) return null;
  if (candidate.version !== 1) return null;
  if (typeof candidate.requestId !== "string" || candidate.requestId.length < 1 || candidate.requestId.length > 128) {
    return null;
  }
  const { acceptedCount } = candidate;
  if (typeof acceptedCount !== "number" || !Number.isInteger(acceptedCount)) return null;
  if (acceptedCount < 1 || acceptedCount > MAX_X_PROFILE_CANDIDATES) return null;
  return { acceptedCount, requestId: candidate.requestId };
}

export function profileCollectFailureCopy(code: string): string {
  switch (code) {
    case "not_profile":
      return "请打开该账号主页（地址栏是 x.com/用户名）后再读取。首页时间线、收藏夹和单帖都不能当作主页作品。";
    case "login":
      return "请先在浏览器登录 X，再打开该账号主页。扩展不会读取 Cookie，也不会把页面登录当成汲作已连接。";
    case "empty":
      return "没有找到该账号自己的主帖。请确认停在「帖子」分页，并向下滚动加载列表。";
    case "injection_failed":
      return "读取主页作品失败，请刷新页面后重试。";
    case "native_error":
      return "无法连接汲作。页面能读到作品不代表通道已通。请确认汲作已打开，且为本机当前版本。";
    case "upgrade_app":
      return "当前汲作还不支持主页作品选择，请升级后再试。未保存任何内容。";
    default:
      return "读取未完成，请重试。";
  }
}

export function profilePresentedMessage(count: number): string {
  return `汲作已收到 ${count} 条作品候选，请到汲作勾选后保存。尚未入库，也不会自动总结。`;
}

/**
 * 必须完全自包含：executeScript 只序列化本函数体。
 */
export async function collectXProfileItemsInPage(
  expectedHandle: string,
  maxItems: number,
): Promise<XProfileCollectResult> {
  const handle = String(expectedHandle || "").toLowerCase();
  const profileURL = `https://x.com/${handle}`;
  const items: Array<{ id: string; url: string; previewText?: string; publishedText?: string }> = [];
  const seen = new Set<string>();

  const loginVisible = Array.from(document.querySelectorAll('[role="dialog"],.login-container,.login-modal'))
    .some((node) => {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden") return false;
      return /登录|Log in|Sign in/u.test(node.textContent || "");
    });

  const nameRoot = document.querySelector('main [data-testid="UserName"],[role="main"] [data-testid="UserName"]');
  const title = document.title || "";
  const marker = title.toLowerCase().indexOf(`(@${handle})`);
  const titleName = marker > 0 ? title.slice(0, marker).trim() : `@${handle}`;
  const token = `@${handle}`;
  const paren = `(${token})`;
  let profileName = (nameRoot?.textContent || titleName).replace(/\s+/gu, " ").trim();
  for (;;) {
    const lower = profileName.toLowerCase();
    if (lower.endsWith(paren)) {
      profileName = profileName.slice(0, profileName.length - paren.length).trim();
      continue;
    }
    if (lower.endsWith(token)) {
      profileName = profileName.slice(0, profileName.length - token.length).trim();
      continue;
    }
    break;
  }
  const strippedName = profileName.replace(/^@/u, "");
  profileName = !profileName || strippedName.toLowerCase() === handle ? "" : profileName.slice(0, 80);

  const headerOwned = (node: Element | null): node is Element => {
    if (!node) return false;
    const style = getComputedStyle(node);
    if (style.display === "none" || style.visibility === "hidden") return false;
    const rect = node.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    return !node.closest('article, aside, nav, [data-testid="tweet"]');
  };
  const admitTwimg = (raw: string | null | undefined): string | null => {
    if (!raw) return null;
    try {
      const url = new URL(raw, location.href);
      if (url.protocol !== "https:") return null;
      if (url.username || url.password) return null;
      if (url.port && url.port !== "443") return null;
      const host = url.hostname.toLowerCase();
      if (host !== "twimg.com" && !host.endsWith(".twimg.com")) return null;
      if (!url.pathname.toLowerCase().includes("/profile_images/")) return null;
      return url.href;
    } catch {
      return null;
    }
  };
  const photoPath = `/${handle}/photo`;
  let photoImg = document.querySelector(`main a[href="${photoPath}"] img`);
  if (!photoImg) {
    const link = Array.from(document.querySelectorAll("main a[href]")).find((anchor) => {
      try {
        return new URL(anchor.getAttribute("href") || "", location.href).pathname.replace(/\/$/u, "").toLowerCase() === photoPath;
      } catch {
        return false;
      }
    });
    photoImg = link?.querySelector("img") ?? null;
  }
  const preferred = document.querySelector(`main [data-testid="UserAvatar-Container-${handle}"] img`);
  const avatarNode = [photoImg, preferred].find(headerOwned) ?? null;
  const profileAvatarURL = admitTwimg(
    (avatarNode instanceof HTMLImageElement ? avatarNode.currentSrc : "")
      || avatarNode?.getAttribute("src")
      || avatarNode?.getAttribute("data-src"),
  );

  const idFromHref = (href: string | null): string | null => {
    if (!href) return null;
    const match = href.match(/\/status\/(\d{8,25})(?:$|[/?#])/u);
    return match?.[1] ?? null;
  };

  const harvest = (): boolean => {
    const root = document.querySelector("main,[role='main']");
    if (!root) return false;
    const articles = Array.from(root.querySelectorAll("article")).filter(
      (node) => !node.parentElement?.closest("article"),
    );
    for (const article of articles) {
      if (article.closest("aside,nav,[class*='recommend']")) continue;
      const social = article.querySelector('[data-testid="socialContext"]');
      if (social && /repost|转帖|转发/iu.test(social.textContent || "")) continue;
      // The main header owns the post. Never search a quoted card for a matching author.
      const header = Array.from(article.querySelectorAll('[data-testid="User-Name"]'))
        .find((node) => !node.closest('[role="link"],[data-testid="quoteTweet"]'));
      const time = header?.querySelector("time");
      const anchor = time?.closest("a[href]");
      const href = anchor?.getAttribute("href");
      if (!href) continue;
      const parsed = new URL(href, location.href);
      if (parsed.protocol !== "https:" || !["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(parsed.hostname)) continue;
      const parts = parsed.pathname.split("/").filter(Boolean);
      if (parts.length !== 3 || parts[1] !== "status" || parts[0]?.toLowerCase() !== handle) continue;
      const id = idFromHref(href);
      if (!id || seen.has(id)) continue;
      if (article.querySelector('[data-testid="placementTracking"],[data-testid="promotedIndicator"]')) continue;
      seen.add(id);
      const mainText = Array.from(article.querySelectorAll('[data-testid="tweetText"]'))
        .find((node) => !node.closest('[role="link"],[data-testid="quoteTweet"]'));
      const preview = (mainText?.textContent || "").replace(/\s+/gu, " ").trim().slice(0, 200);
      const published = (time?.textContent || "").replace(/\s+/gu, " ").trim().slice(0, 40);
      items.push({
        id,
        url: `https://x.com/${handle}/status/${id}`,
        ...(preview ? { previewText: preview } : {}),
        ...(published ? { publishedText: published } : {}),
      });
      if (items.length >= maxItems) return true;
    }
    return false;
  };

  let stagnant = 0;
  for (let round = 0; round < 60; round += 1) {
    const before = items.length;
    if (harvest()) break;
    stagnant = items.length === before ? stagnant + 1 : 0;
    if (stagnant >= (items.length ? 8 : 20)) break;
    window.scrollBy(0, window.innerHeight * 0.8);
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  harvest();

  return {
    authorID: handle,
    profileURL,
    profileName,
    ...(profileAvatarURL ? { profileAvatarURL } : {}),
    items,
    loginRequired: items.length === 0 && loginVisible,
  };
}
