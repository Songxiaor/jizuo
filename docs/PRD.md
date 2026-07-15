# LinkDigest PRD

> 状态：V0.1 macOS 原生路线、自动化垂直链路与 Chrome/Brave/Edge 三浏览器工程证据已经收口。Edge 150 的证据由真实 Popup 预览，以及修复后 Service Worker → Native Host → Unix socket → Swift App 的 20/20 传输组成；修复后没有再次完成工具栏点击到 APP 的连续截图。正式 Host 稳定目录、Developer ID 签名、公证和发布包属于后续 release spike。
>
> 本文是产品范围、优先级和验收标准的唯一真相源。技术组件见 `docs/ARCHITECTURE.md`；第一条链路见 `docs/specs/V0.1_VERTICAL_SLICE.md`；V0.2 工程证据见 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`；远期容量假设见 `docs/CAPACITY_MODEL.md`。

> **范围与当前实现说明**：本文的 P0 是第一版产品目标，不代表当前代码已经实现全部 P0。V0.1 三浏览器交接矩阵已有工程证据，但正式安装、签名、公证和发布包仍未完成。V0.2 A–D 的本地工程链路已完成：ProviderProfile/Keychain、OpenAI-compatible streaming adapter、总结/翻译 RunState 与 UI、停止/不完整状态、统一恢复文案和 secret hygiene 均有自动证据。设置页连接测试尚未实现，也未调用真实模型 API。V0.3 的正式 History Domain、冻结 migration 001 与 GRDB Repository 已完成 02A 独立工程验收；02B 的 App composition、启动恢复闸门、Capture/Run 持久化、storage failure 黏性禁写与并发 Capture 线性化已经独立 PASS。Gate 0 production vertical smoke 已以显式注入的临时 Application Support root 实际通过，不会回退解析真实用户目录。历史 Sidebar/详情/删除 UI 尚未开始，文件导出属于 V0.4。

## 1. 一句话定位

LinkDigest 是一款 macOS 原生、local-first 的链接理解工具：用户在 Chromium 浏览器中主动发送当前页面，Mac APP 保存可核查的原文，并使用用户自己的模型连接完成总结、翻译和导出。

## 2. 第一版为什么存在

### 2.1 首要用户

第一版只优先服务一类用户：**需要频繁阅读、研究和整理网页内容的个人创作者或研究者**。

典型场景：

1. 用户在 Chrome、Brave 或 Edge 中打开一篇已经合法可见的文章。
2. 用户点击 LinkDigest 扩展，选择“总结”或“发送到 APP”。
3. Mac APP 展示提取到的标题、来源、正文和完整性提示。
4. 用户使用自己的 OpenAI-compatible 模型生成总结或翻译。
5. 原文、结果和执行证据保存在本机，并可导出为 Markdown。

### 2.2 核心问题

- 登录后或动态渲染的页面，服务器重新抓 URL 经常只能得到登录壳或空页面。
- 纯浏览器扩展不适合承担长期历史、模型配置、诊断和导出。
- 固定模型端点会带来地区、成本、隐私和可用性限制。
- 多数总结工具无法说明正文从哪里来、是否完整、失败发生在哪一层。

### 2.3 用户承诺

- **眼前可见优先**：优先处理用户当前已打开的页面 DOM。
- **先获得价值**：P0 不要求注册账号。
- **数据默认本地**：原文、结果、历史和 API Key 默认不经过 LinkDigest 云端。
- **模型可替换**：用户可以配置自己的 OpenAI-compatible Base URL、API Key 和模型名。
- **失败可恢复**：提取、连接、模型和存储错误必须给出人话原因和下一步动作。

## 3. 已确认的第一版技术方向

| 区域 | 决定 | 原因 |
|---|---|---|
| macOS APP | Swift + SwiftUI | 第一版只做 Apple 平台，原生 UI 是产品价值的一部分 |
| 平台补位 | 少量 AppKit | 富文本、窗口、菜单或 SwiftUI 明确不足时局部桥接 |
| Chromium 扩展 | TypeScript + WXT + Manifest V3 | 浏览器扩展生态仍以 Web 技术为主 |
| 跨端交接 | Native Messaging + 版本化 JSON | Swift 与 TypeScript 不共享源码，只共享可验证协议 |
| 本地数据 | SQLite | 单文件、事务可靠、适合 local-first 历史 |
| 秘密 | macOS Keychain | API Key 不进入 SQLite、日志、导出或 Git |
| 模型调用 | URLSession + Swift Concurrency | 使用系统原生网络与取消机制 |

技术边界不是永久锁死：如果 release spike 证明 Native Messaging、签名、公证或 SQLite 组合不可接受，再比较替代方案。Windows 不作为 P0 约束。

## 4. 核心循环

```text
浏览器当前页
  → 用户主动点击扩展
  → 提取当前 DOM / 选区
  → 版本化 JSON 交给 Mac APP
  → 用户检查来源与正文
  → BYOK 总结或翻译
  → 本地保存
  → Markdown 导出
```

云端、账号和同步不在这条链路中。任何未来云服务都不得成为打开本地数据或运行 BYOK 的前置条件。

## 5. P0 范围

### 5.1 必须完成

- macOS SwiftUI APP 可以启动、退出并恢复主窗口。
- Chrome、Brave、Edge 扩展可以读取用户主动触发的当前页面。
- 扩展发送 URL、标题、选区、正文、字符数和捕获证据。
- Native Messaging 可以完成握手、版本检查、超时和错误返回。
- APP 创建 `Task` 与 `ContentSnapshot`，展示来源、正文和完整性。
- 支持一个 OpenAI-compatible Chat Completions 模型连接。
- API Key 只写入 Keychain，界面、日志和导出不回显完整值。
- 支持总结、翻译、停止、重试和保存部分结果。
- SQLite 保存任务、正文快照、运行记录和结果。
- 支持打开历史、删除单项和导出 Markdown。
- Cloud API 完全不存在或断网时，以上能力仍可使用。

### 5.2 明确不做

- Windows、iPhone、iPad、Safari 扩展。
- 账号、登录、设备管理、订阅和托管模型。
- 云同步、端到端加密同步和团队协作。
- Cookie 读取、付费墙绕过、验证码绕过或批量账号采集。
- YouTube/B站字幕、`yt-dlp`、`ffmpeg`、Whisper 和媒体下载。
- 小红书、抖音、X 等专用适配器。
- 批量导入、批量总结、PDF/HTML 导出。
- 远程配置、遥测平台、微服务和百万用户容量部署。
- 为未来 Windows 提前牺牲 macOS 体验。

问答不属于已确认的 P0 必做项。它可以在 P0 本地闭环稳定后作为候选能力重新评估，但不得反向扩大 V0.1–V0.4 的当前范围。

## 6. v0.1 垂直链路

第一条链路只证明最危险的跨进程交接，不同时解决所有产品能力。

```text
固定测试文章
  → Chromium 扩展提取正文
  → service worker 调用 Native Messaging
  → macOS APP 接收并校验 CaptureEnvelopeV1
  → SwiftUI 界面显示标题、URL、正文和字符数
```

详细验收与失败恢复见 `docs/specs/V0.1_VERTICAL_SLICE.md`。

## 7. 后续里程碑

| 里程碑 | 用户可观察结果 | 本阶段不做 |
|---|---|---|
| V0.1 交接 | 当前页正文出现在 Mac APP | 模型、数据库、漂亮 UI |
| V0.2 BYOK | 用户能配置模型并获得流式总结 | 多 Provider、账号、云端 |
| V0.3 本地历史 | 02A/02B 已通过独立复审：领域、Repository、启动恢复、当前 Capture/Run 落库与失败后禁写已关闭；历史浏览 UI 尚未开始 | 同步、全文搜索优化 |
| V0.4 导出与打磨 | 可导出 Markdown，完成原生交互打磨 | 媒体、批量处理 |
| V0.5 发布验证 | 签名、公证、更新和扩展安装链路可复现 | Windows、App Store 承诺 |

只有本地闭环经过真实使用后，才重新评估账号、同步、托管额度和云端容量。

## 8. 关键界面

### 8.1 主窗口

```text
+----------------------+------------------------------------------+
| 任务列表              | 当前任务                                  |
|                      | 来源 / 捕获方式 / 完整性                  |
| 今天                  | 标题与原网页                              |
| · 一篇测试文章         |------------------------------------------|
|                      | 结果 | 原文 | 执行记录                    |
|                      |                                          |
|                      | 当前内容                                  |
+----------------------+------------------------------------------+
```

主窗口使用 macOS 原生侧边栏与详情结构。视觉比例可以调整，但必须保留：任务列表、来源证据、原文、结果和执行记录。

### 8.2 扩展面板

扩展只承担：

- 显示当前页面是否可捕获。
- 展示标题、正文字符数和捕获范围。
- 发送“总结”“翻译”或“仅发送”。
- 显示 APP 连接、版本和发送结果。

历史、模型设置、导出和详细诊断只存在于 Mac APP。

## 9. 状态与失败语义

| 阶段 | 用户可见状态 | 主要恢复动作 |
|---|---|---|
| 页面捕获 | 可捕获、内容过少、受限页面 | 等待加载、选择文字、切换普通页面 |
| Native Messaging | 未安装、APP 未运行、版本不兼容、超时 | 打开 APP、重新检测、升级对应组件 |
| 正文 | 完整正文、当前可见、选区、未知 | 查看原文、重新捕获 |
| 模型 | 401、限流、协议不匹配、网络中断 | 更新 Key、切换模式、重试 |
| 存储 | 可写、只读恢复、保存失败 | 立即导出、备份、修复目录 |

APP 已运行时，Host 把校验通过的消息交给 APP，SwiftUI 更新当前页面状态。APP 未运行时，Host 不负责自动启动 APP，也不保存正文等待稍后处理；它返回 `APP_UNAVAILABLE`，并给出 `open_app` 动作，用户打开 APP 后重新发送。

错误对象至少包含：

```text
category / code / retryable / action / safeDetail
```

`safeDetail` 不得包含 API Key、Cookie、Token、完整私人 URL 或正文。

## 10. 数据边界

| 数据 | P0 默认位置 | 禁止 |
|---|---|---|
| API Key | macOS Keychain | SQLite、日志、测试夹具、导出、Git |
| 原文和摘要 | SQLite | 未经用户操作上传 LinkDigest 云端 |
| 捕获证据 | SQLite | 保存 Cookie 值或完整敏感 Header |
| 扩展设置 | 浏览器本地 storage | 保存模型秘密 |
| 导出文件 | 用户选择的位置 | 包含 Key、Cookie、Token 或本机秘密路径 |

## 11. 第一版验收指标

### 11.1 产品价值

| 指标 | 目标 | 验证方法 |
|---|---:|---|
| 首次价值时间 | 安装与模型配置完成后，5 分钟内完成第一条总结 | 新用户观察测试 |
| 固定样本任务完成率 | ≥ 90% | 20 条普通文章测试集 |
| 当前页正文可用率 | ≥ 80% | 人工核对标题、主体和结尾 |
| 失败恢复率 | ≥ 70% | 测试用户按提示完成重试 |
| 7 日复用 | 早期测试用户一周内再次处理链接 | 本地访谈记录，不默认上传遥测 |

### 11.2 摘要质量

每条验收摘要必须满足：

- 核心结论不与原文矛盾。
- 不把页面导航、评论或推荐区当作正文结论。
- 不捏造原文不存在的人名、数字、引用或因果关系。
- 用户能够切换到原文复核。
- 正文不完整时，结果明确标记信息来源与完整性。

P0 不承诺自动事实核查外部世界，只承诺摘要忠于本次捕获到的正文。

### 11.3 工程指标

| 指标 | 目标 |
|---|---:|
| 扩展面板打开 p95 | ≤ 500ms |
| 固定 20,000 字页面捕获 p95 | ≤ 2s |
| Native Message 到 APP 展示 p95 | ≤ 1s |
| 停止模型流响应 | ≤ 500ms |
| 10,000 条本地历史查询 p95 | ≤ 300ms |
| 敏感信息扫描命中 | 0 |

指标必须在 Release 构建和固定夹具上测量；未测量时不得宣称达标。

## 12. 真实样本验证

进入 V0.2 前建立至少 20 条脱敏测试页面：

- 10 条普通静态文章。
- 5 条客户端渲染文章。
- 3 条登录后但用户已合法可见的页面。
- 2 条故意失败的受限或正文不足页面。

每个样本记录：预期标题、正文起止、最低字符数、完整性标签和允许的降级路径。真实账号内容不得进入仓库夹具。

## 13. 已知未知项

- 正式产品名、商标、域名和图标。
- Swift SQLite binding 的最终选择与签名兼容性。
- Native Messaging Host 的安装、升级、卸载和公证体验。
- 首发使用公证 DMG 还是 Mac App Store；P0 不承诺 App Store。
- SwiftUI 富文本显示和结果编辑是否需要 AppKit 桥接。
- OpenAI-compatible 端点之间的流式协议差异。
- Chrome Web Store 当前审核与隐私披露要求。

以上未知项通过小型 spike 或真实样本验证解决，不通过扩大架构解决。

## 14. 文档真相源

| 主题 | 唯一真相源 |
|---|---|
| 产品范围、优先级、验收 | `docs/PRD.md` |
| V0.1 交接实现 | `docs/specs/V0.1_VERTICAL_SLICE.md` |
| 当前组件边界 | `docs/ARCHITECTURE.md` |
| 远期容量假设 | `docs/CAPACITY_MODEL.md` |
| 当前依赖和许可证 | `docs/DEPENDENCIES.md` |
| 耐久决策与反转原因 | Project Brain，经 `./scripts/brain` 读写 |
| 实际行为 | 代码、测试和构建产物 |

当文档与代码冲突时，已运行的代码描述当前事实，PRD 描述期望；必须显式标记差距，不能静默选择一方。
