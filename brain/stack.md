---
slug: stack
kind: root-page
title: Tech Stack
updated: "2026-07-14T12:13:32"
---

# Tech Stack

## 当前已落地栈

| domain | current choice | evidence | system consequence |
|---|---|---|---|
| Workspace | pnpm 11 workspace | `package.json` workspaces `apps/*`, `packages/*` | TypeScript 侧统一 lint/typecheck/test/build，但 Swift 仍由脚本桥接 |
| Node runtime | Node >= 22.13 | root `package.json` engines | 扩展构建与 validator 生成依赖现代 Node |
| Browser extension | TypeScript 6.0.3 + WXT 0.20.27 + MV3 | `apps/browser-extension/package.json` | 适合 Chromium 权限与 service worker；不能使用 MV3 CSP 禁止的动态 validator |
| TS schema runtime | Ajv 8.17.1 + ajv-formats 3.0.1 | extension dependencies | 构建期生成静态 validator，避免运行时 `eval/new Function` |
| macOS app | Swift 6 package, macOS 15 target | `apps/desktop/Package.swift` | 原生 APP 与 Host 可用 Swift Package 构建；发布仍需 Xcode/signing spike |
| UI | SwiftUI | `LinkDigestApp.swift` | 当前只显示接收状态与正文；后续富文本/长文编辑可能触发 AppKit bridge |
| Transport | Native Messaging + Unix domain socket | `LinkDigestNativeHost`, `Framing.swift`, `UnixSocket.swift` | 清晰隔离浏览器 framing 与 APP 生命周期，但增加安装/签名/路径恢复成本 |
| Contract | JSON Schema Draft 2020-12 + fixtures | `contracts/capture-envelope-v1.schema.json` | Swift/TypeScript 不共享源码类型；两端必须执行同一合同和语义 invariant |
| Validation | Handwritten Swift JSON Schema subset + static Ajv validator | `JSONSchema.swift`, generated validator | 当前覆盖所需 schema 特性；未来复杂 schema 可能需要受控代码生成或更完整 validator |
| Planned storage | SQLite | PRD/Architecture | 尚未选择 Swift binding；必须验证许可证、签名、公证、迁移和只读恢复 |
| Planned secrets | macOS Keychain | PRD/Architecture | API Key 不允许降级进入 SQLite/UserDefaults/plain file |
| Planned model I/O | URLSession + Swift Concurrency | PRD/Architecture | 支持流式、取消和本机生命周期；Provider adapter 需要隔离端点差异 |

## 当前脚本与验证入口

- `pnpm check:web`：lint、typecheck、test、browser build、doctor。
- `pnpm check:swift`：contract sync、Swift tests、Debug/Release build、native-host check、Host smoke、vertical smoke。
- `pnpm check`：Web + Swift 总检查。
- `pnpm xcode:build`：Xcode App/Host Debug/Release 构建。
- `scripts/native-host/install-dev.sh`：开发期 manifest 安装，默认 dry-run，需要显式浏览器目标。
- `scripts/native-host/uninstall-plan.sh`：只读卸载计划，不自动删除。

## 许可与安全边界

- 商业闭源准备下，GPL/AGPL/非商业许可不得未经评估直接合入。
- WXT 依赖链按当前文档走 MIT/BSD 可接受分支。
- API Key、Cookie、Token、正文和私人 URL 不进入普通日志、测试夹具或 Git。
- 扩展不申请 Cookie/history/host permissions；只处理用户主动触发的当前页面。

## 未决技术选择

1. Microsoft Edge 真实验收：需要先获得外部软件安装授权。
2. Host 正式稳定安装目录与 resource bundle 共置方式。
3. Developer ID 签名、公证、DMG 与可能的 Mac App Store 路线。
4. Swift SQLite binding 与 migration/只读恢复策略。
5. SwiftUI 长文显示、选择、编辑是否需要 AppKit bridge。
6. OpenAI-compatible 流式协议差异与 fake server/真实端点抽样。

## 系统性影响

短期栈选择把复杂度压在两个边界：跨语言合同和 Native Host 发布链路。收益是 P0 能保持 local-first、原生体验和浏览器最小权限；长期成本是每次合同字段、Host 路径、资源打包或签名策略变化都必须双端验证。不能用“共享 TypeScript 类型”或“把 Host 逻辑塞进 APP/UI”来局部省事，因为那会把跨边界错误推迟到真实浏览器和真实用户机器上爆发。
