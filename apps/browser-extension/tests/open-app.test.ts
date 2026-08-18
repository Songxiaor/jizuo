import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

afterEach(() => vi.unstubAllGlobals());

describe("popup open-app click", () => {
  it("prevents the custom-scheme href and asks the background to open via native host", () => {
    const popup = readFileSync(join(root, "entrypoints/popup/main.ts"), "utf8");
    expect(popup).toContain("event.preventDefault()");
    expect(popup).toContain('sendMessage({ type: "open-app" })');
    const html = readFileSync(join(root, "entrypoints/popup/index.html"), "utf8");
    expect(html).toContain('id="open-app"');
  });

  it("sends kind openApp over native messaging instead of relying on Launch Services", () => {
    const background = readFileSync(join(root, "src/entrypoints/background.ts"), "utf8");
    expect(background).toContain('message.type === "open-app"');
    expect(background).toContain('kind: "openApp"');
    expect(background).toContain("sendNativeMessage(HOST_NAME, message)");
  });
});

describe("openPeerApp native message", () => {
  it("treats taskAccepted as success", async () => {
    const sendNativeMessage = vi.fn().mockResolvedValue({
      kind: "taskAccepted", version: 1, requestId: "fixed", characterCount: 0,
    });
    vi.stubGlobal("crypto", { randomUUID: () => "fixed" });
    vi.stubGlobal("browser", { runtime: { sendNativeMessage } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.resetModules();
    const { openPeerApp } = await import("../src/entrypoints/background");
    await expect(openPeerApp()).resolves.toEqual({ ok: true });
    expect(sendNativeMessage).toHaveBeenCalledWith(
      "com.syc.linkdigest.v01",
      { kind: "openApp", version: 1, requestId: "fixed" },
    );
  });
});
