import { describe, expect, it } from "vitest";
import { syncResultTip } from "../src/entrypoints/x-timeline";

describe("syncResultTip", () => {
  it("排队成功与已在库分开报，不把「没排队」说成失败", () => {
    expect(syncResultTip({ ok: true, outcome: { queued: 1, skipped: 0 } }, true)).toEqual({
      state: "done",
      text: "已发送到 App",
    });
    expect(syncResultTip({ ok: true, outcome: { queued: 0, skipped: 1 } }, true)).toEqual({
      state: "done",
      text: "已在库",
    });
  });

  // 这是这个文件存在的理由：两种「没拿到响应」的解法相反，合并成一句会把人
  // 困在「一直重点但永远不会成功」上。
  it("service worker 未就绪才提示重点一次", () => {
    expect(syncResultTip(undefined, true)).toEqual({
      state: "error",
      text: "扩展未响应，请重点一次",
    });
  });

  it("扩展上下文失效时必须改口让人刷新页面", () => {
    const tip = syncResultTip(undefined, false);
    expect(tip.state).toBe("error");
    expect(tip.text).toBe("扩展已更新，请刷新页面");
    expect(tip.text).not.toContain("重点");
  });

  it("null 与 undefined 走同一条判定", () => {
    expect(syncResultTip(null, false).text).toBe("扩展已更新，请刷新页面");
    expect(syncResultTip(null, true).text).toBe("扩展未响应，请重点一次");
  });

  // 拿到了结构化失败就说具体原因，不能被上下文状态盖掉——App 没连上时刷新页面
  // 没有任何用。
  it("结构化失败码不受上下文状态影响", () => {
    for (const alive of [true, false]) {
      expect(syncResultTip({ ok: false, code: "native_error" }, alive).text).toBe("App 未连接");
      expect(syncResultTip({ ok: false, code: "invalid_id" }, alive).text).toBe("读不到帖子ID");
      expect(syncResultTip({ ok: false, code: "rate_limited" }, alive).text).toBe("失败：rate_limited");
    }
  });
});
