import { afterEach, describe, expect, it, vi } from "vitest";

const id = "7655224917603994914";
const diagnosticSentinel = {
  pageURL: "diagnostic-url-sentinel",
  title: "diagnostic-title-sentinel",
  author: "diagnostic-author-sentinel",
  time: "diagnostic-time-sentinel",
  count: "diagnostic-count-sentinel",
  rawJSON: "diagnostic-rawJSON-sentinel",
  DOM: "diagnostic-DOM-sentinel",
  selector: "diagnostic-selector-sentinel",
  host: "diagnostic-host-sentinel",
  cookie: "diagnostic-cookie-sentinel",
  storage: "diagnostic-storage-sentinel",
  network: "diagnostic-network-sentinel",
};

function metadataDiagnostic() {
  return {
    route: { eligible: true, rejectCode: "none" as const, ...diagnosticSentinel },
    video: { positiveVisibleCount: 1, dominantVideoCount: 1, rejectCode: "none" as const, ...diagnosticSentinel },
    scopes: { safeCount: 1, dedicatedCount: 0, rejectCode: "none" as const, ...diagnosticSentinel },
    dom: { publishedSelectorHit: false, statSelectorHitMask: 0, statAcceptedCount: 0, ...diagnosticSentinel },
    rawJSON: diagnosticSentinel.rawJSON,
  };
}

function ssrDiagnostic() {
  return {
    fixedRootPresent: 1, fixedRootParseable: 1, exactHit: false,
    rejectCode: "no_exact_item" as const, limitCode: "none" as const,
    ...diagnosticSentinel,
  };
}

function containsDiagnosticKey(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some(containsDiagnosticKey);
  return Object.entries(value as Record<string, unknown>).some(([key, child]) =>
    key === "metadataDiagnostic" || key === "mediaDiagnostic" || containsDiagnosticKey(child));
}

function assertWireHasNoDiagnosticSentinel(wire: unknown): void {
  const encoded = JSON.stringify(wire);
  expect(containsDiagnosticKey(wire)).toBe(false);
  for (const sentinel of Object.values(diagnosticSentinel)) expect(encoded).not.toContain(sentinel);
}

afterEach(() => vi.unstubAllGlobals());

describe("native wire excludes popup-only metadata diagnostics", () => {
  it("uses actual sendNativeMessage second parameters for V1, V2, downgrade, strip, and a fresh retry", async () => {
    const cases = [
      { name: "v1", text: "V1 body" },
      { name: "v2", text: "V2 body", media: {
        kind: "directFile", platform: "douyin", pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`, ephemeralPlaybackURL: "https://media.example.test/direct.mp4",
        transcriptionCapability: "supported",
      } },
      { name: "downgrade", text: "Downgrade body", media: {
        kind: "directFile", platform: "douyin", pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`, ephemeralPlaybackURL: "https://media.example.test/invalid.mp4",
        transcriptionCapability: "supported", candidateCount: 1_001,
      } },
      { name: "strip", text: "Strip body", media: {
        kind: "directFile", platform: "douyin", pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`, ephemeralPlaybackURL: "https://media.example.test/strip.mp4",
        rawExtra: "p".repeat(3 * 1024 * 1024),
        transcriptionCapability: "supported",
      } },
      { name: "fresh-retry", text: "Fresh retry body" },
    ] as const;
    let captureIndex = 0;
    const executeScript = vi.fn(async (injection: { world?: string }) => {
      const current = cases[captureIndex]!;
      if (injection.world === "MAIN") {
        captureIndex += 1;
        return [{ result: { metadata: null, diagnostic: ssrDiagnostic() } }];
      }
      return [{ result: {
        awemeId: id, title: "ordinary page title", author: null, description: current.text,
        pageURL: `https://www.douyin.com/video/${id}`, metadataDiagnostic: metadataDiagnostic(),
        ...("media" in current ? { mediaDescriptor: current.media } : {}),
      } }];
    });
    const sent: unknown[] = [];
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ url: `https://www.douyin.com/video/${id}`, title: "ordinary page title" }) },
      scripting: { executeScript },
      runtime: { sendNativeMessage: vi.fn(async (_host: string, wire: { requestId: string; capture: { characterCount: number } }) => {
        sent.push(wire);
        return { kind: "taskAccepted", version: 1, requestId: wire.requestId, characterCount: wire.capture.characterCount };
      }) },
    });
    vi.stubGlobal("crypto", { randomUUID: vi.fn(() => `request-${captureIndex + 1}`) });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { sendCapture } = await import("../src/entrypoints/background");

    for (let index = 0; index < cases.length; index += 1) {
      const result = await sendCapture(1);
      expect(result.response.kind).toBe("taskAccepted");
      expect(result.metadataDiagnostic).toMatchObject({ missingPublished: true, missingStatsMask: 15 });
    }

    expect(sent).toHaveLength(5);
    for (const wire of sent) assertWireHasNoDiagnosticSentinel(wire);
    expect(sent[0]).toMatchObject({ version: 1 });
    expect(sent[1]).toMatchObject({ version: 2, media: { kind: "directFile" } });
    expect(sent[2]).toMatchObject({ version: 1 });
    expect(sent[2]).not.toHaveProperty("media");
    expect(sent[3]).toMatchObject({ version: 1, evidence: { sourceLabel: "Current page DOM (truncated)" } });
    expect(sent[3]).not.toHaveProperty("media");
    expect((sent[4] as { requestId: string }).requestId).not.toBe((sent[0] as { requestId: string }).requestId);
  });

  it("runs the 3 MiB text truncation path before fail-closed validation without sending a native parameter", async () => {
    const oversized = "x".repeat(3 * 1024 * 1024 + 64);
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: id, title: "ordinary", author: null, description: oversized,
        pageURL: `https://www.douyin.com/video/${id}`, metadataDiagnostic: metadataDiagnostic(),
      } }])
      .mockResolvedValueOnce([{ result: { metadata: null, diagnostic: ssrDiagnostic() } }]);
    const sendNativeMessage = vi.fn();
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ url: `https://www.douyin.com/video/${id}`, title: "ordinary" }) },
      scripting: { executeScript }, runtime: { sendNativeMessage },
    });
    vi.stubGlobal("crypto", { randomUUID: vi.fn(() => "oversized") });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { sendCapture } = await import("../src/entrypoints/background");

    const result = await sendCapture(1);
    expect(result).toMatchObject({ errorStage: "extension_validation", response: { kind: "error", error: { code: "CAPTURE_PAYLOAD_TOO_LARGE" } } });
    expect(sendNativeMessage).not.toHaveBeenCalled();
  });

  it("returns a sanitized session media diagnostic to the popup but never places it on the native wire", async () => {
    const rawMediaSentinel = "diagnostic-media-raw-sentinel";
    const blobDescriptor = {
      kind: "browserSessionOnly" as const,
      platform: "douyin" as const,
      pageURL: `https://www.douyin.com/video/${id}`,
      canonicalURL: `https://www.douyin.com/video/${id}`,
      transcriptionCapability: "unavailable" as const,
      failureReason: "blob_or_mse" as const,
    };
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: id,
        title: "ordinary blob page",
        author: null,
        description: "ordinary body",
        pageURL: `https://www.douyin.com/video/${id}`,
        mediaDescriptor: blobDescriptor,
        metadataDiagnostic: metadataDiagnostic(),
      } }])
      // Playback lookup misses, so the session-detail path runs.
      .mockResolvedValueOnce([{ result: { ok: false } }])
      // This raw MAIN-world result contains both an allowed host diagnostic and
      // an untrusted extra field. Only the allowlisted diagnostic may reach the popup.
      .mockResolvedValueOnce([{ result: {
        ok: false,
        code: "no_allowed_host",
        blockedHost: diagnosticSentinel.host,
        rawDetail: rawMediaSentinel,
      } }])
      .mockResolvedValueOnce([{ result: { metadata: null, diagnostic: ssrDiagnostic() } }]);
    const sent: unknown[] = [];
    const sendNativeMessage = vi.fn(async (_host: string, wire: {
      requestId: string;
      capture: { characterCount: number };
    }) => {
      sent.push(wire);
      return {
        kind: "taskAccepted",
        version: 1,
        requestId: wire.requestId,
        characterCount: wire.capture.characterCount,
      };
    });
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({
        url: `https://www.douyin.com/video/${id}`,
        title: "ordinary blob page",
      }) },
      scripting: { executeScript },
      runtime: { sendNativeMessage },
    });
    vi.stubGlobal("crypto", { randomUUID: vi.fn(() => "media-diagnostic-wire") });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { sendCapture } = await import("../src/entrypoints/background");

    const result = await sendCapture(1);

    expect(executeScript).toHaveBeenCalledTimes(4);
    expect(result.response.kind).toBe("taskAccepted");
    expect(result.mediaDiagnostic).toEqual({
      code: "no_allowed_host",
      blockedHost: diagnosticSentinel.host,
    });
    expect(result.metadataDiagnostic).toMatchObject({
      missingPublished: true,
      missingStatsMask: 15,
    });
    expect(JSON.stringify(result)).not.toContain(rawMediaSentinel);
    expect(sent).toHaveLength(1);
    assertWireHasNoDiagnosticSentinel(sent[0]);
    expect(JSON.stringify(sent[0])).not.toContain(rawMediaSentinel);
  });
});
