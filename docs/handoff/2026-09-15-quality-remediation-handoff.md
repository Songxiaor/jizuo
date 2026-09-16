# 汲作 质量整改 交接文档（2026-09-15）

> 给下一位接手的 Agent（Pi Agent / deepseek、Grok 或任何模型）。读完本文即可继续，不需要看对话记录。
> 用户是 Syc，AI 产品经理新手，默认中文沟通，先讲结果和用户影响，术语一句话解释。

## 0. 一分钟看懂现状

- 工作副本：`/Users/song/.superconductor/worktrees/link-summary-app/mcp-preview-release`，分支 `release/creator-workflow-0.2.26`，**工作区有 100+ 个未提交文件，全部是今天的成果，不要 stash / checkout / reset / commit / push**（提交需要 Syc 明确授权）。
- 正在运行的 App：`/Users/song/Applications/汲作.app`，是今天 18:55 部署的版本（性能优化第二轮，含数据库迁移 021/022）。之后的整改（本文第 3 节）**尚未部署**。
- 每次部署前都做过备份，最近的：App `~/Applications/汲作.backup-round2-20260915-185523.app`，数据库 `~/Library/Application Support/LinkDigest/history.sqlite.backup-pre-m021-20260915-185523`。
- 今天完成并已部署的：性能审计 + 两轮优化（启动、渲染、数据库、网络、内存、Observation 迁移、FTS 全文索引、媒体目录治理等）。详情见对话产出的两份报告，要点在第 1 节。
- 今天启动但**未完成**的：五路并行的「质量整改」（第 3 节），因用户额度告急被中途叫停。各路停在能编译的安全点，进度见第 4 节（由各路自报）。
- 接手后第一件事：**先构建、再跑测试，确认当前树是绿的**（第 5 节命令）。若不是，先修到绿，再继续第 3 节剩余项。

## 1. 今天已完成并部署的内容（不用再做）

性能：启动路径并行化与延后；详情页派生值缓存；侧栏平台图标查表；搜索框独立草稿；`reload` 不刷聚合；三个巨型模型（HistoryViewModel / AppViewModel / ProviderSettingsViewModel）从 ObservableObject 迁到 `@Observable`；非流式回包连续缓冲；域名解析异步化（一次抓取只解析一次）；流式输出脱敏器只返回增量；编辑器局部着色 + 40ms 合并；音频分片流水线 + 429 重试 + 磁盘流式上传；socket accept 事件驱动；数据库 PRAGMA synchronous=NORMAL / cache_size；Migration021（tasks.content_kind / normalized_host + 索引）；Migration022（FTS5 trigram 全文索引，转写稿可搜）；媒体目录孤儿扫描与总容量上限（默认关）。

产品：B 站发布时间与播放量；导入面板头部合并、平台图标；博主目录页头/分组/卡片；删除博主；工具栏上下条按钮移入「···」；隐藏手机同步入口；模型服务列表行控件；设置「视频存储」新增治理控件。

已知环境事实：
- Xcode 今天升级到 27.0。SwiftPM 资源包改为嵌套布局，测试路径的兼容已做（CoreResourceBundle / JSONSchema 的定位逻辑，**不要动**）。
- 两条并发测试在新工具链下永久挂起（基线也挂）：`testConcurrentCaptureFailureLinearizesBeforeSecondRepositoryAuthorization`、`testQueuedCaptureCancellationDoesNotRunWriteOperation`；跑 App 测试包必须 `--skip` 它们。`HistoryGalleryGeometryTests/testSidebarBoundsMatchNativeNavigationContainer` 在基线也失败，可忽略。第 3 节第 5 路的任务之一就是修这几条。
- 界面审查时误点侧栏「今天」新建了一条空笔记「2026-09-15」，**未删除**，等 Syc 确认；这本身是第 3 节第 2 路要修的问题。

## 2. 三个已定的默认决策

1. 对象统一叫「内容」（侧栏组名「资料」改「内容」）。
2. 自动总结保持默认关闭，但「待总结」页给带预估与二次确认的批量入口。
3. 误建的空笔记不动。

统一词表（所有面向用户文案按此）：
- 对象：内容（博主视角下「作品」可保留）。
- 动词：抓取 = 从网页取回；保存 = 收进汲作；下载到本机 = 视频文件落盘；收藏 = 仅加星。
- 转写 / 转写稿 / 整理；字幕 OCR = 读取画面字幕；总结（不叫摘要）。
- 工程词对照：Base URL → 服务地址；API Key → 密钥；MCP 连接 → AI 助手接入；孤儿文件 → 没被任何内容用到的视频；Provider → 模型服务；工件 → 安装文件；manifest → 安装清单。
- 错误文案模板：发生了什么 + 数据安不安全 + 现在能做什么，三句一条，永远带一个动作。

## 3. 五路整改任务书（原样保留，按文件归属互不重叠）

并行原则：每路只改自己拥有的文件；构建目录 `.build` 共用，SwiftPM 会排队等锁；构建错误若出现在别人文件里是中间状态，等 1 到 2 分钟重试；不部署、不提交、不碰真实数据目录 `~/Library/Application Support/LinkDigest/`。

### 第 1 路：数据安全、持久化与启动治理
拥有：`LinkDigestPersistence/*`；`LinkDigestCore/HistoryRepository.swift、HistoryApplicationService.swift、HistoryModels.swift、HistoryTags.swift`；`LinkDigestApp/LinkDigestApp.swift、ExperimentalFeatures.swift、AppUpdateController.swift、ReadingContinuity.swift`；新建 `LinkDigestApp/DataBackupSettingsView.swift`；`ProviderSettingsView.swift` 仅两处最小改动（注册新分栏、手机同步开关）。只有本路可新增迁移（从 023 起）。

1. 升级前自动备份 + 设置页「数据与备份」分栏（立即备份 / 备份列表 / 从备份恢复（二次确认，重启）/ 打开备份文件夹）。备份到同目录 `backups/history-v<旧版本>-<时间戳>.sqlite`，保留最近 3 份，迁移失败保留备份并在只读原因里带路径。
2. 手机同步上锁：`ExperimentalFeatures.isCompanionSyncOffered`（默认 false）；分栏可见性与启动同步只看它，且启动同步还要用户在设置里明确打开过（默认 false，不再用 entitlement 当默认值）。
3. Sparkle：`updater.automaticallyDownloadsUpdates = config.automaticallyUpdates` 显式应用；测试改成真实属性断言；`SUEnableAutomaticChecks` 在两条打包路径统一处理。
4. 软删除与回收站（数据层）。Migration023：`tasks.deleted_at_ms INTEGER`（NULL = 未删）+ 部分索引。接口签名必须一字不差：
   - `func moveToTrash(taskIDs: Set<TaskID>) throws`
   - `func restoreFromTrash(taskIDs: Set<TaskID>) throws`
   - `func purgeTrash(olderThanDays: Int) throws -> Int`
   - `func trashCount() throws -> Int`
   - `HistoryListFilter.scope` 增加 `.trash`；其它 scope、搜索、计数、博主作品页、召回、FTS 都排除已删除；`HistoryNavigationCounts.trash: Int`；`deleteTasks` 保留为永久删除；启动 bootstrap 后台调一次 `purgeTrash(olderThanDays: 30)`。
5. 阅读进度进库：Migration023 建表 `reading_progress(task_id PK REFERENCES tasks ON DELETE CASCADE, position REAL, updated_at_ms)`；Core 加 `ReadingProgressStore` 协议；`ReadingContinuity` 改走注入 store，对外接口不变；首次运行迁入 UserDefaults 旧值并删 key。
6. 口径：待总结 = 没有任何一次 kind = summarize 且 completed 且带 artifact 的运行；`HistoryRowProjection.hasSummary` 同口径；「最近」= 按 `created_at_ms` 最近 7 天。
7. 迁移矩阵测试：v20/v21/v22/v23 各造样本库跑到最新，逐表断言。
8. 小修：`Dictionary(uniqueKeysWithValues:)` → `uniquingKeysWith`；修正 `docs/AGENTS.md` 三条过期事实与 `docs/SOURCE_ADAPTER_STANDARD.md` §3。

### 第 2 路：主界面（侧栏、列表、详情、笔记、剪贴板）
拥有：`HistoryContentView.swift、HistoryViewModel.swift、HistoryRowView.swift、UIReadingHistoryRow.swift、HistorySkeletonRow.swift、ManualLinkViewModel.swift、AnnotationSectionView.swift、TagPillFlow.swift、HistoryWindowChrome.swift`，`MarkdownEditorView.swift` 仅保存反馈相关。

A. 静默失败改可见：HistoryViewModel 约 6253（AI 稿件写回）、5826、5832、6055/6074、2468 行的 `try?` 改 do/catch 并写入 failure 字段。
B. 待总结与最近：绿点与引导用 `hasSummary`；侧栏「待总结」取消强调底色；「最近」改「最近 7 天」；待总结页顶部横幅「自动总结当前已关闭」+「总结前 20 条…」（确认框显示条数、模型名、会消耗用量，复用 `requestBatchSummary`）。
C. 列表：画出预览行；悬停露出 收藏/总结/更多；日期前缀「发布 / 存于」；合并两份重复右键菜单并补齐 收藏/标签/总结/删除（删除 destructive + danger 色 + 独立分区）；错误态三句模板 + 动作；「待分类」统一为「其他」。
D. 详情页：指标缺失就隐藏 + 中文单字标签；「AI 处理」按钮按内容宽度；专注阅读图标换语义准确的；齿轮 label/help 统一「打开设置」；「大小」显示当前字号 + 恢复默认；「···」删除独立分区 danger 色并纳入收藏/标签；笔记·标签栏提到顶部信息区下方（可折叠）；正文加顶部安全内边距或工具栏不透明；「[已省略 HTML 片段]」改「（此处内容无法显示）」；区块标题统一；模型未配置时常驻「还没配置模型 · 去配置」，批量项灰掉给原因。
E. 笔记与今天：「今天」改带 plus 的按钮样式，当天已有则只打开；笔记标题「9月15日」格式；副标题改首行预览；编辑器右下「已保存 · HH:mm」+ 字数。
F. 剪贴板横幅：浮层不挤压布局；忽略持久化（链接哈希）；读 `UserDefaults.standard.bool(forKey: "capture.clipboardLinkDetectionEnabled")`（不存在视为 true）。
G. 无障碍：列表行补「按下」；内容列表 label「内容列表」；「AI 处理」label；影院关闭按钮「关闭全屏」。
H. `HistoryContentView.swift` 约 1978 行 `uniqueKeysWithValues` 改 `uniquingKeysWith`；硬编码字号换 `themedFont`。
回收站界面：侧栏「内容」组末尾「回收站」（计数 0 隐藏）；删除改为移入回收站（确认文案「移到回收站，30 天后自动清理」）；回收站视图右键「恢复」「彻底删除」（二次确认）。

### 第 3 路：设置文案、确认与视觉一致性
拥有：`ProviderSettingsView.swift`（文案，最小改动）、`ProviderSettingsViewModel.swift、SettingsCard.swift、BrowserSupportSettingsView.swift、BrowserSupportViewModel.swift、SiteLoginSettingsView.swift、SiteSessionController.swift（仅文案）、MCPSettingsView.swift、KnowledgeVaultSettingsView*.swift、MediaStorageSettingsView*.swift、CompanionNoteSyncSettingsView.swift、AppearanceTheme.swift、DesignTokens.swift、AppButtonStyles.swift、AppComponents.swift、StorageErrorPresentation.swift、V02ErrorPresentation.swift、CapabilityConsent.swift`、Core 里纯错误文案。不碰 `AppUpdateSettingsView.swift`。

1. 文案去工程化（按词表）；繁体「併入」改「并入」；错误目录里指向不存在的「维护入口」改为指向「数据与备份」。
2. 危险操作加确认：清除登录、删除这 N 个文件、恢复默认文件夹、清除授权记录、重置为默认提示词、断开。
3. 危险色与按钮层级：删除/清除/重置类用 `theme.danger`（AppButtonStyles 加 danger 样式）；绿色实心主按钮只用于新建/开始；系统蓝改主题色。
4. 细节：设置窗口默认 960×720；浏览器支持页矛盾状态统一；「总结模型」补 ⓘ；「图片识别」只读样式；外观页字体预览用示例文字；生成偏好页加开关「切回汲作时检测剪贴板里的链接」绑定 `capture.clipboardLinkDetectionEnabled`。
5. 硬编码字号换 `themedFont`，页面标题跟随系统字号。
6. 修回 `GenerationSettingsPresentationTests.swift:26` 那条 XCTSkip。

### 第 4 路：播放器、图库、博主页、导入面板、媒体安全
拥有：`HistoryMediaPlayback.swift、SessionMediaPlaybackController.swift、YouTubeEmbedPlayer.swift、ArticleInlineVideo.swift、PlatformHistoryGallery.swift、XPostGallery.swift、WeChatArticleGallery.swift、CreatorDirectoryViews.swift、CreatorWorkCardLayout.swift、CreatorWorkEngagement.swift、DouyinProfileImport.swift、ProfileImportBatchViews.swift、MarkdownPresentation.swift、WorkThumbnailLoader.swift、PlatformGridView.swift`；`LocalMediaStore.swift` 仅加安全抓取调用点。

1. 媒体下载走 `SafeResourceFetching`（HistoryMediaPlayback 约 698、721 行；YouTubeEmbedPlayer 一处），保持流式落盘；补测试：私网地址被拒。
2. 「此处暂不可播」卡：直说「在线播放地址每次打开都要重新取一次，不会保存到本机」；按钮降次级；warning 淡底；播放器控件与影院关闭按钮补 accessibilityLabel。
3. 图库/博主页：图库页头「返回内容列表」；排序控件主题色；「抓取顺序」→「发现顺序」；「抓取作品」次级 + 确认；「更新资料」→「刷新博主信息」；黑帧占位；空博主卡「去抓取」；卡片 accessibilityLabel；计数口径「已保存 N 条内容」。
4. `DouyinProfileImport.swift` 约 971、1221 行与 `MarkdownPresentation.swift` 约 153 行 `uniqueKeysWithValues` 改 `uniquingKeysWith`。
5. 硬编码字号换 `themedFont`。

### 第 5 路：可观测性、扩展合同、发布链、测试可靠性
拥有：Core `Models.swift、ModelRunOrchestrator.swift、ManualLinkCapture.swift`，新建 `AppLog.swift`；Adapters `OpenAICompatibleProvider.swift、*Fetcher*.swift、LocalMediaStore.swift（只加日志）`；App `CaptureReceiver.swift、CaptureIngestService.swift、AppUpdateSettingsView.swift`，新建 `DiagnosticsExport.swift`；`MCPProtocol.swift`；`Framing.swift`；`apps/browser-extension` 全部；`scripts/*`；`.github/workflows/*`；指定测试文件。

1. `AppLog`（os.Logger，subsystem `com.syc.linkdigest`，category capture/provider/media/storage/extension，绝不记正文、完整 URL、密钥）；在抓取、模型、媒体、门禁四条链路打点；`DiagnosticsExport`（`log show` 最近 2 小时 + 版本 + 模型服务显示名 + 成败计数，存用户选择位置）；本地成败计数 `diagnostics/capture-outcomes.json`；「版本与更新」页加「导出诊断信息」「反馈问题」（mailto，收件地址若无配置留 `feedback@` 占位，需 Syc 填）。
2. 合同：`PROTOCOL_VERSION_UNSUPPORTED` → `action: "upgrade_app"`，requestID 用真实值；扩展 popup 对 `upgrade_app` 显示「打开汲作检查更新」；popup/main.ts 约 276、349、482 三处裸 catch 修正；background.ts 不塌缩错误码；`openApp` 响应带支持版本列表做协商；Models.swift version ≥ 3 先尝试降级；扩展字数校验改按 UTF-8 字节与 4MB 对齐。
3. 发布链：`sync-contracts.sh` 补拷 `native-response-fixtures.json`；CI 加 `git diff --exit-code apps/browser-extension/src/generated/`；`package-dmg.py` 生成 `SHA256SUMS.txt`；`scripts/doctor` 加 `set -euo pipefail`；`prepare-ci-tools.sh` 钉 ripgrep；新增 `docs/RELEASE_KEYS.md`；`MCPProtocol.swift:11` 去掉 `try!`。
4. 测试可靠性：两条 DNS 挂起测试改 CheckedContinuation + 5 秒超时；全 Tests 无超时 `await task.value` 加超时辅助；查明并修复两条 App 包永久挂起的并发测试；`HistoryGalleryGeometryTests` 改断言自绘 marker；快照测试基础设施（NSHostingView → PNG 比对，无第三方依赖）并替换 3 条最脆的源码字符串断言。

## 4. 各路停止时的进度（由各路自报，接手前务必核对 `git status` 与构建）

> ⚠️ 本节写于 20:14，**已大面积过期**：下面「未完成」里的绝大多数条目已在 20:14–22:00 之间做完。判断进度请看文末第 7 节的实测复核，不要照本节行事。

停止时各路都报告「自己的文件能编译」。**已知的整包编译阻塞（接手第一件事）**：
- `Tests/LinkDigestAppTests/ReadingContinuityTests.swift:110` 缺 return（第 1 路改写该测试时的中间状态）。
- 曾报 `Tests/LinkDigestAppTests/ConcurrencyTestSupport.swift:105` 在异步上下文用了 `DispatchSemaphore.wait`（第 5 路新文件，后续可能已修）。
- `HistoryListScope` 新增 `.trash` 后 `HistoryContentView.swift` 里的 `switch` 需穷尽（第 2 路已补三处，再核对一次）。
修法：跑 `swift build` 与 `swift build --build-tests`，按报错逐个修到绿，再跑第 5 节测试。

### 第 1 路（数据安全）— 主体完成
已完成：DatabaseMaintenance 新增 `DatabaseBackupStore`（自动备份 3 份上限，手动备份不清）、`restoreInPlace`；LocalDatabase 升到 023，迁移前先备份、备份失败不升级直接只读；新建 `DataBackupSettingsView.swift`；`ExperimentalFeatures.isCompanionSyncOffered`（false）+ 启动同步需用户明确打开；Sparkle `automaticallyDownloadsUpdates` 显式应用；Migration023（`tasks.deleted_at_ms` + `reading_progress` 表）；回收站四个接口按签名齐备，`HistoryListScope.trash`、`HistoryNavigationCounts.trash`、`HistoryTrashPolicy.retentionDays = 30`，所有查询排除已删除，启动后台 `purgeTrash(30)`；`ReadingProgressStore` 协议 + GRDB 实现，ReadingContinuity 改走库并迁移旧 UserDefaults 键；「待总结」唯一判据 `completedSummarySQL`、`hasSummary` 同口径；「最近」按 `created_at_ms`；新增测试 DatabaseBackupTests(9)、HistoryTrashTests(10)、ReadingProgressStoreTests(6)、MigrationMatrixTests(2)、ReadingContinuityTests 改写。
未完成：**一条测试都没跑过**（被上述编译阻塞挡住）；`AppUpdateControllerTests` 仍是源码字符串断言，需改成对真实 `SPUUpdater` 属性断言；「开关关闭时不调用 synchronize」测试未补；`scripts/build-debug-candidate.py:237` 与 `release_unit.py` 的 `SUEnableAutomaticChecks` 统一未做（连带 `build-debug-candidate_check.py:104`）；`docs/SOURCE_ADAPTER_STANDARD.md:38` 及 §4 关于 `extractPageInIsolatedWorld` 双实现的过期说法未改（本副本的 AGENTS.md 没有那三条，无需改）。
需要接线：`LocalDatabase.readOnlyRecoveryHint`（含备份路径）需透出到只读提示条（`AppComposition.swift` / `HistoryViewModel.swift` / `HistoryWindowChrome.swift`）；`DataBackupSettingsView` 的恢复路径未实机验证。

### 第 2 路（主界面）— 约六成
已完成：6 处静默失败改可见；绿点改 `hasSummary`；「最近 7 天」；「待总结」取消强调；待总结横幅 + 「总结前 N 条…」确认框（复用 `requestBatchSummary(taskIDs:modelName:)`，新增 `canRunBatchSummary`）；列表预览行；悬停 收藏/总结/更多；日期前缀「发布 / 存于」；右键菜单合并为唯一 `historyContextMenu(for:)` 并补齐动作、删除独立分区 danger 色；三处错误态改三句模板并带动作；「资料」→「内容」；行 `accessibilityAction` 与「内容列表」标签；`uniquingKeysWith`；「[已省略 HTML 片段]」→「（此处内容无法显示）」（在 MarkdownPresentation.swift，越界 2 行）；VM 新增 `toggleFavorite(taskID:)`、`addTag(_:to:)`；`.trash` 三处 switch 已补。
未完成：**详情页整段 D 未落地**（指标隐藏 + 单字标签、AI 处理按钮 `.fixedSize()`、专注阅读图标 `rectangle.compress.vertical`、齿轮 label「打开设置」、字号菜单显示当前值 + 恢复默认、「···」补收藏/标签 + 删除 danger、顶部可折叠「笔记 · 标签」栏（不复用 AnnotationSectionView，避免抢 `ExcerptCaptureRouter.shared.handler`）、工具栏穿透、区块标题「正文」、模型未配置常驻提示）；剪贴板横幅已改浮层，但 ManualLinkViewModel 的忽略持久化与 `capture.clipboardLinkDetectionEnabled` 读取未做；回收站界面全部未做（侧栏项、删除改移入回收站、回收站右键恢复/彻底删除；VM 层 `moveToTrash` 等包装方法尚未加）；E 段（「今天」按钮、笔记标题日期格式、副标题预览、编辑器已保存反馈）全部未做；硬编码字号未换；影院关闭按钮标签未确认；`PlatformHistoryGallery.swift:201`「载入失败，点击重试」未改（归第 4 路）。
风险：本轮没跑测试，`HistoryContentViewTests`（2600 行源码断言）、`ThemeTypographyTests`、`SilentFailureGuardTests` 可能需同步更新断言。

### 第 3 路（设置）— 基本完成
已完成：文案去工程化（服务地址/密钥/AI 助手接入/安装清单/连接文件/没被任何内容用到的视频 等）；`V02ErrorPresentation` 28 条重写；6 处危险操作确认 + `appDestructive(theme.danger)`；9 处系统蓝改主题色；窗口 ideal 960×720；浏览器支持矛盾状态拆开；「总结模型」ⓘ；「图片识别」只读样式；字体预览示例文字；生成偏好新增剪贴板检测开关（`@AppStorage("capture.clipboardLinkDetectionEnabled")`，键常量 `ProviderSettingsView.clipboardLinkDetectionKey`）；页头字号 `themedFont(.title3)`；`GenerationSettingsPresentationTests` 修回真断言；新增 9 条约定测试。
未完成：繁体「併入」→「并入」（`HistoryWindowChrome.swift:114` 用户可见，`ManualLinkViewModel.swift:618` 注释；归第 2 路文件）；`StorageErrorPresentation.swift`、Core 的 `TranscriptionTempStoreError` / `ManualLinkError.userMessage` 未改（可选）；改动后的 filter 测试未跑成（被编译阻塞挡住）。

### 第 4 路（播放器与图库）— 汇报未到
接手前用 `git diff --stat -- apps/desktop/Sources/LinkDigestApp/HistoryMediaPlayback.swift apps/desktop/Sources/LinkDigestApp/PlatformHistoryGallery.swift apps/desktop/Sources/LinkDigestApp/CreatorDirectoryViews.swift apps/desktop/Sources/LinkDigestApp/DouyinProfileImport.swift apps/desktop/Sources/LinkDigestApp/YouTubeEmbedPlayer.swift` 看它动了什么，对照第 3 节第 4 路任务书判断剩余。

### 第 5 路（可观测性与合同）— 约四成
已完成：`LinkDigestCore/AppLog.swift`（os.Logger，五个 category，`redact()` 六道脱敏，`host()`）；`LinkDigestApp/DiagnosticsExport.swift`（`CaptureOutcomeStore` 计数文件、`DiagnosticsReport`、`FeedbackMail`、`DiagnosticsExportAction`）；`CaptureIngestService` 三处日志 + 计数；Models.swift version ≥ 3 先尝试降级；`ConcurrencyTestSupport.swift`（BlockingWorkExecutor、awaitValue/withTimeout/awaitSignal 5 秒超时）；两条 App 包挂起测试已改为不阻塞协作线程（根因：写事务闭包里的 `DispatchSemaphore.wait` 按住唯一协作线程）；两条 DNS 测试改 CheckedContinuation + 超时（它们本来就通过，属防回归）。
未完成：`AppUpdateSettingsView` 的「导出诊断信息」「反馈问题」两个按钮；Provider / Orchestrator / LocalMediaStore / fetchers 的日志打点；AppLog 脱敏与计数文件测试；修好的四条测试尚未实跑；`HistoryGalleryGeometryTests` marker 改写；快照测试基础设施与 3 条替换；扩展侧全部（`upgrade_app` 文案、三处裸 catch、`native_error` 塌缩、openApp 版本协商、UTF-8 字节校验）；CaptureReceiver `upgrade_app` 映射与真实 requestID；`MCPProtocol.swift:11` 的 `try!`；任务 3 发布链全部（sync-contracts、ci.yml diff 检查、SHA256SUMS、doctor 严格模式、prepare-ci-tools、RELEASE_KEYS.md）；扩展三样检查一次未跑。
需要 Syc 填：`config/app-release.json` 无支持邮箱，`FeedbackMail` 用 `feedback@` 占位。

## 5. 命令与验收流程

```bash
cd /Users/song/.superconductor/worktrees/link-summary-app/mcp-preview-release/apps/desktop
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | grep -E 'error:|Build complete'
# 非 App 包
swift test --filter 'LinkDigestCoreTests|LinkDigestAdaptersTests|LinkDigestPersistenceTests|LinkDigestTransportTests|LinkDigestMCPKitTests|LinkDigestNativeHostTests'
# App 包（跳过两条已知挂起）
swift test --filter 'LinkDigestAppTests' --skip testConcurrentCaptureFailureLinearizesBeforeSecondRepositoryAuthorization --skip testQueuedCaptureCancellationDoesNotRunWriteOperation
```

扩展（若改了 apps/browser-extension）：`CI=true pnpm vitest`、`CI=true pnpm tsc --noEmit`、`CI=true pnpm wxt build`，三样缺一不可。

部署（只在测试全绿后）：
```bash
ts=$(date +%Y%m%d-%H%M%S)
ditto ~/Applications/汲作.app ~/Applications/汲作.backup-$ts.app
osascript -e 'tell application id "com.syc.linkdigest" to quit'; sleep 4
db="/Users/song/Library/Application Support/LinkDigest/history.sqlite"
sqlite3 "$db" ".backup '$db.backup-$ts'"        # 有新迁移时必须
cd /Users/song/.superconductor/worktrees/link-summary-app/mcp-preview-release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/build-and-deploy-local.py --replace --skip-extension
open ~/Applications/汲作.app
sqlite3 "file:$db?mode=ro" 'pragma user_version'   # 应为最新迁移号
```

验收给 Syc 的方式：打开哪里、做什么、看到什么算通过；每项一条。启动探针在 `/private/tmp/claude-501/.../scratchpad/launch_probe`（临时目录，可能已清），不重要。

## 6. 硬性规则（来自项目 AGENTS.md，必须遵守）
- 不 git commit / push / stash / reset；dirty 工作区是基线，不清理无关修改。
- 数据库不手工 UPDATE；回滚只能整库换 `.backup` 副本。
- 不展示、不记录密码、API Key、Token、Cookie。
- 部署前备份 App 与数据库；同一时刻只允许一个 App 实例打开 history.sqlite。
- 扩展改完三样检查缺一不可；`OpenAICompatibleProvider.lowReasoningEffort` 必须是 `"low"`。
- 每次交付结尾给一行「FDE 视角」。

## 7. 2026-09-15 22:40 实测复核（第 4 节之后的工作已完成）

复核方式：读代码 + 真跑测试，不采信第 4 节的自报。

**全绿的部分**
- `swift build` → Build complete。
- 非 App 包（Core | Adapters | Persistence | Transport | MCPKit | NativeHost）→ **321 tests, 3 skipped, 0 failures**。
- App 包（带两条 `--skip`）→ **917 tests, 0 failures, 34 秒**，日志 `/tmp/forge-app-final.log`。
- 扩展三样：`CI=true npx vitest run` → 22 文件 / **380 tests 全过**；`npx tsc --noEmit` → exit 0；`npx wxt build` → success。

**第 5 路已全部落地**：`AppLog` 打点覆盖 `OpenAICompatibleProvider`、`ModelRunOrchestrator`、四个 `*Fetcher*`、`LocalMediaStore`、`CaptureIngestService`；`AppUpdateSettingsView` 有「导出诊断信息」「反馈问题」；发布链全齐（`docs/RELEASE_KEYS.md`、`package-dmg.py` 出 `SHA256SUMS.txt`、`sync-contracts.sh` 拷 `native-response-fixtures.json`、`doctor` 有 `set -euo pipefail`、`ci.yml` 有 `apps/browser-extension/src/generated/` 的 diff 检查、`prepare-ci-tools.sh` 钉 ripgrep 版本、`MCPProtocol.swift` 已无 `try!`）。

**第 2 路剩余项也已落地**：回收站接线完整（`HistoryViewModel.moveToTrash/restoreFromTrash`；`HistoryContentView.swift:944` 侧栏入口、:1773 彻底删除、:1856 移到回收站）；剪贴板开关被 `ManualLinkViewModel.swift:592` 读取；编辑器「已保存 · HH:mm」在 `HistoryContentView.swift:3316`；`HistoryGalleryGeometryTests` 改断言自绘 marker；快照基础设施 `SnapshotTestSupport.swift` + `SnapshotRenderingTests.swift` 已建。

**仍未完成 / 需要人**
1. 两条并发测试在 Xcode 27 工具链下**仍然永久挂起**：`CaptureReceiverTests.testConcurrentCaptureFailureLinearizesBeforeSecondRepositoryAuthorization`、`ManualLinkViewModelTests.testQueuedCaptureCancellationDoesNotRunWriteOperation`。`sample` 抓到的现场：XCTest 主线程停在同步等待，一条线程停在 `PersistenceWiringTests.swift:12` 的 `CommitBlocker.release.wait()`，第二个任务始终没拿到线程。`BlockingWorkExecutor` 没能解决，根因在 Swift 并发调度与 XCTest 同步等待的交互，暂按第 5 节 `--skip` 处理。
2. ~~整改尚未部署~~ → **已于 2026-09-15 22:04 部署完成**（0.2.28 / build 37）。备份：`~/Applications/汲作.backup-20260915-220103.app`、`history.sqlite.backup-20260915-220103`；迁移前自动备份落到了 `backups/history-v22-20260915-220444.sqlite`；`user_version` 22 → **23**，`reading_progress` 表与 `tasks.deleted_at_ms` 列均已建出；无崩溃报告，`log show` 无报错。扩展也已同步部署到 `~/Applications/LinkDigest-extension-0.2.0`（内容哈希与 `.output/chrome-mv3` 一致，旧版备份 `LinkDigest-extension-0.2.0.backup-20260915-220621`）——**扩展需在浏览器扩展页手动「重新加载」才生效**。
3. `config/app-release.json` 没有支持邮箱字段（`DiagnosticsExport.swift:255` 用 `feedback@` 占位），「反馈问题」按钮拼不出有效 mailto，需要 Syc 填。

**下次别再踩的坑**
- `swift test --filter` 在工程里**只匹配 target 名**：写类名（如 `ManualLinkViewModelTests`）会得到 0 tests。挑单条要写 `LinkDigestAppTests.SuiteName/testName`。
- 全量 App 包**不带 `--skip` 必定挂死**，并留下孤儿 `xctest` 进程、一直占着 `.build/.lock`；之后所有 `swift build` / `swift test` 都会阻塞，若再用 `timeout` 包着就表现为「完全没有输出」，看起来像会话卡死。挂死后先 `pgrep -fl xctest` 清进程。
