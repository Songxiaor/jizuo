import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "wxt";

const productDisplay = JSON.parse(
  readFileSync(fileURLToPath(new URL("../desktop/Sources/LinkDigestCore/Resources/product-display.json", import.meta.url)), "utf8")
) as { displayName: string; extensionDescription: string; formatVersion: number };
const extensionIdentity = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../config/extension-identity.json", import.meta.url)), "utf8")
) as { extensionID: string; formatVersion: number; manifestKey: string; version: string };

if (productDisplay.formatVersion !== 1 || extensionIdentity.formatVersion !== 1) {
  throw new Error("LinkDigest product display or extension identity config is invalid");
}

export default defineConfig({
  manifest: {
    key: extensionIdentity.manifestKey,
    name: productDisplay.displayName,
    description: productDisplay.extensionDescription,
    version: extensionIdentity.version,
    version_name: "0.2.0-douyin-metadata-diagnostic-r1",
    permissions: ["activeTab", "scripting", "storage", "nativeMessaging"],
    icons: { "16": "icon/16.png", "32": "icon/32.png", "48": "icon/48.png", "96": "icon/96.png", "128": "icon/128.png" },
    action: { default_icon: { "16": "icon/16.png", "32": "icon/32.png" } }
  }
});
