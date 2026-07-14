# LinkDigest PRD

> 状态：2026-07-15，MAS-first 为当前权威路线。本文描述首发目标与代码差距，不把目标写成已完成能力。
>
> 产品范围、优先级和验收以本文为准；技术边界见 `docs/ARCHITECTURE.md`；接续 Issue 顺序见 `docs/specs/MAS_FIRST_CONTINUATION.md`；V0.2 证据见 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`。

## 1. 一句话定位

LinkDigest 是一款 macOS 原生、local-first 的链接理解工具：用户可以在 Mac App 中粘贴文字或公开网页链接，核查来源与原文，使用自己的 OpenAI-compatible 模型完成总结或简体中文翻译，并在本机管理、删除和导出历史。

## 2. 首发原则

### 2.1 MAS-first

首发优先按 Mac App Store 分发约束设计。MAS-first 的含义是：

- Mac App 必须脱离浏览器扩展完成独立闭环。
- App Sandbox、网络访问、用户选择文件位置和本地数据路径必须有发布级证据。
- Chromium 扩展只有在 sandbox 与安全 loopback bridge 验证通过后才进入首发。
- 当前没有签名、提交或审核授权；MAS-first 不是“已经可以上架”。

### 2.2 产品承诺

- **先获得价值**：首发不要求注册 LinkDigest 账号或安装浏览器扩展。
- **来源可核查**：总结或翻译必须能回到本次输入的来源与原文。
- **数据默认本地**：原文、结果和历史默认保存在本机。
- **模型可替换**：用户配置自己的 OpenAI-compatible Base URL、API Key 和模型名。
- **失败可解释**：输入、网页读取、模型、存储和导出失败分别给出原因与恢复动作。
- **数据可迁移**：用户可以导出 Markdown、纯文本和版本化 JSON。

## 3. 当前代码真相

V0.2 不是重写起点，而是首发继续使用的工程基线。

| 区域 | 当前事实 | 首发处理 |
|---|---|---|
| 版本化 JSON 合同与 fixtures | 已实现并由 Swift/TypeScript 双端验证 | 保留；新输入和持久化合同继续版本化 |
| WXT 当前页捕获 | 已实现；Chrome/Brave 真实验收通过 | 保留为条件式增强，不阻塞独立 App |
| Native Messaging/Host/Unix socket | 已形成开发链路，当前使用临时路径 | 不作为 MAS 主路线；保留为开发证据或未来公证 DMG 候选 |
| SwiftUI 当前内容界面 | 已实现当前 capture 展示和模型结果区 | 复用并扩展为独立输入与任务工作区 |
| ProviderProfile + Keychain | 已实现单 profile、staged save 与固定 mask | 直接复用；API Key 继续只进 Keychain |
| Chat Completions streaming | 已实现 URLSession/SSE、有界重试和取消 | 直接复用；继续使用 fake server 自动验收 |
| RunState 与错误恢复 | 已实现总结、简体中文翻译、停止、完成、不完整和失败 | 直接复用；接入持久化与独立输入 |
| secret hygiene/redaction | 已实现独立门禁和 sentinel 测试 | 保持为合并与发布门禁 |
| App 独立输入 | 未实现 | 首发必须新增粘贴文字与公开 HTTP(S) URL |
| App Sandbox | 未验证 | 首发前必须建立 target、entitlements 与 sandbox 行为证据 |
| 扩展 loopback bridge | 未实现 | 独立闭环完成后再做安全 spike；失败则首发不带扩展 |
| SQLite、历史、删除 | 未实现 | 首发必须完成 |
| Markdown/TXT/JSON 导出 | 未实现 | 首发必须完成 |

现有 Provider fake server 使用 loopback 做自动测试，只证明模型 adapter 可以被本地替身验证；它不证明浏览器扩展可以安全连接 sandboxed App。

## 4. 首发用户场景

### 4.1 粘贴文字

1. 用户打开 LinkDigest，不安装扩展。
2. 用户粘贴一段自己有权处理的文字，可选填写来源标题或 URL。
3. App 显示输入正文、来源类型与字符数。
4. 用户选择总结或翻译为简体中文。
5. App 显示 streaming 结果，允许停止并保留不完整结果。
6. 任务和结果保存在本机；用户可以重新打开、删除或导出。

### 4.2 公开网页链接

1. 用户粘贴一个公开 `http` 或 `https` URL。
2. App 在 sandbox 允许的网络边界内读取公开响应并提取正文。
3. App 显示原 URL、标题、正文、提取方式和完整性提示。
4. 用户核查原文后运行总结或翻译。
5. 受限、登录后、脚本渲染或正文不足页面必须解释限制，并建议改为粘贴可见文字；首发不读取 Cookie。

### 4.3 条件式浏览器增强

如果安全 bridge 通过独立验收，用户可从 Chromium 当前页主动发送已经可见的 DOM 到 App。这个入口复用 `CaptureEnvelopeV1` 和 WXT 捕获，但不能成为首发独立闭环的依赖。

## 5. 首发必须完成

### 5.1 输入与核查

- Mac App 可独立启动、退出和恢复主窗口。
- 支持粘贴文字和公开 HTTP(S) URL。
- 每个任务保存输入类型、来源、原文快照、字符数、提取方式和完整性。
- 用户运行模型前可以查看原文；结果完成后仍可回到对应原文。
- URL 不可访问、需要登录、脚本渲染不足或正文过短时给出不同恢复动作。

### 5.2 BYOK 理解

- 支持一个 OpenAI-compatible Chat Completions 配置。
- API Key 只进入 Keychain，不进入 SQLite、UserDefaults 明文、日志、导出或 Git。
- 支持总结、简体中文翻译、停止、重试、完成和不完整结果。
- 首次向真实 Provider 发送正文前显示数据将直接发往用户所配置 Provider 的提示。
- LinkDigest Cloud API 不存在或不可用时，本地输入、历史、删除、导出和 BYOK 仍可使用。

### 5.3 本地历史与迁移

- SQLite 保存 Task、ContentSnapshot、Run、Artifact 与 migration history。
- App 重启后可以打开历史任务、原文和结果。
- 用户可以删除单项；删除结果与失败状态可观察。
- migration 只向前；升级失败时优先只读打开并允许导出，不通过删除数据库恢复。

### 5.4 导出

- 支持 Markdown、纯文本和版本化 JSON。
- 导出包含来源、原文、总结/翻译结果、完整性和必要执行证据。
- 导出不包含 API Key、Cookie、Authorization Header、Keychain reference 或本机秘密路径。
- 用户选择保存位置；取消选择不创建半成品文件。

### 5.5 MAS 验收

- 发布形态启用 App Sandbox，并记录所需最小 entitlement 及其原因。
- 独立闭环在 sandboxed Release 构建中通过，不依赖 Native Host 或 `/tmp` socket。
- 没有签名凭据时可完成未签名的结构与行为检查；签名、商店提交和发布仍等待 Syc 授权。
- 如果 extension bridge 未通过安全与审核可行性验证，首发范围自动降级为独立 Mac App，不阻塞产品价值。

## 6. 明确不做

- Edge 首发门禁、稳定 Native Host 安装、Developer ID 公证 DMG。
- 真实 Provider 自动测试；任何手工抽样都需要 Syc 单独授权。
- 微信公众号、X、YouTube、B站、小红书、抖音等平台专用适配。
- Cookie 读取、付费墙或验证码绕过、批量账号采集。
- 字幕下载、媒体下载、`yt-dlp`、`ffmpeg`、Whisper 或转写。
- Windows、iPhone、iPad、Safari。
- LinkDigest 账号、订阅、同步、团队协作、托管模型和服务器。
- Q&A、自动分块、批量导入、批量总结、PDF/HTML 导出。

这些能力保留在 backlog，不得因为旧 Issue 已存在而自动进入首发。

## 7. 产品工作流

```text
Mac App 独立输入
  ├─ 粘贴文字
  └─ 公开 HTTP(S) URL
        ↓
来源与原文快照
        ↓
用户核查完整性
        ↓
BYOK 总结 / 简体中文翻译
        ↓
SQLite 历史
        ↓
打开 / 删除 / Markdown-TXT-JSON 导出
```

条件式扩展只增加第三种输入来源，不改变 Core、Provider、SQLite 或 Exporter 的职责。

## 8. 关键界面

### 8.1 主窗口

```text
+----------------------+------------------------------------------+
| 本地任务              | 当前任务                                  |
|                      | 来源 / 输入方式 / 完整性                  |
| 今天                  | 标题 / 原链接                             |
| · 一篇公开文章         |------------------------------------------|
| · 一段粘贴文字         | 结果 | 原文 | 执行记录                    |
|                      |                                          |
|                      | 当前内容                                  |
+----------------------+------------------------------------------+
```

必须保留：新建输入、任务列表、来源证据、原文、结果、执行记录、删除和导出。视觉规格由独立 UI/UX Issue 定义，不能用通用 Web dashboard 代替 macOS-native 交互。

### 8.2 设置

- Base URL、模型名、API 模式和 SecureField API Key。
- 固定 mask 只表示“已保存”，不显示真实末四位。
- 数据去向提示与配置错误恢复。
- 测试连接按钮是可选增强，不是独立闭环门禁；若实现必须提示可能产生少量 Provider 用量。

## 9. 状态与失败语义

| 阶段 | 用户可见状态 | 主要恢复动作 |
|---|---|---|
| 文字输入 | 空、可用、过长 | 补充或缩短输入 |
| 公开 URL | 读取中、不可访问、受限、正文不足、成功 | 检查 URL、稍后重试、改粘贴可见文字 |
| 正文 | 完整、当前响应可见、用户粘贴、未知 | 查看原文、重新输入 |
| 模型 | 未配置、401、429、5xx、协议不匹配、网络中断 | 打开设置、更新 Key、等待、检查 Base URL、重试 |
| 运行 | starting、streaming、stopping、stopped、completed、incomplete、failed | 停止、保留部分结果、手动重试 |
| 存储 | 可写、只读恢复、迁移失败、删除失败 | 导出、备份、修复后重试 |
| 导出 | 选择位置、写入中、取消、失败、完成 | 换位置、重试、保留本地历史 |

错误对象至少包含 `category / code / retryable / action / safeDetail`。`safeDetail` 不得包含 API Key、Cookie、Token、Provider 原始 body、完整私人 URL 或正文。

## 10. 数据边界

| 数据 | 首发默认位置 | 禁止 |
|---|---|---|
| API Key | macOS Keychain | SQLite、UserDefaults 明文、日志、测试夹具、导出、Git |
| Provider profile | UserDefaults 或后续非敏感配置表 | 保存完整 Key |
| 原文、结果、历史 | App Sandbox 容器内 SQLite | 未经用户动作上传 LinkDigest 云端 |
| 捕获/提取证据 | SQLite | Cookie、完整敏感 Header |
| 导出文件 | 用户选择的位置 | Key、Cookie、Token、内部 secret reference |

调用 BYOK 时，本次输入会直接发送给用户配置的 Provider。LinkDigest 不代理请求，但 UI 必须在首次真实发送前说明这一点。

## 11. 首发验收

### 11.1 端到端剧本

1. **纯文字独立闭环**：全新 App、不安装扩展，粘贴固定脱敏文字，使用 fake provider 得到 streaming 总结，重启后仍可打开并导出三种格式。
2. **公开 URL 独立闭环**：本地固定 HTTP fixture 或公开脱敏测试页进入 App，来源、原文和完整性可核查；不依赖 Cookie。
3. **停止与不完整结果**：streaming 中停止，500 ms 内不再增长；部分结果持久化并标记不完整。
4. **历史与删除**：创建多条任务、重启、打开、删除单项；数据库与 UI 状态一致。
5. **迁移恢复**：从固定旧 schema 升级；失败时只读打开并允许导出。
6. **秘密门禁**：随机 sentinel 不进入 SQLite、UserDefaults 明文、日志、导出、fixture 或 UI 错误。
7. **Sandbox Release**：启用 sandbox 的 Release 构建完成 1–6；未启用 Native Host 也不影响。
8. **可选扩展增强**：仅在 bridge gate 通过时，当前 DOM 作为第三种输入进入同一工作区；失败不破坏独立输入。

### 11.2 工程指标

| 指标 | 目标 |
|---|---:|
| 停止模型流响应 | ≤ 500 ms |
| 10,000 条本地历史查询 p95 | ≤ 300 ms |
| 固定 20,000 字输入建立快照 p95 | ≤ 2 s |
| 敏感信息扫描命中 | 0 |
| 固定迁移 fixture 成功率 | 100% |

未测量时不得宣称达标。真实 Provider、真实商店审核和 Edge 不属于这些自动指标。

## 12. 里程碑与依赖

| 里程碑 | 用户可观察结果 | 依赖 |
|---|---|---|
| V0.2 基线（已完成） | 当前 capture 可总结/翻译/停止，秘密边界可验证 | V0.1 capture 与 fake provider |
| MAS Gate | sandboxed App 可独立运行，明确最小 entitlements | 本文与架构真相源 |
| 独立输入 | 粘贴文字/公开 URL 形成可核查快照 | MAS Gate、输入/错误规格 |
| 本地历史 | 重启后可打开、删除、只读恢复 | SQLite spike、领域合同 |
| 导出与工作区 | Markdown/TXT/JSON 与完整任务工作区 | 历史模型、UI 规格 |
| 独立首发验收 | 不装扩展也完成端到端剧本 | 前述全部 |
| 条件式扩展 | 安全 bridge 通过后增加当前页输入 | 独立首发验收、sandbox + bridge gate |

可执行 Issue 顺序、现有 Issue 的复用/改写建议和停止条件见 `docs/specs/MAS_FIRST_CONTINUATION.md`。本次只记录路线，不创建或提升后续 Issue。

## 13. 已知未知项

- 发布级 Xcode/MAS target 如何从当前 Swift Package 演进。
- App Sandbox 最小 entitlements 与公开网页读取的真实行为。
- SQLite binding 的许可证、打包、迁移与只读恢复证据。
- loopback bridge 在 sandbox、浏览器与商店审核边界下是否可接受。
- 正式产品名、商标、图标、隐私政策和商店材料。

未知项通过小型 spike 与固定 fixture 解决，不通过扩大平台或云端范围解决。

## 14. 文档真相源

| 主题 | 唯一真相源 |
|---|---|
| 产品范围、优先级、验收 | `docs/PRD.md` |
| 当前与目标组件边界 | `docs/ARCHITECTURE.md` |
| 后续 Issue 顺序与门禁 | `docs/specs/MAS_FIRST_CONTINUATION.md` |
| V0.1/V0.2 已完成证据 | 对应 specs、代码、测试与 CI |
| 耐久决策与反转 | Project Brain，经 `./scripts/brain` 读写 |
| 实际行为 | 代码、测试和构建产物 |

当文档与代码冲突时，代码描述当前事实，PRD 描述目标；必须用状态表显式标记差距。路线再次反转时，先更新 Project Brain，再同步本文、Architecture 与接续路线。
