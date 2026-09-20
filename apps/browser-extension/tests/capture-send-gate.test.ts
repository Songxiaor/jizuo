import { describe, expect, it } from "vitest";
import { captureSendBlockReason } from "../src/content/capture-send-gate";

describe("captureSendBlockReason", () => {
  it("blocks hard failures", () => {
    expect(
      captureSendBlockReason({
        captureIssue: "CAPTURE_SECURITY_CHALLENGE",
        characterCount: 5000,
      }),
    ).toBe("CAPTURE_SECURITY_CHALLENGE");
    expect(
      captureSendBlockReason({
        captureIssue: "CAPTURE_PAGE_LOAD_FAILED",
        characterCount: 0,
      }),
    ).toBe("CAPTURE_PAGE_LOAD_FAILED");
  });

  it("allows selection on soft failures", () => {
    expect(
      captureSendBlockReason({
        captureIssue: "CAPTURE_LOGIN_WALL",
        completeness: "selection_only",
        characterCount: 40,
      }),
    ).toBeUndefined();
  });

  it("allows substantial body on SPA chrome mis-detect, not whole-page login walls", () => {
    expect(
      captureSendBlockReason({
        captureIssue: "CAPTURE_APP_SHELL",
        characterCount: 240,
      }),
    ).toBeUndefined();
    expect(
      captureSendBlockReason({
        captureIssue: "CAPTURE_LOGIN_WALL",
        characterCount: 800,
      }),
    ).toBe("CAPTURE_LOGIN_WALL");
  });
});
