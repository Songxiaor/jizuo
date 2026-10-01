import { afterEach, describe, expect, it, vi } from "vitest";
import { makeAppError, type NativeResponse } from "../src/contract";
import {
  connectionCopy,
  isNativeCodeConnectionFailure,
  nativeCodeRetryVerdict,
  openAppThenRetry,
  sendRetryVerdict,
  withConnectionRetry,
} from "../src/popup-connection";
import type { SafeExtensionSendResult } from "../src/popup-presentation";

const accepted: SafeExtensionSendResult = {
  response: { kind: "taskAccepted", version: 1, requestId: "req", characterCount: 3 } as NativeResponse,
};
const failure = (code: string, action: Parameters<typeof makeAppError>[4] = "retry"): SafeExtensionSendResult => ({
  response: { kind: "error", error: makeAppError("req", "network", code, true, action) },
});

/** 假的连接函数：按次序吐结果，记下被调了几次。 */
function fakeConnection<T>(...results: T[]) {
  let calls = 0;
  const attempt = vi.fn(async () => results[Math.min(calls++, results.length - 1)]!);
  return attempt;
}

const instant = { wait: async () => {}, now: () => 0 };

describe("withConnectionRetry · 单条保存", () => {
  it("连接很快失败就按 1s、2s 自动再试，成功即停", async () => {
    const attempt = fakeConnection(failure("NATIVE_MESSAGE_FAILED"), accepted);
    const waits: number[] = [];
    const onRetry = vi.fn();
    const result = await withConnectionRetry(attempt, sendRetryVerdict, {
      now: () => 0,
      wait: async (ms) => { waits.push(ms); },
      onRetry,
    });
    expect(result).toBe(accepted);
    expect(attempt).toHaveBeenCalledTimes(2);
    expect(waits).toEqual([1_000]);
    expect(onRetry).toHaveBeenCalledWith(1);
  });

  it("一直连不上：共试 3 次后交回最后一次失败", async () => {
    const attempt = fakeConnection(failure("APP_UNAVAILABLE", "open_app"));
    const waits: number[] = [];
    const result = await withConnectionRetry(attempt, sendRetryVerdict, {
      now: () => 0,
      wait: async (ms) => { waits.push(ms); },
    });
    expect(attempt).toHaveBeenCalledTimes(3);
    expect(waits).toEqual([1_000, 2_000]);
    expect(result.response.kind).toBe("error");
  });

  it("版本不兼容、未装浏览器支持、超时都不自动重试", async () => {
    for (const result of [
      failure("PROTOCOL_VERSION_UNSUPPORTED", "upgrade_app"),
      failure("NATIVE_HOST_NOT_FOUND", "open_install_guide"),
      // 超时时汲作可能已经收下，自动重发会存出两份。
      failure("NATIVE_MESSAGE_TIMEOUT"),
    ]) {
      const attempt = fakeConnection(result);
      await withConnectionRetry(attempt, sendRetryVerdict, instant);
      expect(attempt).toHaveBeenCalledTimes(1);
    }
  });

  it("单次失败耗时太久（Host 已冷启动等满）就不再自动等", async () => {
    const attempt = fakeConnection(failure("APP_UNAVAILABLE", "open_app"));
    let clock = 0;
    await withConnectionRetry(async () => { clock += 25_000; return attempt(); }, sendRetryVerdict, {
      now: () => clock,
      wait: async () => {},
    });
    expect(attempt).toHaveBeenCalledTimes(1);
  });
});

describe("收藏页 / 主页的 { ok, code } 结果", () => {
  it("只有 background 标了 transient 的 native_error 才自动重试", async () => {
    const transient = fakeConnection(
      { ok: false as const, code: "native_error", transient: true as const },
      { ok: true as const },
    );
    await expect(withConnectionRetry(transient, nativeCodeRetryVerdict, instant)).resolves.toEqual({ ok: true });
    expect(transient).toHaveBeenCalledTimes(2);

    const slow = fakeConnection({ ok: false as const, code: "native_error" });
    await withConnectionRetry(slow, nativeCodeRetryVerdict, instant);
    expect(slow).toHaveBeenCalledTimes(1);

    const upgrade = fakeConnection({ ok: false as const, code: "upgrade_app" });
    await withConnectionRetry(upgrade, nativeCodeRetryVerdict, instant);
    expect(upgrade).toHaveBeenCalledTimes(1);
  });

  it("native_error 不论快慢都给「打开汲作并重试」，upgrade_app 不给", () => {
    expect(isNativeCodeConnectionFailure({ ok: false, code: "native_error" })).toBe(true);
    expect(isNativeCodeConnectionFailure({ ok: false, code: "upgrade_app" })).toBe(false);
    expect(isNativeCodeConnectionFailure({ ok: true })).toBe(false);
  });
});

describe("openAppThenRetry · 打开汲作并重试", () => {
  it("打开成功后稍等，再试一次", async () => {
    const attempt = fakeConnection(accepted);
    const waits: number[] = [];
    const outcome = await openAppThenRetry(async () => ({ ok: true }), attempt, { wait: async (ms) => { waits.push(ms); } });
    expect(outcome).toEqual({ kind: "retried", result: accepted });
    expect(attempt).toHaveBeenCalledTimes(1);
    expect(waits).toEqual([1_500]);
  });

  it("版本不兼容或打不开汲作时不再重试", async () => {
    const attempt = fakeConnection(accepted);
    await expect(openAppThenRetry(async () => ({ ok: false, code: "upgrade_app" }), attempt, instant))
      .resolves.toEqual({ kind: "upgrade" });
    await expect(openAppThenRetry(async () => ({ ok: false, code: "native_error" }), attempt, instant))
      .resolves.toEqual({ kind: "open_failed" });
    await expect(openAppThenRetry(async () => { throw new Error("boom"); }, attempt, instant))
      .resolves.toEqual({ kind: "open_failed" });
    await expect(openAppThenRetry(async () => undefined, attempt, instant))
      .resolves.toEqual({ kind: "open_failed" });
    expect(attempt).not.toHaveBeenCalled();
  });

  it("最后的说明是简短一句，不先叫用户排查", () => {
    expect(connectionCopy.needsApp).not.toContain("完全退出");
    expect(connectionCopy.gaveUp.length).toBeLessThan(50);
  });
});

describe("background 标记很快断开的连接失败", () => {
  afterEach(() => vi.unstubAllGlobals());

  async function loadBackground(sendNativeMessage: ReturnType<typeof vi.fn>) {
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.stubGlobal("browser", { runtime: { sendNativeMessage } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.resetModules();
    return import("../src/entrypoints/background");
  }

  it("通道断开 → transient；超时 → 不标", async () => {
    const id = "1234567890123456789";
    const dropped = await loadBackground(vi.fn().mockRejectedValue(new Error("Error when communicating with the native messaging host.")));
    await expect(dropped.enqueueXBookmarkIDs([id])).resolves.toEqual({ ok: false, code: "native_error", transient: true });

    const timedOut = await loadBackground(vi.fn().mockRejectedValue(new Error("NATIVE_MESSAGE_TIMEOUT")));
    await expect(timedOut.enqueueXBookmarkIDs([id])).resolves.toEqual({ ok: false, code: "native_error" });
  });
});
