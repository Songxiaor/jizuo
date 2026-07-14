import { describe, expect, it } from "vitest";

import { mapNativeFailure, withTimeout } from "../src/native-client";

describe("native messaging failures", () => {
  it("maps a timeout to a retryable timeout code", async () => {
    await expect(withTimeout(new Promise<never>(() => undefined), 1)).rejects.toThrow("NATIVE_MESSAGE_TIMEOUT");
    expect(mapNativeFailure(new Error("NATIVE_MESSAGE_TIMEOUT"))).toEqual({ code: "NATIVE_MESSAGE_TIMEOUT", action: "retry" });
  });

  it("maps browser host lookup failures to the install guide", () => {
    expect(mapNativeFailure(new Error("Specified native messaging host not found"))).toEqual({ code: "NATIVE_HOST_NOT_FOUND", action: "open_install_guide" });
  });
});
