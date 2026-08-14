# LinkDigest PRD

> 状态：V0.1–V0.4 工程链已按各自证据收口。浏览器辅助视频路线的 M0 与 M1 已完成本地工程实现和自动验证：M1 新增独立 V2 合同、通用视频能力分类与 V2→History 正文接线，但尚未实现远程播放、收藏、临时转写媒体或云 ASR。Loop 4 r1/r2/r3/r4a 已最终独立工程复审 PASS；r4b local-test ad-hoc DMG 也已独立 PASS 0/0/0 并 finalize，当前为 **READY_FOR_MANUAL_OPEN，等待 Syc 手工启动**。这不代表公开发布；产品仍 BLOCKED，真实 Host 安装、Developer ID、正式签名、公证、stapling、浏览器验收和发布仍未完成。
>
> 本文是产品范围、优先级和验收标准的唯一真相源。技术组件见 `docs/ARCHITECTURE.md`；第一条链路见 `docs/specs/V0.1_VERTICAL_SLICE.md`；V0.2 工程证据见 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`；远期容量假设见 `docs/CAPACITY_MODEL.md`。

> **范围与当前实现说明**：本文的 P0 是第一版产品目标，不代表当前代码已经实现全部 P0。V0.1、V0.2、V0.3/02A–02C 与 Loop 2 的完成状态以各自验收证据为准。Loop 3 的数据去向确认/`connectionTest` 已最终独立复审 PASS。Loop 4 r1 的 56 项 deterministic check 与最终独立 re-review 已 PASS，P0/P1/P2 均为 0。r2 新增 permanent pre-provisioned clean-room lock、plan digest、receipt v2 ownership/lineage、transaction journal、receipt commit point、initial/v1 migration/upgrade/uninstall/recover。首次 r2 final review 的三项 P1 已通过命名空间双向 overlap 拒绝、r1 canonical 0.1 + transaction 显式 expected version、strict journal plan schema + malformed exit 8 修复；110 项 fast gate、56 项 r1 compatibility gate 与同一 reviewer 唯一 re-review 已 PASS，P0/P1/P2 = 0/0/0。所有 mutation 仅限 `/private/tmp` clean-room。checksum 只证明一致性，不代表签名或发布真实性；真实安装、签名、公证和发布仍需另行授权。

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
5. 原文、结果和执行证据保存在本机，并可导出为 Markdown、纯文本或 JSON。

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
- 无目标视频的纯文本页面继续发送 V1；检测到目标视频后发送独立 `CaptureEnvelopeV2` 与 `MediaDescriptor`，支持 direct MP4/MOV、HLS、blob/MSE、未加载、DRM/不支持类型与多视频歧义的真实能力分类。
- Native Messaging 可以完成握手、版本检查、超时和错误返回。
- APP 创建 `Task` 与 `ContentSnapshot`，展示来源、正文和完整性。
- 支持一个 OpenAI-compatible Chat Completions 模型连接。
- API Key 只写入 Keychain，界面、日志和导出不回显完整值。
- 首次向某个模型目的地发送网页标题和正文前，显示 Base URL/host、模型、模式与本地数据边界；取消不得创建 Run 或调用 Provider。
- 设置页可用极短 `Reply with OK.` 请求测试当前连接，明确可能产生极少模型用量，不创建 History/Run/Artifact 或保存回复。
- 支持总结、翻译、停止、重试和保存部分结果。
- SQLite 保存任务、正文快照、运行记录和结果。
- 支持打开历史、删除单项和导出 Markdown、纯文本（`.txt`）和 JSON。
- 手动公开链接按三分流生产实现：普通公网且无显式系统代理使用 `PeerBoundNetworkWebPageFetcher` / `Network.framework`，它把 policy 已核验的 numeric IP 绑定为实际 peer，并保留原 hostname 的 HTTPS SNI、`SecPolicyCreateSSL`、HTTP Host、system trust 与禁用 trust 网络补取；显式系统 HTTP(S) 代理或 DNS 全部返回 `198.18.0.0/15` fake-ip 时使用 `SystemProxyWebPageFetcher`。系统代理是**独立信任边界**：Foundation/代理可能重新解析 hostname，本机 URL/DNS admission 不能证明代理实际 peer，因而不宣称与 PeerBound 等价，剩余 proxy-resolution SSRF 风险由系统代理/VPN 所在环境承担。代理路线仅接受 HTTPS，拒绝 HTTP 并提示使用浏览器扩展；两路线均在每次 redirect 重新检查 URL、私网/test-net、凭据 URL、标准端口与 HTTPS→HTTP 降级。`URLSessionWebPageFetcher` 仍为 test-only legacy，不是 production fallback。
- Cloud API 完全不存在或断网时，以上能力仍可使用。

### 5.2 明确不做

- Windows、iPhone、iPad、Safari 扩展。
- 账号、登录、设备管理、订阅和托管模型。
- 云同步、端到端加密同步和团队协作。
- Cookie 读取、付费墙绕过、验证码绕过或批量账号采集。
- 后台剪贴板监听、任意网页 WebView 执行、用户浏览器 Profile/凭据导入或对登录页的手动抓取。
- YouTube/B站字幕、`yt-dlp`、`ffmpeg`、Whisper、M1 自动媒体下载和远程播放。
- 小红书、X、YouTube 等新平台专用媒体适配器；M1 的抖音只读取当前 DOM 的公开 `video/source` 与页面 metadata，不请求私有详情端点。
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
| V0.3 本地历史 | 02A/02B 已通过独立复审；02C 已完成 History Sidebar、分页、详情、删除、重启读取与 future-schema 只读浏览 | 同步、全文搜索优化 |
| V0.4 导出与打磨 | Loop 2 已完成单条 Markdown、`.txt`、JSON 本地导出与原生保存面板；Loop 3 数据去向/连接测试与最终独立复审已完成 | 媒体、批量处理 |
| V0.5 发布验证 | r1/r2/r3/r4a 已独立工程 PASS；r4a re-review 0/0/0，但 unsigned artifact 与 malformed manifest 使产品继续 BLOCKED | Developer ID、公证、stapling、真实安装/浏览器验收、Windows、App Store 承诺 |
| 视频 M1 合同与识别 | V1 保持兼容；V2 能把通用媒体能力经 Host 交给 APP，正文进入 History，临时播放地址只留当前进程内存 | 播放、下载、收藏、ASR、PromptPreset、新平台适配与真实样本 |

只有本地闭环经过真实使用后，才重新评估账号、同步、托管额度和云端容量。

历史详情会显示实际保存的操作、模型、时间、状态和服务商在流尾提供的 Token 用量；历史旧 run 没有 usage 时显示“—”。BYOK 模型没有可验证且持续有效的统一价格表，因此“估算费用”从路线图裁剪：产品不估算、不显示费用，避免把不可靠数字伪装成账单事实。

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
| 发送确认记录 | 本机 UserDefaults，仅含规范化 Base URL、host、模型、API 模式 | API Key、Keychain reference、正文、标题、运行记录 |
| 原文和摘要 | SQLite | 未经用户操作上传 LinkDigest 云端 |
| 捕获证据 | SQLite | 保存 Cookie 值或完整敏感 Header |
| 扩展设置 | 浏览器本地 storage | 保存模型秘密 |
| 导出文件 | 用户选择的位置 | 包含 Key、Cookie、Token 或本机秘密路径 |
| 批量 Markdown 导出 | 用户选择文件夹内的带时间戳子目录 | 覆盖同名条目、阻塞主线程、夹带 Key/Cookie/Token |
| 整库备份 | 用户选择位置的单个 `.linkdigestbackup` 文件；仅含一致 SQLite 快照与 App 内部媒体 | Keychain、站点 Cookie、外部用户文件、运行中的 WAL/SHM |
| 诊断包 | 用户主动选择位置的 zip；仅含版本/build、macOS、基础运行信息和近期本 App 崩溃报告 | 历史正文/摘要、完整 URL 列表、API Key、Cookie、Token、自动上传 |

整库恢复是覆盖性操作：所选备份必须先通过 manifest、SHA-256、SQLite integrity/foreign-key/schema 校验；随后自动把当前资料库另存为独立备份。真正替换只在 App 退出并重新启动、SQLite 尚未打开时执行，安装失败则回滚当前库。

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
- r4a 已在 `/private/tmp` 建立并独立复审通过 unsigned App-DMG release-unit binding；r4b local-test ad-hoc DMG 已独立 PASS 并放入 `release/LinkDigest-0.1.0-local-test/`，等待 Syc 手工打开。Chrome/Edge manifest 当前为 malformed，且 Developer ID、notarization/stapling、真实 Host 安装与浏览器验收未完成，产品和公开发布继续 BLOCKED。
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
