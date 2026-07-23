export type DouyinSessionDiagnosticCode =
  | "invalid_context"
  | "id_before_after"
  | "main_fetch_timeout"
  | "main_fetch_network"
  | "main_injection_failed"
  | "http_403"
  | "http_429"
  | "http_other"
  | "body_too_large"
  | "body_unavailable"
  | "json_invalid"
  | "api_status"
  | "detail_missing"
  | "aweme_id_missing_or_nonstring"
  | "aweme_id_mismatch"
  | "video_missing"
  | "no_candidates"
  | "candidate_limit"
  | "no_allowed_host";

export type DouyinSessionDetailSuccess = {
  ok: true;
  playbackURL: string;
  candidateCount: number;
};

export type DouyinSessionDetailFailure = {
  ok: false;
  code: DouyinSessionDiagnosticCode;
  blockedHost?: string;
};

export type DouyinSessionDiagnostic = Omit<DouyinSessionDetailFailure, "ok">;

export type DouyinSessionDetailResult = DouyinSessionDetailSuccess | DouyinSessionDetailFailure;

/**
 * MAIN-world, single-request fallback for a user-triggered Douyin capture.
 * Keep this function completely self-contained: Chrome serializes only its
 * function body when `executeScript` crosses from the service worker.
 */
export async function fetchDouyinSessionDetailInMainWorld(
  lockedAwemeId: string,
): Promise<DouyinSessionDetailResult> {
  const maximumBodyBytes = 2 * 1024 * 1024;
  const maximumCandidates = 256;
  const failure = (
    code: DouyinSessionDiagnosticCode,
    blockedHost?: string,
  ): DouyinSessionDetailFailure => ({ ok: false, code, ...(blockedHost ? { blockedHost } : {}) });
  const validID = (value: unknown): value is string =>
    typeof value === "string" && /^\d{8,25}$/u.test(value);
  const currentURLState = (): "ok" | "invalid_context" | "id_before_after" => {
    try {
      const current = new URL(location.href);
      if (current.protocol !== "https:") return "invalid_context";
      const host = current.hostname.toLowerCase();
      if (host !== "www.douyin.com" && host !== "douyin.com") return "invalid_context";
      const ids: string[] = [];
      for (const key of ["modal_id", "aweme_id", "item_id", "video_id", "group_id"]) {
        const value = current.searchParams.get(key);
        if (value !== null) {
          if (!validID(value)) return "invalid_context";
          ids.push(value);
        }
      }
      const path = current.pathname.match(/^\/(?:video|note)\/(\d{8,25})(?:\/|$)/u)?.[1];
      if (path) ids.push(path);
      if (ids.length === 0) return "invalid_context";
      return ids.every((value) => value === lockedAwemeId) ? "ok" : "id_before_after";
    } catch {
      return "invalid_context";
    }
  };
  const allowedPlaybackURL = (rawURL: string): boolean => {
    if (rawURL.length === 0 || rawURL.length > 8192) return false;
    try {
      const url = new URL(rawURL);
      if (url.protocol !== "https:" || url.username || url.password || url.hash) return false;
      if (url.port && url.port !== "443") return false;
      const host = url.hostname.toLowerCase();
      if (host === "douyinvod.com" || host.endsWith(".douyinvod.com")) return true;
      if (host === "douyincdn.com" || host.endsWith(".douyincdn.com")) return true;
      return (host === "douyin.com" || host === "www.douyin.com")
        && /^\/aweme\/v1\/(?:web\/)?play\/$/u.test(url.pathname);
    } catch {
      return false;
    }
  };
  const safeBlockedHost = (rawURL: string): string | undefined => {
    try {
      const url = new URL(rawURL);
      if (url.username || url.password) return undefined;
      const host = url.hostname.toLowerCase();
      return host.length > 0
        && host.length <= 253
        && /^[a-z0-9.-]+$/u.test(host)
        ? host
        : undefined;
    } catch {
      return undefined;
    }
  };

  if (!validID(lockedAwemeId)) return failure("invalid_context");
  const beforeState = currentURLState();
  if (beforeState !== "ok") return failure(beforeState);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5_000);
  let helperFrame: HTMLIFrameElement | undefined;
  try {
    const endpoint = new URL("/aweme/v1/web/aweme/detail/", location.origin);
    endpoint.searchParams.set("aweme_id", lockedAwemeId);
    endpoint.searchParams.set("aid", "6383");
    endpoint.searchParams.set("device_platform", "webapp");
    endpoint.searchParams.set("version_name", "23.5.0");
    endpoint.searchParams.set("os_name", "mac");
    // Douyin's own APM SDK (Slardar / ibytedapm) monkey-patches window.fetch on
    // the page and rejects this same-origin detail request with a synthetic
    // "Failed to fetch". Borrow a pristine, un-hooked fetch from a same-origin
    // about:blank iframe so the request leaves untouched — still same-origin, so
    // session cookies are sent. Falls back to the page fetch if unavailable.
    let pageFetch: typeof fetch = fetch;
    try {
      helperFrame = document.createElement("iframe");
      helperFrame.style.display = "none";
      helperFrame.setAttribute("aria-hidden", "true");
      (document.body ?? document.documentElement).appendChild(helperFrame);
      const frameFetch = helperFrame.contentWindow?.fetch;
      if (typeof frameFetch === "function" && frameFetch.toString().includes("[native code]")) {
        pageFetch = frameFetch.bind(helperFrame.contentWindow);
      }
    } catch {
      // Keep the page fetch when the helper iframe cannot be created.
    }
    let response: Response;
    try {
      response = await pageFetch(endpoint.href, {
        method: "GET",
        headers: { Accept: "application/json, text/plain, */*" },
        credentials: "same-origin",
        mode: "same-origin",
        redirect: "error",
        cache: "no-store",
        signal: controller.signal,
      });
    } catch {
      return failure(controller.signal.aborted ? "main_fetch_timeout" : "main_fetch_network");
    }
    const afterFetchState = currentURLState();
    if (afterFetchState !== "ok") return failure("id_before_after");
    if (response.status === 403) return failure("http_403");
    if (response.status === 429) return failure("http_429");
    if (response.status !== 200) return failure("http_other");
    const declaredLength = response.headers.get("content-length");
    if (declaredLength !== null) {
      if (!/^\d+$/u.test(declaredLength)) return failure("body_unavailable");
      if (Number(declaredLength) > maximumBodyBytes) return failure("body_too_large");
    }
    const reader = response.body?.getReader();
    if (!reader) return failure("body_unavailable");
    const chunks: Uint8Array[] = [];
    let byteCount = 0;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        byteCount += next.value.byteLength;
        if (byteCount > maximumBodyBytes) {
          await reader.cancel();
          return failure("body_too_large");
        }
        chunks.push(next.value);
      }
    } catch {
      return failure(controller.signal.aborted ? "main_fetch_timeout" : "body_unavailable");
    }
    if (currentURLState() !== "ok") return failure("id_before_after");
    const bytes = new Uint8Array(byteCount);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    let payload: unknown;
    try {
      payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } catch {
      return failure("json_invalid");
    }
    if (!payload || typeof payload !== "object") return failure("json_invalid");
    const root = payload as Record<string, unknown>;
    if (root.status_code !== undefined && root.status_code !== 0) return failure("api_status");
    const data = root.data && typeof root.data === "object"
      ? root.data as Record<string, unknown>
      : undefined;
    if (data?.status_code !== undefined && data.status_code !== 0) return failure("api_status");
    const detailCandidates = [root.aweme_detail, root.aweme, data?.aweme_detail, data];
    const detailObjects = detailCandidates.filter(
      (value): value is Record<string, unknown> => Boolean(value) && typeof value === "object",
    );
    const detail = detailObjects.find((value) => "aweme_id" in value || "video" in value)
      ?? detailObjects[0];
    if (!detail) return failure("detail_missing");
    if (typeof detail.aweme_id !== "string") return failure("aweme_id_missing_or_nonstring");
    if (detail.aweme_id !== lockedAwemeId) return failure("aweme_id_mismatch");
    if (!detail.video || typeof detail.video !== "object") return failure("video_missing");
    const video = detail.video as Record<string, unknown>;
    const ranked: Array<{ bitrate: number; order: number; urls: string[] }> = [];
    let order = 0;
    if (Array.isArray(video.bit_rate)) {
      for (const entry of video.bit_rate) {
        if (!entry || typeof entry !== "object") continue;
        const item = entry as Record<string, unknown>;
        const address = item.play_addr;
        const urls = address && typeof address === "object"
          ? (address as Record<string, unknown>).url_list
          : undefined;
        if (!Array.isArray(urls)) continue;
        ranked.push({
          bitrate: typeof item.bit_rate === "number" && Number.isFinite(item.bit_rate) ? item.bit_rate : 0,
          order: order++,
          urls: urls.filter((value): value is string => typeof value === "string"),
        });
      }
    }
    const fallbackAddress = video.play_addr;
    const fallbackURLs = fallbackAddress && typeof fallbackAddress === "object"
      ? (fallbackAddress as Record<string, unknown>).url_list
      : undefined;
    if (Array.isArray(fallbackURLs)) {
      ranked.push({
        bitrate: -1,
        order: order++,
        urls: fallbackURLs.filter((value): value is string => typeof value === "string"),
      });
    }
    ranked.sort((left, right) => right.bitrate - left.bitrate || left.order - right.order);
    const rawURLs = ranked.flatMap((entry) => entry.urls);
    if (rawURLs.length === 0) return failure("no_candidates");
    if (rawURLs.length > maximumCandidates) return failure("candidate_limit");
    const uniqueAllowed = [...new Set(rawURLs)].filter(allowedPlaybackURL);
    if (uniqueAllowed.length === 0) {
      const blockedHost = rawURLs.map(safeBlockedHost).find((value) => value !== undefined);
      return failure("no_allowed_host", blockedHost);
    }
    return { ok: true, playbackURL: uniqueAllowed[0]!, candidateCount: uniqueAllowed.length };
  } catch {
    return failure("body_unavailable");
  } finally {
    clearTimeout(timeout);
    helperFrame?.remove();
  }
}

/** Independent second gate in the extension service worker. */
export function isAllowedDouyinPlaybackURL(rawURL: string): boolean {
  if (rawURL.length === 0 || rawURL.length > 8192) return false;
  try {
    const url = new URL(rawURL);
    if (url.protocol !== "https:" || url.username || url.password || url.hash) return false;
    if (url.port && url.port !== "443") return false;
    const host = url.hostname.toLowerCase();
    if (host === "douyinvod.com" || host.endsWith(".douyinvod.com")) return true;
    if (host === "douyincdn.com" || host.endsWith(".douyincdn.com")) return true;
    return (host === "douyin.com" || host === "www.douyin.com")
      && /^\/aweme\/v1\/(?:web\/)?play\/$/u.test(url.pathname);
  } catch {
    return false;
  }
}
