# LinkDigest

> 内部工作名；正式上架名称需在发布前完成商标、域名与应用商店重名检索。

LinkDigest 的产品目标是成为一个 local-first 的链接理解工具：用户可以粘贴网页链接，或从 Chrome、Brave、Edge 的当前页面直接发送内容，在桌面 APP 中完成正文提取、总结、翻译和导出；问答作为 P0 之后的候选能力。当前实现范围以“当前阶段”小节为准，粘贴链接、历史和导出尚未完成。

这个仓库同时运行两条轨道：

- **开发轨**：持续交付可运行、可验证、可发布的软件。
- **学习轨**：记录每个阶段的场景、组件角色、技术决策、命令、验证和踩坑。

## 当前阶段

产品路线已收敛为 **macOS 原生优先**：桌面 APP 使用 SwiftUI + 少量 AppKit，Chromium 扩展继续使用 TypeScript/WXT，两端通过 Native Messaging 与版本化 JSON 协议交接。

当前代码已完成到 **P0-RC-02B App capture/run persistence wiring**：V0.1 Chromium capture bridge、V0.2 BYOK 总结/翻译，以及 V0.3 的正式 History Domain、冻结 migration 001、GRDB Repository、启动恢复闸门和当前 Capture/Run 持久化接线已经贯通。02A 已独立通过，02B 已独立 PASS。Repository commit 是 UI 与浏览器成功 ACK 的共同闸门；生命周期共享的 `StorageWriteGate` 会在线性化的 Capture permit queue 中阻止存储失败后的继续写入；Run 的 queued/running/partial/terminal、取消、迟到数据与跨 delta secret holdback 均有确定性测试。Gate 0 production vertical smoke 现在用脚本创建的临时 Application Support root 显式注入真实 Debug composition，20/20 通过且禁止回退解析真实用户目录。这个结论只关闭 02B/Gate 0，不表示完整 P0 或发布完成；历史 Sidebar/详情/单项删除、Markdown/TXT/JSON 导出、稳定 Host 安装升级卸载、签名、公证和发布包仍未实现。

- 架构边界见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。
- 当前 P0 产品范围与验收见 [`docs/PRD.md`](docs/PRD.md)。
- 第一条“测试页面 → 扩展 → Native Messaging → SwiftUI”链路见 [`docs/specs/V0.1_VERTICAL_SLICE.md`](docs/specs/V0.1_VERTICAL_SLICE.md)。
- 10 万/100 万容量口径作为远期参考保留在 [`docs/CAPACITY_MODEL.md`](docs/CAPACITY_MODEL.md)，不驱动 P0 实施。
- 学习在开发过程中同步解释，不设置课后答题门槛，见 [`docs/LEARNING_GUIDE.md`](docs/LEARNING_GUIDE.md) 与 [`docs/TASK_TEMPLATE.md`](docs/TASK_TEMPLATE.md)。
- 项目名词见 [`docs/GLOSSARY.md`](docs/GLOSSARY.md)，讲解记录见 [`docs/LEARNING_LOG.md`](docs/LEARNING_LOG.md)。
- Project Brain 只能通过 `./scripts/brain` 读写；一键只读体检使用 `./scripts/doctor`，说明见 [`VERIFY.md`](VERIFY.md)。
- 当前依赖版本、兼容理由和许可证边界见 [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)。
- V0.2 的集中工程证据见 [`docs/specs/V0.2_BYOK_ACCEPTANCE.md`](docs/specs/V0.2_BYOK_ACCEPTANCE.md)。
- P0-RC-02B 的最终实施、验收与证据见 [`docs/specs/P0_RC_02B_APP_WIRING_IMPLEMENTATION.md`](docs/specs/P0_RC_02B_APP_WIRING_IMPLEMENTATION.md)、[`docs/specs/P0_RC_02B_APP_WIRING_ACCEPTANCE.md`](docs/specs/P0_RC_02B_APP_WIRING_ACCEPTANCE.md) 与 [`docs/evidence/P0_RC_02B_APP_WIRING_ACCEPTANCE_2026-07-15.md`](docs/evidence/P0_RC_02B_APP_WIRING_ACCEPTANCE_2026-07-15.md)。
- V0.1 自动化垂直链路已建立：语言中立 JSON Schema、共同 fixtures、WXT MV3 扩展、SwiftUI APP、Native Host、Unix socket 与结构化错误均可构建和测试；Chrome、Brave 150 的真实触发、离线错误、在线接收与 20 次 Release p95 已通过。Edge 150 的隔离 Profile 也已完成真实 Popup 预览观察，以及修复后 Service Worker → Native Host → Unix socket → 运行中 Swift App 的 20/20 传输证据。
- V0.2 任务 A–D 已完成本地工程验收：配置与 Keychain、Chat Completions adapter、总结/翻译 RunState、统一恢复文案和 secret hygiene 均有自动证据。单独“测试连接”按钮留给后续小任务；当前可通过总结/翻译路径验证连接，不影响本轮完成标准。
- 旧 Electron/百万容量对齐文档保存在 `docs/archive/`，只用于追溯，不再作为当前实现依据。

V0.1 三浏览器交接矩阵的工程证据已经收口；Edge 的 Popup 观察与 Service Worker 传输压测分别记录，不能合并解读为一次连续的工具栏点击截图验收。Native Host 的正式稳定目录、Developer ID 签名与公证属于后续 release spike，不是本任务关闭门槛；当前 `/tmp` 路径也不得当成发布方案。

## 目录

```text
apps/
  desktop/            macOS SwiftUI 桌面 APP
  browser-extension/  Chrome / Brave / Edge 扩展
contracts/            当前跨语言唯一合同：根 JSON Schema 与共同 fixtures
packages/
  extractor/          后续提取模块预留；当前只有占位 README
  llm/                后续模型模块预留；当前只有占位 README
  shared/             旧 TypeScript 协议原型与兼容参考；不是当前跨语言真相源
server/               远期服务端预留，不进入 P0
docs/                 PRD、架构、学习与发布资料
```

## 第一条产品原则

优先处理用户在浏览器中已经合法打开并看见的内容。默认不读取整个浏览器 Cookie 数据库；只有深度媒体提取确实需要登录态时，才请求当前域名、可撤销、短时有效的授权。

## 安全边界

- API Key、Cookie、Token、浏览器配置和账号数据不得进入 Git。
- P0 不依赖自建服务器，先验证本地核心闭环。
- 任何付费、部署、上架、发布和远程写入都需要 Syc 明确确认。
- 平台适配只服务于用户主动提交的内容，不设计批量采集或绕过访问控制。
