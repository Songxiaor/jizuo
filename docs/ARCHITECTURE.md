# LinkDigest 架构基线

> 状态：2026-07-15，MAS-first 为当前权威路线。V0.2 A–D 工程基线继续复用；App 独立输入、App Sandbox、扩展安全 loopback bridge、SQLite、历史、删除和导出尚未实现。

## 1. 架构目标

LinkDigest 首发必须先形成不依赖浏览器扩展的 sandboxed Mac App：粘贴文字或公开 URL 进入统一内容快照，经现有 BYOK 组件总结或简体中文翻译，再由 SQLite 保存并导出 Markdown、纯文本或 JSON。

Chromium 扩展是可选输入 adapter。版本化合同属于可复用的产品边界；Native Messaging、独立 Host 和 Unix socket 属于可替换的运输层。

## 2. 场景、角色与交接

### 2.1 MAS 首发主路径

```text
SwiftUI Input
  ├─ 用户粘贴文字
  └─ 用户粘贴公开 HTTP(S) URL
        |
        v
Input Router / Public Web Fetcher（未实现）
  职责：校验输入、读取公开响应、提取正文、解释受限页面
  交接：版本化 Content Input / ContentSnapshot candidate
        |
        v
Application + Domain Core
  职责：任务编排、来源证据、RunState、取消、稳定错误
  交接：Task / ContentSnapshot / Run / Artifact
        |
        +--> ProviderProfile + Keychain + OpenAI-compatible Adapter（已实现）
        |
        +--> SQLite Repository（未实现）
        |
        +--> Markdown / TXT / JSON Exporter（未实现）
        |
        v
SwiftUI Workspace
  职责：输入、原文核查、结果、历史、删除、导出和恢复
```

### 2.2 条件式扩展路径

```text
Chromium/WXT current DOM（已实现）
  → CaptureEnvelopeV1（已实现）
  → 安全 loopback bridge（未实现、待 sandbox spike）
  → 同一 Application input port
```

如果 bridge gate 失败，删除这条首发路径即可；Core、BYOK、SQLite、导出和独立 App 仍然成立。

### 2.3 已验证的开发路径

```text
Chromium/WXT current DOM
  → CaptureEnvelopeV1
  → Native Messaging / LinkDigestNativeHost
  → /tmp/linkdigest-<uid>.sock
  → SwiftUI current capture
```

这条路径证明了当前页 DOM、跨语言合同、framing、大小限制、超时和结构化错误。它不证明 App Sandbox、MAS 审核可行性或发布安装体验。

## 3. 当前状态矩阵

| 组件 | 代码状态 | MAS-first 结论 |
|---|---|---|
| SwiftUI App shell/current content | 已实现 | 复用并扩展为独立工作区 |
| `CaptureEnvelopeV1` JSON Schema | 已实现、双端执行 | 保留为浏览器输入合同；新合同沿用版本化规则 |
| WXT DOM capture | 已实现、Chrome/Brave 有证据 | 条件式增强；Edge 不阻塞独立首发 |
| Native Host/framing/Unix socket | 已实现开发链 | 开发证据或未来 DMG 候选；不是 MAS 主运输层 |
| ProviderProfile/UserDefaults | 已实现 | 复用非敏感 profile port/adapter |
| Keychain SecretStore | 已实现 | 复用；sandbox target 中重新跑真实 Keychain 行为测试 |
| OpenAI-compatible Provider | 已实现 | 复用 URLSession/SSE/重试/取消；自动测试继续 fake server |
| ModelRunOrchestrator/RunState | 已实现 | 复用并把输入、结果接入持久化 |
| App Sandbox | 未实现/未验证 | 首个发布 gate；当前无发布级 MAS target/entitlements 证据 |
| App 内文字与 URL 输入 | 未实现 | 首发主入口 |
| Public Web Fetcher/extractor | 未实现 | 只处理公开 HTTP(S)；受限页面降级为粘贴文字 |
| 扩展 loopback bridge | 未实现 | 独立 App 闭环后再 spike |
| SQLite Repository | 未实现 | 首发必需 |
| 删除与只读恢复 | 未实现 | 首发必需 |
| Markdown/TXT/JSON Exporter | 未实现 | 首发必需 |

测试中的 `FakeOpenAICompatibleServer` 已使用 `127.0.0.1`，但它只验证 Provider adapter。它不能替代扩展 bridge 的身份校验、重放防护、端口生命周期、sandbox 行为和浏览器集成证据。

## 4. 不重写 V0.2 的边界

### 4.1 直接复用

- `ProviderProfile`、`SecretReference`、`ProviderProfileStore`、`SecretStore` 与 staged save。
- `KeychainSecretStore` 和非敏感 `UserDefaultsProviderProfileStore`。
- `ModelProvider` port、`OpenAICompatibleProvider`、SSE decoder、有界重试和显式取消。
- `ModelRunOrchestrator`、`RunIntent.summarize/translate`、RunState 与 stale-run 隔离。
- 22 个 stable code 的中文恢复目录、API Key redaction、sentinel 测试与 `pnpm secret:check`。
- SwiftUI 当前原文/结果区域及其 MainActor 状态更新模式。

### 4.2 保留合同，替换运输层

- `CaptureEnvelopeV1`、共同 fixtures 和结构化错误语义继续有效。
- `browser.runtime.sendNativeMessage`、`LinkDigestNativeHost`、4-byte framing、manifest installer 和 `/tmp` Unix socket 不进入 MAS 主路径。
- 若未来发布公证 DMG，可重新评估这套运输层；不得让 DMG 安装假设污染 sandboxed App 的独立闭环。

### 4.3 新增而非重写

- 独立输入 port 与 `text/publicURL` 来源类型。
- 公开网页 fetch/extract adapter。
- SQLite repository、forward migration、只读恢复和删除。
- Markdown/TXT/JSON exporter。
- 发布级 MAS target、entitlements、container 路径和 sandbox 测试。

## 5. 分层与依赖方向

```text
App Shell
  SwiftUI lifecycle / Window / Menu / Settings

Presentation
  Input / Workspace / History / Error / Export state

Application
  Input commands / Task Orchestrator / Run commands / Delete / Export

Domain
  Task / ContentSnapshot / Run / Artifact / AppError

Ports
  ContentInput / PublicPageReader / ModelProvider / Repository / SecretStore / Exporter

Adapters
  Paste / URLSession Fetch / OpenAI-compatible / SQLite / Keychain / File Export

Conditional adapters
  WXT Capture / loopback bridge
```

边界规则：

- SwiftUI View 不直接访问 URLSession、SQLite、Keychain、文件系统或浏览器 bridge。
- Application 层不依赖具体 SwiftUI View 或数据库表。
- Domain 不认识浏览器、Provider 品牌、SQLite binding 或运输层。
- Adapter 把平台错误映射为稳定 `AppError`，Provider 原始 body 不进入 UI。
- AppKit 只用于明确的 macOS 系统缺口，不创建第二套 UI 架构。

## 6. 输入合同

### 6.1 统一来源

独立输入与可选浏览器输入最终都应生成同一领域含义：

```text
sourceType: pasted_text | public_url | browser_current_dom
sourceURL?: http(s)
title?: string
text: string
characterCount: integer
captureMethod: user_paste | public_fetch | rendered_dom | selection
completeness: user_provided | full_article | current_visible | unknown
createdAt / requestId / contractVersion
```

这不是要求立刻修改 `CaptureEnvelopeV1`。实现任务应先决定新增通用 envelope 还是在 Application port 内映射多个版本化输入合同，并提供向前兼容与共同 fixtures。

### 6.2 公开 URL 边界

- 只接受 `http`/`https`，拒绝 userinfo 与危险 scheme。
- 首发只读取公开响应，不注入 Cookie、Authorization Header 或浏览器账号状态。
- 重定向、响应大小、Content-Type、超时和最大正文长度必须有上限。
- 登录壳、脚本渲染不足、robots/平台限制或正文不足应解释失败，建议用户粘贴已合法可见文字。
- 不把网页内容当作可信指令；输入只作为待总结/翻译数据。

## 7. App Sandbox 与 loopback gate

### 7.1 App Sandbox 当前状态

当前仓库以 Swift Package 组织 App/Host，没有发布级 MAS target、entitlements、签名或 container 行为证据。因此“Swift build 通过”不能推导出“可在 MAS sandbox 中工作”。

第一个 gate 至少验证：

- sandboxed Debug/Release App 能启动并恢复主窗口。
- 用户主动粘贴文字不需要额外权限。
- 公开 URL 读取只申请必要的 outgoing network 能力。
- Keychain、SQLite container、用户选择导出位置和取消路径行为明确。
- 关闭 Native Host 后独立闭环仍通过。

### 7.2 loopback 安全验收

扩展 bridge 只有同时满足以下条件才可进入首发：

- 只绑定 loopback，不监听局域网或公网地址。
- 端口生命周期与 App 生命周期绑定，不使用无保护的固定开放端口。
- 使用短时、不可预测的 session capability，验证请求来源、版本、大小、时效和重放。
- 不把 API Key、Cookie、正文或长期 token 写入日志、扩展 storage 或 fixture。
- 浏览器不可用、App 未运行、版本不匹配和超时都有稳定恢复动作。
- sandboxed Release 行为、威胁模型、自动测试和人工攻击性检查均有证据。
- 评估结果明确说明是否符合当时的 App Store 审核与分发边界；该结论必须在实施时重新核查，不能只依赖本文。

失败策略：首发移除扩展入口，保留独立 Mac App；不退回未验证的 Native Host 安装结构，也不绕过 sandbox。

## 8. 状态、并发与取消

- UI 状态在 MainActor 更新。
- 输入读取、模型流、数据库和导出使用受控异步任务。
- 每个 Run 持有可取消任务；停止必须传播到 Provider/URLSession。
- 不允许 detached task 绕过生命周期写数据库。
- 流式部分结果属于当前 Run；完成、停止或中断后再持久化 Artifact 状态。
- 旧 run、旧 URL fetch 或已删除任务的迟到事件不能覆盖当前状态。

## 9. 本地数据

### 9.1 SQLite

SQLite 保存 Task、ContentSnapshot、Run、Artifact 与 migration history。Provider profile 是否迁入数据库由 adapter 决定，但完整 API Key 永不进入数据库。

binding spike 必须验证：

- 许可证与商业闭源边界。
- Apple Silicon、sandboxed Debug/Release 和测试环境。
- forward migration、事务、备份与 10,000 条历史查询。
- migration 失败时只读打开和导出逃生口。
- 删除的事务语义与失败恢复。

### 9.2 Keychain

API Key 使用 Keychain；数据库只保存不泄露秘密的引用。Keychain 写入失败不得降级为明文文件、UserDefaults 或 SQLite。当前 staged save 与 orphan 风险继续保留，维护入口另行决策。

### 9.3 导出

Exporter 只接收脱敏领域对象，不访问 Keychain。Markdown/TXT/JSON 写到用户选择的位置；临时文件、失败清理和同名覆盖必须可解释。

## 10. BYOK 模型路径

```text
ContentSnapshot
  → ModelRunOrchestrator
  → ProviderProfile + Keychain secret
  → OpenAICompatibleProvider / URLSession streaming
  → RunState
  → persisted Run + Artifact
```

V0.2 只支持 OpenAI-compatible Chat Completions；翻译目标固定为简体中文。Responses、Ollama、多 Provider、Q&A 和自动分块不进入首发。

401 不自动重试；429/5xx 只在无输出时做有界重试；流中断保留 partial 并标记 incomplete；用户停止先调用 Provider 取消入口，再停止消费任务。首次真实发送前必须说明正文会直接发送到用户配置的 Provider。

## 11. 安全边界

- API Key、Cookie、Token、Provider 原始 body、私人正文和完整私人 URL 不进入普通日志。
- 所有跨进程或文件边界执行版本、大小、类型与语义校验。
- App 不加载远程 Web UI，不执行网页脚本作为本机代码。
- 不读取浏览器 Cookie 数据库，不保存完整敏感 Header。
- fixture 必须脱敏，真实账号内容不得进入仓库。
- 新依赖先核对许可证；GPL、AGPL、非商业或 UNKNOWN 不得未经评估合入。

## 12. 发布路线

当前顺序：

1. 保留 V0.2 基线和 CI。
2. 建立发布级 MAS target 与 App Sandbox 行为证据。
3. 完成独立文字/公开 URL 输入。
4. 完成 SQLite、历史、删除、导出和整合工作区。
5. 在 fake provider 与 sandboxed Release 中关闭独立首发验收。
6. 独立首发稳定后，单独验证 extension loopback bridge。
7. 只有 bridge 通过才把扩展加入 MAS 首发；否则继续 backlog。
8. 签名、商店提交与发布等待 Syc 单独授权。

Edge、稳定 Native Host、公证 DMG 可作为未来独立路线，不能阻塞步骤 1–5。

## 13. 可替换与不可静默改变

可以替换：

- Swift SQLite binding。
- 公开网页提取实现。
- WXT 与扩展 bridge 运输方式。
- Native Host 的具体进程与安装形式。
- Provider adapter 实现。

不可静默改变：

- MAS-first 与 Mac App 独立闭环。
- macOS 原生 SwiftUI 主路线。
- local-first、Provider-neutral 与用户数据可迁移。
- API Key 只进 Keychain，秘密不进普通状态。
- 版本化、语言中立、可解释失败的合同。
- Cookie、平台专用适配、媒体和云端保持 deferred。

改变这些边界前必须通过 Project Brain 记录 reversal，再同步 PRD、Architecture、接续路线与验收文档。
