# MAS-first 接续路线与验收门禁

> 状态：2026-07-15 路线建议。本文只记录 Issue 顺序、依赖和验收，不创建、提升或启动任何后续 Issue。

## 1. 目标

在不重写 V0.2 的前提下，把 LinkDigest 从“浏览器当前页经开发 Host 进入 App”接续为“sandboxed Mac App 可以独立完成输入、理解、历史、删除和导出”。Chromium 扩展在独立闭环之后按证据决定是否进入首发。

## 2. 依赖图

```text
SYC-39 真相源对齐
  ├─ MAS Sandbox Gate（需新建或重写一个 backlog Issue）
  └─ SYC-27 独立 App UI/UX 规格（重写范围）
          |
          +--> SYC-28 粘贴文字 + 公开 URL 输入（重写范围）
          |
          +--> SYC-29 SQLite 历史/迁移/删除
                    |
                    +--> SYC-30 Markdown/TXT/JSON 导出
                    |
                    +--> SYC-31 独立任务工作区整合
                              |
                              +--> 独立 MAS Release 验收（需新建 backlog Issue）
                                        |
                                        +--> 可选 extension loopback spike（需新建 backlog Issue）
```

`SYC-26` 的真实 Provider 数据去向提示在任何真实 Provider 抽样之前完成，可与 SQLite/导出工作并行；抽样本身仍需 Syc 单独授权。

## 3. 建议执行顺序

### Gate A：MAS App Sandbox 可行性

**Issue 处理**：在 Syc 审查本路线后，新建一个 backlog Issue，或把尚未启动的发布结构 Issue 明确重写为 MAS sandbox gate。当前不启动。

**依赖**：SYC-39 合并。

**只做**：

- 建立发布级 Mac App target 与最小 entitlements。
- 验证 sandboxed Debug/Release 启动、主窗口、Keychain、container 文件位置和 outgoing network。
- 用固定本地/脱敏 fixture 验证公开 URL 读取边界。
- 证明关闭 Native Host 后 App 仍可运行。

**验收**：

- entitlement 清单逐项说明原因，没有不必要能力。
- 未签名或本地签名的 sandboxed Release 构建完成固定 smoke；不使用 Apple Developer 凭据。
- 失败时明确是 target、entitlement、Keychain、网络还是文件位置问题。
- 不实现 extension bridge、SQLite 产品层或正式发布。

**停止条件**：如果当前 Swift Package 不能直接承载发布 target，先形成最小 Xcode/MAS 壳并复用现有 targets；不得把 App 重写成 Electron，也不得把签名/提交作为本 gate 的隐含要求。

### Stage B：独立 App 规格与输入

#### B1. SYC-27：完整 P0 UI/UX 与状态设计规格

**需要重写的范围**：以 Mac App 独立闭环为主，不把扩展、权限引导或 Native Host 当作首次使用前置。首次引导、输入、来源核查、模型数据提示、历史、删除、导出和 sandbox 错误必须成套设计。

**依赖**：SYC-39；可与 Gate A 的技术 spike 并行，但 entitlement 结论必须回写规格。

**验收**：

- 用户旅程从“不安装扩展”开始。
- 粘贴文字与公开 URL 的状态、错误与恢复完整。
- 任务/原文/结果/执行记录/删除/导出均有信息架构。
- 扩展入口被标为可选增强。

#### B2. SYC-28：粘贴文字与公开 URL 输入

**需要重写的范围**：旧标题只写“粘贴链接”；应增加粘贴文字，并把公开 URL、受限页面、脚本渲染不足和需要当前 DOM 的情况分层。

**依赖**：Gate A 的 outgoing network 结论；SYC-27 的输入/错误规格。

**验收**：

- 文字与公开 URL 都生成版本化、可核查的内容快照。
- 只接受安全的 HTTP(S) 输入；响应大小、重定向、Content-Type 与超时有上限。
- 不读取 Cookie、账号状态或完整浏览器数据库。
- 固定 fixture 覆盖成功、无正文、受限、超时和超限。
- 输入能交给现有 ModelRunOrchestrator；自动测试只用 fake provider。

### Stage C：本地事实与可迁移性

#### C1. SYC-29：SQLite 本地历史与迁移恢复

**依赖**：Gate A 的 container 路径；SYC-27 的历史/删除状态；B2 的快照合同。

**验收**：

- binding 的许可证、sandboxed Debug/Release、Apple Silicon 和测试证据齐全。
- Task、ContentSnapshot、Run、Artifact 与 migration history 可持久化。
- App 重启后可打开；单项删除有事务与失败恢复。
- 固定旧 schema 可向前迁移；失败时只读打开并保留导出逃生口。
- 10,000 条固定数据查询 p95 目标有测量，API Key/Cookie 为零命中。

#### C2. SYC-26：真实 Provider 数据提示与 BYOK 维护边界

**依赖**：SYC-27 的设置/运行提示规格；可与 C1 并行。

**验收**：

- 首次真实发送前说明正文会直接发送到用户配置的 Provider。
- 可选连接测试若实现，使用 Application service 短时读取 Key，并提示可能产生少量用量。
- Keychain orphan 处理范围只触及 LinkDigest 自有 service/reference。
- 不调用真实 Provider；抽样继续等待 Syc 单独授权。

#### C3. SYC-30：Markdown、纯文本与 JSON 导出

**依赖**：C1 的稳定领域对象和只读恢复口。

**验收**：

- 三种格式覆盖来源、原文、结果、完整性和必要执行证据。
- 版本化 JSON 有 schema/fixture 与兼容规则。
- 用户取消、写入失败、同名文件和临时文件清理可恢复。
- sentinel 扫描证明无 API Key、Cookie、Header、secret reference 或私密本机路径。

### Stage D：独立工作区与首发闭环

#### D1. SYC-31：整合 macOS 任务工作区

**依赖**：B1、B2、C1、C2、C3。

**验收**：

- 不安装扩展即可完成输入 → 原文核查 → 总结/翻译 → 历史 → 删除/导出。
- 长任务、停止、不完整结果、存储失败和删除失败都可观察。
- View 不直接访问 SQLite、Keychain、URLSession 或文件系统。
- sandboxed Release 使用 fake provider 完成端到端固定剧本。

#### D2. 独立 MAS Release 验收

**Issue 处理**：在 D1 准备后新建 backlog Issue，由 QA/发布审查执行；当前不创建。

**验收**：

- `pnpm check`、Xcode/MAS Debug/Release、secret/contract/fixture/migration/export 门禁全部通过。
- 干净用户环境中不安装扩展或 Native Host也能完成独立闭环。
- 隐私、数据去向、删除、导出、失败恢复和明确非目标有人工证据。
- 报告区分“本地 sandbox 验收通过”和“Apple 签名/审核/发布未授权”。

### Stage E：条件式 Chromium 增强

#### E1. 安全 loopback bridge spike

**依赖**：D2 通过。先新建 backlog Issue，不与独立闭环并行抢跑。

**验收**：

- 只绑定 loopback；端口生命周期、短时 capability、请求时效、重放、版本、大小和超时有测试。
- 扩展不保存长期 secret、Cookie 或正文；App 未运行与版本不匹配可恢复。
- sandboxed Release、Chrome/Brave 隔离 Profile 与攻击性测试有证据。
- 当时的 App Store 审核/分发可行性经过重新核查。

**失败策略**：首发不带扩展；不影响 D2，不切回当前 `/tmp` Host。

#### E2. Native Host / Edge / 公证 DMG

现有 `SYC-25`（Edge）与 `SYC-36`（稳定 Native Host）继续停放。它们只属于未来 Chromium/公证 DMG 路线，不是 MAS 独立闭环依赖。

## 4. 现有队列需要 Syc 审查的漂移

以下是建议，不在本任务中修改 Multica 状态或描述：

- `SYC-27`：保留，但改为独立 App 主旅程，扩展降为条件式入口。
- `SYC-28`：保留并增加“粘贴文字”；公开 URL 只做通用基线。
- `SYC-29`：保留；显式依赖 sandbox container 与版本化输入模型。
- `SYC-26`、`SYC-30`、`SYC-31`：保留，按本文依赖重排。
- `SYC-32`：包含微信公众号专用适配，超出首发；应拆掉专用部分或整体继续 backlog。
- `SYC-33`、`SYC-34`、`SYC-35`：平台专用、Cookie、媒体与多平台矩阵继续 backlog。
- `SYC-25`、`SYC-36`：Edge/Native Host 属于未来增强或公证 DMG 候选。
- `SYC-37`：签名、公证、商店与发布需要 Syc 独立授权；技术准备也不能自动提交。
- `SYC-38`：云端继续 deferred。

## 5. 全阶段明确非目标

- 安装 Edge 或其它外部软件。
- 使用真实 API Key、调用真实 Provider 或上传私人正文。
- 读取 Cookie、浏览器历史或日常 Profile。
- 平台专用适配、字幕、媒体下载或转写。
- 签名、公证、购买 Apple Developer 账号、提交 App Store 或发布。
- 账号、同步、托管模型、服务器和遥测平台。

## 6. 失败与恢复

- **Sandbox gate 失败**：保留 V0.2 targets 和测试，隔离最小发布壳问题；不重写 Core。
- **公开 URL 提取不稳定**：首发保留粘贴文字，受限页面明确降级；不引入 Cookie 或平台爬虫。
- **SQLite binding 不满足许可证/打包**：保持 Repository port，更换 adapter；不让 UI 绑定具体表。
- **迁移失败**：只读打开并允许导出；禁止删除用户数据库“恢复”。
- **loopback bridge 失败**：首发移除扩展；当前 Native Host 继续只是开发/DMG 证据。
- **CI 或文档漂移**：以代码/测试为当前事实，修正文档状态；路线反转通过 Brain CLI 留痕。

## 7. 当前任务的停止点

SYC-39 完成文档、Brain、检查和 PR 后停止。任何后续 Issue 的创建、描述重写、状态提升、功能实现、签名或发布都等待 Syc 审查与明确决定。
