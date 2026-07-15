import { describe, expect, it } from "vitest";
import { makeAppError, type NativeResponse } from "../src/contract";
import { popupMessageForResponse } from "../src/popup-presentation";

const storageCodes = [
  "STORAGE_UNAVAILABLE", "STORAGE_WRITE_FAILED", "STORAGE_FUTURE_SCHEMA",
  "STORAGE_MIGRATION_FAILED", "STORAGE_READ_ONLY", "STORAGE_INTEGRITY_FAILED",
  "STORAGE_STATE_CONFLICT", "CAPTURE_IDEMPOTENCY_CONFLICT", "RUN_IDEMPOTENCY_CONFLICT",
];

describe("popup error presentation", () => {
  it("uses fixed allowlisted storage copy without raw wire fields", () => {
    for (const code of storageCodes) {
      const response: NativeResponse = { kind: "error", error: { ...makeAppError("req", "storage", code, true, "retry"), safeDetail: "sentinel-secret-path" } };
      const message = popupMessageForResponse(response)!;
      expect(message).not.toContain(code);
      expect(message).not.toContain("retry");
      expect(message).not.toContain("sentinel-secret-path");
    }
  });

  it("uses a generic fallback for unknown input", () => {
    const response: NativeResponse = { kind: "error", error: makeAppError("req", "unknown", "SENTINEL_RAW_CODE", false, "none") };
    expect(popupMessageForResponse(response)).toBe("操作未完成，请重试。");
  });
});
