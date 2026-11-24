import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "wxt";

const productDisplay = JSON.parse(
  readFileSync(fileURLToPath(new URL("../desktop/Sources/LinkDigestCore/Resources/product-display.json", import.meta.url)), "utf8")
) as { displayName: string; extensionDescription: string; formatVersion: number };
const extensionIdentity = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../config/extension-identity.json", import.meta.url)), "utf8")
) as { extensionID: string; formatVersion: number; manifestKey: string; version: string };
const appRelease = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../config/app-release.json", import.meta.url)), "utf8")
) as { formatVersion: number; shortVersion: string };
// 代抓能自动抓的站点名单：App 与扩展共用这一份。App 侧同名文件由
// BrowserCaptureHostPolicy 读取；两边都从这一个 JSON 生成/校验，改名单只改这里。
const relayHosts = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../desktop/Sources/LinkDigestCore/Resources/relay-host-permissions.json", import.meta.url)),
    "utf8"
  )
) as { formatVersion: number; hosts: string[] };

if (
  productDisplay.formatVersion !== 1 ||
  extensionIdentity.formatVersion !== 1 ||
  appRelease.formatVersion !== 1 ||
  relayHosts.formatVersion !== 1
) {
  throw new Error("LinkDigest product display, extension identity, or app release config is invalid");
}

/** 常用平台：https/http + 域名本身与所有子域。 */
const relayHostPermissions = relayHosts.hosts.flatMap((host) => [
  `https://${host}/*`,
  `https://*.${host}/*`,
  `http://${host}/*`,
  `http://*.${host}/*`,
]);

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
    version_name: appRelease.shortVersion,
    permissions: ["activeTab", "scripting", "storage", "nativeMessaging", "alarms"],
    // 浏览器代抓：App 在后台开一个标签，这里要在没有用户点击（没有 activeTab 授权）
    // 的情况下注入提取脚本。只声明实际支持的平台；泛网页放 optional，未授权时代抓
    // 直接失败并说明原因（browser_capture_permission_missing），不静默超时。
    host_permissions: relayHostPermissions,
    optional_host_permissions: ["http://*/*", "https://*/*"],
    icons: { "16": "icon/16.png", "32": "icon/32.png", "48": "icon/48.png", "96": "icon/96.png", "128": "icon/128.png" },
    action: { default_icon: { "16": "icon/16.png", "32": "icon/32.png" } }
  }
});
