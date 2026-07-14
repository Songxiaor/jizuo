---
slug: roadmap
title: Roadmap
role: milestones
updated: "2026-07-15T01:47:01"
---

# Roadmap

## 当前顺序

1. **完成**：V0.1/V0.2 工程基线——版本化合同、WXT capture、开发 Host、SwiftUI、Keychain、单 Provider streaming、RunState、错误与秘密门禁。
2. **当前**：MAS-first 真相源与接续路线对齐（SYC-39）。
3. **下一 gate**：发布级 MAS target、最小 entitlements 与 App Sandbox 行为 spike。
4. **独立输入**：Mac App 粘贴文字与公开 HTTP(S) URL，来源/原文/完整性可核查。
5. **本地事实**：SQLite Task/ContentSnapshot/Run/Artifact、forward migration、只读恢复与删除。
6. **可迁移性**：Markdown、纯文本、版本化 JSON 导出与完整任务工作区。
7. **独立首发验收**：不安装扩展或 Native Host，sandboxed Release 使用 fake provider 完成端到端闭环。
8. **条件式增强**：独立验证扩展安全 loopback bridge；通过才进入首发，否则继续 backlog。
9. **人工授权**：签名、商店提交与发布由 Syc 单独决定。

## 已完成资产

- macOS SwiftUI、local-first、Provider-neutral 与版本化跨语言合同边界。
- V0.1 WXT/Host/SwiftUI 开发链和 Chrome/Brave 真实证据。
- V0.2 ProviderProfile/Keychain、OpenAI-compatible streaming、summary/简体中文 translation、stop/incomplete、redaction 与 CI。

## 停放项

- Edge、稳定 Native Host 与公证 DMG。
- 真实 Provider 抽样。
- 平台专用适配、Cookie、字幕与媒体。
- 账号、同步、托管模型、服务器、Windows、iOS 与 Safari。

## 门禁

- Sandbox gate 失败时隔离发布壳问题，不重写 V0.2 Core。
- 公开 URL 不可可靠读取时保留粘贴文字并解释降级，不引入 Cookie。
- SQLite binding 不满足许可证/打包/恢复时替换 adapter，不让 UI 绑定表结构。
- loopback bridge 失败时首发移除扩展，不切回未验证的 `/tmp` Host。
- 安装、真实 Provider、签名、公证、提交和发布均需 Syc 明确授权。
