import { describe, expect, it } from "vitest";

import { mapNativeFailure, withTimeout } from "../src/native-client";

const expectFailure = (value: ReturnType<typeof mapNativeFailure>, code: string, action: string) => {
  expect(value).toMatchObject({ version: 1, requestId: "req-1", category: "network", code, action });
  expect(Number.isNaN(Date.parse(value.createdAt))).toBe(false);
};

describe("native messaging failures", () => {
  it("maps timeout and host failures to complete network AppError values", async () => {
    await expect(withTimeout(new Promise<never>(() => undefined), 1)).rejects.toThrow("NATIVE_MESSAGE_TIMEOUT");
    expectFailure(mapNativeFailure(new Error("NATIVE_MESSAGE_TIMEOUT"), "req-1"), "NATIVE_MESSAGE_TIMEOUT", "retry");
    expectFailure(mapNativeFailure(new Error("Specified native messaging host not found"), "req-1"), "NATIVE_HOST_NOT_FOUND", "open_install_guide");
    expectFailure(mapNativeFailure(new Error("Native host has exited."), "req-1"), "NATIVE_HOST_START_FAILED", "open_install_guide");
  });

  it("keeps unknown and non-Error failures generic without raw text", () => {
    const raw = "sentinel-browser-internal-secret";
    const values = [mapNativeFailure(new Error(raw), "req-1"), mapNativeFailure(raw, "req-1"), mapNativeFailure(undefined, "req-1")];
    for (const value of values) {
      expectFailure(value, "NATIVE_MESSAGE_FAILED", "retry");
      expect(JSON.stringify(value)).not.toContain(raw);
    }
  });
});
