/**
 * 浏览器代抓（扩展侧）。
 *
 * App 自己读不到某一页时，会在用户浏览器里后台打开一个标签并登记一次性 job。为了让扩展
 * 不必在每次页面加载时都去问一次 App（那会把用户所有 http/https 地址都交给 Host），
 * App 打开的标签地址带一个固定片段 `#jizuo-relay`：
 *
 * - 只有带这个片段的标签才会去问「有待抓任务吗」——正常浏览时一次 native message 都不发；
 * - 片段同时证明「这是代抓开的标签」，命中/失败/过期后可以安全关闭，绝不碰用户自己的标签。
 *
 * 这里只放可以单测的逻辑；标签事件与 alarm 在 background.ts 里接。
 */

export const RELAY_JOB_KIND = "browserCaptureJob";
export const RELAY_JOB_VERSION = 1;
/** App 打开的代抓标签带这个片段（短链跳转后仍保留）。 */
export const RELAY_MARKER = "jizuo-relay";
/** 一次最多带几个地址：当前地址 + 这一页导航过程中见过的地址（短链会跳转）。 */
export const RELAY_MAX_CANDIDATE_URLS = 4;
/** 只关「刚打开不久」的标签，避免误关用户自己正在看的页面。 */
export const RELAY_TAB_MAX_AGE_MS = 180_000;
/** App 长时间联系不上时，别让代抓标签永久留在浏览器里。 */
export const RELAY_TAB_ABANDON_MS = 600_000;
/** 定时清扫：页面一直加载不完、或 job 已作废时，把代抓标签收掉。 */
export const RELAY_SWEEP_ALARM = "linkdigest-relay-sweep";
export const RELAY_SWEEP_PERIOD_MINUTES = 1;

export type RelayNativeSender = (message: object) => Promise<unknown>;

/** 地址里有没有代抓标记（片段按 `&` 分段，标记必须是独立一段）。 */
export function hasRelayMarker(url: string | undefined): boolean {
  if (!url) return false;
  const hash = url.split("#", 2)[1];
  if (!hash) return false;
  return hash.split("&").some((part) => part === RELAY_MARKER);
}

/** 去掉代抓标记，其余片段原样保留；没有片段了就连 `#` 一起去掉。 */
export function stripRelayMarker(url: string): string {
  const [base, hash] = url.split("#", 2);
  if (!hash) return base ?? url;
  const rest = hash.split("&").filter((part) => part !== RELAY_MARKER);
  return rest.length > 0 ? `${base}#${rest.join("&")}` : (base ?? url);
}

/** App 打开代抓标签时用的地址：已有片段就接在后面，不覆盖页面自己的锚点。 */
export function appendRelayMarker(url: string): string {
  const [base, hash] = url.split("#", 2);
  if (!hash) return `${base}#${RELAY_MARKER}`;
  if (hasRelayMarker(url)) return url;
  return `${base}#${hash}&${RELAY_MARKER}`;
}

/**
 * 记下这个标签导航过的地址（最新的在前）。
 *
 * 短链（v.douyin.com、xhslink.com）打开后立刻跳转，标签最终地址和 App 登记的
 * 原始链接已经不是同一个字符串；只在「加载完成」那一帧看地址会永远对不上。
 */
export function rememberNavigationURL(
  navigated: Map<number, string[]>,
  tabId: number,
  url: string | undefined,
): void {
  if (!url) return;
  const cleaned = stripRelayMarker(url);
  const previous = navigated.get(tabId) ?? [];
  const next = [cleaned, ...previous.filter((value) => value !== cleaned)].slice(0, RELAY_MAX_CANDIDATE_URLS);
  navigated.set(tabId, next);
}

export function relayCandidateURLs(
  navigated: Map<number, string[]>,
  tabId: number,
  currentURL: string | undefined,
): string[] {
  const seen = navigated.get(tabId) ?? [];
  const values = [currentURL, ...seen]
    .filter((value): value is string => typeof value === "string" && /^https?:\/\//iu.test(value))
    .map(stripRelayMarker);
  return [...new Set(values)].slice(0, RELAY_MAX_CANDIDATE_URLS);
}

/** 查任务的结果：拿到 job、明确没有、或者 App/Host 暂时联系不上。 */
export type RelayQueryResult =
  | { state: "job"; jobID: string }
  | { state: "none" }
  | { state: "unreachable" };

/** 解析 Host 的回包。只有明确的「没有任务」才能据以关标签，出错不能当没有。 */
export function parseRelayJobResponse(value: unknown, expectedRequestId: string): RelayQueryResult {
  if (!value || typeof value !== "object") return { state: "unreachable" };
  const row = value as {
    kind?: unknown;
    version?: unknown;
    requestId?: unknown;
    jobID?: unknown;
    error?: unknown;
  };
  if (row.kind === "error") return { state: "unreachable" };
  if (row.kind !== RELAY_JOB_KIND || row.version !== RELAY_JOB_VERSION) return { state: "unreachable" };
  if (row.requestId !== expectedRequestId) return { state: "unreachable" };
  if (typeof row.jobID !== "string" || row.jobID.length === 0 || row.jobID.length > 64) {
    return { state: "none" };
  }
  return { state: "job", jobID: row.jobID };
}

export type RelayCommentMode = { kind: "disabled" } | { kind: "auto"; limit: number };

/**
 * 代抓时评论按「保存时自动存」同一份设置处理：平台设为不抓就禁用；开了自动保存就现读前 N 条；
 * 没开就只存正文（和用户点保存但不勾选评论一致）。
 */
export function relayCommentMode(platformLimit: number | undefined, autoSaveComments: boolean): RelayCommentMode | undefined {
  if (platformLimit === undefined) return undefined;
  if (platformLimit <= 0) return { kind: "disabled" };
  if (autoSaveComments) return { kind: "auto", limit: platformLimit };
  return undefined;
}

/** 代抓标签已经等得太久（App 一直没应答）——超过这个时间就收掉，别永久占着标签页。 */
export function relayTabIsAbandoned(
  createdAt: number | undefined,
  now: number,
  abandonMs: number = RELAY_TAB_ABANDON_MS,
): boolean {
  return createdAt !== undefined && now - createdAt > abandonMs;
}

/** 只关「我们自己刚打开的那个标签」：创建时间在时限内，且知道它是新开的。 */
export function mayCloseRelayTab(
  createdAt: number | undefined,
  now: number,
  maxAgeMs: number = RELAY_TAB_MAX_AGE_MS,
): boolean {
  if (createdAt === undefined) return false;
  return now - createdAt <= maxAgeMs;
}

/** 平台落地页说明「这页打不开」时，App 据此立刻给出真实错误。 */
export type RelayBlockReason =
  | "note_unavailable"
  | "login_required"
  | "verification_required"
  | "not_found"
  | "unknown";

export type RelayLanding = { blocked: boolean; reason: RelayBlockReason };

/**
 * 判断代抓标签落地后是不是平台自己的错误页/登录页。
 *
 * 只看地址（+标题里很确定的几种）——不读正文，避免把正常文章误判。小红书无访问码
 * 的笔记会落到 `/404?source=…&error_code=…`，抖音会落到验证页；这两类如果不认，
 * 就只能在 90 秒后报「扩展没连上」，既不准也耽误自动化。
 */
export function classifyRelayLanding(url: string, title?: string | null): RelayLanding {
  let parsed: URL;
  try {
    parsed = new URL(stripRelayMarker(url));
  } catch {
    return { blocked: false, reason: "unknown" };
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname.toLowerCase();
  const search = parsed.search.toLowerCase();
  const pageTitle = (title ?? "").toLowerCase();
  const on = (domain: string): boolean => host === domain || host.endsWith(`.${domain}`);

  if (on("xiaohongshu.com") || on("xhslink.com") || on("xhslink.cn")) {
    if (path.startsWith("/404") || search.includes("error_code") || pageTitle.includes("404") || pageTitle.includes("不见了")) {
      return { blocked: true, reason: "note_unavailable" };
    }
    if (path.includes("website-login") || path.includes("/login")) {
      return { blocked: true, reason: "login_required" };
    }
  }
  if (on("douyin.com") || on("iesdouyin.com")) {
    if (path.includes("verify") || path.includes("captcha") || pageTitle.includes("验证")) {
      return { blocked: true, reason: "verification_required" };
    }
    if (path.includes("login")) return { blocked: true, reason: "login_required" };
  }
  if (path === "/404" || path.startsWith("/404/") || path === "/not-found" || pageTitle.includes("404")) {
    return { blocked: true, reason: "not_found" };
  }
  if (path.includes("/login") || path.includes("/signin") || path.includes("/website-login")) {
    return { blocked: true, reason: "login_required" };
  }
  if (search.includes("error_code=")) return { blocked: true, reason: "not_found" };
  return { blocked: false, reason: "unknown" };
}

/** 向 Host/App 问一次：这些地址里有待代抓任务吗。 */
export async function queryRelayJob(
  urls: readonly string[],
  tabID: number,
  relayTab: boolean,
  send: RelayNativeSender,
  newRequestId: () => string,
): Promise<RelayQueryResult> {
  if (urls.length === 0) return { state: "none" };
  const requestId = newRequestId();
  const message = {
    kind: RELAY_JOB_KIND,
    version: RELAY_JOB_VERSION,
    requestId,
    tabID,
    // 带标记的标签：地址对不上时，App 可以在「只有一单在等」的情况下交给它。
    ...(relayTab ? { relayTab: true } : {}),
    urls: [...urls].slice(0, RELAY_MAX_CANDIDATE_URLS),
  };
  try {
    return parseRelayJobResponse(await send(message), requestId);
  } catch {
    return { state: "unreachable" };
  }
}

export type RelayTabState = {
  navigated: Map<number, string[]>;
  createdAt: Map<number, number>;
  inFlight: Set<number>;
  /** 见过代抓标记的标签：alarm 清扫时要找它们。 */
  markerTabs: Set<number>;
};

export function createRelayTabState(): RelayTabState {
  return { navigated: new Map(), createdAt: new Map(), inFlight: new Set(), markerTabs: new Set() };
}

export function forgetRelayTab(state: RelayTabState, tabId: number): void {
  state.createdAt.delete(tabId);
  state.navigated.delete(tabId);
  state.inFlight.delete(tabId);
  state.markerTabs.delete(tabId);
}

export type RelayTabDeps = {
  /** 问 App 这个地址有没有待代抓任务。 */
  query: (urls: string[], tabID: number) => Promise<RelayQueryResult>;
  /** 这个平台的评论按保存设置怎么处理。 */
  commentMode: (tabURL: string) => Promise<RelayCommentMode | undefined>;
  /** 用现有抓取链路抓这个标签，并按 job id 送回。 */
  capture: (
    tabId: number,
    mode: RelayCommentMode | undefined,
    jobID: string,
  ) => Promise<{ accepted: boolean; code?: string }>;
  closeTab: (tabId: number) => Promise<void>;
  /** 落地页是平台错误页/登录页：带 job 回报，让 App 立刻按真实原因失败。 */
  reportBlocked: (
    tabId: number,
    jobID: string,
    finalURL: string,
    reason: RelayBlockReason,
  ) => Promise<void>;
  /** 扩展有没有这个站点的访问权限（没有就无从注入，直接说明失败）。 */
  hasHostPermission: (url: string) => Promise<boolean>;
  now: () => number;
  /** 有代抓标签时保证清扫 alarm 存在；没有了就清掉。 */
  setSweepAlarm: (enabled: boolean) => void;
};

/**
 * 标签有更新时调用。只有带代抓标记的标签才会触发 native message：
 *
 * - 加载完成 + 有 job：抓、送回、关掉自己刚开的标签；
 * - 加载完成 + 明确没有 job（过期/失败/作废）：关掉自己刚开的标签；
 * - 联系不上 App：不动，等 alarm 再试，绝不误判成「没有任务」。
 */
export async function handleRelayTabEvent(
  state: RelayTabState,
  tabId: number,
  tabURL: string | undefined,
  tabTitle: string | undefined,
  status: string | undefined,
  deps: RelayTabDeps,
): Promise<void> {
  if (!tabURL || !/^https?:\/\//iu.test(tabURL)) return;
  rememberNavigationURL(state.navigated, tabId, tabURL);
  if (!hasRelayMarker(tabURL) && !state.markerTabs.has(tabId)) return;

  state.markerTabs.add(tabId);
  deps.setSweepAlarm(true);
  if (status !== "complete") return;
  if (state.inFlight.has(tabId)) return;
  state.inFlight.add(tabId);
  try {
    const result = await deps.query(relayCandidateURLs(state.navigated, tabId, tabURL), tabId);
    switch (result.state) {
      case "none":
        await closeRelayTabIfOwned(state, tabId, deps);
        return;
      case "unreachable":
        return;
      case "job":
        break;
    }
    const landing = classifyRelayLanding(tabURL, tabTitle);
    if (landing.blocked) {
      // 平台自己说这页打不开：带着 job 回报，App 立即失败；标签收掉，不留尾巴。
      await deps.reportBlocked(tabId, result.jobID, stripRelayMarker(tabURL), landing.reason);
      await closeRelayTabIfOwned(state, tabId, deps);
      return;
    }
    if (!(await deps.hasHostPermission(stripRelayMarker(tabURL)))) {
      // 站点访问权限被收回：再抓也只会失败，收掉标签让 App 按超时/权限问题失败。
      await closeRelayTabIfOwned(state, tabId, deps);
      return;
    }
    const mode = await deps.commentMode(stripRelayMarker(tabURL));
    const captured = await deps.capture(tabId, mode, result.jobID);
    if (captured.accepted || captured.code === "CAPTURE_JOB_EXPIRED") {
      await closeRelayTabIfOwned(state, tabId, deps);
    }
  } catch {
    // 代抓是尽力而为：Host 没装、页面打不开，都不该影响用户自己的浏览。
  } finally {
    state.inFlight.delete(tabId);
  }
}

/**
 * alarm 清扫：页面一直加载不完、或者 job 早就作废时，把代抓标签收掉。
 * 只处理带标记的标签，别的一律不碰。
 */
export async function sweepRelayTabs(
  state: RelayTabState,
  listTabs: () => Promise<Array<{ id?: number | undefined; url?: string | undefined }>>,
  deps: Pick<RelayTabDeps, "query" | "closeTab" | "now">,
): Promise<{ closed: number; remaining: number }> {
  const tabs = await listTabs();
  let remaining = 0;
  let closed = 0;
  for (const tab of tabs) {
    if (typeof tab.id !== "number" || !hasRelayMarker(tab.url)) continue;
    const tabId = tab.id;
    state.markerTabs.add(tabId);
    const result = await deps.query(relayCandidateURLs(state.navigated, tabId, tab.url), tabId);
    if (result.state === "unreachable") {
      // App 退出/失联：先留着等它回来；超过 10 分钟就当作这单没人管了，收掉标签。
      if (relayTabIsAbandoned(state.createdAt.get(tabId), deps.now(), RELAY_TAB_ABANDON_MS)) {
        await deps.closeTab(tabId);
        forgetRelayTab(state, tabId);
        closed += 1;
      } else {
        remaining += 1;
      }
      continue;
    }
    if (result.state === "none" && mayCloseRelayTab(state.createdAt.get(tabId), deps.now())) {
      await deps.closeTab(tabId);
      forgetRelayTab(state, tabId);
      closed += 1;
    } else {
      remaining += 1;
    }
  }
  return { closed, remaining };
}

async function closeRelayTabIfOwned(state: RelayTabState, tabId: number, deps: RelayTabDeps): Promise<void> {
  if (!mayCloseRelayTab(state.createdAt.get(tabId), deps.now())) {
    forgetRelayTab(state, tabId);
    return;
  }
  await deps.closeTab(tabId);
  forgetRelayTab(state, tabId);
}
