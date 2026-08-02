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
  // content script 里也要用产品显示名（X 时间线那个按钮的提示与读屏文案）。
  // 在那边手写一遍的下场已经发生过：产品改叫「汲作」之后，按钮的
  // tooltip 还在念旧名。改成构建期从同一份 product-display.json 注入，
  // 让「改名字只改一处」这句话对扩展也成立。
  vite: () => ({
    define: {
      __PRODUCT_DISPLAY_NAME__: JSON.stringify(productDisplay.displayName)
    }
  }),
  manifest: {
    key: extensionIdentity.manifestKey,
    name: productDisplay.displayName,
    description: productDisplay.extensionDescription,
    version: extensionIdentity.version,
    version_name: "0.2.0-x-timeline-clean-r13",
    permissions: ["activeTab", "scripting", "storage", "nativeMessaging"],
    icons: { "16": "icon/16.png", "32": "icon/32.png", "48": "icon/48.png", "96": "icon/96.png", "128": "icon/128.png" },
    action: { default_icon: { "16": "icon/16.png", "32": "icon/32.png" } }
  }
});
