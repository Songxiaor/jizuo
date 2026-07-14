# Browser Extension

负责 Chrome、Brave、Edge 当前标签页的用户触发式提取与分享。P0 使用 TypeScript、WXT 与 Manifest V3，默认只申请 `activeTab`、`scripting`、`storage`、`nativeMessaging`；Cookie 与域名权限不进入 P0。

Content Script 读取 DOM，Service Worker 校验版本化 JSON 并调用 Native Messaging，Popup 只展示捕获与连接状态。扩展不保存模型 API Key，不承担历史、导出或完整设置。

V0.1 使用用户点击后的 `activeTab + scripting` 注入，不申请 `host_permissions` 或静默全站脚本。构建与固定文章入口：

```bash
pnpm --filter @linkdigest/browser-extension test
pnpm --filter @linkdigest/browser-extension build
node scripts/serve-test-article.mjs
```

构建产物位于 `apps/browser-extension/.output/chrome-mv3/`；真实浏览器安装和 Native Host manifest 绑定见 `docs/V0.1_IMPLEMENTATION.md`。
