import { describe, expect, it, vi } from "vitest";

import {
  appendRelayMarker,
  classifyRelayLanding,
  createRelayTabState,
  handleRelayTabEvent,
  hasRelayMarker,
  mayCloseRelayTab,
  parseRelayJobResponse,
  queryRelayJob,
  relayCandidateURLs,
  relayCommentMode,
  RELAY_TAB_ABANDON_MS,
  RELAY_TAB_MAX_AGE_MS,
  stripRelayMarker,
  sweepRelayTabs,
  type RelayTabDeps,
} from "../src/relay";

type TestDeps = RelayTabDeps & {
  query: ReturnType<typeof vi.fn>;
  capture: ReturnType<typeof vi.fn>;
  closeTab: ReturnType<typeof vi.fn>;
  reportBlocked: ReturnType<typeof vi.fn>;
  setSweepAlarm: ReturnType<typeof vi.fn>;
};

function deps(overrides: Partial<RelayTabDeps> = {}): TestDeps {
  return {
    query: vi.fn().mockResolvedValue({ state: "none" }),
    commentMode: vi.fn().mockResolvedValue(undefined),
    capture: vi.fn().mockResolvedValue({ accepted: true }),
    closeTab: vi.fn().mockResolvedValue(undefined),
    hasHostPermission: vi.fn().mockResolvedValue(true),
    reportBlocked: vi.fn().mockResolvedValue(undefined),
    now: () => 1_000_000,
    setSweepAlarm: vi.fn(),
    ...overrides,
  } as TestDeps;
}

describe("browser capture relay", () => {
  it("marks and strips its own fragment without touching the page anchor", () => {
    expect(appendRelayMarker("https://v.douyin.com/abc")).toBe("https://v.douyin.com/abc#jizuo-relay");
    expect(appendRelayMarker("https://example.test/a#top")).toBe("https://example.test/a#top&jizuo-relay");
    expect(hasRelayMarker("https://example.test/a#top&jizuo-relay")).toBe(true);
    expect(hasRelayMarker("https://example.test/a#top")).toBe(false);
    expect(hasRelayMarker("https://example.test/a")).toBe(false);
    expect(stripRelayMarker("https://example.test/a#top&jizuo-relay")).toBe("https://example.test/a#top");
    expect(stripRelayMarker("https://example.test/a#jizuo-relay")).toBe("https://example.test/a");
    expect(stripRelayMarker("https://example.test/a")).toBe("https://example.test/a");
  });

  it("never asks the host for a page the user opened themselves", async () => {
    const d = deps();
    const state = createRelayTabState();
    await handleRelayTabEvent(state, 7, "https://www.douyin.com/video/1", undefined, "complete", d);
    expect(d.query).not.toHaveBeenCalled();
    expect(d.capture).not.toHaveBeenCalled();
    expect(d.closeTab).not.toHaveBeenCalled();
    expect(state.markerTabs.size).toBe(0);
  });

  it("queries, captures and closes the tab it opened", async () => {
    const d = deps({ query: vi.fn().mockResolvedValue({ state: "job", jobID: "job-1" }) });
    const state = createRelayTabState();
    state.createdAt.set(7, d.now() - 5_000);
    await handleRelayTabEvent(state, 7, "https://www.douyin.com/video/1#jizuo-relay", undefined, "complete", d);
    expect(d.query).toHaveBeenCalledWith(["https://www.douyin.com/video/1"], 7);
    expect(d.capture).toHaveBeenCalledWith(7, undefined, "job-1");
    expect(d.closeTab).toHaveBeenCalledWith(7);
    expect(state.markerTabs.has(7)).toBe(false);
  });

  it("closes its own tab once the job is gone, but never a long-lived tab", async () => {
    const fresh = deps();
    const state = createRelayTabState();
    state.createdAt.set(7, fresh.now() - 2_000);
    await handleRelayTabEvent(state, 7, "https://example.test/x#jizuo-relay", undefined, "complete", fresh);
    expect(fresh.closeTab).toHaveBeenCalledWith(7);

    const stale = deps();
    const staleState = createRelayTabState();
    staleState.createdAt.set(8, stale.now() - RELAY_TAB_MAX_AGE_MS - 1);
    await handleRelayTabEvent(staleState, 8, "https://example.test/x#jizuo-relay", undefined, "complete", stale);
    expect(stale.closeTab).not.toHaveBeenCalled();
  });

  it("keeps the tab when the app cannot be reached, so a transient outage cannot lose the job", async () => {
    const d = deps({ query: vi.fn().mockResolvedValue({ state: "unreachable" }) });
    const state = createRelayTabState();
    state.createdAt.set(7, d.now());
    await handleRelayTabEvent(state, 7, "https://example.test/x#jizuo-relay", undefined, "complete", d);
    expect(d.capture).not.toHaveBeenCalled();
    expect(d.closeTab).not.toHaveBeenCalled();
    expect(d.setSweepAlarm).toHaveBeenCalledWith(true);
  });

  it("closes instead of capturing when the site permission was revoked", async () => {
    const d = deps({
      query: vi.fn().mockResolvedValue({ state: "job", jobID: "job-1" }),
      hasHostPermission: vi.fn().mockResolvedValue(false),
    });
    const state = createRelayTabState();
    state.createdAt.set(7, d.now());
    await handleRelayTabEvent(state, 7, "https://www.douyin.com/video/1#jizuo-relay", undefined, "complete", d);
    expect(d.capture).not.toHaveBeenCalled();
    expect(d.closeTab).toHaveBeenCalledWith(7);
  });

  it("closes when the app reports the capture job already expired", async () => {
    const d = deps({
      query: vi.fn().mockResolvedValue({ state: "job", jobID: "job-1" }),
      capture: vi.fn().mockResolvedValue({ accepted: false, code: "CAPTURE_JOB_EXPIRED" }),
    });
    const state = createRelayTabState();
    state.createdAt.set(7, d.now());
    await handleRelayTabEvent(state, 7, "https://example.test/x#jizuo-relay", undefined, "complete", d);
    expect(d.closeTab).toHaveBeenCalledWith(7);
  });

  it("keeps the page anchor while carrying the relay marker through redirects", () => {
    const navigated = new Map<number, string[]>();
    const marked = appendRelayMarker("https://v.douyin.com/abc");
    navigated.set(7, [stripRelayMarker(marked), "https://www.douyin.com/video/1"]);
    expect(relayCandidateURLs(navigated, 7, "https://www.douyin.com/video/1#jizuo-relay")).toEqual([
      "https://www.douyin.com/video/1",
      "https://v.douyin.com/abc",
    ]);
  });

  it("sweeps relay tabs and drops the ones whose job is gone", async () => {
    const d = deps();
    const state = createRelayTabState();
    state.createdAt.set(7, d.now() - 1_000);
    state.createdAt.set(8, d.now() - 1_000);
    d.query = vi.fn(async (_urls: string[], tabID: number) =>
      tabID === 7 ? { state: "none" as const } : { state: "unreachable" as const });
    const outcome = await sweepRelayTabs(
      state,
      async () => [
        { id: 7, url: "https://example.test/a#jizuo-relay" },
        { id: 8, url: "https://example.test/b#jizuo-relay" },
        { id: 9, url: "https://example.test/c" },
      ],
      { query: d.query, closeTab: d.closeTab, now: d.now },
    );
    expect(d.closeTab).toHaveBeenCalledTimes(1);
    expect(d.closeTab).toHaveBeenCalledWith(7);
    expect(outcome).toEqual({ closed: 1, remaining: 1 });
  });

  it("closes even a relay tab the app stopped answering for, but only after the abandon window", async () => {
    const fresh = deps();
    fresh.query = vi.fn().mockResolvedValue({ state: "unreachable" as const });
    const freshState = createRelayTabState();
    freshState.createdAt.set(7, fresh.now() - 1_000);
    let outcome = await sweepRelayTabs(
      freshState,
      async () => [{ id: 7, url: "https://example.test/a#jizuo-relay" }],
      { query: fresh.query, closeTab: fresh.closeTab, now: fresh.now },
    );
    expect(fresh.closeTab).not.toHaveBeenCalled();
    expect(outcome.remaining).toBe(1);

    const abandoned = deps();
    abandoned.query = vi.fn().mockResolvedValue({ state: "unreachable" as const });
    const abandonedState = createRelayTabState();
    abandonedState.createdAt.set(7, abandoned.now() - RELAY_TAB_ABANDON_MS - 1);
    outcome = await sweepRelayTabs(
      abandonedState,
      async () => [{ id: 7, url: "https://example.test/a#jizuo-relay" }],
      { query: abandoned.query, closeTab: abandoned.closeTab, now: abandoned.now },
    );
    expect(abandoned.closeTab).toHaveBeenCalledWith(7);
    expect(outcome).toEqual({ closed: 1, remaining: 0 });
  });

  it("follows the save-comment settings when capturing in the background", () => {
    expect(relayCommentMode(undefined, true)).toBeUndefined();
    expect(relayCommentMode(0, true)).toEqual({ kind: "disabled" });
    expect(relayCommentMode(20, true)).toEqual({ kind: "auto", limit: 20 });
    expect(relayCommentMode(20, false)).toBeUndefined();
  });

  it("sends the job query with the asking tab so only one tab can claim it", async () => {
    const send = vi.fn().mockResolvedValue({
      kind: "browserCaptureJob",
      version: 1,
      requestId: "req-1",
      jobID: "job-9",
    });
    const result = await queryRelayJob(["https://example.test/a"], 42, true, send, () => "req-1");
    expect(result).toEqual({ state: "job", jobID: "job-9" });
    expect(send).toHaveBeenCalledWith({
      kind: "browserCaptureJob",
      version: 1,
      requestId: "req-1",
      tabID: 42,
      relayTab: true,
      urls: ["https://example.test/a"],
    });
  });

  it("distinguishes a missing job from an unreachable host", async () => {
    const none = vi.fn().mockResolvedValue({ kind: "browserCaptureJob", version: 1, requestId: "r", jobID: null });
    await expect(queryRelayJob(["https://example.test/a"], 1, true, none, () => "r")).resolves.toEqual({ state: "none" });

    const down = vi.fn().mockRejectedValue(new Error("boom"));
    await expect(queryRelayJob(["https://example.test/a"], 1, true, down, () => "r")).resolves.toEqual({ state: "unreachable" });

    const appDown = vi.fn().mockResolvedValue({
      kind: "error",
      error: { version: 1, requestId: "r", code: "APP_UNAVAILABLE" },
    });
    await expect(queryRelayJob(["https://example.test/a"], 1, true, appDown, () => "r")).resolves.toEqual({ state: "unreachable" });
  });

  it("parses a job answer only when the request id matches", () => {
    const response = { kind: "browserCaptureJob", version: 1, requestId: "r1", jobID: "job-1" };
    expect(parseRelayJobResponse(response, "r1")).toEqual({ state: "job", jobID: "job-1" });
    expect(parseRelayJobResponse(response, "r2")).toEqual({ state: "unreachable" });
    expect(parseRelayJobResponse({ ...response, jobID: 7 }, "r1")).toEqual({ state: "none" });
    expect(parseRelayJobResponse(null, "r1")).toEqual({ state: "unreachable" });
  });

  it("closes a tab only within its freshness window", () => {
    expect(mayCloseRelayTab(undefined, 100)).toBe(false);
    expect(mayCloseRelayTab(100, 90_000)).toBe(true);
    expect(mayCloseRelayTab(0, RELAY_TAB_MAX_AGE_MS + 1)).toBe(false);
  });
  it("classifies platform error and login pages without misreading real pages", () => {
    expect(classifyRelayLanding(
      "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031&error_msg=当前笔记暂时无法浏览#jizuo-relay",
    )).toEqual({ blocked: true, reason: "note_unavailable" });
    expect(classifyRelayLanding("https://www.xiaohongshu.com/website-login")).toEqual({
      blocked: true, reason: "login_required",
    });
    expect(classifyRelayLanding("https://www.douyin.com/verify/captcha")).toEqual({
      blocked: true, reason: "verification_required",
    });
    expect(classifyRelayLanding("https://example.test/404")).toEqual({ blocked: true, reason: "not_found" });
    expect(classifyRelayLanding("https://example.test/login")).toEqual({ blocked: true, reason: "login_required" });

    // 正常笔记/视频不能被当成错误页——否则代抓会把能存的内容丢掉。
    expect(classifyRelayLanding("https://www.xiaohongshu.com/explore/6af1824c000000003402b751")).toEqual({
      blocked: false, reason: "unknown",
    });
    expect(classifyRelayLanding("https://www.douyin.com/video/7420000000000000001")).toEqual({
      blocked: false, reason: "unknown",
    });
    expect(classifyRelayLanding("https://example.test/article")).toEqual({ blocked: false, reason: "unknown" });
  });

  it("reports a blocked landing page instead of waiting for the timeout", async () => {
    const d = deps({
      query: vi.fn().mockResolvedValue({ state: "job", jobID: "job-1" }),
    });
    const state = createRelayTabState();
    state.createdAt.set(7, d.now());
    await handleRelayTabEvent(
      state,
      7,
      "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031#jizuo-relay",
      "你访问的页面不见了",
      "complete",
      d,
    );
    expect(d.reportBlocked).toHaveBeenCalledWith(
      7,
      "job-1",
      "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031",
      "note_unavailable",
    );
    expect(d.capture).not.toHaveBeenCalled();
    expect(d.closeTab).toHaveBeenCalledWith(7);
  });

});
