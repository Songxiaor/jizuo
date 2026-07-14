import { defineConfig } from "wxt";

export default defineConfig({
  manifest: {
    name: "LinkDigest",
    description: "Send the current page to LinkDigest",
    permissions: ["activeTab", "scripting", "storage", "nativeMessaging"]
  }
});
