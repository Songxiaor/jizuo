import type { SafeExtensionSendResult } from "./popup-presentation";

/**
 * 弹窗连不上汲作时怎么办（2026-10-01）。
 *
 * 原来一失败就甩一句「请完全退出后重新打开汲作，再重试」，把排查推给用户。现在分三步：
 * 1. 失败得很快（通道一时没接上）就自动再试两次，间隔 1s、2s，期间显示「正在连接汲作…」；
 * 2. 还不行，给「打开汲作并重试」按钮：走 Host 的 openApp 把汲作拉到前台，再试一次；
 * 3. 仍失败才给一句简短说明。
 *
 * 不自动重试的情况：
 * - 版本不兼容、未安装浏览器支持组件：再试也一样，重试只会让人干等；
 * - 单条保存超时（NATIVE_MESSAGE_TIMEOUT）：汲作可能已经收下，自动重发会存出两份；
 * - 单次失败本身就耗了很久：Host 已经自己冷启动并等过 25s，再自动等两轮就是一分多钟。
 */

export type ConnectionVerdict = "done" | "retry";

export const CONNECTION_RETRY_DELAYS_MS: readonly number[] = [1_000, 2_000];
/** 一次失败超过这个时长就不再自动重试，直接给「打开汲作并重试」。 */
export const CONNECTION_FAST_FAILURE_MS = 5_000;
/** 打开汲作后等它起来再试的间隔。 */
export const OPEN_APP_SETTLE_MS = 1_500;

export const connectionCopy = {
  connecting: "正在连接汲作…",
  opening: "正在打开汲作…",
  openRetryLabel: "打开汲作并重试",
  needsApp: "暂时连不上汲作。点「打开汲作并重试」，会自动再试一次。",
  gaveUp: "还是连不上汲作。请确认汲作能正常打开；如果已经开着，退出后重新打开再试。",
  upgrade: "扩展与汲作版本不兼容。请打开汲作检查更新。",
} as const;

export type RetryOptions = {
  delays?: readonly number[];
  fastFailureMs?: number;
  wait?: (milliseconds: number) => Promise<void>;
  now?: () => number;
  /** 第 n 次自动重试开始前调用（n 从 1 起），弹窗借此显示「正在连接汲作…」。 */
  onRetry?: (retry: number) => void;
};

const defaultWait = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => { setTimeout(resolve, milliseconds); });

/** 跑一次；判定为「连接类、可重试」且失败得够快时按间隔再试。返回最后一次的结果。 */
export async function withConnectionRetry<T>(
  attempt: () => Promise<T>,
  verdict: (result: T) => ConnectionVerdict,
  options: RetryOptions = {},
): Promise<T> {
  const delays = options.delays ?? CONNECTION_RETRY_DELAYS_MS;
  const fastFailureMs = options.fastFailureMs ?? CONNECTION_FAST_FAILURE_MS;
  const wait = options.wait ?? defaultWait;
  const now = options.now ?? Date.now;
  let started = now();
  let result = await attempt();
  for (const [index, delay] of delays.entries()) {
    if (verdict(result) !== "retry" || now() - started > fastFailureMs) break;
    options.onRetry?.(index + 1);
    await wait(delay);
    started = now();
    result = await attempt();
  }
  return result;
}

/** 单条保存：只有确定没送到汲作的连接失败才自动重试。 */
const AUTO_RETRY_SEND_CODES: ReadonlySet<string> = new Set(["APP_UNAVAILABLE", "NATIVE_MESSAGE_FAILED"]);
/** 单条保存：值得给「打开汲作并重试」的失败（含超时：汲作可能卡住或没开）。 */
const CONNECTION_SEND_CODES: ReadonlySet<string> = new Set([...AUTO_RETRY_SEND_CODES, "NATIVE_MESSAGE_TIMEOUT"]);

export function sendRetryVerdict(result: SafeExtensionSendResult): ConnectionVerdict {
  return result.response.kind === "error" && AUTO_RETRY_SEND_CODES.has(result.response.error.code) ? "retry" : "done";
}

export function isSendConnectionFailure(result: SafeExtensionSendResult): boolean {
  return result.response.kind === "error" && CONNECTION_SEND_CODES.has(result.response.error.code);
}

type CodeResult = { ok: boolean; code?: string; transient?: boolean } | undefined;

/** 收藏夹 / 主页作品这类 `{ ok, code }` 结果：native_error 都算连接失败，值得给「打开汲作并重试」。 */
export function isNativeCodeConnectionFailure(result: CodeResult): boolean {
  return result !== undefined && !result.ok && result.code === "native_error";
}

/**
 * 只有 background 标了 transient（浏览器那层很快断开）才自动重试；
 * 超时、Host 冷启动后仍连不上、upgrade_app 都不自动再试。
 */
export function nativeCodeRetryVerdict(result: CodeResult): ConnectionVerdict {
  return isNativeCodeConnectionFailure(result) && result?.transient === true ? "retry" : "done";
}

export type OpenAppResult = { ok: true } | { ok: false; code: "native_error" | "upgrade_app" };

export type OpenAndRetryOutcome<T> =
  | { kind: "retried"; result: T }
  | { kind: "upgrade" }
  | { kind: "open_failed" };

/** 「打开汲作并重试」：先让 Host 把汲作拉起来，稍等再试一次；打不开就不再试。 */
export async function openAppThenRetry<T>(
  openApp: () => Promise<OpenAppResult | undefined>,
  attempt: () => Promise<T>,
  options: { settleMs?: number; wait?: (milliseconds: number) => Promise<void> } = {},
): Promise<OpenAndRetryOutcome<T>> {
  let opened: OpenAppResult | undefined;
  try {
    opened = await openApp();
  } catch {
    opened = undefined;
  }
  if (!opened) return { kind: "open_failed" };
  if (!opened.ok) return { kind: opened.code === "upgrade_app" ? "upgrade" : "open_failed" };
  await (options.wait ?? defaultWait)(options.settleMs ?? OPEN_APP_SETTLE_MS);
  return { kind: "retried", result: await attempt() };
}
