# LinkDigest 架构基线

> 状态：V0.1 Swift Package、WXT 扩展、Native Host 与自动化进程链路已实现；Chrome/Brave 真实垂直链路已通过，Edge 仍待补齐。V0.2 任务 A–D 的 ProviderProfile/Keychain、OpenAI-compatible adapter、总结/翻译 streaming UI、停止/不完整状态、统一错误恢复与 secret hygiene 已完成本地工程验收；设置页连接测试、SQLite、历史与 Export 仍未接入，签名、公证和发布包也未完成。该状态不表示 P0 或产品发布完成。

## 1. 一句话定位

LinkDigest 用 SwiftUI 构建 macOS 原生桌面 APP，用 TypeScript/WXT 构建 Chromium 扩展；两端不共享语言源码，而是通过版本化 JSON 与 Native Messaging 交接。P0 的提取、BYOK、历史和导出全部 local-first，不依赖 LinkDigest 云端。

## 2. 场景、角色与交接

```text
Chromium Extension（TypeScript/WXT）
  职责：读取用户主动触发的当前页面 DOM/选区
  交接：CaptureEnvelopeV1 JSON
        |
        v Native Messaging
macOS Native Host / App Boundary（Swift）
  职责：framing、版本校验、大小限制、唤起与错误映射
  交接：已验证的 Swift 领域对象
        |
        v
macOS Local Core（Swift）
  职责：任务编排、提取、BYOK、SQLite、Keychain、导出
  交接：可观察状态和领域结果
        |
        v
SwiftUI + 少量 AppKit
  职责：任务列表、原文、结果、执行记录和系统交互
```

### 2.1 为什么采用双语言

- Chromium 扩展的权限、service worker、content script 和商店工具链天然适合 TypeScript。
- 第一版只做 macOS，原生窗口、菜单、快捷键、材质、焦点和可访问性是产品质量的一部分。
- Swift 与 TypeScript 通过语言中立协议隔离，避免为了“共享类型”把整个桌面 APP 绑定到 Web Runtime。
- Windows 若进入后续阶段，复用产品协议与行为规范，不承诺复用 macOS UI 源码。

## 3. P0 组件边界

### 3.1 Chromium 扩展

| 组件 | 负责 | 不负责 |
|---|---|---|
| Content Script | 读取当前 DOM、选区和页面元数据 | Native Messaging、数据库、模型调用 |
| Service Worker | 权限、载荷校验、Native Messaging、超时 | 渲染完整历史和复杂设置 |
| Popup | 捕获范围、动作、字符数和连接状态 | 长期任务状态、导出、Key 管理 |

P0 默认权限：

- `activeTab`
- `scripting`
- `storage`
- `nativeMessaging`

不申请 Cookie、浏览器历史或全站静默访问。受限页面只显示明确说明，不尝试绕过。

### 3.2 Native Messaging 边界

Native Messaging 是首要 release spike，必须单独验证：

- Chrome/Brave/Edge Host manifest 的安装和卸载。
- APP 已运行、未运行、升级中三种状态。
- 长度前缀 framing、消息上限和超时。
- Host 与 APP 的签名、公证和路径稳定性。
- 扩展/APP 版本不一致时的恢复文案。

V0.1 已选择独立 `LinkDigestNativeHost` executable：它处理 Chromium 4-byte little-endian framing、4 MiB 上限、10 秒超时和合同校验，再通过用户私有 `/tmp/linkdigest-<uid>.sock` Unix domain socket 交给正在运行的 APP。APP 未运行时返回 `APP_UNAVAILABLE`，不静默拉起；Host 不承载提取、模型或数据库业务。签名、公证与安装包内的最终 Helper 位置仍由 release spike 决定。

### 3.3 macOS APP

```text
App Shell
  SwiftUI App lifecycle / Window / Menu / Settings

Presentation
  Views / View State / Navigation

Application
  Task Orchestrator / Commands / Cancellation

Domain
  Task / ContentSnapshot / Run / Artifact / AppError

Ports
  CaptureInbox / ModelProvider / Repository / SecretStore / Exporter

Adapters
  Native Messaging / URLSession / SQLite / Keychain / File Export
```

边界规则：

- SwiftUI View 不直接访问 SQLite、Keychain、文件系统或模型端点。
- Application 层不依赖具体 SwiftUI View。
- Domain 不依赖浏览器、SQLite binding 或某个模型 Provider。
- Adapter 将平台错误映射成稳定 `AppError`。
- AppKit 只通过小型 adapter/representable 局部使用，不创建第二套 UI 架构。

## 4. 状态与并发

P0 使用 Swift Concurrency：

- UI 状态在 MainActor 更新。
- 页面接收、数据库、导出和模型流在受控异步任务中运行。
- 每个 `Run` 持有可取消任务；停止操作必须向 URLSession/stream 传播取消。
- 不允许 detached task 绕过任务生命周期写数据库。
- 流式结果先属于运行中的 `Run`，完成或中断后再形成 `Artifact`。

状态管理优先使用 Observation/`@Observable` 或等价原生机制；只有明确需要 Publisher 组合时才引入 Combine。

## 5. 稳定协议

### 5.1 协议唯一来源

Swift 与 TypeScript 无法直接共享类型。进入 V0.1 实施前必须确定一种语言中立合同来源：

1. 推荐：受版本控制的 JSON Schema，生成或验证两端模型。
2. 可接受：手写 schema + 同一组跨语言 JSON fixtures。
3. 不接受：只把 TypeScript interface 当成跨语言真相源。

`contracts/capture-envelope-v1.schema.json` 是当前跨语言唯一合同。扩展构建时由 Ajv 2020 生成静态校验函数，运行时不使用 Manifest V3 CSP 禁止的 `eval` / `new Function`；Swift 运行时加载打包后的同一 Schema 并执行其 `required/const/enum/type/length/pattern/format` 规则。两端再共同执行字符数等 Schema 无法直接表达的语义 invariant，并读取同一组 `contracts/fixtures/`。`scripts/check-contract-sync.sh` 防止 Swift resource 副本漂移，`generate-contract-validator.mjs --check` 防止扩展静态校验器漂移；旧 `packages/shared` 的 Zod 模型只保留兼容参考。

### 5.2 消息头

所有跨浏览器与 APP 边界的消息包含：

```ts
type MessageMeta = {
  version: number;
  requestId: string;
  createdAt: string;
  idempotencyKey?: string;
};
```

兼容规则：

- 兼容字段只能新增为可选。
- 破坏性变化发布新 major version。
- 未知可选字段宽容读取。
- 不支持的 major version 必须拒绝并给出升级动作。
- 重复 `requestId/idempotencyKey` 不得重复创建任务。

### 5.3 P0 领域模型

| 模型 | 含义 |
|---|---|
| `CaptureEnvelopeV1` | 浏览器交给 APP 的来源、正文和捕获证据 |
| `Task` | 用户想完成的一次链接理解工作 |
| `ContentSnapshot` | 某个时间和捕获路径下的正文快照 |
| `Run` | 一次提取、总结、翻译或导出执行 |
| `Artifact` | 可保存、复制或导出的结果 |
| `AppError` | 稳定错误类别、代码与恢复动作 |

云端 `User/Device/Entitlement/SyncManifest/UsageLedger` 不进入 P0 合同实现。

## 6. 本地数据

### 6.1 SQLite

SQLite 保存：

- Task
- ContentSnapshot
- Run
- Artifact
- 非敏感 ProviderProfile
- migration history

选择 Swift SQLite binding 前必须验证：

- Swift Package 许可证。
- Apple Silicon 与发布构建。
- 签名、公证和升级迁移。
- 备份、只读恢复和事务行为。

数据库 migration 只向前；升级失败时以只读模式打开并允许导出，不通过删除数据库恢复。

### 6.2 Keychain

API Key 使用 Keychain 保存，SQLite 只记录不可逆推出秘密的引用。Keychain 写入失败时禁止降级为明文文件或 UserDefaults。

### 6.3 文件导出

导出由用户选择位置。Markdown/TXT/JSON 生成器只接收脱敏领域对象，不直接读取 Keychain。

## 7. BYOK 模型路径

```text
SwiftUI Action
  → Task Orchestrator
  → ProviderProfile + Keychain secret
  → URLSession streaming request
  → Provider Adapter
  → Run progress
  → Artifact
  → SQLite / Export
```

P0 只实现 OpenAI-compatible Chat Completions。Responses、Ollama 和多 Provider 管理在首条本地闭环稳定后评估。

协议、Base URL、模型名和秘密分离：

- Adapter 负责请求路径、Header 和流式事件翻译。
- 领域层不认识具体 Provider 名。
- 401 不自动重试；429/5xx 只做有界重试。
- 流中断保存部分结果并标记不完整，不自动拼接不可信续写。

V0.2 的具体组件、秘密边界、错误矩阵与任务拆分见 `docs/specs/V0.2_BYOK_PLAN.md`，集中验收证据见 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`。当前实现止于“捕获正文 → Orchestrator → Provider adapter → streaming RunState → SwiftUI 结果”；SQLite、历史和 Export 属于后续里程碑。每个 stable code 由 App 层统一映射为中文原因与恢复动作，未知输入不会原样进入 UI；Orchestrator 在 RunState 前对本次短时 API Key 做精确 redaction。

## 8. UI 与 AppKit 边界

SwiftUI 负责：

- App/Scene 生命周期。
- NavigationSplitView、任务列表、详情和设置。
- 原生 toolbar、commands、focus、keyboard shortcuts。
- 空状态、错误卡、进度和动画。

只有以下情况才评估 AppKit：

- SwiftUI TextEditor 无法满足结果编辑与选择行为。
- 精细 NSWindow、NSMenu 或系统服务接入。
- 性能 profiling 证明 SwiftUI 控件不达标。

每个 AppKit bridge 必须拥有单一职责、Coordinator 边界和可测试状态映射。

## 9. P0 安全边界

- API Key、Cookie、Token、正文和私人 URL 不进入普通日志。
- 扩展消息执行大小限制和运行时 schema 校验。
- URL 只接受 `http`/`https`；文件路径与自定义 scheme 默认拒绝。
- APP 不加载远程 Web UI，不嵌入任意网页执行环境。
- 不读取浏览器 Cookie 数据库。
- 测试 fixture 必须脱敏，不包含真实账号页面。
- 商业闭源依赖先检查许可证；GPL/AGPL/非商业许可不得直接合入。

## 10. 发布路线

P0 优先验证公证 DMG：

1. Xcode Release 构建。
2. APP、Helper/Host 与扩展版本对齐。
3. Developer ID 签名与 hardened runtime。
4. Notarization 与 stapling。
5. 干净用户环境安装、升级、卸载。
6. Chrome/Brave/Edge Native Host manifest 检测。

是否进入 Mac App Store 必须在 Native Messaging 与 sandbox spike 后决定，不能在 PRD 中提前承诺。

## 11. 未来云端边界

账号、选择性同步和托管模型仍是候选增值能力，但全部在 P0 之后重新验证。若进入云端阶段：

- local-first 与 BYOK 不依赖 Cloud API。
- 原文默认不上云。
- 云端框架和部署厂商重新选择，不由旧 Electron 方案自动继承。
- `docs/CAPACITY_MODEL.md` 只作为远期假设和压测参考，不驱动当前部署。

## 12. 已知未知项与 spike 顺序

| 顺序 | 未知项 | 证据 |
|---|---|---|
| 1 | Native Host 安装/唤起/公证 | V0.1 release spike |
| 2 | 跨语言 schema 一致性 | 两端 fixture tests |
| 3 | Swift SQLite binding | 打包、迁移和恢复测试 |
| 4 | 流式 Provider 兼容 | 固定 fake server + 真实端点抽样 |
| 5 | SwiftUI 富文本能力 | 可选择、复制、编辑和长文性能测试 |
| 6 | DMG 与 Mac App Store | sandbox/分发 spike |

未知项按顺序验证；前一项未通过时，不扩大后续平台或云端范围。

## 13. 可替换与不可变

可以替换：

- WXT。
- Swift SQLite binding。
- Native Host 的具体进程形式。
- Provider adapter 实现。
- 公证 DMG 的安装器工具。

不可静默改变：

- macOS 原生 SwiftUI 主路线。
- 当前页面优先。
- local-first 与免登录 P0。
- Provider-neutral。
- 秘密不进普通存储。
- 版本化、可解释的跨端协议。

需要改变不可变项时，必须先通过 Project Brain 记录 reversal，再同步 PRD、Architecture 和验收。
