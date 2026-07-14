# LinkDigest

> 内部工作名；正式上架名称需在发布前完成商标、域名与应用商店重名检索。

LinkDigest 是一款 macOS 原生、local-first 的链接理解工具。首发目标是让用户只依靠 Mac App，就能粘贴文字或公开网页链接、核查来源与原文、使用自己的 OpenAI-compatible 模型完成总结或简体中文翻译，并在本机管理、删除和导出历史。

## 当前权威路线

首发采用 **MAS-first（Mac App Store 优先）**。这表示后续设计与验证先满足 App Sandbox、Mac App 独立闭环和商店分发约束，但不表示已经完成签名、提交或审核。

Chromium 扩展是条件式增强能力，不是 Mac App 首次价值的前置条件。只有 App Sandbox 与安全 loopback bridge 都有可复现证据后，扩展才进入 App Store 首发；否则首发只交付独立 Mac App，扩展继续留在 backlog。

当前 Native Messaging + 独立 Host + `/tmp` Unix socket 已证明 Chrome/Brave 当前页可以可靠进入 SwiftUI。它仍是开发证据，也可作为未来公证 DMG 的候选运输层；它不是 MAS 主路线，不能把当前安装脚本或临时路径包装成 App Store 架构。

## 代码真实状态

| 能力 | 当前状态 | 结论 |
|---|---|---|
| V0.1 当前页捕获 | 已实现并自动化；Chrome/Brave 真实验收通过 | JSON 合同、WXT、DOM 捕获、错误语义继续复用；Edge 不再阻塞 MAS 独立闭环 |
| V0.2 BYOK | A–D 工程验收完成 | ProviderProfile、Keychain、Chat Completions streaming、RunState、停止/不完整结果、redaction 与 secret hygiene 继续复用 |
| Mac App 独立输入 | 未实现 | 尚不能在 App 内粘贴文字或公开 URL 完成输入闭环 |
| App Sandbox | 未验证 | 当前 Swift Package 没有发布级 MAS target、entitlements 或 sandbox 验收证据 |
| 扩展安全 loopback bridge | 未实现 | 现有 Provider fake server 的 loopback 测试不等于扩展到 App 的产品桥 |
| SQLite 历史与删除 | 未实现 | 当前只有内存中的 capture/run；非敏感 Provider profile 使用 UserDefaults |
| Markdown/TXT/JSON 导出 | 未实现 | 只有端口与产品边界，没有 exporter 代码 |

V0.2 的集中证据见 [`docs/specs/V0.2_BYOK_ACCEPTANCE.md`](docs/specs/V0.2_BYOK_ACCEPTANCE.md)。MAS-first 的后续依赖、验收与明确非目标见 [`docs/specs/MAS_FIRST_CONTINUATION.md`](docs/specs/MAS_FIRST_CONTINUATION.md)。

## 首发独立闭环

```text
粘贴文字或公开 HTTP(S) URL
  → App 生成可核查的来源与原文快照
  → 用户使用自己的 OpenAI-compatible 模型总结或翻译
  → SQLite 保存本地历史
  → 用户打开、删除或导出 Markdown / 纯文本 / JSON
```

首发不要求浏览器扩展、LinkDigest 账号或 LinkDigest 云端。模型请求会直接发往用户配置的 Provider；正式使用前仍需补齐数据去向提示。

## 明确停放

- Edge 真实验收与稳定 Native Host 安装结构。
- 真实 Provider 抽样、签名、公证、App Store 提交和发布。
- 微信公众号、X、YouTube、B站、小红书、抖音等平台专用适配。
- Cookie、字幕、媒体下载与转写。
- 账号、同步、托管模型、服务器、Windows、iOS 和 Safari。

这些事项只有在独立 Issue、技术证据和 Syc 明确授权后才能启动。

## 文档入口

- 产品范围、状态与验收：[`docs/PRD.md`](docs/PRD.md)
- 当前与目标架构：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- MAS-first 接续路线：[`docs/specs/MAS_FIRST_CONTINUATION.md`](docs/specs/MAS_FIRST_CONTINUATION.md)
- V0.1 跨进程证据：[`docs/specs/V0.1_VERTICAL_SLICE.md`](docs/specs/V0.1_VERTICAL_SLICE.md)
- V0.2 BYOK 证据：[`docs/specs/V0.2_BYOK_ACCEPTANCE.md`](docs/specs/V0.2_BYOK_ACCEPTANCE.md)
- 学习协作：[`docs/LEARNING_GUIDE.md`](docs/LEARNING_GUIDE.md)、[`docs/TASK_TEMPLATE.md`](docs/TASK_TEMPLATE.md)、[`docs/LEARNING_LOG.md`](docs/LEARNING_LOG.md)
- 依赖与许可证：[`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)
- 本地验证：[`VERIFY.md`](VERIFY.md)

Project Brain 只能通过 `./scripts/brain` 读写；`./scripts/doctor` 提供只读体检。

## 目录

```text
apps/
  desktop/            macOS SwiftUI App、Core、Adapters 与开发期 Native Host
  browser-extension/  条件式增强的 Chromium/WXT 扩展
contracts/            当前跨语言唯一合同：JSON Schema 与共同 fixtures
packages/
  shared/             旧 TypeScript 协议原型与兼容参考
docs/                 PRD、架构、验收、学习与路线文档
server/               远期预留；不进入首发
```

## 安全边界

- API Key、Cookie、Token、私人正文和账号数据不得进入 Git、普通日志、截图或测试夹具。
- API Key 只进入 Keychain；用户内容默认留在本机，只有用户主动运行模型时才发送到其配置的 Provider。
- 不读取完整浏览器 Cookie 数据库，不绕过付费墙、验证码或平台访问控制。
- 安装外部软件、使用真实 Provider、付费、签名、公证、提交商店和发布都需要 Syc 单独确认。
