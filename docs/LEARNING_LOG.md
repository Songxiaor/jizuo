# LinkDigest 学习日志

学习日志记录“哪项任务工程上完成了、AI 在过程中解释了什么、哪里可以继续深挖”。它不是开发日报，也不是要求 Syc 课后答题的成绩单。

## 状态说明

- **工程进行中**：功能或文档仍在实施。
- **工程完成**：产物已经验证，场景、角色与交接、工作流和工具协同已在过程中讲解并留下入口。
- **可选深挖**：不是任务状态；Syc 对某个概念感兴趣或仍有疑问时，可另开小窗口学习，不阻塞主开发流程。

## 任务：设置页服务商原生化与官方图标

- 日期：2026-07-22
- 当前状态：**工程完成。** 服务商页已改用 macOS grouped Form；新增 5 条专项 XCTest 全部通过，并以真实 `NSImage` 光栅化路径产出九枚图标的对比 PNG。
- 用户场景：设置页需要让人先看懂哪些能力可用、再清楚选择服务商、最后填写连接信息；服务商不能只靠字母块辨认，也不能因为一个未知服务商而显示空白。
- 场景 → 角色与交接：`ProviderIconCatalog` 像本地的品牌索引卡，把九个固定 `ProviderPreset` 交给 App bundle 中的官方 SVG，并用独立 `NSCache` 保存 Retina 位图；缺少索引卡的自定义服务商改交给稳定的首字母和彩色圆形兜底。`ProviderSettingsView` 只消费这些显示结果，保留既有 ViewModel 的选择、Keychain 草稿清理、模型读取、保存和连接测试交接。`release_unit.py` 与 `local_test_release.py` 则把图标目录当成装箱清单的一部分，复制后逐项检查文件集、单链接与 SHA-256，最后把证据写进 release/local-test unit。
- 核心名词：**资源目录冻结（L3）** 是把“应该装进 App 的文件名集合”锁为精确清单，像出货箱里的逐项装箱单；多一个、少一个或名字变了都会拒绝发布。**Retina 光栅化（L2）** 是先按更高像素密度把 SVG 画成位图，再以 16pt 显示，像先用高清原稿印小标签，避免边缘发虚。**显示层兜底（L2）** 是品牌资源未知时仍给用户稳定的首字母和颜色；它不改变服务商连接逻辑，只保证界面不留空。
- 自动验证：`swift build --disable-sandbox` 通过；`ProviderSettingsPresentationTests` 5/5 通过，覆盖九个映射与精确资产集、同一 catalog 光栅化路径、未知/自定义首字母、无 `LazyVGrid`/旧卡片、Base URL 与 API Key 各一处行标签，以及两条发布脚本的冻结元组、资源复制、hash verifier 与证据绑定。完整 `swift test --disable-sandbox` 运行到 582 项，但环境中的 loopback/Keychain/disk-space 受限与既有 V2 链同时导致 60 条失败（44 unexpected）；本任务 5 条专项测试均通过。对比图位于 `/private/tmp/claude-501/-Users-song-Documents-Codex-link-summary-app/dfc89de3-ce8b-4499-8c65-bbc4b0798189/scratchpad/provider-icons-rendercheck.png`。
- 失败与恢复：首次 SwiftPM 因系统 Clang module cache 受沙箱保护而无法创建；将 `CLANG_MODULE_CACHE_PATH` 与 `SWIFT_MODULECACHE_PATH` 指向 `/private/tmp` 并使用 `--disable-sandbox` 后专项测试通过。`local_test_release.py check-config` 仍因本任务前已存在的 `AppIcon.icns` 冻结 hash 漂移拒绝，未修改该非本任务资产或其冻结值。
- 可选跟做（5–10 分钟）：在“模型与识别”中依次选择两个服务商，观察名称和说明可换行、选中状态只用系统 checkmark 表示；再选“自定义”，观察它仍有稳定首字母兜底。这个观察用于理解显示层与连接逻辑的分工，不是完成前置条件。

## 任务：R8 — 抖音身份证明与前台剪贴板链接

- 日期：2026-07-21
- 当前状态：**工程完成。** 扩展完整类型检查与 163 项 Vitest 通过；桌面端 build 与 10 条新增/受影响定向 XCTest 通过。
- 用户场景：抖音 feed/modal 的当前视频播放器有时不带自身 ID，导致发布时间与互动数据缺失；同时，用户从浏览器复制链接后，希望切回 App 直接看到可抓取提示，而不暴露其他剪贴板内容。
- 场景 → 角色与交接：扩展先锁定当前 `awemeId`，`safeItemScopes` 仍只接收显式且全匹配的身份范围；无身份范围只能由唯一、压倒性主视频证明进入 `dedicatedMetadataScopes`，再交给时间和四项 selector。桌面端 `LinkDigestApp` 只把 `.active` 事件交给 `ManualLinkViewModel`；后者只读一次剪贴板、把安全 HTTPS URL 归一化后交给 `HistoryRepository` 的精确 canonical 查询，未存在时才把安全候选交给 `HistoryContentView` 横幅，抓取按钮再复用既有微信 WKWebView/普通网页通路。
- 核心名词：**支配视频证明（L3）** 是“屏幕中只有一个主角”的保守证据：只有一个可见视频，或最大者至少是第二名四倍且占视口 20%；像确认一张照片里唯一占主体的人，不能确认就不取数据。**Canonical URL（L3）** 是去除 fragment、统一 host/默认端口后的稳定链接身份证；像把同一地址的大小写门牌统一，避免重复提示。**Fail-closed（L3）** 是历史查询失败、冲突身份或不安全 URL 时不提示也不抓取；像门禁查不到名单就不开门。
- 自动验证：`pnpm typecheck`、`pnpm test`（163/163）；新增或调整 Vitest 七条（含一个三行情形表）均以 `-t` 单独通过。Swift `swift build --disable-sandbox` 通过；新增或受影响的 `ManualLinkViewModelTests` 8 条、`HistoryContentViewTests` 1 条、`HistoryMigrationAndFaultTests` 1 条均以 `swift test --filter` 单独通过。
- 失败与恢复：dedicated 检查从播放器容器而非裸 `<video>` 开始；播放器本身冲突/含第二可见视频时拒绝，而更宽 wrapper 的冲突、第二视频或 121 个身份只停止向上，保留已证明的播放器范围。只有完整证明留下的 scope 才报告 `dominant_video_proof`，作者和结构化数值仍只读 `safeItemScopes`。非 URL、HTTP、凭据 URL、非标准端口、空值和历史查询失败不会进入 `@Published` 原文、日志或数据库；横幅显示后若历史已新增同一 canonical URL，或点击时复查查询失败，都会无网络/写入地关闭横幅。忽略只在内存中保留安全 canonical URL，剪贴板变内容后才允许再提示。
- 可选跟做（5–10 分钟）：复制一个 `https` 链接，切回 App 观察 History 顶部横幅；点“忽略”后保持剪贴板不变再切换窗口，横幅不会重现；换成另一个 URL 后再切回，横幅会重新出现。这个观察用于理解，不是完成前置条件。

## 任务：R7 — 公众号图片与来源元数据

- 日期：2026-07-21
- 当前状态：**完整闭环完成。** 已在外层系统沙箱外完成构建、全量测试与真实公众号链接验证。
- 用户场景：保存公众号文章后，正文图片应在原来的段落位置离线显示，且读者能看见公众号名、作者、发布时间和本地封面；图片失败不能让正文丢失。
- 场景 → 角色与交接：`WeChatWKWebViewCaptureService` 从已渲染的 `#js_content` 读取文字与图片标记，并把 `nickname`、作者、发布时间、封面交给 `WeChatWebCapturePolicy`。该策略像收货员，只复制类型和大小合规的字段，转换 `ct` 秒时间戳；随后把非结构化来源信息写进 Markdown frontmatter。`ManualLinkViewModel` 把允许图床的远程图片交给既有 `GitHubREADMEImageCache` 暂存，入库成功后提升为任务目录；`HistoryContentView` 再用哈希对应本地文件，正文图回到标记处、封面单独显示。
- 核心名词：**Frontmatter（L3）** 是正文顶部的一小段本地属性卡，像给文章附上的来源标签；没有它就要扩 SQLite 才能保存这类可选信息。**Staging / 暂存（L3）** 是入库确认前的临时图片仓，像结账前先放购物篮；保存失败或取消会清掉，成功才随任务保存。**Fail-open（L3）** 是图片增强失败时仍保存正文，像插图缺货不取消整本书。**DOM 顺序 walker（L2）** 按网页节点出现顺序走访，像按原页码把插图夹回段落而不是堆到最后。
- 技术取舍：不扩 `CapturedDocument` 或 SQLite schema；来源元数据写入版本无关的 Markdown frontmatter。图片仅允许 HTTPS 的 `mmbiz.qpic.cn`（含子域）与精确 `mmecoa.qpic.cn`，每张 10 MiB、总量 60 MiB、总缓存最多 60 张（封面也计入，正文 DOM 顺序优先），每次 redirect 继续执行同一允许清单。没有增加互动数据、Cookie、凭证或 `getappmsgext` 路径。
- 自动验证：R7 `WeChatWKWebViewCaptureServiceTests` 4/4、`WeChatWebCapturePolicyTests` 7/7、`HistoryContentViewTests` 47/47 通过；实现过程的定向检查为 23+4 项绿灯。最终 `swift build` 为 `Build complete! (2.76s)`（仅既有 WKNavigationDelegate near-match warning）；最终 `swift test` 为 553 tests / 9 failures / 0 unexpected / 13.936s，失败只属于既有 4 个 V2 临时播放/媒体持久化隔离用例。真实链接 verifier 成功：纯正文 4703 scalar、正文图 9/9 下载、封面成功、账号/作者均为「数字生命卡兹克」、发布时间 `2026-07-21T01:11:53.000Z`、耗时 3.809293375 秒。
- 失败与恢复：首次命令因 `~/.cache/clang` 权限失败，`/private/tmp` scratch 又受外层沙箱 DNS 限制；使用现有 `.build`、`/private/tmp` clang cache 和 `--disable-sandbox` 可跑定向检查，最终在批准的外层环境得出真实全量结果。单张下载、超时、格式或防盗链失败会跳过该图，正文仍保存；总预算到达时停止后续下载，已完成图片保留。若要撤回，移除微信专用提取/暂存与显示分支即可；不要改动 R6 的 `textContent`、浏览器扩展、互动数据、V2 播放地址隔离或数据库 schema。
- 可选跟做（5–10 分钟）：用一篇含重复图片引用的公众号文章保存后，在“原文”观察同一图片位于两个原位置、封面位于属性条；临时断网再保存一次，确认正文仍出现、只有图片缺失。该观察用于共同理解，不是完成前置条件。

## 任务：抖音详情元数据与历史侧栏

- 日期：2026-07-21
- 当前状态：**产品逻辑完成，2 个 P2 测试证据待补强，已部署待人工观察。**
- 用户场景：从抖音详情保存后，用户需要看到真实的点赞、评论、分享、收藏、作者和发布时间；转写视频后，这些来源信息也不能消失或被导入时间冒充。
- 角色与交接：扩展的 `extractDouyinSingleItemMetaInPage` 从当前 aweme 的身份安全范围读取 DOM 元数据 → `background.ts` 用同一 aweme id 的页面 SSR 数据逐字段补齐并写成 Markdown frontmatter → `GRDBHistoryRepository` 从最新非 `local_transcription` 来源快照解析 frontmatter → `HistoryRowView` 显示作者（缺失时域名）和真实发布时间（缺失时明确提示）。
- 工作流：用户打开单条视频 → 共同 DOM 范围必须在**完整身份节点集合**中只含当前 aweme（超过检查上限也拒绝）才读取同级操作栏 → SSR 有字段时覆盖 DOM、没有则保留 DOM → 数据本机落入既有正文 → 历史侧栏读取来源快照；转写仍照原有 effective snapshot 规则显示正文。
- 工具协同：浏览器 Vitest 构造同级操作栏、相邻视频 `999`、第 121 个异 aweme、document-wide 作者污染、嵌套/超限 SSR 与真实 `0`；Swift XCTest 验证 frontmatter、截断 UTF-8 前缀、转写后来源属性与正文分别交接、两种 ISO 时间格式。没有读取真实 Cookie、浏览器 profile、数据库或 Provider。
- 复审返修与自动验收：首轮复核发现“前 120 个身份节点后仍信任 scope”、DOM 作者可从页面全局串入、SSR 队列/数值边界不够硬、转写正文可能复用来源 body、`.000Z` 未保证本地化解析五项问题；已以 fail-closed scope、author 仅 safe scope、1200 对象/队列/子节点上限、effective snapshot body 独立解析、双 ISO formatter 关闭。`background-douyin.test.ts` 32/32、扩展 `typecheck` 通过；Swift `HistoryContentViewTests` 36/36 + `MarkdownNoteFrontmatterTests` 4/4 + 持久化来源快照专项 1/1；`git diff --check` 通过。
- 失败与恢复：DOM 范围若含另一 aweme 身份，宁可不写统计/时间，避免串视频；SSR 的 ID 或 Unix 秒非法时省略字段；没有发布时间时显示“发布时间未获取”，不使用导入/更新时间代替。旧的已保存记录不会被伪造回填，需重新在浏览器发送该视频才会带入新元数据。
- 可选跟做：打开一个抖音详情页，发送后在历史侧栏观察“作者 / 发布时间”；随后完成本机转写，回到同一条历史确认侧栏信息仍保持。该观察不阻塞使用。

## 任务 Loop V-1b：单条视频识别（modal_id / 拒 Feed 壳）

- 日期：2026-07-19
- 当前状态：工程完成
- 用户场景：在抖音精选 Feed 弹层（`jingxuan?modal_id=`）点扩展，应只入库该条视频，不能把侧栏导航当正文。
- 借鉴：StepAudio Douyin Transcriber v3.0.1 的多源 ID 检测（`modal_id` 优先、`/video/{id}`、打分排序）；不搬云端 ASR。
- 角色与交接：`douyin-detect.ts` 解析 aweme id → `extractDouyinPage` 只写标题/描述/作者并规范化 URL → 详情仍用 media 播放。
- 自动验证：扩展 Vitest 42 + typecheck；Swift DouyinSourceAdapterTests 6/6。
- 可选跟做：在精选点开一条弹层视频再发送，History 的 URL 应为 `/video/{id}`，正文不含「精选/关注/朋友」。

## 任务 Loop V-1：抖音视频抓取与落库

- 日期：2026-07-19
- 当前状态：工程完成（待主控 GUI 播放确认与后续 V-2 转写；V-1b 已修 modal_id）
- 用户场景：Syc 在抖音看到口播视频，用扩展「发送」或手动丢链接；详情页顶部出现本机视频卡，可播放；风控时引导改用扩展，不崩溃。
- 角色与交接：
  - `capture-envelope` 可选 `media` 块：跨语言海关单上的视频元数据（不存签名 URL 供以后用）。
  - 扩展 `extractDouyinPlayURLInPage`：在**当前已打开标签**里用同域 `fetch(credentials:include)` 取播放地址——当前页会话，不是 Cookie 库。
  - `DouyinSourceAdapter`：手动链接尽力解析 SSR/`<video>`；命中 acrawler/空壳 → `extensionCaptureRequired`。
  - `VideoMediaDownloader` + `LocalMediaStore`：PeerBound/代理门禁、200MB、mp4/mov 校验、Referer 对 CDN 的公开页来源。
  - `Migration003 media_assets` + 详情 `HistoryVideoPlayerCard`：本机文件 + AVKit 播放。
- 工作流：双入口 → 立即下载签名 URL → 按内容 SHA-256 落盘 → History 详情顶部播放。
- 本次核心名词：media 块、签名 URL 立即下载、media_assets、AVKit 本地播放卡、当前页会话取流。
- 自动验证：Swift 380/380；扩展 Vitest 33/33 + typecheck；shared 10/10；`git diff --check` 干净。
- 真实验证：3 条真实公开抖音视频（扩展手递签名 URL×1 + 手动入口路径×2）经 PeerBound 下载入库（31MB/18MB/70MB），media 行与文件均存在；裸手动抓取 3 条真实页面稳定降级为「请在浏览器打开后用扩展发送。」且不崩溃。
- 可选跟做：用 Debug App 打开 History 详情，确认顶部视频卡可播放；不要求提交答案。
- 未决：GUI 内一键播放截图由主控确认；Loop V-2 本机转写；删除时媒体文件清理已接 ViewModel，需 V-3 补回归测试强化。

## 任务 006：Loop 6 代理安全与生成偏好复审修复

- 日期：2026-07-17
- 当前状态：工程进行中（等待本轮定向测试、全量测试与 reviewer 复审）
- 用户场景：代理/VPN 的 fake-ip 环境仍应可读取用户主动提交的 HTTPS 页面，同时不能把“本机 DNS 检查”误当成“代理真正连接的 IP”；重启后首次生成也必须使用用户已保存的 prompt 与翻译语言。
- 角色与交接：`PublicWebURLPolicy` 决定直连或系统代理；PeerBound 负责可观察 numeric peer 的严格路径；SystemProxy 只接收 HTTPS 并保留 hostname TLS 校验；启动 composition 先把非秘密偏好从 UserDefaults 交给主窗口，加载期间按钮不可生成。
- 工作流：用户提交链接 → 路由选择 PeerBound 或 HTTPS-only 系统代理 → redirect 每跳复检；用户启动 APP → 偏好读取完成 → 首次总结/翻译冻结保存的 prompt/目标语言。
- 工具协同：本地 classic CONNECT fixture 记录真实 CONNECT target，以进程内 trust anchor 验证 matching/wrong-host/untrusted 证书；UserDefaults DTO 在进入领域模型前重新校验。
- 本次核心名词：System Proxy Trust Boundary、HTTP CONNECT、Model Preferences、DTO、TLS trust anchor。
- 已知失败与恢复：系统代理不能承诺 numeric peer binding；HTTP 页面改用浏览器扩展。测试夹具只使用临时自签材料和进程内 anchor，不写系统 trust/Keychain；当前执行环境若禁止 loopback，按报告所列命令在沙箱外复跑。
- 可选跟做：在设置页保存一个容易辨认的目标语言，重启 APP 后观察首次“翻译为 …”按钮在偏好加载完成后才可用；不要求提交答案。

## 任务 001：建立项目骨架与完整 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：把模糊产品想法变成可持续开发、可最终上架的真实项目。
- 工程产物：项目目录、PRD、架构建议、学习指南、Project Brain 骨架和本地 Git 仓库。
- 本次核心名词：Repository、PRD、Project Brain、Git、Monorepo。
- 自动验证：PRD lint 通过；`package.json` 可解析；Brain 链接检查通过；Git 分支为 `main`。
- 过程讲解重点：
  1. PRD 和代码分别解决什么问题？
  2. Git 为什么不是网盘？
  3. `apps/` 和 `packages/` 在这个仓库里分别承担什么角色？
- 可选跟做：在 Finder 或编辑器打开项目，找到桌面端、扩展和共享包三个区域；该动作不阻塞后续任务。
- 可选深挖：Repository、Git 或 Monorepo 中任一概念可单独开小窗口学习。

## 任务 002：建立任务级学习闭环

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：避免开发过程变成“AI 写完代码，Syc 只看到结果”。
- 工程产物：任务学习模板、名词词典、学习日志和项目级双验收规则。
- 本次核心名词：Definition of Done（完成定义）、工程验收、学习验收、理解等级。
- 自动验证：三个学习文档均存在；README、项目规则和学习指南已建立入口；Brain `lint-links` 通过并识别 1 个 active 决策页。
- 过程讲解重点：
  1. 为什么自动化测试通过还不等于学习完成？
  2. L1 与 L3 的区别是什么？
  3. 以后一个任务在什么条件下才能标记为“完整完成”？
- 可选跟做：浏览 `TASK_TEMPLATE.md` 的八个部分，观察过程讲解现在位于哪一段；不要求提交答案。
- 可选深挖：理解等级和工程验收可以单独开小窗口学习。

## 任务 003：建立百万注册架构与容量路基

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：从项目第一天就建立可从本地 MVP 平滑增长到 10 万、100 万注册用户的边界，避免因为规模增长推翻客户端、领域模型和 TypeScript 主干。
- 本次只解决：架构、数据边界、稳定协议、容量计算、SLO、扩容与恢复触发条件；不修改 PRD、不安装依赖、不开始功能代码。
- 角色与交接：`ARCHITECTURE.md` 定义扩展、Electron、本地领域核心、云端模块和基础设施的职责；`CAPACITY_MODEL.md` 把注册目标换算成 RPS、jobs/s、数据规模和压测阈值；过程讲解完成后直接交给下一阶段，不设置学习考试门。
- 工程产物：重写 `docs/ARCHITECTURE.md`；新增 `docs/CAPACITY_MODEL.md`；补充五个实际进入项目的架构名词。
- 本次核心名词：Capacity Model、Modular Monolith、RPS、SLO、Idempotency。
- 技术选择：TypeScript 主干、Electron + React、WXT + MV3、Fastify 模块化单体、SQLite 本地事实、PostgreSQL 云端事实、缓存/队列/对象存储为可替换适配层。
- 自动验证：架构与容量 8 项结构断言全部通过；Brain `lint-links` 通过；`package.json` 可解析；未发现 `TODO`、`待补充` 或 placeholder。
- 已确认失败路径：Cloud API、PostgreSQL、队列、对象存储和模型 Provider 故障时的降级与恢复已分别定义；云端故障不得阻止本地提取、BYOK、历史和导出。
- 恢复方式：本阶段只修改架构、容量、词典和学习日志；PRD、代码、依赖和 Git 历史均未改变。产品判断发生反转时，修订文档并通过 Brain CLI 追加 reversal。
- 过程讲解：已在任务开始、架构写入和容量检查三个节点解释场景、组件职责、交接物与选择原因。
- 过程讲解重点：
  1. 为什么 100 万注册用户不等于 100 万人同时请求服务器？
  2. 原文、API Key、账号权益和同步密文分别由谁保存？
  3. 什么证据出现后才允许把模块化单体拆成微服务？
- 可选跟做：打开 `docs/CAPACITY_MODEL.md` 第 4 节，把峰值在线从 10,000 改为 5,000 进行口算；预期目标从 1,000 RPS 变为 500 RPS。该动作不是继续开发的前置条件。
- 可选深挖：Capacity Model、Modular Monolith、RPS、SLO、Idempotency 均可单独开小窗口学习。

## 任务 004：建立唯一 Project Brain 与 doctor 门禁

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：让新的 Agent 或新会话能快速读懂项目，并能发现入口、记忆、架构和规则已经互相漂移。
- 本次只解决：项目记忆播种、统一 Brain CLI、只读健康检查、验证入口和非阻塞学习协作；不安装依赖、不修改 PRD、不提交 Git。
- 角色与交接：README 提供当前入口；AGENTS 规定工作方式；BRAIN 与 9 条 active decision 保存耐久判断；`scripts/brain` 提供统一读写入口；`scripts/doctor` 检查它们是否一致；`VERIFY.md` 解释检查和恢复方式。
- 工程产物：六个已播种 Brain 根页面、8 条新架构决策、学习契约 reversal、`scripts/brain`、`scripts/check-brain-root`、`scripts/doctor`、`VERIFY.md`、五条 APP 学习主线。
- 本次核心名词：Single Source of Truth、Bootstrap、Doctor、Drift。
- 自动验证：`./scripts/doctor` 实跑为 `PASS=35 WARN=2 FAIL=0`；两项 WARN 分别是无首次 Git commit 和工作树未提交，均需要 Syc 明确授权而不是脚本自动处理。
- 已确认失败路径：Brain CLI 缺失、根页面仍为 placeholder、坏链、阻塞式学习旧文案、敏感文件候选和缺少 Git 基线都有独立报告与恢复说明。
- 过程讲解：在创建入口、播种 Brain、首次运行 doctor 三个节点解释了唯一真相源、完整文档与耐久决策的区别、doctor 的只读职责及预期 warning。
- 可选跟做：运行 `./scripts/doctor` 并观察五个 section；这不是继续 PRD 重写的前置条件。
- 可选深挖：想了解 Brain timeline、reversal 或 doctor shell 实现时，可分别开一个小窗口学习。

## 任务 005：按百万注册架构重写 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：把 local-first、可选账号、加密同步、托管模型和 10 万/100 万容量边界翻译成用户能看到、开发者能实现、测试能验收的产品规则。
- 本次只解决：更新 11 章 PRD；不安装依赖、不创建账号服务、不购买云资源、不开始功能代码。
- 角色与交接：架构文档提供组件边界，容量模型提供数字与触发条件，PRD 把它们转换成 P0–P3、UI 状态、数据模型、失败路径、SLO 和验收剧本；下一阶段代码只实现 PRD 已确定的最小顺序。
- 工程产物：本地免登录 P0；账号/设备、选择性加密同步、托管模型与额度三个新模块；六个云端稳定模型；四层技术架构；10 万/100 万优先级与性能指标；五条端到端验收剧本。
- 本次核心名词：Identity、Entitlement、Encrypted Blob、Usage Ledger、OIDC Adapter。
- 自动验证：`qiaomu-ai-prd` lint 通过；章节、P0–P3、云端模型和五条验收剧本的额外结构断言通过；`./scripts/doctor` 为 `PASS=35 WARN=2 FAIL=0`。
- 被证据修正的一点：首轮 PRD lint 把 Markdown 方括号、`active-active` 中的“区域 a”和优先级章节重复出现的 `P0` 判为模板/结构问题；已改为不产生歧义的正文，产品语义未改变。
- 过程讲解：在产品分层、账号/同步/托管模块、数据模型、容量优先级和 lint 修复节点分别解释了架构如何变成用户行为，以及为什么不能用百万用户目标过度建设 P0。
- 已确认失败路径：Cloud API、身份 session、同步密钥、版本冲突、对象存储、托管额度、Provider 限流、重复请求、账号删除和容量劣化均有用户提示与恢复动作。
- 可选跟做：按 PRD 第 3.8–3.10 节观察 Identity、Sync、Managed AI 三个模块如何各自拥有状态；不要求提交答案。
- 可选深挖：Identity/OIDC、端到端加密、Usage Ledger 或容量压测均可单独开小窗口学习。

## 任务 006：建立 TypeScript monorepo 与共享协议

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：在扩展、Electron、本地数据库和未来 Cloud API 开工前，先建立一套机器可验证、可锁版本、可在 CI 复现的数据合同。
- 本次只解决：项目级 TypeScript 工具链、lockfile、CI、12 个稳定模型的 Zod Schema 与协议测试；不安装 Electron/React/WXT/Fastify，不连接真实页面、模型、数据库或云端。
- 角色与交接：`common.ts` 提供共同 ID、时间、请求与错误；`local.ts` 提供捕获、任务、快照、运行和结果；`cloud.ts` 提供用户、设备、权益、同步密文和用量流水；index 统一导出给后续应用。
- 工程产物：pnpm workspace 工具链、TypeScript/ESLint/Vitest、`pnpm-lock.yaml`、固定 SHA 的 GitHub CI、`@linkdigest/shared`、许可证清单与门禁。
- 本次核心名词：Dependency、Lockfile、Schema、Type Check、Contract Test。
- 被证据修正的一点：最新 TypeScript 7.0.2 超出 typescript-eslint 的 `<6.1.0` peer dependency，改为兼容的 TypeScript 6.0.3；没有为了追最新版制造工具冲突。
- 自动验证：`pnpm check` 通过；lint 和 typecheck 通过；Vitest 9 项协议测试通过；frozen-lockfile 安装通过；生产与完整依赖审计均未发现已知漏洞；doctor 无失败。
- 协议失败证据：拒绝 `CaptureEnvelopeV1` 的 version 2、非 HTTP(S) URL、正文字符数不一致、持久快照字符数不一致、AppError 未声明 `apiKey` 字段，以及用户与 Blob 不一致的对象存储路径。
- 许可证证据：生产依赖仅 Zod/MIT；全依赖树无 GPL、AGPL、非商业、UNLICENSED 或 UNKNOWN 包；开发链 MPL-2.0 已单独记录。
- 过程讲解：在依赖选择、兼容修正、Schema 分层、安装、四道门和许可证检查节点解释了每个工具的场景、职责、交接与失败表现。
- 安全边界：Schema 负责格式、版本和对象自洽；未来 Cloud API 仍必须用登录身份重新判断资源归属，不能把客户端传来的 `userId` 当作授权证据。
- 可选跟做：运行 `pnpm --filter @linkdigest/shared test` 观察 9 个合同测试；该动作不阻塞下一阶段。
- 可选深挖：Zod、TypeScript 类型推导、CI SHA 固定或 peer dependency 可分别开小窗口学习。

## 任务 007：收敛 macOS 原生第一版并重构 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：第一版只做 Apple 平台，并把 Sam 一类原生 UI 质感作为产品价值，不再让远期 Windows 与百万容量规划主导当前实现。
- 本次只解决：冻结 SwiftUI + 少量 AppKit 桌面路线；保留 TypeScript/WXT Chromium 扩展；精简 P0 PRD；建立 V0.1 垂直切片；同步 Architecture、README、验证与 Project Brain。
- 明确不做：创建 Xcode 工程、安装 WXT/Swift 依赖、修改现有 TypeScript 合同代码、建立账号/云端、提交或推送 Git。
- 角色与交接：扩展读取当前页面并交出版本化 JSON；Native Host 校验 framing 与版本；Swift Local Core 转成领域对象；SwiftUI 展示用户可观察结果。
- 本次核心名词：SwiftUI、AppKit Bridge、Native Host、Vertical Slice、Reversal。
- 被修正的判断：旧路线认为共享 TypeScript 源码和未来 Windows 的复用价值高于 Mac 原生体验；在第一版 Apple-only 且 UI 是差异点的约束下，桌面端改为 SwiftUI，TypeScript 只保留在浏览器扩展和现有协议原型。
- 工程产物：当前 PRD、V0.1 规格、当前 Architecture、旧方案归档、项目入口和 doctor 真相源更新；Project Brain 新增 SwiftUI 混合架构决策，旧 TypeScript 主干、百万容量、同步和托管模型四条决策以 reversal 归档。
- 自动验证：`pnpm check` 全部通过；ESLint、TypeScript typecheck 和 Vitest 9 项合同测试通过；Brain `lint-links` 为 10 pages / 6 roots / 0 broken links；doctor 为 `PASS=45 WARN=2 FAIL=0`，两项 WARN 仍是无首次 commit 和工作树未提交。
- 失败与恢复：如果 Native Messaging 公证、安装或跨语言合同 spike 失败，先保留协议与证据并重新评估 Helper 结构；不能因一次 spike 失败静默改回 Electron。
- 可选跟做：对照 `docs/PRD.md` 的 P0“必须完成/明确不做”，观察第一版范围如何从账号、同步和百万容量收敛到一条本地闭环；不要求提交答案。
- 可选深挖：SwiftUI/AppKit 分工、Native Messaging framing 或跨语言 JSON Schema 可分别开小窗口学习。

## 任务 008：建立 V0.1 当前页到 SwiftUI 自动化垂直链路

- 日期：2026-07-14
- 当前状态：工程完成（Chrome/Brave/Edge 三浏览器工程证据已收口；正式安装与发布仍未完成）
- 用户场景：用户在 Chromium 当前文章页点击扩展，标题、URL、正文、捕获方式和字符数进入本机 SwiftUI APP；APP 或 Host 不可用时得到可恢复错误。
- 本次只解决：语言中立合同、固定文章提取、MV3 background、Native Messaging framing、独立 Host、APP socket inbox 与 SwiftUI 展示；不实现模型、SQLite、账号、云、签名、公证或正式视觉。
- 角色与交接：Popup 接收用户动作；注入函数读取 DOM；background 交出 `CaptureEnvelopeV1`；Native Host 校验 framing 与合同；Unix domain socket 交给 APP；Application inbox 幂等接收；SwiftUI 只展示状态。
- 本次核心名词：`CaptureEnvelopeV1`、JSON Schema、Native Messaging Framing、Application Boundary、Idempotency。
- 技术选择：JSON Schema Draft 2020-12 是跨语言唯一合同；TypeScript 使用 Ajv，Swift 运行时执行打包的同一 Schema；Schema 无法表达的字符数 invariant 由两端同 fixtures 验证。Host 与 APP 用用户私有 Unix socket；APP 离线返回 `APP_UNAVAILABLE`，不自动拉起。
- 被证据修正的判断：
  1. 首轮 Xcode 使用了错误的 `-packagePath` 参数，实际从 `apps/desktop` 运行 `xcodebuild -scheme ...` 可以发现并构建 Swift Package schemes。
  2. 首轮 Swift 只同步 Schema 文件但未执行完整 Schema，无法防止 `usedCookie=true`、非法枚举和时间越过边界；已增加 Swift JSON Schema evaluator 与专项测试。
  3. 首轮 APP 串行读取连接，半包不结束会阻塞后续消息；已改为每连接独立 task、读写超时，并用 stalled client + 20 条消息验证隔离。
  4. WXT 双许可传递依赖被旧 checker 误判为 GPL-only；检查器现按 SPDX `OR` 选择 MIT/BSD 路径，纯 GPL/AGPL 仍失败。
  5. Node/Vitest 中可运行的 Ajv runtime compiler 在 Chrome MV3 Service Worker 中被 CSP 拒绝；已改为构建期生成静态 validator，并加入同 fixtures 与无动态代码生成测试。
  6. 终端可直接启动的 Host 从 Chrome 启动时会因 `Documents` TCC 等待权限；单独搬 executable 又缺 Swift resource bundle。真实验收改为成对暂存 executable + resource bundle，正式安装边界由“一个二进制”修正为“签名 Host 与合同资源的完整交付单元”。
  7. Brave 150 在 macOS 上把用户级 Native Messaging 查找目录兼容映射到 Chrome 的注册位置；现场进程时间线与对应源码一致。验收因此以“确认实际生效的 manifest”作为交接检查，不把浏览器品牌目录名本身当作真相源，也不把当前版本行为外推为永久规则。
  8. Edge 150 使用隔离 `--user-data-dir` 时，用户级 Native Messaging manifest 查找根随之变为 `<user-data-dir>/NativeMessagingHosts/`；旧脚本只写默认 Edge 目录。脚本现保留默认路径，并以仅 Edge 可用的 `--user-data-dir` 显式选择隔离目标。
- 自动验证：shared 10 tests、extension 9 tests、Swift 既有 46 tests 证据；WXT MV3 build；Swift/Xcode App 与 Host Debug/Release；Host 离线/超限 smoke；stalled client + 20/20 vertical smoke；doctor 无 FAIL。Chrome 真实触发完成 APP 离线 `APP_UNAVAILABLE`、SwiftUI 字段观察和 20/20 Release p95 `49.2 ms`；Brave 隔离 Profile 完成离线错误、在线接收和 20/20 p95 `34.9 ms`；Edge 隔离 Profile 完成人工 Popup 预览，以及修复后 Service Worker → Host → socket → Swift App `taskAccepted 20/20`、p95 `24.5 ms`。完整证据边界见 `docs/V0.1_IMPLEMENTATION.md`。
- 已确认失败路径：不支持版本、非 Web URL、空正文、字符数不一致、超大正文/Frame、非法 Schema 字段、Host 未安装、APP 未运行、Native timeout 均有稳定错误或测试证据；普通日志不记录正文和秘密。
- 恢复方式：合同漂移用 `scripts/sync-contracts.sh` + `pnpm check`；APP 离线打开后重试；manifest 使用实际 extension ID dry-run 后再 apply；路线失败保留合同与证据并通过 Brain CLI 记录 reversal。
- 过程讲解：任务开始与每个实施阶段已按“场景 → 角色与交接 → 工作流 → 工具协同”解释合同、framing、Application boundary、幂等、连接隔离、CSP、TCC 与失败恢复；解释跟随真实断点出现，没有把理解变成 Syc 的关闭任务门槛。
- 可选跟做：对同一 `contracts/fixtures/valid.json` 把 `version` 改成 2，观察 TypeScript 与 Swift 都拒绝；或运行 `./scripts/run-vertical-smoke.sh` 观察 stalled client 不阻塞后续 20 条。两者都不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：JSON Schema evaluator、Chromium framing、Unix socket 或 Swift MainActor 可分别另开小窗口。
- 下一步：V0.1 工程矩阵已关闭；正式稳定 Host 目录、Developer ID 签名、公证和发布包留到后续 release spike。Edge 的 Popup 观察与修复后 20/20 传输是两层独立证据，不补写成连续截图。

## 任务 009：收紧 Native Host 安装与卸载门禁

- 日期：2026-07-14
- 当前状态：工程完成（默认与 Edge 隔离 Profile 目标边界均有回归证据）
- 用户场景：开发者需要把同一个 Native Host manifest 绑定到指定 Chromium 浏览器，同时能够预览、备份和人工卸载，不误写其它浏览器配置。
- 角色与交接：安装脚本接收显式浏览器选择和 Host 交付单元；路径校验器确认 executable、resource bundle 与 Schema；同目录 rename 写入步骤交出固定 basename manifest；只读卸载计划交出人工命令，不执行破坏性动作。
- 本次核心名词：显式授权、目标去重、同目录 rename 设计、只读卸载计划。
- 被现场证据修正的判断：Brave 150 当前用户级查找映射到 Chrome 目录，因此不能简单把浏览器品牌名当作目录真相；脚本现在将 Brave 与 Chrome 去重，并要求 Edge 单独显式选择。
- 自动验证：`pnpm native-host:check` 在物理路径临时 `HOME` 中通过；验证 `all`/缺 browser/非法 ID/相对路径/缺 bundle/缺 Schema 拒绝、Brave→Chrome 目标、Edge 默认 dry-run、Edge 隔离目标实际写入、Chrome 拒绝该参数、缺失 Profile、Profile 本身/父级/中间组件 symlink、`.`、`..`、重复 `/`、尾随 `/` 拒绝，以及这些失败不会在解析位置创建 `NativeMessagingHosts` 或 manifest。默认 HOME 的目标组件检查、备份 symlink、0600 权限、唯一备份、同目录 rename、失败临时文件和只读 uninstall plan 回归继续通过。
- 安全边界：该脚本任务没有读取其它 Native Messaging manifest，没有真实 HOME apply，也没有执行 `rm`；后续真实 Edge 验收使用隔离、禁同步 Profile 独立完成。
- 可选跟做：在隔离 `HOME` 下运行 `./scripts/native-host/uninstall-plan.sh --browser brave`，只观察目标存在状态和人工恢复命令；不是继续开发的前置条件。
- 下一步：正式稳定 Host 目录、Developer ID 签名与公证留到后续 release spike。默认 Edge 回滚可用只读 uninstall plan；隔离 Profile 回滚以安装时打印的 `TARGET` 为准人工核对。

## 任务 010：统一文档状态与 PRD 范围口径

- 日期：2026-07-14
- 当前状态：工程完成
- 用户场景：让读者能区分第一版产品目标、V0.1 已实现链路和后续里程碑，避免依据过期文案误判当前能力。
- 本次只解决：校准 PRD、V0.1 规格、README、学习指南、词典和依赖基线的状态与范围表述；不改代码、Project Brain 或产品范围。
- 角色与交接：PRD 定义产品目标；V0.1 规格记录当前链路；README 提供仓库入口；学习、词典与依赖文档分别统一课程、术语和版本口径。
- 本次核心名词：语言中立合同、APP 未运行恢复路径、release spike；均为项目已出现概念，本次未新增词典条目。
- 过程讲解：任务开始时已按“场景 → 角色与交接 → 工作流 → 工具协同”说明文档职责；实施前说明了合同真相源、成功/恢复路径和当前模块边界。
- 失败与恢复：若后续实现状态变化，先以代码、测试和真实验收核对当前事实，再更新对应真相源；不要把 `/tmp` 测试 Host 路径写成发布方案。
- 可选跟做：对照 `docs/PRD.md` 顶部说明与第 7 节里程碑，观察 P0 目标和 V0.1 当前实现如何分开；该动作不阻塞后续任务。
- Syc 主动提出的待解释点：无。

## 任务 011：V0.2 BYOK 实现前置规划

- 日期：2026-07-14
- 当前状态：工程完成（规划文档）
- 用户场景：在 V0.1 已能显示当前正文的基础上，把“用户自带模型连接”拆成安全、可测试、可逐步实施的本地链路。
- 本次只解决：Provider profile、Keychain secret、OpenAI-compatible streaming、RunState、错误语义、测试与后续任务拆分；不实现业务代码，不改变 V0.1 状态。
- 角色与交接：SwiftUI 交出用户意图；ModelRunOrchestrator 协调 profile、secret 与 ModelProvider；OpenAICompatibleProvider 交出 stream event；RunState 把状态交回 MainActor UI。
- 工程产物：`docs/specs/V0.2_BYOK_PLAN.md`；Architecture 入口；5 个实际进入规划的名词。
- 本次核心名词：ProviderProfile、SecretStore、ModelProvider、RunState、有界重试。
- 被当前实现修正的判断：现有 `AppViewModel` 仍直接承接 V0.1 socket 展示，尚无 Application/Provider 边界；V0.2 必须先建立 port/adapter，不能从 View 直接接 Keychain 或 URLSession。
- 安全与恢复：API Key 只进入 Keychain；写入失败不降级明文；流中断保留 partial 并标记 incomplete；取消传播到 URLSession。该任务实施时 V0.1 Edge 仍未关闭，后续已由任务 018 独立补齐证据，未借 V0.2 组件测试代替浏览器验收。
- 过程讲解：在规划开始、读取当前实现和收敛组件边界三个节点解释了配置、秘密、Provider、streaming 与 UI 的交接关系。
- 自动验证：规划完成后运行目标 `git diff`、关键词检查与 `./scripts/doctor`；结果记录在本次执行回报。
- 可选跟做：沿 `V0.2_BYOK_PLAN.md` 第 2 节数据流，从 ContentView 依次指出 Orchestrator、SecretStore、ModelProvider 与 RunState；该动作不阻塞后续开发。
- Syc 主动提出的待解释点：无。
- 可选深挖：Keychain access model、SSE 解析、Swift cancellation 或有界重试可分别另开小窗口。

## 任务 012：实现 Provider profile 与 Keychain secret boundary

- 日期：2026-07-14
- 当前状态：工程完成
- 用户场景：用户在 macOS APP 中配置单个 OpenAI-compatible Base URL、模型名和 API Key，APP 能恢复非敏感配置，但永远不回显或普通存储完整 Key。
- 本次只解决：ProviderProfile、SecretReference、profile/secret ports、UserDefaults 与 Keychain adapters、staged save、最小 SwiftUI 配置 UI 和相应测试；不实现模型请求、streaming、总结/翻译、SQLite、多 Provider 或连接测试。
- 角色与交接：ProviderSettingsView 只交出输入动作；ProviderSettingsViewModel 交给 ProviderConfigurationService；服务先把 Key 写入 SecretStore，再把 opaque reference 写入 ProviderProfileStore；UI 只接收稳定状态与固定 mask。
- 工程产物：`LinkDigestAdapters` target；Core 配置合同与 staged-save 服务；Keychain/UserDefaults adapters；SecureField 配置 UI；Core、Adapter 与 ViewModel 测试。
- 本次核心名词：ProviderProfile、SecretReference、SecretStore、staged save、secure input。
- 工程证据：`swift test` 与 `pnpm swift:test` 均通过 20 项测试；Keychain 使用随机测试 service/account 完成写入、读取、替换和删除；Swift Debug/Release 与 Xcode App/Host Debug/Release 构建全部通过；doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 失败与恢复：
  1. 第一次增量测试因先声明 test target、尚未创建测试目录而停止；补齐测试文件后恢复。
  2. XCTest autoclosure 不接受 async 调用；改为先 await 结果再断言。
  3. Swift 6 拒绝把仍在测试侧访问的 UserDefaults 实例发送给 actor；adapter 改为只接收 suite name 并在 actor 内创建实例。
  4. Keychain 写入失败映射为 `SECRET_STORE_WRITE_FAILED`，不会提交新的 profile reference；profile 保存失败会 best-effort 删除 staged secret。
- 安全边界：完整 Key 只进入 SecureField 的局部短时输入、ProviderConfigurationService 方法参数和 Keychain adapter；不进入 ProviderProfile、UserDefaults、ObservableObject、日志、safeDetail、fixture、截图、导出或 Git。
- 过程讲解：在 Core/Adapter 分层、首次编译失败和完整测试通过三个节点说明了 port/adapter、staged save 与 Swift 6 actor 隔离的职责和交接物。
- 可选跟做：打开 APP，输入一个专用测试值并保存，观察界面只显示固定 `••••••••`；该动作会写入本机 Keychain，但不是任务关闭门槛，也不要使用真实生产 Key。
- Syc 主动提出的待解释点：无。
- 可选深挖：Keychain generic password item、Swift actor isolation 或 staged save 可分别另开小窗口。
- 已知限制：profile 提交成功后删除旧 Keychain item 采用 best-effort；若系统在该时刻拒绝删除，新 profile 仍然有效，但旧 item 可能暂时成为 orphan，后续需要决定是否增加清理队列或维护入口。
- 下一步：任务 B 才实现 Chat Completions adapter、fake server 和连接测试；本任务没有调用任何模型 API。

## 任务 013：实现 OpenAI-compatible streaming adapter 与 fake server

- 日期：2026-07-14
- 当前状态：工程完成（adapter 与自动验证；设置页连接测试 UI 未纳入本轮）
- 用户场景：在不发送真实页面正文、不调用真实 Provider 的前提下，先证明 APP 能按 OpenAI-compatible Chat Completions 规则组装请求、接收流、解释失败并停止请求。
- 本次只解决：ModelProvider port、connection-test intent、stream event、稳定失败、Base URL 安全拼接、Chat Completions 请求、SSE 解码、有界重试、取消传播与 loopback fake server；不实现总结/翻译正文 UI、RunState、SQLite、多 Provider、Responses API、Ollama 或真实 Provider 测试。
- 角色与交接：未来 Orchestrator 短时交出已校验 profile、Keychain 读取的 secret 与 intent；OpenAICompatibleProvider 组装请求；URLSession 交出字节流；ChatCompletionsStreamDecoder 把 `data:` 行翻译为 delta/completed；稳定失败只把 code、retryable 和 hadOutput 交回上层。
- 工程产物：`ModelProvider.swift`、`OpenAICompatibleProvider.swift`、`ChatCompletionsStreamDecoder.swift`、Network.framework loopback fake server 与 adapter 测试。
- 本次核心名词：ModelProvider、SSE、Chat Completions、有界重试、cancellation propagation。
- 工程证据：fake server 覆盖 path prefix、重复 endpoint 拒绝、method/header/body、多 delta + `[DONE]`、401/404/413、429/5xx 三次总尝试、`Retry-After` 10 秒上限、delta 后断流、malformed、错误 Content-Type、取消与 secret hygiene；`swift test` 与 `pnpm swift:test` 均通过 28 项测试，Swift Debug/Release 与对应 pnpm 包装构建均通过，doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 失败与恢复：首次编译发现 HTTP response 的局部作用域错误，提升为单次尝试状态后同时接入 `Retry-After`；Swift 6 对 fake server 并发 closure 的捕获提出 Sendable 错误，改为锁保护的内部状态；取消测试在本次复核后改为显式取消 Provider 活动 producer task，并断言 500 ms 内退出、活动计数归零和无迟到 delta，避免依赖 TCP 对端何时感知关闭或 URLSession delegate 回调时序。
- 安全边界：完整 Key 只作为 `stream` 方法的短时参数进入 Authorization header；生产代码无日志；fake server 丢弃 header value，只记录 present/matched 布尔值；错误 description 只有稳定 code，测试运行时生成随机 sentinel，并断言 request record 与 failure 不含它。
- 过程讲解：在 port/adapter 数据流、第一次编译失败、fake server 首次全绿与取消/404/413 补强四个节点解释了职责、交接物和失效表现。
- 可选跟做：运行 `cd apps/desktop && swift test --filter OpenAICompatibleProviderTests`，观察八个 loopback 协议测试；不会访问真实 Provider，也不是后续开发的前置条件。
- Syc 主动提出的待解释点：无。
- 可选深挖：SSE line framing、URLSession cancellation、Retry-After 或 loopback fake server 可分别另开小窗口学习。
- 已知限制：连接测试 intent 已存在，但尚无 Application Orchestrator 从 SecretStore 短时取 Key，因此本轮没有让 SwiftUI ViewModel 直接接触 Keychain 或 API Key；对应 UI 应在保持该边界的后续小任务中接入。
- 下一步：任务 C 前先由 Syc/MindMux 决定是否补一个独立连接测试 UI 小任务。当时 V0.1 Edge 尚未关闭，后续已由任务 018 独立补齐证据。

## 任务 014：实现总结/翻译 RunState、streaming UI 与取消传播

- 日期：2026-07-14
- 当前状态：工程完成（自动化与构建证据完成；未调用真实 Provider）
- 用户场景：用户已把当前网页正文送入 APP，希望点击总结或翻译后看到流式文本，并能停止、保留部分结果和理解失败状态。
- 本次只解决：`RunIntent.summarize/translate`、`RunState`、`ModelRunOrchestrator`、当前 capture prompt、SwiftUI 结果区、停止传播和 stale-run 隔离；不实现 SQLite、导出、Q&A、自动分块、多 Provider、连接测试 UI、Edge、签名或发布。
- 角色与交接：SwiftUI 只交出总结/翻译/停止意图；Orchestrator 从 `ProviderConfigurationService` 短时取得 profile 与 Key；`ModelProvider` 交回 delta/completed/failure；Orchestrator 映射为 UI-safe `RunState`；MainActor ViewModel 只接受当前 run identifier 的状态。
- 本次核心名词：RunState、ModelRunOrchestrator、cancellation propagation、stale run isolation、incomplete result。
- 技术选择：状态机与运行协调放在 Core，而不塞进 ViewModel；API Key 只作为 `loadCredentials → Orchestrator → ModelProvider.stream` 的局部短时值，RunState、ViewModel、fixture、日志和 fake request record 均不保存原文。
- Prompt 边界：总结 prompt 要求只依据捕获正文、不得编造并提示可能不完整；翻译 prompt 固定目标语言为简体中文、保留结构/名称/数字/链接；两者只加入可选标题和正文，不加入 source URL、Cookie、Header 或 Key。
- 自动验证：新增 8 项 Orchestrator 测试、3 项 AppViewModel 测试和 1 项 adapter prompt 测试；`swift test` 与 `pnpm swift:test` 共 40 项通过；Swift Debug/Release、Xcode App/Host Debug/Release 通过；doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 正常与失败证据：delta 顺序累积后 completed；无 profile、secret read failure 与空正文均不会调用 Provider；无 partial 的 Provider failure 进入 failed，有 partial 则保留为 incomplete；stop 产生 stopping/stopped 并取消 fake producer；新 run 建立后旧延迟 delta 不进入最终状态。
- 被实现证据修正的判断：无需把 API Key 暴露给 AppViewModel 才能启动模型请求；共享同一个 `ProviderConfigurationService` 即可让设置保存与 Orchestrator 短时读取保持单一边界。为避免 actor reentrancy 下的 UI 覆盖，除了 Core 的 current run ID，MainActor ViewModel 也维护 visible run ID。
- 遇到的错误及恢复：本轮新增代码首次编译与测试均通过；主要风险不是语法错误，而是取消和 MainActor 交接的竞态，因此通过延迟 delta、stop 和连续新 run 三组自动测试固定恢复语义。收口时曾从 `apps/desktop` 误运行 `./scripts/doctor`，因相对路径错误失败；改用项目根运行或 `../../scripts/doctor` 后恢复，代码与 doctor 门禁本身没有失败。
- 安全边界：没有真实 API Key、Cookie、Token、私人 URL 或正文进入日志/fixture；测试只生成随机 sentinel，并只记录 Key 是否存在；没有调用真实模型 API。
- 过程讲解：在任务开始、Core/Adapter 首次编译通过、状态机测试完成和全量构建四个节点解释了 RunState、Orchestrator、取消传播、旧 run 隔离与 incomplete 的职责、交接物和失效表现。
- 可选跟做：运行 `cd apps/desktop && swift test --filter ModelRunOrchestratorTests`，观察停止与旧 run 隔离测试；该动作不访问网络，也不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：Swift actor reentrancy、AsyncThrowingStream termination 或 MainActor 状态过滤可分别另开小窗口。
- 已知限制与下一步：设置页连接测试 UI 未接入；真实 Provider 兼容抽样需要单独授权；错误恢复文案与秘密门禁随后已由任务 D 收口；V0.1 Edge 证据后来由任务 018 独立收口。

## 任务 015：统一错误语义、秘密门禁并完成 V0.2 工程验收

- 日期：2026-07-14
- 当前状态：工程完成（本地 V0.2 工程链路；不表示发布完成）
- 用户场景：配置、模型和运行失败时，普通用户需要看到一致的中文原因和下一步动作；同时项目需要证明 API Key 不会随着错误、partial 或测试证据进入可见状态和仓库。
- 本次只解决：22 个 stable code 的统一文案与恢复动作、failed/incomplete/stopped 状态收口、Provider 异常回显 Key 的 redaction、独立 secret scan、V0.2 集中验收证据和文档状态；不实现 SQLite、历史、导出、连接测试 UI、多 Provider、真实 Provider、Edge 或发布能力。
- 角色与交接：Core/Adapter 交出 stable code 与 RunState；`V02ErrorCatalog` 交出固定 `message/recoveryAction`；SwiftUI 只显示这份 allowlist 文案；Orchestrator 在 delta 进入 RunState 前移除本次 Key；Swift tests 与 secret scan 反向检查整个交接。
- 本次核心名词：稳定错误、恢复动作、redaction、验收证据。
- 工程产物：统一错误目录、Orchestrator 输出 redaction、错误/状态/secret tests、`scripts/check-v02-secret-hygiene.sh`、`pnpm secret:check`、doctor 门禁与 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`。
- 工程证据：22 个 stable code 都有非空中文原因和恢复动作；unknown input 不回显 raw body/Header/URL/secret；stopped 和 incomplete 明确“不完整”；随机 sentinel 不进入 RunState、ViewModel visible text、错误文案、fake record、ProviderProfile 或 UserDefaults。Swift 46 项测试、Swift/pnpm Debug/Release、Xcode App/Host 四项均通过；secret scan 为 OK；doctor 为 `PASS=51 WARN=2 FAIL=0`。
- 失败与恢复：第一次增量测试只有一项失败，原因是旧断言要求 UI 包含内部 stable code，而新产品要求改为普通用户文案；更新为统一目录断言后恢复。未通过增加 raw detail 解决，因为那会破坏秘密边界。
- 安全边界：生产 Swift 源无普通日志调用；unknown code 不被插值；API Key 只短时进入 Authorization header，并在任何异常回显进入 RunState 前替换为固定 `[已隐藏]`；没有新增第三方依赖。
- 过程讲解：在规则读取、stable code 盘点、旧断言失败、运行时/静态门禁通过和工程证据收口五个节点解释了错误目录、恢复动作、redaction 与验收证据的职责和交接物。
- 可选跟做：运行 `pnpm secret:check`，观察只读门禁如何检查日志、observable state、fixture 和 UserDefaults adapter；不会读取 Keychain 或访问网络，也不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：allowlist 错误目录、流式输出 redaction 的边界或发布前 secret incident response 可分别另开小窗口。
- 已知限制：单独测试连接 UI 留给后续小任务；真实 Provider 抽样需要单独授权；旧 Keychain orphan 清理仍需要后续维护入口。V0.1 Edge 证据后来由任务 018 独立收口。

## 任务 016：V0.2 收口后复核修正与下一阶段准备

- 日期：2026-07-14
- 当前状态：工程完成（复核修正；不表示产品发布完成）
- 用户场景：V0.2 本地 BYOK 链路已经收口，需要再次确认文档没有把工程完成写成产品发布，错误文案和秘密门禁没有遗漏，并为 V0.3 前的工作排出顺序。
- 本次只解决：状态口径、未知错误防回显测试、secret hygiene 规则、doctor/VERIFY 说明、集中验收证据和下一步排序；不实现 Edge、真实 Provider、连接按钮、Keychain 清理、SQLite、历史、导出、签名、公证或发布。
- 角色与交接：代码和 Swift tests 提供当前行为；`V02ErrorCatalog` 把 stable code 交成固定中文文案；`pnpm secret:check` 只交出规则名与路径；doctor 把检查结果归入 PASS/FAIL；acceptance 文档把已完成、未完成和建议顺序交给下一阶段。
- 本次核心名词：secret hygiene、sentinel、Keychain orphan；stable error 和 `Retry-After` 复用已有概念。
- 被复核证据修正的判断：README 的产品定位句容易被理解为粘贴链接、历史和导出已经可用；V0.2 plan 仍把翻译目标语言写成未决，并保留“后续不实现测试”的旧时态；当前 UI 也尚未实现真实 Provider 发送前的数据去向提示。现已修正文档，最后一项明确保留为发布/真实抽样前缺口，没有扩张成本任务。
- 错误与秘密边界：所有 22 个 stable code 继续使用 allowlist 文案；unknown 输入测试扩展到原始 code、Provider body、Header、API Key sentinel 和完整私人 URL。secret hygiene 从“禁止任何生产日志”收敛为“阻断日志中的敏感形状”，并补齐 observable/RunState、fixture/snapshot、UI code sink 与 UserDefaults 规则；命中不打印疑似值。
- 取消复核：重复运行发现原测试把“服务端后续 TCP 写入失败”当作底层取消证据，存在非确定时序；同时 Orchestrator 没有显式调用 Provider 取消入口。现已增加 `ModelProvider.cancelActiveStreams()`，OpenAI adapter 跟踪并取消活动 producer task，Orchestrator stop 先调用该入口再取消消费 Task；测试固定 500 ms 内退出、活动计数归零、无迟到 delta 和 stop 交接次数。
- 自动验证：`pnpm secret:check`、`./scripts/doctor`、Swift 46 项测试、Swift/pnpm Debug/Release build、`git status --short` 与 `git diff --check` 均在本任务结束前执行并记录；不调用真实 Provider。
- 失败与恢复：若 secret hygiene 误报，先看规则名和路径，再用明显 `sentinel-<UUID>` 复现；不得把真实值粘贴进日志或聊天。若后续实现使测试数量变化，以当次命令输出更新 acceptance，不保留过期数字。
- 过程讲解：任务开始时解释复核的场景、角色、工作流和工具协同；实施时就地说明 stable code、sentinel、secret hygiene 与 Keychain orphan 的职责、交接物和失效表现。
- 可选跟做：运行 `pnpm secret:check`，观察成功时只显示 `secret-hygiene: OK`；该动作不读取 Keychain、不访问网络，也不是下一阶段的前置条件。
- Syc 主动提出的待解释点：无。
- 建议下一步：V0.1 Edge 证据已由任务 018 收口；后续顺序为可选真实 Provider 手工抽样 → 可选测试连接按钮 → Keychain orphan 清理维护入口 → V0.3 SQLite 本地历史。

## 任务 017：迁移到 Multica 并修复干净 CI 的 WXT 类型准备

- 日期：2026-07-14
- 当前状态：工程进行中（Multica 组织迁移与首次 GitHub 推送完成；等待修复后的 CI 复核）
- 用户场景：把 Codex 本地项目迁移为可视化、可分派、可由专业 Agent 协作的 Multica 项目，并确保远程仓库能在没有本机缓存的干净环境中复现检查。
- 角色与交接：Multica Project 保存产品上下文与仓库资源；总控 Agent 拆分和分派专业 Issue；GitHub Actions 从全新 checkout 安装依赖；WXT `prepare` 在 typecheck 前生成 `.wxt` 全局类型，再交给 TypeScript 编译器。
- 本次核心名词：Project Resource、Squad Leader、Stage、clean checkout、WXT prepare。
- 被远程证据修正的判断：本机 `pnpm check` 通过是因为已有 `.wxt` 缓存；首次 GitHub CI 在干净 checkout 中找不到 `browser` 和 `defineBackground`，证明 typecheck 不能依赖本机生成目录。扩展脚本现显式在 build/typecheck/test 前运行 `wxt prepare`。
- 第二次远程修正：WXT 类型生成通过后，CI runner 仍因缺少 `rg` 和本机 `brain-page` CLI 使 `doctor` 失败。CI 现在显式安装 ripgrep，并从固定 Git commit 准备零依赖 Brain CLI；feature branch 只走 pull_request 检查，避免 push 与 PR 重复运行同一套任务。
- 工程产物：私有 GitHub 基线、6 个专业 Agent、LinkDigest 产品小队、16 个历史 Issue、8 阶段未来路线、`docs/MULTICA_WORKFLOW.md` 与干净环境 WXT 类型准备。
- 安全边界：没有上传 API Key、Cookie、Token 或私人正文；所有未来功能 Issue 保持 backlog；该迁移任务没有操作 Edge、调用真实 Provider、购买服务、签名、公证或发布。
- 验证方式：删除 WXT 生成缓存后运行扩展 typecheck，再运行完整 `pnpm check`；通过 PR 和新的 GitHub Actions 结果确认远程干净环境。
- 过程讲解：迁移时解释了总控、专业 Agent、Squad Leader 路由、backlog/todo 和 Stage；CI 失败后解释了本机缓存为何会掩盖干净环境缺失步骤。
- 可选跟做：在 Multica 打开 `SYC-24` 查看八个 Stage，并观察所有未来任务仍在 backlog；不需要启动任务或回答问题。

## 任务 018：V0.1 Edge 隔离 Profile 工程收口

- 日期：2026-07-15
- 当前状态：工程完成（V0.1 三浏览器工程证据收口；正式安装与发布仍未完成）
- 用户场景：Edge 使用隔离、禁同步 Profile 加载 LinkDigest 后，Popup 能预览固定文章，扩展后台也能找到 Native Host，并把固定正文稳定交给运行中的 Swift App。
- 本次只解决：Edge 隔离 `user-data-dir` 的 Native Messaging manifest 目标、扩展失败分类、真实 Edge 证据与文档状态校准；不新增依赖，不调用真实 Provider，不运行受 Hana 外层沙盒影响的 Swift 网络/Keychain 测试，不修改 Brain、提交或推送。
- 角色与交接：前一 Luna 实施实例因模型路由变化中止，留下部分 README、V0.1 文档、安装脚本和扩展错误分类 diff；本轮 Sol 实施 Agent 先审查未提交差异，保留主控与前序实例的正确修复，再补齐 PRD、Architecture、规格、证据、学习日志和验证。Popup 交出页面预览；真实 Edge Service Worker 交出 Native Messaging 请求；Host 交给 Unix socket；运行中 Swift App 返回 `taskAccepted`。
- 本次核心名词：`user-data-dir`、Native Messaging manifest 查找根、Service Worker、Unix socket、证据分层。
- 根因：Edge 以 `--user-data-dir=/tmp/...` 启动时，用户级 manifest 查找根随隔离数据根变为 `<user-data-dir>/NativeMessagingHosts/`；旧脚本只写默认 `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/`，因此隔离 Edge 找不到 Host。`install-dev.sh` 现保留默认路径，并提供仅 Edge 可用的 `--user-data-dir /absolute/profile` 显式目标；Chrome 拒绝该参数。后续安全审查又发现仅检查 Profile 最终节点会漏掉父级 symlink，现已增加词法规范、从 `/` 开始逐组件拒绝 symlink、严格直接子目录和创建/写入前后复验。
- 真实证据：Edge `150.0.4078.65`、隔离禁同步 Profile、扩展 ID `dpjfghbojjgoagocbjdpfpejhgfdojfh`。人工 Popup 观察为 `Fixed Test Article / 68 个字符`；修复后真实 Service Worker 使用固定 68 字符 envelope，经 Host → Unix socket → 运行中 Swift App 连续返回 `taskAccepted 20/20`，失败 0，p95 `24.5 ms`、min `14.4 ms`、max `46.3 ms`。
- 证据边界：Popup 观察与修复后 20/20 传输属于两层真实证据；没有修复后单次工具栏点击到 APP 的连续截图，也没有伪造连续截图。Syc 无需再做手动测试才能关闭本轮工程任务。
- 自动验证：扩展测试在安全复核后为 3 files / 9 tests 全通过；`pnpm native-host:check` 覆盖 Profile 本身、父级和中间 symlink、`.`、`..`、重复 `/`、尾随 `/`、直接子目录及失败无越界写入；`pnpm check:web` 通过，其中 shared 10/10、extension 9/9、WXT build 通过，doctor 为 `PASS=52 WARN=1 FAIL=0`，secret hygiene 为 OK；`git diff --check` 通过。
- Swift 证据处理：正常环境既有 46 项 Swift tests 仍有效。本轮没有运行当前 Hana 外层沙盒中已知会因 Network.framework、Keychain 与已有 socket 权限或占用失败的测试，也没有修改测试绕过安全；这些环境失败不记为产品回归。
- 失败恢复与回滚：安装前先 dry-run 核对 `TARGET`，`--apply` 覆盖前创建同目录时间戳 `.bak`。默认 Edge 目标可用只读 `uninstall-plan.sh --browser edge` 查看计划；隔离 Profile 以安装时打印的 `TARGET` 为准，在 `<user-data-dir>/NativeMessagingHosts/` 人工核对并恢复对应 `.bak` 或删除测试 manifest。两类路径相互独立，脚本不自动删除或恢复。逐组件预检与创建/写入前后复验缩小竞态窗口，但不宣称完全消除恶意并发换链。
- 过程讲解：本轮按页面预览、扩展后台、Host、socket、App 的交接顺序解释了 `user-data-dir` 为什么同时是数据隔离边界和 manifest 查找根，以及为什么 Popup 截图与后台 20/20 传输不能合并成一条证据。
- 可选跟做：只读对比默认 Edge dry-run 与隔离 Profile dry-run 输出中的 `TARGET`；该动作不写浏览器目录，也不是任务关闭门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：Chromium Native Messaging 查找规则、macOS Host 签名/公证、Unix socket framing 或真实浏览器证据设计可分别另开小窗口。
- 仍未完成：正式稳定 Host 安装目录、Developer ID 签名、公证、发布包，以及一张修复后工具栏点击到 APP 的连续截图；最后一项不影响本轮 V0.1 工程收口。

## 任务 019：V0.3 SQLite Binding、迁移与恢复 Spike

- 日期：2026-07-15
- 当前状态：历史 Spike 已独立 Sol 审查通过；GRDB 结论已由 02A/02B 后续实现采用。此条中记录的 Xcode nested-sandbox 阻断只是当时环境快照，当前 02B 已通过 Xcode 四目标；不代表 History UI、Export、安装或发布完成。
- 用户场景：正式本地历史开工前，先证明 SQLite 基础层能安全事务、前向迁移、活跃备份、故障只读和并发读取，避免把用户数据押在未经验证的 binding 上。
- 本次只解决：GRDB 7.11.1、SQLite.swift 0.16.0、系统 SQLite3 证据比较；隔离 `LinkDigestPersistence` 两表 spike；失败注入、1+8 并发和 10k Release benchmark。不接历史 UI、正式四表 Repository、真实 Application Support 或 Provider。
- 角色与交接：未来 Application Service 只应交给 Repository Port；本轮 tests/benchmark 调用 `LinkDigestPersistence`，模块内部 GRDB 再交给系统 SQLite。Core、SwiftUI、Capture、Provider 与 Native Host 没有持有 binding 类型。
- 本次核心名词：Binding、WAL、Migration、Online Backup、Read-only Recovery。
- 候选选择：GRDB 7.11.1 exact，MIT，本机 resolved graph 无传递 package，SwiftPM Debug/Release 通过；SQLite.swift tag 声明两个条件包且需要更多备份/并发封装；系统 SQLite3 需要自行承担 C 生命周期与 Swift 并发边界。
- 被证据修正的一点：首轮误在 GRDB `write` 自动事务内再开事务，触发嵌套事务失败；改为单层 `write` 后，注入异常仍自动回滚。第二处是 Online Backup 目标继承 WAL mode 后不能作为无 sidecar 的独立只读文件打开；现只在备份目标连接上切回 DELETE journal，活跃源库保持 WAL，全程不复制主文件。
- 自动验证（历史 Spike 记录）：persistence 12/12；SwiftPM Debug/Release；事务、WAL/checkpoint、Online Backup/恢复 integrity、future schema、migration 失败、不可写存储、错误路径脱敏、1 writer + 8 readers 均通过。10k Release 首页 p95 0.048000 ms、详情 p95 0.033750 ms，各 30 个 raw samples，门槛 300 ms。当时完整 Swift suite 的 58 项中有 10 项环境失败；这不是当前状态，02B 后续已记录完整 Swift 117/117 通过。
- 许可证：`bash scripts/check-swift-licenses` 独立校验 GRDB exact pin、revision、零传递依赖与 MIT notice；pnpm license check不代替 Swift 检查。MIT notice需进入未来第三方清单。
- 历史环境快照：当时 `pnpm xcode:build` 首个 scheme 在 package resolution 被 Hana 外层 nested sandbox 的 `sandbox_apply: Operation not permitted` 阻断；完整 Swift suite 另有上述 Network/Keychain/socket 环境失败。未改 Xcode defaults、全局安全、既有测试或 Package 约束。该记录已被后续 02B 的 Xcode 四目标与 Swift 117/117 工程证据取代，不能再写成当前 Xcode BLOCKED。
- 仓库集成修正：首次 `pnpm check:web` 把新生成的 SwiftPM checkout 当成项目 JavaScript，报告 798 个上游 SQLite WASM lint错误；ESLint现只忽略 `apps/desktop/.build/**`，重跑 check:web全通过，项目源码规则未放宽。
- 失败与恢复：future schema、migration 失败、文件/目录不可写时拒绝写入，数据可读时保留 projection；不删库。回滚本 spike只移除新增 package pin、target、tests、benchmark、脚本和文档，绝不触碰既有 Brain/V0.1 改动或真实用户数据。
- 过程讲解：在候选复核、事务失败、WAL 备份恢复和 benchmark 四个节点就地解释了组件职责、交接物、失败表现和恢复方式。
- 可选跟做：运行 `pnpm sqlite:spike` 观察 12 项恢复测试，或运行 `pnpm sqlite:benchmark:release` 查看 JSON raw samples；两者都只使用临时库，不是后续开发门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：SQLite WAL checkpoint、Online Backup 生命周期或正式 migration 001 冻结可分别另开小窗口。

## 任务 020：P0-RC-02A 正式 History Domain、migration 001 与 GRDB Repository

- 日期：2026-07-15
- 当前状态：独立 Sol xhigh 复审通过。旧候选未被接受、未进入用户数据库；修订后的 migration 001 是首个已接受并冻结版本，后续只能追加 002+。
- 用户场景：浏览器传来的同一链接和正文重试不会重复建档，正文变化会形成新 Snapshot；总结/翻译 Run、partial、usage/cost、删除、详情与导出 projection 可在本机事务化保存并恢复。
- 角色与交接：CaptureEnvelopeV1 先交给现有 validator；Core 生成 Canonical URL、payload/body fingerprint 和 Repository 命令；GRDB Adapter 在单事务内交给 migration 001 五表；Application/UI 只拿 projection，不持有 SQL 或 GRDB。
- 本次核心名词：Canonical URL、Payload Fingerprint、Repository Port、Forward Migration、Keyset Pagination。
- 被证据修正的判断：最初以为读取端显式 `CAST(body_text AS BLOB)` 足以保留 U+0000；专项测试仍只读到 `a`，证明 Swift String SQL binding 在写入端已经截断。Snapshot 与 Artifact 正式路径均改为完整 UTF-8 Data 绑定后在 SQLite 内 cast 为 TEXT，detail/export 再由 BLOB bytes 严格解码；History preview 只取 bounded blob 并生成最长合法前缀。
- 事务证据：capture ledger/Task/Snapshot 同事务；terminal/Artifact/usage-cost 同事务。事务中点注入失败后 Run 仍 running，Artifact 与 usage/cost 均不存在。
- 恢复证据：migration 注入失败保持 user_version 0 且零半表；future schema 只读；PASSIVE/TRUNCATE checkpoint、Online Backup、staging restore、integrity/foreign key/五表计数均通过。
- 并发证据：1 writer + 8 readers 使用统一 start gate 和 writer-start overlap witness，10 秒上限、安全 cancellation flag，最终 120 Task 无丢写；超时收口等待覆盖 2 秒 SQLite busy timeout。两个独立 DatabasePool 的 capture/run 竞态分别验证同 payload 幂等与不同语义稳定 conflict。
- benchmark：Release 10k Task、12k Snapshot、15k Run、15k Artifact，含计时外验证的 NUL Artifact；首页 p95 0.57275 ms，详情 p95 0.129084 ms，各 30 raw samples，门槛 300 ms。Debug executable 按编译条件以 status 64 拒绝。
- 过程讲解：在 Core 边界、事务原子性、NUL 失败修正与正式 benchmark 四个节点同步解释了职责、交接物、失败表现和恢复方式。
- 可选跟做：运行 `pnpm history:test` 看 02A 专项，或读取新 benchmark evidence 的 30+30 raw samples；均只使用隔离临时目录，不是后续开发门槛。
- Syc 主动提出的待解释点：无。
- 独立复审修订：补齐 Artifact `a\0b`/`\0a` partial、terminal、reopen、recovery、detail、export、preview；UUID extra-hyphen 反例；latest Run 时间与 Task 排序时间冻结语义；Release 编译条件 benchmark。
- 回滚：只移除 02A Core/Persistence/Tests/benchmark/fixtures/文档并恢复 Package/scripts；不删库、不触碰 Brain、V0.1/V0.2 或真实用户资料。migration 001 已冻结，后续不得直接修订。

## 任务 021：P0-RC-02B App Capture / Run 持久化接线

- 日期：2026-07-15
- 当前状态：02B 已完成并独立 PASS；最终主线程 Swift 117/117、SwiftPM Debug/Release、Web 与 Xcode 四目标通过。历史 Sidebar/详情/删除 UI 与导出仍未启动。
- 用户场景：浏览器正文只有在本地 archive 事务提交后才出现在当前窗口并返回 ACK；总结/翻译从 queued 到 terminal 的每一步都留下可恢复记录，写入失败不会让 UI 假装成功。
- 角色与交接：`AppComposition` 打开唯一 Repository/Service并完成 recovery gate；`CaptureReceiver` 把 frame 交给 validator、History service、MainActor UI 与 ACK；现有 `ModelRunOrchestrator` 独占 Run、Provider、partial、terminal、stop 与 stale ownership。
- 本次核心名词：Composition Root、Recovery Gate、Committed Partial、Stale Run。
- 过程讲解：开工时解释了三个组件的交接；实现 storage error 时说明 stable code 会丢弃 raw path/SQL；实现流式持久化时用“账本确认后才更新余额”类比 candidate 与 committed partial；专项测试时解释 recovery→server 与 commit→UI→ACK 的可观察顺序。
- 被证据修正的一点：最初 receiver 测试夹具使用合同不允许的 `platform: test`，所以正确得到 protocol rejection；改为 schema 允许的 `generic` 后，read-only/open/recovery 与 storage request ID 分层全部通过。
- 自动证据：高风险、设计、安全与并发专项 60/60，包括 Composition 4/4、CaptureReceiver 7/7、temp GRDB Orchestrator 8/8、Persistent Orchestrator 14/14、Orchestrator 并发/回归 13/13、History Domain 4/4、AppViewModel 10/10。Ordered blocker 证明 commit success 前无 ACK/UI/normal server；恶意 Provider 忽略取消仍无迟到污染；temp reopen 证明 usage 五列 NULL 与写失败后 interrupted recovery。安全预审后新增 starting/stopping/streaming callback barrier、producer 注册/取消、Stop/completed 双线性化、RunID mismatch conflict、terminal failure 后新 Run、split-secret holdback/flush failure、hostile late events、MainActor 旧状态矩阵与 24 路并发 Capture 一致性；完整 Swift 117/117、Debug/Release、Web、licenses、secret、doctor 与 diff PASS。production vertical smoke 的隔离注入在后续 Gate 0 任务中实际补齐并通过。
- 安全边界：没有启动生产 App，没有访问真实 Application Support、浏览器资料、Keychain 或 Provider；App/Core 不 import GRDB 或持有 SQL；storage `safeDetail` 默认为 nil；migration 001 hash 保持冻结值。
- 可选跟做：运行 `swift test --disable-sandbox --filter 'AppCompositionTests|CaptureReceiverTests|PersistentModelRunOrchestratorTests'`，观察时序与 rollback 断言；它只使用 fake/temp，不是任务关闭门槛。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 App→Persistence 接线、新 App 文件、Orchestrator 扩展、02B tests/docs；不删库、不降级、不清理真实 Application Support/Keychain，也不触碰 V0.1 Host。

## 任务 022：Gate 0 安全 production vertical smoke

- 日期：2026-07-15
- 当前状态：完成本地最小修正与 Gate 0 验证；02A 已独立通过，02B 已独立 PASS。历史 Sidebar/详情/单项删除和 Markdown/TXT/JSON Export 均未开始，也不属于本任务。
- 用户场景：浏览器送来 Capture 时，真实 App composition 必须能把事务提交到本地历史并返回 ACK；工程 smoke 同时不能把这次验证误写到用户已有的历史数据库。
- 角色与交接：`run-vertical-smoke.sh` 创建专属临时 Application Support root 并把它作为明确交接物传入 Debug App；`AppApplicationSupportRoot` 只在 Debug 读取该 root，`AppComposition` 再把同一 root 交给 `LocalDatabaseLocation`/Repository；Host 与 socket 维持既有 20 次 Capture 交接。
- 本次核心名词：显式注入（把测试目录直接交给组件，而不是让组件自己猜目录）、live resolver（正常运行时查用户 Application Support 的单一函数）、fail-closed guard（测试模式一旦意外回退到 live resolver 就拒绝而非继续）。
- 自动证据：`AppCompositionTests` 7/7 PASS，其中 root 注入用例把 live resolver 设为必定失败仍得到临时 root，failure 注入只接受精确值 `1`。`./scripts/run-vertical-smoke.sh` 在成功与确定性失败两条路径均 PASS：成功 20/20 `taskAccepted`，失败 20/20 `STORAGE_UNAVAILABLE`；每条路径都在运行前后记录并比较真实 `~/Library/Application Support/LinkDigest` 的非内容状态指纹，二者相同。成功路径仅在专属临时 root 创建 `history.sqlite`，失败路径不创建临时数据库目录；退出后断言脚本创建的临时 root 已不存在。
- 失败与恢复：如果 socket、数据库创建、结构化失败响应或 20 次 Capture 任一断言失败，脚本仍停止 App，并且只删除这次 `mktemp` 创建的临时 root（socket、log 与 Application Support 都在其中）；不会删除、reset、降级或清理真实用户数据库。若 future change 意外调用 live resolver，Debug guard 会让 App 落入结构化 storage unavailable，smoke 不能得到 `taskAccepted`，从而失败而不是触碰真实目录。
- 安全边界：override 只编译入 Debug，Release 始终使用正常 live root；没有真实 Provider、Key、Cookie、浏览器资料或私人正文，没有改 migration 001，也未创建 Migration002。
- 可选跟做：运行 `./scripts/run-vertical-smoke.sh`，它会自行创建和删除临时 root；终端的 PASS 说明一次真实进程链路完成，但不等于产品发布验收。
- Syc 主动提出的待解释点：无。
- 回滚：撤销本任务的 Debug root resolver、两项 composition tests、smoke 脚本与状态文档即可；绝不对用户的 Application Support 数据执行任何删除或 schema 操作。

## 任务 023：Gate 0 最终阻断修复与 baseline fast-forward

- 日期：2026-07-15
- 当前状态：工程门禁已通过，等待 Issue 审查；这不表示 History UI、详情/删除、Export、安装、签名、公证、发布或 Syc 产品验收完成。
- 用户场景：RC smoke 必须同时证明正常交接和存储无法打开时的用户可恢复响应，而且验证本身绝不能影响已有本地历史；依赖审计也不能以忽略告警取代修复。
- 角色与交接：shell smoke 把唯一新建的临时 Application Support root 交给 Debug composition；composition 在成功时交给 GRDB，在精确的 Debug failure 开关下交给既有 storage-unavailable 分支；Host 只转发 frame 和结构化响应。Ajv 2020 与 `ajv-formats` 继续在构建期生成 MV3 可用 validator，不改变 wire contract。
- 本次核心名词：状态指纹（不打印正文或文件名的目录状态摘要）、确定性失败注入（不依赖权限偶然性地走同一失败分支）、production audit（只检查实际随产品交付的依赖）。
- 自动证据：GHSA-2g4f-4pwh-qvx6 的受影响范围 `< 8.18.0` 已以 Ajv 8.18.0 修复；`pnpm audit --prod` 为 0 vulnerability。Web、Swift 120/120、SwiftPM Debug/Release、Xcode 四目标、history Release benchmark、contracts/generated validator、licenses、secret hygiene、doctor、success/failure vertical smoke、migration 001 hash 与无 Migration002 均已重跑通过。
- 安全边界：failure 开关只在 Debug 对精确值 `1` 生效，Release 不读取它；state comparison 不输出真实目录内容；cleanup 只删除脚本本次创建的临时 root。没有 Provider、API Key、Cookie、真实正文、签名、公证或发布。
- 可选跟做：运行 `./scripts/run-vertical-smoke.sh`，观察 success 与 failure 各 20 次 Host → socket → App 响应以及相同状态指纹；该动作不写真实 Application Support，也不是关闭 Issue 的前提。
- 回滚：回退本任务的 smoke failure 开关、其单元测试、Ajv 8.18.0 lock/declarations 和状态文档；绝不触碰 migration 001、真实用户数据库或 Keychain。

## 任务 024：P0-RC-02C History Sidebar、详情、删除与只读浏览

- 日期：2026-07-16
- 当前状态：工程实现、六状态视觉证据与 Design QA 已通过；工作区改动尚未暂存、提交或推送。Markdown/TXT/JSON Export、真实安装包、签名、公证和发布仍未开始。
- 用户场景：用户从浏览器提交页面并生成结果后，退出重开仍能在原生左栏找回记录、查看详情并安全删除单项；未来版本数据库不能被旧版本误写，但原数据仍应可读。
- 本次只解决：1100×760 `NavigationSplitView`、340pt History Sidebar、禁用搜索占位、keyset 分页、详情、原生删除确认、重启读取、future-schema 只读浏览，以及 Sam 参考下的像素级壳层/排版对齐。添加链接、剪贴板、分享、Rerun、格式与 Export 只保留参考位置或后续范围，不在本轮接业务。
- 角色与交接：`AppComposition` 打开唯一 Repository，并把 writable Service 同时交给 Capture/Run/History，把 read-only Service 只交给 History；`HistoryViewModel` 在后台读取 projection、用请求身份闸门拒绝旧回写、串行执行删除；`HistoryContentView` 只展示状态和发起意图；`AppViewModel` 用 RunID→TaskID 绑定保护正在生成的真实 Task，而不是跟随可变化的 current Capture。
- 本次核心名词：NavigationSplitView、Request Identity Guard、Deletion Target Binding。场景中的分工是“本地档案服务交 projection → ViewModel 管选择/异步身份 → 原生 View 展示”；没有这些边界时，慢请求会覆盖新选择，删除确认可能在新 Capture 到来后误删，生成中的 Task 也可能被级联删除并关闭全局写入闸门。
- 视觉决策：Syc 最终确认以用户提供的 Sam 空/有内容截图作为像素级布局参考；对齐窗口、分栏、搜索框、空状态、列表密度、标题、URL、两行元数据、toolbar 和正文节奏，但保留 LinkDigest 名称、产品文案与功能边界，不复制 Sam 品牌、Logo、专有美术或内容资产。
- 被证据修正的判断：Multica 候选曾整体替换旧 `ContentView`，会丢失总结/翻译/停止/流式结果，因此只迁移思路并人工整合。首轮截图又证明列宽 modifier 放错容器后真实只有约 300pt，而不是代码写下的 340pt；真实 loading 截图还证明 Foundation 会把 `/private/tmp` 规范化成 `/tmp`，使旧 Debug gate 失效。独立代码复审进一步发现删除确认目标漂移、活跃 Run 删除，以及 Run A 生成时 Capture B 到来后保护 ID 漂移，最终分别以 `pendingDeletionTaskID`、请求/确认双重保护和 RunID→TaskID 绑定修复。
- 自动证据：完整 Swift 130/130；SwiftPM Debug/Release；`pnpm --config.verifyDepsBeforeRun=false check` 的 Web、contracts、secret、host/vertical smoke 全通过（首次裸 `pnpm check` 因无 TTY 将尝试清理依赖目录而主动中止，未执行依赖安装或清理）；Xcode App/Host Debug/Release 四目标；10k Release History 首页 p95 2.521208 ms、详情 p95 0.231208 ms，均低于 300 ms；pnpm/Swift licenses、production audit 0 vulnerability、`git diff --check`、migration 001 冻结 hash 与无 Migration002 均通过。
- 视觉证据：空历史、列表+详情、删除确认、稳定 loading、阻断错误、future-schema 只读六态均由主仓库 Debug App 在隔离 `/private/tmp/linkdigest-history-state.*` 中实拍；空/有内容参考与实现放入同一张 1100×760 对照图。Design QA 迭代修复了列宽、搜索图标、空状态字号、元数据方向、纵向节奏、loading gate 与只读说明/对比度，最终独立视觉复审 PASS。
- 安全边界：截图数据完全脱敏；没有访问真实 Provider、API Key、Cookie、浏览器账号或真实 Application Support。Debug loading gate 同时要求精确环境值、限定临时路径和 sentinel，Release 编译不启用。future-schema 只读时 Capture/Run/Delete 均拒写，migration 001 字节未变。
- 过程讲解：开工时用“当前 Capture 与历史 archive 共用同一 Task/Run 交接物”解释两套界面为何必须合并；实现期解释了请求身份闸门与后台 Repository worker；视觉期用真实截图说明“代码标值不等于真实渲染”；复审期解释删除目标、活跃 Run 与 current Capture 是三个不同身份，不能混用。
- 可选跟做：打开 `docs/evidence/SYC_64_STAGE_2/contact-sheet.png` 查看六种用户状态，或并排查看 `compare-empty-final.png` / `compare-populated-final.png`；这是理解入口，不是关闭任务的考试。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 02C App/ViewModel/View/tests 与状态文档，保留 02A/02B Repository、Capture/Run 持久化和 Provider 能力；绝不删库、降级 migration、清理真实 Application Support 或 Keychain。

## 任务 025：P0-RC Loop 2 单条 History 本地导出

- 日期：2026-07-16
- 当前状态：独立复审发现的文件名字节预算、Run 显示归属、启动待定删除保护、JSON 解码校验和 usage 展示问题已修复并通过本地门禁；最终独立复审 PASS，P0/P1/P2 均为 0；工作区改动未暂存、未提交、未发布。
- 用户场景：用户在历史详情中需要把一条记录带走或备份，即使本机数据库因 future schema 只能只读，也不能被困在旧版本里。
- 本次只解决：详情右上角现有分享入口的 Markdown、纯文本（.txt）、JSON 三格式导出；安全文件名、原生保存/取消/覆盖、固定失败恢复，以及快速切换历史时的旧导出隔离。没有新增数据库写入、Migration002、网络、Provider、Keychain、Cookie 或真实用户目录访问。
- 角色与交接：用户在分享菜单选择格式 -> HistoryViewModel 冻结当前 Task、generation 和 request identity -> 非 MainActor 的 HistoryRepositoryWorker 向 HistoryApplicationService 读取 HistoryExportProjection -> LinkDigestCore 的 HistoryExportRenderer 生成脱敏 Data -> HistoryExportDocument 把 Data 交给 SwiftUI fileExporter -> macOS 保存面板选择目录并处理同名覆盖。读取/生成失败显示固定安全中文提示；保存失败提示检查目录权限；取消只清理内存状态、不报错。
- 本次核心名词：Export Projection（给外借档案准备的安全快照）、Renderer（同一份快照的三种排版机）、FileDocument（交给系统保存面板的文件信封）、Export Request Identity（旧请求不能打开新选择的保存面板）。四个名词已同步加入 GLOSSARY，核心边界提供到 L3。
- 技术选择：Core 只依赖 Foundation，返回 HistoryExportFile 的字节和建议文件名；不让 Core 依赖 SwiftUI、AppKit、GRDB 或文件系统。建议文件名按 macOS `NAME_MAX` 的 255 UTF-8 bytes 限制，并在完整 Swift Character 边界截断，预留 `.1.md` / `.1.txt` / `.1.json` 后缀。JSON 使用 prettyPrinted、sortedKeys、withoutEscapingSlashes；public decoder 除 formatVersion 外还校验 canonical typed UUID、usage/cost 领域约束与 Task/Snapshot/Run/Artifact 引用关系。Markdown/TXT 显示 input/output/total token，total 缺失且 input/output 齐全时安全求和。选择原生 fileExporter，而不是手写 AppKit 面板，因为它保留 macOS 的目录、同名覆盖和取消行为。
- 被证据修正的一点：首次 renderer 补丁因自动化字符串转义丢失 Swift 插值，focused build 立即在编译期拒绝；修正为保留插值后 Core tests 通过。并发测试最初在 MainActor 上立即等待 semaphore，阻止导出任务开始；先让任务让出执行机会后，真实 blocker 验证快速切换时旧导出不会弹窗。之后独立复审继续发现 Character 数不能代表 UTF-8 文件名字节、synthesized decoder 会绕过领域构造器、current Capture 与 visible Run 共用显示块会把 A 的输出贴到后来 Capture B，以及 `createRun` 返回前存在未保护删除窗口；本轮分别以 byte budget、显式 v1 decoder 校验、`visibleRunTaskID` 和不提前发布 `.starting` 的 launch-pending 保护修复，最终独立复审已确认这些阻断项关闭。
- 自动证据：最新 focused AppViewModelTests 15/15，完整回归中 HistoryExportRendererTests 10/10、HistoryViewModelTests 10/10；新增阻塞 `createRun`、pre-start storage failure、Orchestrator authority 无回调三条确定性用例，并继续覆盖 Capture B 到来前后 Run A 的停止/状态/输出归属。完整 `swift test --disable-sandbox` 146/146；SwiftPM Debug/Release、Xcode LinkDigestApp/LinkDigestNativeHost Debug/Release 四目标、`git diff --check` 均通过。migration 001 保持冻结 SHA-256 `2402fd0dcb8293010f3c080af583a98c50af661a200915c321e0faaccfb93b57`，未创建 Migration002。最终独立复审 PASS，P0/P1/P2 均为 0。
- 安全边界：HistoryExportProjection 构造和 JSON 编码均剥离 provider 配置、idempotency、cookie-use 标记与 raw error；导出不暴露 API Key、Token、Cookie、secret reference 或本机秘密路径。原文/结果作为用户选择导出的内容被保留；不将任何真实样本或凭据写入测试。
- 过程讲解：开工时先说明“档案服务交安全复印件 -> renderer 排版 -> 系统面板投递”的交接；实现 Core 时解释 renderer 为什么不碰文件系统；接 ViewModel 时解释 request identity 防止旧包裹送到新柜台；复审修复时继续解释 UTF-8 byte budget 与 Character 边界、`activeRunTaskID` 和 `visibleRunTaskID` 的不同职责、decoder 如何验收对象引用而不审查用户正文，以及 launch-pending 如何在不伪造 `.starting` 的前提下保护尚在 `createRun` 的真实 Task。
- 可选跟做（5-15 分钟）：运行 `cd apps/desktop && swift test --filter 'HistoryExportRendererTests|HistoryViewModelTests'`，观察三个安全输出和快速切换隔离断言；它只使用合成 fixture，不会访问 Application Support、Keychain 或网络，也不是任务关闭门槛。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 Loop 2 的 Core renderer/projection 编码、History ViewModel/View、专项测试和本文档；保留 02A/02B/02C 数据库、migration 001、Capture/Run 持久化和 Provider 能力；绝不删库、降级 migration 或清理真实 Application Support/Keychain。

## 任务 026：P0-RC Loop 3 原生数据去向确认与设置页连接测试

- 日期：2026-07-16
- 当前状态：**最终独立复审 PASS，P0/P1/P2 均为 0**。第二次独立复审的三项 P1 已通过 attempt owner、saved identity/generation、configuration revision/mutation owner 和确定性 barrier 关闭；Loop 3 已完成，可以进入 Stable Host 的规划与实现，但签名、公证或发布仍需 Syc 另行授权。
- 用户场景：Syc 在点击总结或翻译前，要先看清标题和网页正文会发送到哪一个模型服务、模型和模式；保存过同一目的地后不应每次打断，但换服务或模型时也不能沿用旧确认。配置完成后，还需要一个不污染历史的最小“门铃测试”。
- 角色与交接：`AppViewModel` 是寄件柜台：读取不含秘密的 `ProviderProfile` 并生成 `DataDestinationIdentity`；`ConsentStore` 是本机签收簿，只记 URL/model/mode；SwiftUI sheet 只呈现冻结的目的地与动作；只有确认仍匹配当前 Capture/设置后，ViewModel 才创建 `PersistentRunRequest` 交给既有 `ModelRunOrchestrator`。连接测试从 `ProviderSettingsViewModel` 交给同一 `ModelProvider` 的 `connectionTest` intent，不经过 History service。
- 本次核心名词：Data Destination Identity、Consent Gate、Connection Test。前两个提供到 L3：可在单测中观察“取消零调用、Capture/配置变化不误发、写入失败仅本次放行”；连接测试提供到 L3：可观察 fake Provider 的 success/failure/重复点击隔离。名词已同步到 `GLOSSARY.md`。
- 工作流：用户点总结/翻译 → 读取非敏感配置 → 已确认则再次核对身份后开始，否则显示确认 sheet → 用户取消时清理内存确认；用户确认时冻结 Capture 的 TaskID/SnapshotID/正文和 intent，并在 consent write 后再比较配置。若页面或配置变化，旧请求不发送，改为取消或新 sheet。连接测试只发送 `Reply with OK.`，不保存 delta、回复、History、Run 或 Artifact。
- 失败与恢复：Consent/UserDefaults 读失败视为未确认并要求本次确认；写失败时明确提示“只允许本次、下次再询问”，绝不静默长期放行。没有 profile、Keychain 读取失败、401、429、5xx、malformed 等只通过 `V02ErrorCatalog` 显示安全中文恢复文案，不回显 API Key、raw body/header/URL error。取消确认不创建 Run，也不调用 Provider。
- 自动证据：实现侧完整 `swift test --disable-sandbox` 为 178/178；独立复审另跑 focused 53/53、安全过滤完整 Swift 177/177（按禁令排除唯一真实 Keychain 用例）、SwiftPM Release 与 Xcode App/Host Debug/Release 四目标。secret hygiene、Swift license、`git diff --check`、Brain lint、migration 001 冻结 hash `2402fd0dcb8293010f3c080af583a98c50af661a200915c321e0faaccfb93b57` 与无 Migration002 通过。14 个确定性 barrier 覆盖 App identity/consent/authorize/launch、Core save/authorize revision、Settings generation/双击和同一 production consent store 并发写；另补未配置后保存重试、profile/authorization 失败释放与 consent write failure 下次重显。最终安全复审还在真实 SwiftPM Release 外部模块中验证 `ProviderAuthorization` 的普通描述、反射描述、字符串插值、`debugPrint`、`dump` 与 `Mirror.children` 只输出固定 `[REDACTED]`，真实 sentinel key、reference、host、model、identity 与 Base URL 均不出现。`pnpm --config.verifyDepsBeforeRun=false check` 的 lint/typecheck/Web tests/extension build/secret hygiene 均通过，但 doctor 的 pnpm license 子检查因本机 pnpm store 缺少 Ajv 8.18.0 package index 返回 `ERR_PNPM_MISSING_PACKAGE_INDEX_FILE`；遵守“不安装依赖”边界未修复环境缓存，因此整体命令退出 1。全部测试使用 fake Provider/store、隔离 UserDefaults/临时数据库，没有调用真实 Provider、用户 Keychain 或用户数据库。
- 被证据修正的一点：首次复审关闭了 Release 编译和确认 A/发送 B 的直接误发；第二次复审进一步证明“使用冻结 A”仍不足以表示配置变化流程正确——如果 save(B) 已开始但未提交，authorize(A) 仍可能放行。本轮因此把 preparation token 收口成 attempt-scoped 单一状态源，把设置测试绑定 saved identity/generation，并用 actor revision + mutation owner 让 save/authorize fail closed；真实 barrier 证明迟到 continuation 只能 no-op。最终复审还证明“不可 Codable、字段 internal”不等于不会泄密：Swift 默认字符串化与 `dump/Mirror` 仍可能反射秘密；通过固定 description/debugDescription 与 leaf mirror 才关闭全部已验证输出路径。
- 过程讲解：开工先用“寄件柜台与签收簿”说明为什么确认不能放到 Provider 之后；修复期用受理单、草稿修订号和保险柜换锁解释 attempt、generation、revision 的角色与交接，并在每个 barrier 放行点观察 A 不得清理或发送 B。可选跟做是运行 `cd apps/desktop && swift test --disable-sandbox --filter 'AppViewModelTests|ProviderSettingsViewModelTests|ProviderConfigurationTests|ProviderStoreTests'`；它只运行假对象与隔离 UserDefaults，不是任务关闭门槛。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 `DataDestinationIdentity`/consent adapter、AppViewModel/SwiftUI sheet、设置页测试状态及对应测试/文档；保留现有 Provider、Keychain、Run persistence、migration 001、History 和导出。绝不清理真实 UserDefaults、Application Support 或 Keychain。

## 任务 027：P0-RC Loop 4 Stable Host package 与 clean-room 初装

- 日期：2026-07-16
- 当前状态：**Loop 4 r1 最终独立 re-review PASS，P0/P1/P2 均为 0**。stable package deterministic check 56 项通过；真实 HOME/浏览器安装、升级、卸载、完整 rollback、`.app`/DMG、签名、公证和发布均未执行，仍需 Syc 另行授权。
- 用户场景：开发期 `.build` Host 虽能通信，但用户无法把它当作完整、可搬迁、可验真的交付物；安装验证还必须保证不会碰真实浏览器和 Application Support。
- 本次只解决：canonical Host config、显式新输出根的 `arm64` Release package、严格 verifier、单一 manifest renderer，以及带 sentinel 的系统临时 clean-room 初装/noop/receipt/failure cleanup。r2 升级/真实卸载/完整事务 rollback 与 r3 RC acceptance 不进入本轮。
- 角色与交接：`config/native-host.json` 交 canonical metadata 给 builder；builder 把 Host、resource bundle、metadata 与 checksums 交给 verifier；verifier 的 package digest 交给 manifest renderer/installer；installer 只把 version directory、browser manifests 和 receipt 写入隔离 HOME；packaged Host smoke 最后验证运行交接。
- 本次核心名词：Host Package、Resource Bundle、Package Verifier、Clean-room Install、Install Receipt。前四项提供到 L3：可观察 package 树、缺 bundle runtime 失败、tamper 拒绝和真实 HOME digest 不变；receipt 提供到 L2，作为未来 r2 ownership 基础。名词已同步到 `GLOSSARY.md`。
- 技术选择：使用 Python 标准库集中 config/verify/render/install 规则，Shell 只提供稳定入口，SwiftPM 只负责编译；不新增依赖。release extension IDs 当前为空并明确 `not-frozen`，测试 ID 只从 CLI 注入。初装遇到未知目标直接拒绝，不覆盖/备份，因为 upgrade 语义必须留给 r2。
- `.build` 回退证据：现场读取 SwiftPM 生成的 `resource_bundle_accessor.swift`，确认 binary 含开发机 buildPath。deterministic check 因此在排除 `.git/.build/node_modules/output/evidence` 的一次性源码副本中离线构建；package 移到含空格/Unicode 路径后删除副本 `.build`，再跑 offline/oversize/timeout Host smoke。另把同一 Host 放到缺 bundle 目录，要求不能返回有效 frame，排除原仓 `.build` 假阳性。
- 路径与事务边界：session/home 必须位于 fixed canonical `/private/tmp`，不读取 `TMPDIR`/`tempfile.gettempdir()`；basename 带 `linkdigest-host-clean-room.`、已有精确 sentinel，home 是 session direct child；从 `/` 到 version/manifest/receipt 每个现存祖先逐级 `lstat` 拒绝 symlink。dry-run 零写；同 digest 二次 apply noop 且 mtime 不变；failure injection 的正常异常路径只清理本事务精确创建路径。`home/Library` 指向 scope 外的负例会在写入前拒绝，外部 marker 保持不变。
- 自动证据：实现与独立 re-review 均完整运行 `check-stable-package.sh`，56 assertions PASS，覆盖 clean-source build/verify、Unicode move、verified package-root Host smoke、raw Host/skip-build/socket override 拒绝、缺 bundle runtime、manifest IDs/release fail closed、Chrome/Brave、Edge、apply/noop/unknown target/额外空目录/failure cleanup/receipt、tamper，以及 Darwin scope 外 clean-room + `TMPDIR=$PWD/$HOME` 零写入。两次 poisoned vertical smoke 均只用 `/private/tmp`，poison root、真实 LinkDigest HOME 与 Git status 不变。
- 被证据修正的判断：初次源码复制误碰浏览器 `output/` dangling symlink，后将其作为用户/运行证据排除；SwiftPM local Git mirror仍想联网补 GRDB 测试 submodule，改为 audit-local path dependency且不改仓库 manifest；Codex sandbox 禁止 Unix socket，只对 hard-gated check使用允许 socket 的执行权限；Darwin `sun_path` 过长后将 audit root固定到 canonical `/private/tmp`，socket tamper 在短路径创建 inode 后移动入深层 package。
- 失败与恢复：package/verifier 失败不创建输出或安装目标；installer 在进程正常抛错的注入路径 best-effort 删除本事务 staging/version/manifest/receipt，不删既有内容，但 SIGKILL/crash recovery 不在 r1。若 release ID 未冻结、真实 HOME/path gate 不安全或删除副本 `.build` 后 Host 仍只能靠 fallback，本轮必须 BLOCK；当前三项停止门禁均未触发。
- 可选跟做（5–15 分钟）：运行 `pnpm --config.verifyDepsBeforeRun=false native-host:config:check` 观察 config/background 同步门禁；它只读、不构建、不安装。完整 stable check 会创建并保留两个 `/private/tmp` 审计目录，适合需要共同检查 package/receipt/tamper case 时再运行，不是任务关闭考试。
- 完整回归：Swift focused 54/54；显式跳过唯一真实 Keychain 用例后的完整 Swift 177/177；SwiftPM Debug/Release；Xcode App/Host Debug/Release 四目标；native-host dev check；vertical smoke success/failure 各 20/20；Swift license、secret hygiene、migration 001 hash、无 Migration002、diff、Brain/config/contracts 均通过。Web lint 通过；typecheck/test/browser build 因当前 node_modules 缺 Ajv/Ajv-formats workspace symlink 被环境阻断。Web license/doctor 复现 pnpm Ajv 8.18.0 package index 缺失，doctor 为 PASS=60/WARN=1/FAIL=1 且唯一 FAIL 是 dependency licenses；遵守禁令未安装依赖。
- 独立 reviewer 透明记录：reviewer 在 BLOCK 轮误运行了唯一随机隔离 Keychain 测试；即使该测试当次通过，也不计入 Loop 4 证据。后续 focused/full Swift 一律显式 `--skip 'ProviderStoreTests/testKeychainWriteReadReplaceAndDeleteUsesIsolatedService'`。
- r1 残余：当前 failure cleanup 只覆盖进程正常返回/抛错路径，不是完整 rollback；SIGKILL、同用户并发 TOCTOU、无跨进程 lock、无 dirfd/openat 路径绑定、无 transaction recovery 均留给 r2。
- 最终 re-review 审计入口：`/private/tmp/linkdigest-stable-package-audit.buv9b6_5` 与 `/private/tmp/linkdigest-host-clean-room.audit.52p1ofbj` 仍保留、未清理。更早的实现/复审审计目录也按禁令保留。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 Loop 4 r1 config、builder/verifier/renderer/clean-room scripts、Host smoke override 与任务 027 文档；保留 Loop 3、migration 001、History、export 和 Provider。绝不删除真实 Application Support、浏览器 profile、Keychain 或用户数据库。

## 任务 028：P0-RC Loop 4 r2 Stable Host 可恢复事务

- 日期：2026-07-16
- 当前状态：**同一独立 reviewer 唯一 re-review PASS，P0/P1/P2 = 0/0/0**。首次 BLOCK 的三项 P1 均已关闭；r2 fast gate 110/110、配套 r1 compatibility gate 56/56 已由主控在获批 `/private/tmp` 范围现场运行通过。PASS 只覆盖 fixed canonical `/private/tmp` clean-room；真实 HOME/浏览器安装与 profile ownership、Keychain/数据库/Provider、Developer ID、签名、公证、stapling 和发布均未触碰。
- 用户场景：r1 初装可以验证 package 与 ownership 起点，但升级或卸载若遇到另一个进程、正常异常或 SIGKILL，用户不能接受“文件大概装了一半”；系统必须知道是恢复旧版本，还是确认新版本已提交后完成收尾。
- 本次只解决：永久预置 clean-room lock、canonical plan digest、receipt v2 ownership/lineage、durable transaction journal、receipt commit point、initial/v1 migration/manifest reconcile/严格升级/卸载/noop/recover、确定性 crash barriers 与 fail-closed STOP 条件。明确不做真实安装、旧版本 GC、签名真实性、同 UID 恶意进程或断电/文件系统故障的形式化证明。
- 角色与交接：调用方先在 `/private/tmp` session 预置 sentinel 与 `.transaction.lock`；`plan` 只读核对 package/receipt/owned trees/manifests，交 canonical plan + digest；`apply` 抢占永久锁并在锁内重算相同计划，交 durable journal + staged/backups；live receipt 是 commit point；`recover` 读取 journal 与 receipt，提交前回滚、提交后向前 finalize。`transaction_host_check.py` 通过 SIGKILL、socket/leaf tamper、锁争用和 ownership drift 观察这条交接。
- 本次五个核心名词：Plan Digest（确认的施工清单指纹）、Cross-process Lock（唯一施工钥匙）、Transaction Journal（逐步签字的操作流水）、Receipt Ownership（精确产权清单）、Crash Recovery（查正式账本后决定撤销或补完）。Receipt Ownership、Cross-process Lock、Transaction Journal、Crash Recovery 已同步到 `GLOSSARY.md`，核心边界提供到 L3；Plan Digest 在 r2 规格中提供到 L3。
- 工作流：`plan` 生成 `planDigest` 与 `<action>:<digest>` confirmation → `apply` 获取非阻塞排他 `flock` → 锁内重算并拒绝 stale plan → journal 先以 `prepared` durable 落盘 → 备份/发布 version 与 manifests → 原子创建/替换 receipt（uninstall 为删除 receipt）形成 commit point → 清理 staged/backups 并标 `complete`。进程中断后，新 plan/apply 先返回 active transaction，`recover` 根据 live receipt 精确选择 rollback 或 finalize，再要求重新 plan。
- 关键选择 1：`.transaction.lock` 是调用方预置、事务代码只读其 leaf 且永不创建/替换/删除。这样 lock inode 在整段事务中稳定，missing、symlink、hardlink、FIFO、socket、mode/content/link-count 漂移会在 mutation 前拒绝；它约束协作进程，不宣称阻挡同 UID 恶意进程。
- 关键选择 2：commit point 选 live receipt，不选 journal 的 `receipt-committed` phase。因为进程可能在 receipt 已原子替换、journal phase 尚未来得及更新时 SIGKILL；恢复若只看 phase 会把已提交版本误回滚。receipt 精确等于 after state 就 finalize；精确等于 before state才 rollback；两者都不是则 exit 8 保留现场。
- 关键选择 3：receipt v2 冻结 current、lineage 与 owned manifests 的完整 path/hash/mode/tree inventory；严格升级把旧 current 追加到 lineage，r2 不 GC 旧版本。uninstall 只移动/删除 receipt 拥有的版本树与 manifests，测试中的 `history.sqlite`、export 和 install sibling 均保留。
- 关键选择 4：plan digest 绑定 canonical action、before/after ownership、package、manifest payloads 与 clean-room roots；`apply` 在锁内重算。digest 只证明计划与执行输入一致，package checksum 只证明内容一致性，二者都不是 Developer ID 签名、来源认证或发布真实性。
- 首次独立复审 BLOCK：reviewer 给出 P0/P1/P2 = 0/3/0。第一项是 Edge profile 可以与 owned current version、install namespace 或 verified package root 互相包含，manifest 可能被事务自身移动/删除；第二项是 transaction 为支持新版本 fixture 而把 r1 verifier 的默认 productVersion 合同全局放宽；第三项是 journal 只检查外壳，深层 malformed plan 可能抛未分类异常并返回 exit 70。该 BLOCK 保留为历史证据，不能被后续绿灯覆盖或改写成“首次就通过”。
- BLOCK 修复选择：所有 Edge profile/manifest target 与 `install_rel`/`packageRoot` 做双向父子 overlap 拒绝，并在 plan 与 journal recover 两次验证；r1 verifier 无显式参数时继续精确认 canonical `0.1.0`，transaction 先解析安全 SemVer 后显式传 expected version；journal plan 的 exact keys、phase、action/operation、roots、before/after ownership、tree/manifest/payload 关系全部 strict validate，malformed 统一包装为 `RECOVERY_REQUIRED` exit 8 并保留现场。
- 首次失败与恢复：首次在受限 Codex sandbox 运行 r2 gate，制造 Unix domain socket tamper leaf 时触发 `PermissionError`；失败现场保留在 `/private/tmp/linkdigest-transaction-host-audit.ul6oa441`，没有把这个环境限制当实现失败。按授权只对 `/private/tmp` clean-room 重跑后 86/86 PASS，成功审计根 `/private/tmp/linkdigest-transaction-host-audit.4cuyynw2` 保留。没有扩大到真实 HOME、安装依赖或修改系统配置。
- 首次候选自动证据（历史保留）：r2 fast gate **86/86**，覆盖 verified r1/v2 fixture、package hardlink、七类坏锁、lock busy、stale plan、session inode replacement、ownership leaf tamper、initial/v1 migration/upgrade/lineage/uninstall、未拥有数据保留、正常异常 rollback metadata、四个 SIGKILL 窗口、scaffold recover、poisoned `TMPDIR`、真实 HOME/worktree digest 不变。配套 r1 stable gate **56/56**，审计根 `/private/tmp/linkdigest-stable-package-audit.lgrq74qb` 与 `/private/tmp/linkdigest-host-clean-room.audit.oewzmpej`；记录到的真实 HOME metadata digest 前后均为 `7925d3e9…de1e4`。这些证据发生在首次 BLOCK 之前，不足以关闭三项 P1。
- BLOCK 修复自动证据：r2 fast gate **110/110**，在旧 86 项上新增 default/independent Edge 正例、current version/install descendant/package root/package descendant 双向 overlap 负例、r1 canonical productVersion 默认拒绝、transaction 显式 expected version，以及 malformed journal exact schema/relationship/exit 8 保留现场回归。r2 audit 为 `/private/tmp/linkdigest-transaction-host-audit.wowu7fax`。配套 r1 compatibility gate **56/56**，audit 为 `/private/tmp/linkdigest-stable-package-audit.4wfrzojr` 与 `/private/tmp/linkdigest-host-clean-room.audit.remagrgu`；56 项只是兼容回归，不是新的 r1 final review。真实 HOME metadata digest 仍为 `7925d3e9…de1e4`。
- 最终独立 re-review：同一 reviewer 唯一 re-review 确认 Edge overlap 两层拒绝、r1 canonical `0.1.0` 默认严格/transaction 显式 expected version、journal strict schema/malformed exit 8 三项 P1 全部关闭，结论 **PASS，P0/P1/P2 = 0/0/0**。该 PASS 不扩大证据范围：不代表真实 HOME/browser 安装、profile ownership、Developer ID、签名、公证/stapling 或发布，也不宣称对同 UID 恶意进程、断电或所有文件系统故障提供形式化证明。
- 文档交接验证：初版 `package.json` JSON parse、`git diff --check`、Brain `lint-links`、Shell syntax 与新文件 whitespace 均通过；`pnpm --config.verifyDepsBeforeRun=false secret:check` 为 `secret-hygiene: OK`。首次直接运行 `pnpm secret:check` 先触发 pnpm pre-run 依赖完整性校验，并因 DNS `ENOTFOUND` 尝试修补缺失 Ajv；没有改动 tracked dependency manifest/lockfile，也未授权继续安装，随后把 `VERIFY.md` 的只读入口收紧为关闭该 pre-run 行为。`./scripts/doctor` 为 PASS=63/WARN=1/FAIL=1，唯一 FAIL 仍是既有 dependency licenses 环境项，WARN 是 dirty worktree；未安装依赖修复环境。首次 BLOCK 修复候选同步后再次运行 package JSON parse、`git diff --check`、Brain `lint-links` 与关闭 pre-run 的 secret hygiene，四项均通过；未重跑 110/56 长门禁。
- 退出与恢复：exit 3 表示锁忙，等待后重新 plan；4 表示 stale plan，重新确认；5 表示先 recover；6 表示 ownership drift，停止自动 mutation；7 表示异常已回滚；8 表示状态不能安全解释，保留 journal/backups/audit root 供人工审查。正常失败不得复用旧 digest，也不得手工批量删除 transaction namespace。
- STOP 条件：锁/anchor/receipt/manifest/version/journal/backup 任何一项无法精确解释；Edge profile/manifest 与 install/package tree 任一方向重叠；同时出现 v1/v2 receipt、多个 active journals、未知或 malformed journal/scaffold、commit state 既非 before 也非 after；参数逃出 `/private/tmp` clean-room；或有人试图把 checksum/110 项/r2 clean-room PASS 写成签名真实性、真实安装或同 UID/断电形式化证明。触发后保留现场并停止。
- 过程讲解：开工时用“施工清单 → 唯一钥匙 → 逐步签字 → 正式账本”说明 plan/lock/journal/receipt 的交接；实现阅读期把 session dirfd 比作抓住房屋地契的把手，解释路径字符串相同仍可能换 inode；恢复期用“正式入账前撤销、入账后补完”解释 commit point；证据期明确 Unix socket sandbox 失败属于运行权限层，而不是事务语义层。
- 可选跟做（5–15 分钟）：运行 `./scripts/native-host/clean-room-transaction.sh --help` 对照 `docs/specs/P0_RC_LOOP_4_R2_TRANSACTIONS.md` 的 plan/apply/recover 与退出码。若共同观察 plan，只使用已预置 sentinel 和 `.transaction.lock` 的现有 `/private/tmp` fixture；不要改成 `$HOME`。完整 110 项门禁已经运行，不是关闭任务的作业或考试。
- Syc 主动提出的待解释点：无。
- 下一步：进入 r3/真实安装前的范围、profile ownership、签名/公证与验收决策；任何真实写入仍需 Syc 另行授权，r2 PASS 不自动授予执行权限。
- 回滚：只撤销 r2 transaction host/wrapper/check、package script、r2 文档与 Brain 状态；保留 r1 Stable Host、Loop 3、migration 001、History、export 和 Provider。绝不删除真实 Application Support、browser profile、Keychain、用户数据库或保留的审计根。

## 任务 029：P0-RC Loop 4 r3 真实安装前只读预检

- 日期：2026-07-16
- 当前状态：正式独立 review 曾 BLOCK（P0/P1/P2 = 0/2/2）；同一 reviewer 唯一 re-review 又因 `spctl` assessment cache 副作用 BLOCK（0/1/0）。Syc 明确要求继续后，cache-safe 101 项候选通过新的独立最终审查，**PASS，P0/P1/P2 = 0/0/0**。生产输出仍按设计为 `BLOCKED`，不代表产品 release ready。
- 用户场景：在真实用户目录、浏览器 profile、签名、公证或发布发生前，Syc 需要先知道“缺什么材料、目标会是什么、谁能授权下一步”，而不是用开发安装器试探真实机器。
- 本次只解决：`native-host-release-policy.json` 冻结 current-user/no-sudo、P0 Developer ID + notarized/stapled DMG 候选、Chrome/Brave shared target 与 Edge default target；`release_preflight.py report|plan` 读取 policy、r1 package verifier 和已有离线证据。正式 review 的 P1/P2 修复将 notarization 改为唯一锚定的 spctl source/origin，把 Apple subprocess 收为 fixed env/argv/DEVNULL/timeout，并在 `Path()` 前拒绝危险 lexical path；唯一 re-review 后再为 spctl 加 `--ignore-cache --no-cache`，避免读取或写入系统 assessment cache。生产 r3 固定 BLOCKED，绝不把无关 App、DMG、外部 receipt 组合成 READY。
- 角色与交接：Syc 选择只读 report/plan → preflight 读取 canonical config/policy → r1 verifier 交 package state，codesign/spctl/stapler 交已有 evidence → canonical JSON 交 status、blockers、warnings、deduplicated browser targets 与 reportDigest → Syc 单独决定是否授权下一任务。r3 不验证 release-unit/真实 target leaves，所以报告固定交出两个 unverified blockers；只有 r4 在单独授权范围内才能接手绑定验证。
- 本次核心名词：安装画像、预检门禁、故障注入、回滚不变量。四项已同步到 `GLOSSARY.md`，并在 r3 规格中通过真实职责、输入/输出和失败表现提供到 L3。
- 失败与恢复：release extension IDs 或 Team ID 未冻结、package/artifact 缺失或漂移、Developer ID/ad hoc/Team/runtime/notary/staple 证据不全、release-unit binding 未验证、真实 target ownership 未验证、receipt unknown/malformed/conflict、symlink/hardlink/noncanonical path 和 Edge custom profile 都 fail closed。r3 不写入，所以恢复不需要删除或 rollback；STOP 后保留报告，等 Syc 对 r4 的真实范围另行授权。
- 自动证据：最终 r3 gate **101 assertions PASS**，覆盖 unique anchored spctl source/origin、文件名/Developer-ID-only/duplicate/forged source、fake Apple runner 的 exact argv/env/DEVNULL/timeout、hostile caller env、fixed-argv-only、`spctl --ignore-cache --no-cache`、lexical path 与 policy type drift。新的独立最终 review 复跑 101 项并给出 PASS，P0/P1/P2 = 0/0/0；reviewer audit root 为 `/private/tmp/linkdigest-release-preflight-audit.rtrupoxs`。r2 110 与 r1 56 沿用主控最新回归，真实 HOME metadata digest 保持 `7925d3e9…de1e4`。doctor 唯一 FAIL 仍是本机 pnpm store 缺 `ajv@8.18.0` index，未安装依赖；secret hygiene、Brain links、JSON/AST/bash/diff 检查通过。
- 过程讲解：开工时用“装修前确认房号和施工边界”解释安装画像；实现时用“登机前查材料、不帮你登机”解释预检门禁；测试时用消防演习解释故障注入；收口时强调 r3 的回滚不变量是“不产生 mutation”。可选跟做是运行 `python3 scripts/native-host/release_preflight.py report` 观察 BLOCKED 清单；它不读写真实 HOME、profile、Keychain 或网络，也不是后续任务的门槛。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 r3 policy/preflight/check/spec/文档/Brain 更新；保留 r1/r2 clean-room 合同、所有既有审计根、历史、导出、Provider 和数据库。绝不删除真实 Application Support、browser profile、Keychain、用户数据库或任何已保留审计根。

## 任务 030：P0-RC Loop 4 r4a unsigned App + DMG release unit

- 日期：2026-07-16 至 2026-07-17
- 当前状态：首次独立 reviewer 结论为 **BLOCK，P0/P1/P2 = 0/4/2**；四项 P1 与两项 P2 集中修复后，同一 reviewer 的唯一 re-review 为 **PASS，P0/P1/P2 = 0/0/0**。该 PASS 只关闭 r4a unsigned release-unit 工程门禁，产品仍 BLOCKED。
- 用户场景：r1–r3 已有 package、transaction 与 preflight 证据，但无法证明某个 App、Host、DMG 与报告来自同一批次。r4a 要像装箱一样把每件物品、版本和 hash 对齐，同时保证构建不污染 workspace、探测不修改真实 profile。
- 本次只解决：strict `app-release.json`；App/Host Schema runtime locator；allowlisted `/private/tmp` audit build；r1 Host package 嵌入；exact `Info.plist`/App tree；外置 canonical `release-unit.json`；UDZO/HFS+ DMG create/verify/readonly attach/exact detach；五个真实固定目标零写入 probe。明确不做 Developer ID、Team ID、公证、stapling、真实安装/修复、App/浏览器启动、网络、依赖安装、Keychain/security identity/notarytool/spctl artifact query、发布与 Git。
- 场景 → 角色与交接：workspace/GRDB checkout 由 nofollow copier 交给 audit source/dependency → Swift Release 交 App/Host/Core bundle → r1 verifier 交 verified Host package → release-unit 绑定 hashes → hdiutil cleanup guard 交 mounted evidence与精确 detach → fd/openat probe 交匿名 target states → 只读 candidate audit 交给独立 review root 产生 `gate-result.json` → reviewer 决定是否关闭 BLOCK。
- 本次四个名词：Release Unit、Audit Root、Tree Digest、Fail Closed。Release-unit Binding 已存在于 glossary，本轮新增/更新 Audit Root、Tree Digest 与 Fail Closed；规格把四项都提供到 L3，不要求 Syc 答题。
- Schema locator：标准 `.app` 只读 `Bundle.main.resourceURL/LinkDigest_LinkDigestCore.bundle`；Host/SwiftPM executable 只读 executable sibling；`Bundle.module` 只能由测试显式 `testLocator()` 使用。四类 Swift 测试分别覆盖 App标准Resources成功、App缺bundle fail closed、Host sibling成功、test fallback明确，避免编译机 `.build` 被成品误用。
- release-unit binding：App config/Info.plist/App Mach-O/Host Mach-O/r1 metadata 四方必须同为 version 0.1.0、build 1、minOS 15.0、arm64。tree record 不含 uid/gid/mtime，只含 byte-sorted path/type/mode/size/hash；symlink、hardlink、FIFO/socket、unsafe path/额外项全部拒绝。App 不创建 `_CodeSignature`，不调用任何 `codesign -s`；报告明确 `{mode: unsigned, teamID: null}`。
- 首次 reviewer BLOCK 0/4/2：真实 target 仍是 path-lstat/read_bytes 两阶段，存在 parent symlink/leaf swap TOCTOU；attach nonzero 或 plist parse 失败时在 cleanup guard 前退出；source/GRDB copy 会跟随 symlink 且未拒 regular hardlink/special file；gate 在 candidate audit 内写 tamper/Swift scratch，并运行会启动本机 loopback TCP listener 的 full Swift suite。P2 是 Learning Log 状态互相矛盾，以及 gate 没有独立 canonical result 绑定。
- P1 修复 1：真实 probe 从 `/` 起逐组件 `openat(O_NOFOLLOW)`，保留 anchored parent/leaf fd；同一 leaf fd 完成 fstat、limit+1 bounded read、hash、前后 snapshot，再用 parent fd 复核 dev/inode/type。parent symlink、leaf swap、oversized、hardlink 与 FIFO 均 fail closed；输出仍不含 path/origins/raw。
- P1 修复 2：attach success/nonzero 后立即进入 cleanup guard。坏/歧义 stdout 或 partial attach改用 `hdiutil info -plist` 按 exact DMG+mount 唯一找 dev-entry；唯一绑定后普通 detach，普通失败只有 verify+info 再确认同一设备才允许一次 force；无法唯一绑定或 residual mount 均 exit 8。fake sequence 覆盖 success、invalid、ambiguous、partial、unbound、force 与 residual。
- P1 修复 3：allowlisted source、GRDB、runtime resource、App executable 与 Host package copy 统一使用 directory-fd/openat nofollow walker；拒绝 symlink parent/leaf、special file 与 regular `nlink != 1`，复制前后同 fd metadata 必须稳定。
- P1/P2 修复 4：`--existing-audit` 全程只读；tamper fixture、Swift HOME/TMPDIR/cache/scratch 与 gate result 只写 caller 提供的新 `/private/tmp/linkdigest-r4a-review.*`。canonical `gate-result.json` 绑定 DMG/release-unit/App tree/source/tool hashes、commands、assertions、focused test count、target exit 10 与 exit status。
- 真实 target probe：Native Host root、v1/v2 receipt 仍 absent；Chrome/Edge manifest current-user-owned、single-link、0600，但 noncanonical JSON，状态 malformed。没有改写、删除或修复真实 manifest。
- 失败历史 1：首轮真实 Release build 后，minOS parser 把 `otool` 的 `15.0` 错误归一化成 `15`，四方一致性门禁 exit 2；现场 `/private/tmp/linkdigest-r4a-release.cc6e9c7f527343488998f4bfd78e734f` 保留。修复为至少保留 major.minor 后重新构建，不把 parser bug 写成环境问题。
- 失败历史 2：受 managed sandbox 限制，`hdiutil create/attach` 返回“设备未配置”，普通 detach 返回 `Operation not permitted`。按授权只对 exact current-audit `hdiutil create`、readonly `attach` 与 exact `/dev/disk4s1 detach` 分别提升；没有提升整个 gate，没有 force detach，也没有扩大到真实 HOME/签名/浏览器。早期失败根 `/private/tmp/linkdigest-r4a-release.974d746a7c8e4bceab5e69a5cb4429bb` 同样保留。
- 授权外测试历史：首次 candidate 曾运行 full Swift 181/181，其中 adapter tests 会启动本机 loopback TCP listener。该运行超出 r4a“无 TCP listener”门禁范围，透明保留为失败历史但**不计入 r4a 证据**；remediation 期间未再运行，gate 源码也不再包含 full suite入口。r4a 只计 focused ContractTests 10/10。
- STOP/恢复：若 workspace inventory 漂移、GRDB offline checkout 缺失、App/Host/config/plist/release-unit 任一不一致、DMG attach 身份不唯一、普通/force detach 后仍有 mount、真实 target leaf 变化，立即保留现场并停止。恢复只复核同一 DMG+mount+dev-entry；不能删除 audit 或真实 manifest。正式 IDs、签名、公证、stapling、真实安装/浏览器验收都需要 separate authorization。
- 可选跟做（5–15 分钟）：只读对比保留 audit root 的 `staging/release-unit.json` 与 `r4a-engineering-report.json` 中 App tree digest、Host packageDigest、DMG/release-unit hash；不要自行 attach、删除 audit 或把路径改成 `$HOME`。该观察不是任务关闭门槛。
- Syc 主动提出的待解释点：无。
- remediation dry-run：旧 candidate audit 前后 inventory 不变；`/private/tmp/linkdigest-r4a-review.dryrun-04` 产生 canonical gate result，72 assertions 完成，包括 focused ContractTests 10/10；这只是实现自检，不覆盖首次 reviewer BLOCK，也不是最终候选证据。
- remediation candidate 证据：最终新的 `/private/tmp/linkdigest-r4a-release.remediation-candidate-02` 完成真实 UDZO/HFS+ DMG create/verify、readonly exact mount、同批次 App tree/release-unit/DMG 复核与 `/dev/disk7s1` 精确普通 detach，未使用 force 且无 residual mount。只读 gate 把全部输出写入新的 `/private/tmp/linkdigest-r4a-review.remediation-candidate-02`，candidate audit 前后 inventory 一致，74 assertions 与 focused ContractTests 10/10 完成；真实 probe 按预期 exit 10、`unchanged: true`、产品 BLOCKED。canonical `gate-result.json` 绑定 DMG `e15c9e67…8f78821`、release unit `8237b09a…c692652`、App tree `928bba01…7d83b8`、source inventory `b82fdeb4…745071` 与 tool hashes。candidate-01 被“所有 attach 返回都必须用 `hdiutil info -plist` 复核 exact DMG+mount，且成功 plist 设备不一致也精确清理”的最终收紧所替代并保留。
- 最终独立复审：同一 reviewer 的唯一 re-review 为 **PASS，P0/P1/P2 = 0/0/0**。它独立重算 artifact、tree、source/audit inventory 与 tool hashes，确认首次六项 finding 全部关闭、无新阻断、无 residual mount；该结论不授权真实 manifest 修复、安装、签名、公证或发布。
- 回归与失败恢复：r3 101 首次与 doctor 并发时因工作区不变式观察到干扰而 fail closed；停止并发后独占重跑 PASS 101。secret hygiene、Brain links、Python AST、JSON、Bash syntax 与 `git diff --check` 通过。doctor 为 PASS=77/WARN=1/FAIL=1，唯一 FAIL 仍是既有 dependency licenses 环境项；未安装依赖。下一步只交同一 reviewer re-review；即使工程 re-review PASS，产品也继续 BLOCKED。

## 任务 031：P0-RC Loop 4 r4b local-test ad-hoc DMG

- 场景：dirty worktree 已包含获授权的 r2/r3/r4a/r4b 工作，不能用 Git commit 充当本批次来源；目标是把 Syc 将要手工打开的 DMG 与完整源码、依赖源码、构建清单放在一起。
- 角色与交接：snapshotter 从 exact allowlist 冻结 live source 和 GRDB；archive verifier 用双归档与 roundtrip 交给 isolated Swift build；Host signer 先交给 r1 packager，App signer 最后封外层；DMG verifier 交给 handoff manifest，独立 gate 只读 audit 并把测试证据写 review root。
- 工作流：三次 live inventory 一致 → nofollow/single-link snapshot + secret scan → deterministic tar.gz → audit-local GRDB patch → offline Release build → Host/App inside-out ad-hoc signing → exact DMG readonly mount/detach → exact handoff → focused independent gate。
- 工具协同：`local_test_release.py` 负责 source/build/sign/DMG/handoff；`stable_host.py` 继续作为 r1 package verifier；r4a helper 只读复用 exact attach cleanup 与五目标 probe；`local_test_release_check.py` 只运行 focused ContractTests 10/10 和安全负例，不运行 full Swift/TCP suite。
- 新名词：Source Snapshot、Inside-out Signing、Local-test Unit、Handoff Tree，均已进入 `docs/GLOSSARY.md`，核心概念提供到 L3。
- 失败与恢复：unknown top-level、symlink/hardlink/special/secret、并发变更、归档不确定、remote dependency、签名事实漂移、checksum/unit cross-binding 或 DMG residual mount 都 fail closed；成功/失败 audit 均保留，不自动删除或写真实 HOME/profile。
- 当前状态：独立 reviewer **PASS，P0/P1/P2 = 0/0/0**；candidate-07 已安全 finalize 到 `release/LinkDigest-0.1.0-local-test/`，状态为 `READY_FOR_MANUAL_OPEN`，等待 Syc 第一次真实 GUI 打开。产品与公开发布继续 BLOCKED。
- 最终证据：r4b local gate 71 assertions、ContractTests 10/10；r3 101 与 r4a focused 74 回归 PASS。最终 DMG SHA-256 为 `51f2a6544c40f4d29bc66a062773f23e997f85cc74a49bd693f8c2759b1fe2a7`，candidate digest 为 `513b523c60f92824ad6a31b2c7f704a9375e0c7878c8fb5e40b81583271e19df`。最终路径完成 `SHA256SUMS` 全覆盖、`hdiutil verify`、readonly exact mount、mounted App/Host/unit/signature reverify、exact detach 与无 residual mount。
- 失败与恢复：candidate-01 至 -06 分别暴露 nested `.build`、fake secret sentinel、GRDB secret 正则误判、SwiftPM package identity、sandbox hdiutil 与 review-root absolute hash 语义问题；全部保留、未覆盖。candidate-07 才是最终 handoff 来源。
- 构建后状态说明：冻结 source archive 精确对应 candidate-07 的构建输入。独立 review/finalize 后仅更新 live workspace 的状态文档与 Brain，不改变产品源码、配置、工具或 DMG；未来修复应修改 live workspace，并用 `SOURCE_MANIFEST.json`/`BUILD_MANIFEST.json` 对照本次测试批次。
- 可选跟做（5–15 分钟）：独立 reviewer PASS 后，只读对照 handoff 的 `BUILD_MANIFEST.json`、`SOURCE_MAP.md` 与 `SHA256SUMS`，观察 DMG、源码和签名 CDHash 如何绑定；不是关闭任务的答题门槛。

## 任务 032：P0-RC Loop 5 桌面手动链接输入

- 当前状态：**AUTOMATION PARTIAL / UI CONFIRMATION PENDING**；工程目标是把一条用户主动输入的公开网页安全落到本机 History，不启动模型、不读取 Cookie/Profile/Keychain，也不接触 release handoff。
- 场景 → 角色与交接：Syc 点击“添加链接”或“从剪贴板添加链接”后，`ManualLinkViewModel` 只在该点击读取 clipboard 并交出 URL；`PeerBoundNetworkWebPageFetcher` 每跳 DNS/IP policy 后只连接已核验 numeric IP，HTTPS 仍用原 hostname 做 SNI、`SecPolicyCreateSSL`、system trust 与 HTTP Host，并禁用 trust 的网络补取；`MinimalHTMLExtractor` 交出标题和正文；`CapturedDocument` 标记 `manual_link` 后交给 `CaptureIngestService`；后者先取得 SQLite commit，再把 CurrentCapture 交给 `HistoryViewModel` reveal 和既有总结/翻译入口。
- 本次核心名词：CapturedDocument、WebPageFetcher、Redirect Policy、Storage Write Gate；均已进入 `docs/GLOSSARY.md`，核心概念提供到 L3。
- 过程讲解：入口只在点击时读取 NSPasteboard，避免“剪贴板监听器”；production fetch 采用 peer-bound `Network.framework`，每跳都把 URL allowlist、DNS/IP policy 与实际 numeric connection endpoint 重新绑定，HTTPS 的 SNI/`SecPolicyCreateSSL` 仍是原 hostname，system trust 以 `SecTrustSetNetworkFetchAllowed(false)` 避免沿未绑定路径补证书；redirect 拒绝 allowlist 外目标和 `https → http` downgrade。首次复审已推翻 ephemeral `URLSession` 手动抓取方案；`URLSessionWebPageFetcher` 只作为 test-only legacy。extractor 按 article→main→body 选择，去除 script/style/noscript 并把空/登录壳明确交回浏览器扩展。
- 被证据修正的一点：实现初次 focused Swift 编译显示 `LinkDigestApp.body` 错误引用 init 局部 clock；已改为 body 内等价注入 closure。随后旧 browser fixture 显示它仍需要只读 wire compatibility surface；保留 browser-only compatibility accessor，但 manual 文档没有 wire envelope，正常业务代码只读取 `document`。
- 失败与恢复：手动 fetch 失败、取消或提取空正文不会写 History；StorageWriteGate 失败不会发布 CurrentCapture；用户可改用浏览器扩展。回滚仅撤回本任务新增的 Core/Adapter/App/documentation 文件，不降级 Migration、不清理用户数据或 release handoff。
- 可选跟做（5–10 分钟）：在 Debug App 空 History 点击“添加链接”，输入一个非 URL 并观察固定中文错误，再取消；不要输入私密/登录/内网链接。这不是关闭任务门槛。
- 独立复审整改：恢复 browser wire 的 `linkdigest:capture-payload:v1` 精确字段顺序（version 与 usedCookie 也参与），manual 改用 `manual:v1` namespace；golden、reopen replay 与 manual→GRDB→CurrentCapture→fake Provider artifact 均有自动化证据。IP 分类改为 `inet_pton` 二进制分类，明确拒绝 IPv4-mapped IPv6、metadata、私网、文档与保留范围；MIME 仅接受去参数后的精确 HTML/XHTML，两个 timestamp 都需合法。
- 首次复审修正：Foundation `URLSession` 无法验证实际 peer address，因此其手动抓取方案被推翻并降为 test-only legacy；production 未注入 peer-bound transport 时仍 fail closed。当前 production `PeerBoundNetworkWebPageFetcher` 以已核验 numeric IP 为连接端点，原 host 留给 TLS SNI、`SecPolicyCreateSSL`、system trust 与 HTTP Host，并以 `SecTrustSetNetworkFetchAllowed(false)` 禁止未绑定证书网络补取；response parser 对 Content-Length、chunked 和 connection-close 施加上限。
- saving 边界补证：`ManualLinkViewModel` 的无轮询 actor/continuation gate 测试在真实 Repository commit 中间观察到 `.saving`、`isSaving == true`、`isFetching/canCancelFetch == false`；此时停止/关闭均不生效、CurrentCapture 尚未发布。release commit 后才发布、关闭 sheet 并回到 idle。另有队列取消测试证明 commit 前取消不执行写操作。
- 自动化证据口径：ConnectionLifecycle 2/2、PeerBound transport **17/17**（matching CA chain success、wrong-host/untrusted fail）、ManualLinkViewModel 4/4、manual→GRDB→CurrentCapture→fake Provider artifact 1/1 均为 0 failures；Debug build PASS。full suite 由主控稍后复跑，Release 与 GUI 截图未在本轮执行；Loop 5 整体仍 **UI CONFIRMATION PENDING**，不标 COMPLETE。
- 第三轮收口的样本交接：`sample-manifest.json` 现在是 20 条可机器检查的验货单，逐条记录标题、正文起止、最低字符数、完整性和允许降级；`LinkDigestManualSampleVerifier` 分开 production peer-bound 网络验证与合成 fixture 验证，避免把“提取器能读本地 HTML”误写成“真实公网链路成功”。
- 第三轮现场修正：本机 DNS/代理把 `en.wikipedia.org`、`github.com`、`developer.mozilla.org` 等公网域名解析到 `198.18.0.0/15` benchmark 段，production policy 按设计返回 `unsafeURL`。因此本轮公开样本必须记录为 environment-blocked，不能注入假 resolver、允许 test-net 或放宽 peer-bound 校验；登录样本仍只允许交给浏览器扩展当前页 DOM。
- 第三轮核心名词：fixture 是无真实账号数据的演练样本；manifest 是逐条验货单；production path 是用户实际走的网络与提取代码；PeerBound 把已核验 IP 与真实连接对端绑定；降级路径是主路径失败时唯一允许的受限替代体验。过程讲解已提供到 fixture/manifest L2、production path/PeerBound/降级路径 L3。
- 第三轮失败与恢复：若公网 DNS 恢复为真实公网地址，只需原命令重跑 `verify-network`；若仍指向私网/保留/test-net，保留结果并由主控在合规网络环境复跑。不可通过修改 URL policy、production resolver 或 Cookie/Profile 边界恢复。

## 任务 033：P0-RC Loop 6 BYOK Product UX、代理兼容与日常 DMG

- 日期：2026-07-17
- 当前状态：**工程实现与 DMG gate 完成，产品仍 BLOCKED**。模型设置已进入主窗口工具栏；当前 Capture 与 History 详情均可总结/多语言翻译；总结 prompt 与目标语言以 UserDefaults 保存，API Key 仍只在 Keychain。新 local-test DMG gate 为 71 assertions + ContractTests 10/10，未签 Developer ID、未公证、未发布。
- 场景 → 角色与交接：`PublicWebURLPolicy` 先交路由决定；`PeerBoundNetworkWebPageFetcher` 保留普通直连；`SystemProxyWebPageFetcher` 接收显式系统代理或全 fake-ip 域名并保留原 hostname TLS 身份；Settings 把非秘密 `ModelPreferences` 交给 AppViewModel，AppViewModel 在发送确认 attempt 中冻结偏好，再交给 Orchestrator/Provider。
- 本次核心名词：Fake-IP DNS、HTTP CONNECT、Model Preferences。均提供到 L3：专项测试观察 fake/public/private 三分流、系统代理优先仍拒绝私网、UserDefaults 只含非秘密偏好、自定义 prompt 与目标语言进入 mock Provider。
- 失败与恢复：fake-ip 通道失败显示检查代理/VPN与系统网络的人话动作；TLS 身份失败单独提示检查代理证书或改用扩展。代理凭据不进入日志/导出。Swift 全量 223 项中 222 通过，唯一失败是受限执行环境写隔离 Keychain service 返回 100001；未扩大真实 Keychain 权限，也未把测试改成跳过。
- 真实网络证据：20 条网络结果均逐条落盘，不再出现 Loop 5 的 fake-ip admission 全阻断。4 条完全命中旧 manifest，7 条抓取成功但旧 marker 漂移；其余为客户端渲染、受限或合成 `.test` URL。另跑 5 条本地 fixture：3 条 loginRequired 降级、2 条 expected failure 全符合预期。网络可达与内容断言严格分开，未宣称 20/20。
- 工具协同与自动证据：SwiftPM Debug/Release、Xcode App/Host Debug/Release 四目标、Web lint/typecheck/20 tests/browser build、secret hygiene、release test seam、Swift license、doctor 87/1/0 均通过。GUI 直接截取主窗口和设置入口；其余页面因前台焦点/辅助功能自动化不稳定留给主控手工补图。
- 可选跟做：打开 local-test DMG 后，用工具栏齿轮观察“模型配置/总结与翻译”，再粘贴一个公开 URL；这是共同观察入口，不是任务完成门槛。
- Syc 主动提出的待解释点：无。
- 回滚：只撤销 Loop 6 的 preferences、代理路由/URLSession delegate、主流程按钮与专项测试/文档；保留 Loop 5 PeerBound 直连、History/SQLite、既有 BYOK/Keychain 和 r4b 流水线。绝不删除真实 Keychain、Application Support、浏览器 profile 或用户数据库。

## 任务 034：Loop 6 P1 修复后的 local-test DMG 冻结与替代候选

- 日期：2026-07-17
- 当前状态：**候选门禁 PASS，等待同一 reviewer 复审与 Syc 手工打开**。同一 reviewer 已确认第二轮源码修复的 3 个 P1 与 2 个 P2 成立；随后发现旧候选 DMG 来自修复前 source archive，故旧入口 `release/loop6-candidate-20260717/LinkDigest-0.1.0-local-test/` 明确为 **SUPERSEDED**，不得作为人工验收对象。新入口是 `release/loop6-candidate-20260717-r2/LinkDigest-0.1.0-local-test/`；其 manifest 仅标记 `READY_FOR_MANUAL_OPEN`，产品与公开发布继续 `BLOCKED`。
- 场景 → 角色与交接：live dirty worktree 由 snapshotter 冻结为 source archive → local-test pipeline 离线构建并 ad-hoc 签名 App/Host → DMG readonly mount 验证交给独立 review root → `SHA256SUMS`、`BUILD_MANIFEST.json` 与 `gate-result.json` 交给 reviewer/Syc。这样手工打开的 DMG 与已复审的安全修复是同一份输入，而不是只看 live workspace 的“后来代码”。
- 工作流与工具协同：复用 r4b `package-local-test-dmg.sh` 生成新的 `/private/tmp` audit root，再以 `check-local-test-release.sh --existing-audit` 在独立 review root 执行 71 项门禁和 DMG 内 ContractTests。检查随后把冻结 handoff tree 原样复制至新候选目录，并对复制件运行 `SHA256SUMS`。整个流程仅使用本地源码、离线依赖和 loopback/临时测试，不写真实 Keychain、系统信任、系统代理或凭据。
- 关键复审绑定：新 source archive 中 `SystemProxyWebPageFetcher.swift`、`ProxyAwareWebPageFetcher.swift`、`LinkDigestApp.swift`、`UserDefaultsModelPreferencesStore.swift`、`SystemProxyWebPageFetcherTests.swift` 分别与当前 worktree SHA-256 一致，确保 HTTPS-only 代理门禁、TLS/redirect/proxy-auth 测试接缝、启动偏好加载与 DTO 校验确实进入 DMG 的构建输入。
- 自动证据：独立 gate **71 assertions PASS**、DMG 内 ContractTests **10/10 PASS**、readonly mount `true`、residual mount `false`；本轮 P1 修复后的 Swift 全量证据为 **233/233 PASS**。新 DMG SHA-256 为 `4b1e2601ade3c03d6f69ee81f7d58c5c93b3922807f8f0b9cf15d7f49254efd8`，新 source archive SHA-256 为 `91cf3cb23b75f9c6ba4bc5392b178b7b769d1215682e5a2632551685abfa0f3e`。
- 可选跟做（5–15 分钟）：只读打开新候选中的 `BUILD_MANIFEST.json` 与 `SHA256SUMS`，再与旧候选的 source archive hash 对比，观察“修复代码”和“可打开产物”为什么必须被同一份冻结清单绑定；这不是等待 Syc 完成的关闭条件。
- 失败与恢复：任何 archive/worktree hash 不同、checksum、DMG verify、readonly mount、ContractTests 或独立 gate 失败，候选不得标为可人工验收；保留失败 audit/review root，不覆盖旧候选。回滚只移除本任务新增的 `-r2` 候选与本条追加记录，绝不删除旧候选、真实用户数据或系统配置。

## 任务 035：Loop 6 UX 小批次与带图标的 r3 DMG

- 日期：2026-07-17
- 当前状态：**工程与独立门禁 PASS，r3 等待 Syc 人工打开**。`release/loop6-candidate-20260717-r2/LinkDigest-0.1.0-local-test/` 现为 **SUPERSEDED** 历史候选；新入口为 `release/loop6-candidate-20260717-r3/LinkDigest-0.1.0-local-test/`，其 manifest 仅为 `READY_FOR_MANUAL_OPEN`，产品和公开发布继续 `BLOCKED`。
- 场景 → 角色与交接：设置页把“还没填”交给中性引导、把“用户点保存后校验失败”交给红色错误态；Keychain 已有条目只交给 ViewModel 一个非秘密的“已配置”状态，点击“更换”后才让 View 接收新的短生命周期输入；总结提示词的“重置”只回填默认模板，仍由原有保存动作写入 UserDefaults。这样 UI 不会把密钥带进可观察状态，也不会把首次空表单误报为失败。
- 图标工作流：冻结 `app-release.json` 明确 `iconFile = AppIcon.icns` → packager 从 source snapshot 的 `apps/desktop/Assets/` 通过 nofollow copier 放入 `LinkDigest.app/Contents/Resources/` → frozen Info.plist 写入 `CFBundleIconFile = AppIcon` → exact Resources 集合严格为 Core resource bundle、NativeHost、AppIcon.icns → bundle 图标 hash 必须等于归档资产并通过 ICNS header/length、签名、readonly mount 复核。图标像产品外箱的识别贴纸，不能塞进 Core bundle，也不能在 App ad-hoc 签名后再补。
- 开发路径说明：`swift run`/SwiftPM Debug 产物是裸 executable，不产生 `.app/Contents/Info.plist`；项目内没有 `.xcodeproj`、`.xcworkspace` 或 Debug `.app`，所以无法在该路径接 Finder/Dock 图标。最终 DMG App bundle 是唯一可验证的图标承载路径，已由 gate 覆盖。
- 自动证据：新增 ViewModel 测试覆盖首次中性态、显式保存后的空 Key 错误态、已配置 Key 的更换态、重置总结提示词；定向 `ProviderSettingsViewModelTests` **16/16 PASS**，Swift 全量 **237/237 PASS**，Debug/Release build PASS，doctor **PASS=87 / WARN=1 / FAIL=0**（唯一 WARN 为预期 dirty worktree）。
- r3 交付证据：独立 local-test gate **74 assertions PASS**（原 71 + 图标 unit/plist/hash 3 项）、DMG 内 ContractTests **10/10 PASS**、readonly mount `true`、residual mount `false`。gate 实测图标 `{file: AppIcon.icns, plistValue: AppIcon, hash: 3537cae0…d298775}`；DMG SHA-256 为 `e8c9932009ccc6a8ddfebd7886f18f0177776fb5f723368758b184bc920ca623`，source archive SHA-256 为 `2cd68f4e855558772a858bf0fc28dcaca059c61a212c33b6c7679db3a8820497`，复制件 `SHA256SUMS` 13/13 OK。
- archive binding：上轮五个代理/偏好关键文件，以及本批次侧边栏、Settings View/ViewModel/测试、AppIcon、两个 frozen config 与四个装箱/gate Python 文件均与安全解包后的 r3 source archive SHA-256 一致。
- 可选跟做（5–10 分钟）：只读打开 r3 的 `BUILD_MANIFEST.json`，找到 `app.icon` 和 `dmg.readonlyMountVerified`；再打开 App 的“模型配置”，观察首次中性提示、已配置后的“✓ 已配置 / 更换”，以及“重置”回填提示词。无需输入真实 API Key，也不是任务关闭条件。
- 失败与恢复：图标缺失、改名、hash/plist 不一致、ICNS 容器不完整、签名后篡改、DMG residual mount 或任一 gate 失败都会 fail closed，不得标记候选可人工验收。回滚只撤销本批次 Settings、装箱合同、术语/学习记录和 `-r3` 候选；不删除 r1/r2 历史候选、真实 Keychain、系统信任、代理或用户数据。

## 任务 036：Loop 6 UX 只读复核整改与 r3-fix1 候选

- 日期：2026-07-17
- 当前状态：**整改后工程/gate PASS，`r3-fix1` 等待 Syc 人工打开**。任务 035 的首个 r3 审计树保留，但只读复核发现其设置保存和 frozen-hash gate 有缺口，故 `release/loop6-candidate-20260717-r3/` 也为 **SUPERSEDED**，不得手工打开。最新入口是 `release/loop6-candidate-20260717-r3-fix1/LinkDigest-0.1.0-local-test/`；仍仅 `READY_FOR_MANUAL_OPEN`，产品和公开发布 `BLOCKED`。
- 复核修正：已配置但未点“更换”时，`canSaveConfiguration == false`，保存按钮不会把空字符串提交给 Keychain；进入更换态才允许保存。`canTestConnection` 同时要求已配置、非更换、无未保存身份修改，因此不会在用户准备换 Key 时测试旧 Key。两项都由 ViewModel 测试覆盖，并由 View 直接绑定。
- 资源合同修正：`r4aFrozenHashes` 现在有固定的六路径 exact set（图标、app config、两条 r4a wrapper、release unit 与其 check）；少任一 pin 或多任一 pin 都由 local-test gate 的临时配置负例 fail closed。这样“图标在 frozen source 内”不会退化成只校验当前配置碰巧列出的任意子集。
- 自动证据：定向 Settings 测试 **16/16 PASS**、Swift 全量 **237/237 PASS**、Debug/Release build PASS、doctor **PASS=87 / WARN=1 / FAIL=0**。r3-fix1 独立 gate **76 assertions PASS**（71 原项 + 3 图标 + 2 exact frozen-hash 负例）、DMG 内 ContractTests **10/10 PASS**、readonly mount `true`、residual mount `false`、复制件 `SHA256SUMS` **13/13 OK**。
- 交付绑定：r3-fix1 的 DMG SHA-256 为 `29f337be62df4a9b2d5924b0d78408ef0ad39d6480cfaf42931d4dbf595332d9`，source archive SHA-256 为 `51fec5b9527a59b4414645cfe33c9efcf4a5edba0ce2e11c1a67e01bd0a8c5c7`；上轮 P1 五文件、本批次 Settings/测试、AppIcon、config 和四个 release scripts 均与安全解包 archive SHA-256 一致。图标证据仍为 `AppIcon.icns` / `AppIcon` / `3537cae0…d298775`。
- 可选跟做（5–10 分钟）：打开 r3-fix1 的模型设置，观察“✓ 已配置”时保存不可用、点“更换”后输入框与保存出现且“测试连接”不可用；无需输入真实 Key。这是共同观察，不是关闭条件。
- 失败与恢复：若后续 reviewer、checksum、hash、readonly mount 或任一 76 项 gate 失败，继续保留 r3/r3-fix1 audit 根和候选，不覆盖或删除；下一轮使用新的候选名。绝不通过放宽保存、测试或 frozen-hash 门禁来恢复 READY。

## 任务 037：Loop 6 设置动作入口门禁下沉与 r3-fix2 候选

- 日期：2026-07-17
- 当前状态：**工程验证与 76 项 local-test gate PASS；`r3-fix1` 现为 SUPERSEDED。** 最新的本地人工验收入口是 `release/loop6-candidate-20260717-r3-fix2/LinkDigest-0.1.0-local-test/`；其 DMG 已通过 checksum、只读挂载与 DMG 内 ContractTests，但仍是 `LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER`，产品与公开发布保持 `BLOCKED`。
- 用户场景：设置页在启动时读取已保存配置。即使按钮尚未来得及变灰，或一个测试任务已经排队，用户也不能借由直接调用动作入口把已有配置覆盖为空、读取旧 Key 或向 Provider 发起请求。
- 场景 → 角色与交接：View 只展示加载/更换/保存/测试状态；`ProviderSettingsViewModel` 是动作入口的唯一门锁；ProfileStore 与 SecretStore 只接收通过 guard 的保存；Provider 只接收保存身份仍匹配、且在读取 Key 前再次复核的测试 intent。`HistoryContentView` 则把搜索框交给侧边栏可用宽度，避免最小 280 宽度被固定控件反向撑破。
- 本次新名词：动作入口门禁。它像门牌之外真正的门锁：`.disabled` 只能阻止正常点击，ViewModel 的独立 guard 才能阻止测试、快捷路径或异步排队绕过。项目位置为 `ProviderSettingsViewModel`；没有它，UI 显示“不可操作”仍可能发生写入、读 Key 或外发请求。
- 修复：ViewModel 初始进入 `isConfigurationLoading`，在首次 `load()` 完成前禁止保存、测试和更换；`save(apiKey:)` 直接复用等价入口 guard。`testConnection()` 同时检查加载、保存、更换、已保存身份与草稿状态；其 Task 在真正读取凭据前调用 `canUseSavedConfiguration` 二次复核，消除排队后切换到更换态仍使用旧凭据的窗口。侧边栏搜索框从固定 `width: 320` 改为 `maxWidth: .infinity`，保留水平内边距并随 280–420 宽度伸缩。
- 自动证据：`ProviderSettingsViewModelTests` **19/19 PASS**，包括 `testDirectSaveDoesNotWriteConfiguredProfileUnlessReplacing`、`testDirectSaveDuringConfigurationLoadDoesNotWrite`、`testDirectConnectionTestDuringReplacementDoesNotReadOrCallProvider`；`HistoryContentViewTests` **4/4 PASS**，包括最小侧边栏宽度的搜索框伸缩断言。Swift 全量 **241/241 PASS**；debug/release build PASS；doctor **87 PASS / 1 dirty-worktree WARN / 0 FAIL**。r3-fix2 独立 gate **76 assertions PASS**，DMG 内 ContractTests **10/10 PASS**，复制候选 `SHA256SUMS` **13/13 OK**。
- 交付绑定：r3-fix2 DMG SHA-256 为 `8ca8bd0c35aa1b3330ebfa3c3182160dea3e1eaa5fe32184ac324069b8850349`。安全解包 source archive 与 worktree 对 11 个需求指定的关键安全/UX 源码、测试及 `AppIcon.icns` 的 SHA-256 均一致；图标仍由 `AppIcon.icns`、`CFBundleIconFile = AppIcon` 和 exact Resources/hash gate 三者共同绑定。
- 失败与恢复：若独立 reviewer、checksum、archive hash、只读 mount 或任一 76 项 gate 失败，保留 r3/r3-fix1/r3-fix2 历史证据，不改写旧候选，并以新的候选名重建；不得通过只保留按钮 `.disabled`、放宽入口 guard 或跳过 Key 读取前复核来恢复 READY。绝不读取或写入真实 Keychain、系统信任、系统代理、浏览器 profile 或用户数据。
- 可选跟做（5–10 分钟）：不输入真实 Key，打开最新候选的设置页并观察启动加载文案、已配置态的“更换”按钮和更换态禁用测试；把侧边栏缩到最小宽度，搜索框会随宽度收缩。这是共同观察，不是关闭任务的门槛。

## 任务 038：DeepInfra 402 错误分类与安全服务商摘要

- 日期：2026-07-17
- 当前状态：**工程修复和验证完成；DMG 未重建。** Syc 的现场 curl 确认 DeepInfra 在未配置支付方式时返回 HTTP 402 `detail.error`，此前 App 将所有未分类 4xx 都说成“协议不兼容”。本轮把该真实根因收敛为计费/额度限制，不改动 DeepInfra 的成功 SSE 解析。
- 用户场景：用户配置正确的 Base URL、模型和 Key 后，仍可能因为服务商支付、余额、模型权限或请求参数被拒绝。提示应说明“谁拒绝了什么”，但不能把 API Key、Authorization、响应原文或可追踪 URL 带到界面与历史里。
- 场景 → 角色与交接：`OpenAICompatibleProvider` 在非 2xx 时短暂读取有限 body → 只识别 OpenAI `error` 与 DeepInfra `detail` 的公开错误字段 → `ModelProviderErrorSummary` 像安检台一样删 query、拒绝凭据样式并截到 200 字符 → `ModelProviderFailure` 交给连接测试或正式 RunState → `V02ErrorCatalog` 组合固定中文恢复动作与纯文本安全摘要。历史仍只保存稳定 code，不保存摘要或原始 body。
- 本次名词：服务商错误摘要。它是经过安检的、长度受限的服务商说明，不是 HTTP body 的原样转发；生活类比是客服只转述“余额不足”，不会把整份后台工单和门禁卡复印给用户。项目位置为 `ModelProviderErrorSummary`；没有它，修复 402 提示时可能反而泄露请求秘密。
- 分类选择：402 → `MODEL_PROVIDER_BILLING_LIMITED`，引导到服务商控制台检查支付/余额/额度；404 根据 OpenAI/DeepInfra 错误 code/message 区分模型不存在或 endpoint 不存在；其它 4xx → `MODEL_PROVIDER_REQUEST_REJECTED`。成功 SSE 的 `choices/delta/usage/[DONE]` 规则保持不变，真正的协议错误继续 fail closed。
- 自动证据：Adapter 定向 **10/10 PASS** 覆盖两种 402、两种 404、422、空 body、超长截断、URL query 删除，以及 Authorization、Set-Cookie、X-Provider-Trace 敏感样式拒绝；连接测试 **20/20 PASS**；正式生成 **32/32 PASS**；错误目录 **3/3 PASS**；Swift 全量 **244/244 PASS**；debug/release build PASS。
- 失败与恢复：任何 body 解析异常、未知 JSON、敏感 marker 或超过截取上限都不会把原文传给 UI；摘要缺失时仍显示固定安全文案。若后续服务商改变错误 envelope，先加无凭据 fixture 再扩解析，不把 raw body 或 header 当作兼容性捷径。
- 可选跟做（5 分钟）：在不输入真实 Key 的前提下阅读 `deepinfra-diagnosis.md` 的 402 fixture，观察“原 body → 安检摘要 → 固定中文恢复动作”的交接；这不是本轮关闭的前置条件。

## 任务 039：Loop 6 r4 最终候选冻结

- 日期：2026-07-18
- 当前状态：**Syc 已完成真实 BYOK 闭环并批准最终冻结；r3-fix2 现为 SUPERSEDED 历史候选。** r4 将从同一份已验证的 dirty worktree 建立新的 local-test DMG；只有独立的 76 项 gate 全绿后，manifest 才可标记 `READY_FOR_MANUAL_OPEN`。这不等同于签名、公证、公开发布或产品解除 `BLOCKED`。
- 场景 → 角色与交接：Syc 的真实操作证明用户链路（DeepSeek 连接成功 → 一次真实翻译完成 → 结果进入本机 History）已经能走通；冻结器把该时点的源码和学习记录交给 source archive，packager 交付 ad-hoc App/Host 与 DMG，独立 gate 再把 checksum、只读挂载、ContractTests 和 manifest 交给人工验收。这样最终可打开的候选与已验证的错误映射是同一份输入，而不是“后来修好的 workspace”。
- 402 根因故事：DeepInfra 的现场 curl 返回 HTTP 402，`detail.error` 指向未配置支付方式；此前未分类 4xx 被误显示为“协议不兼容”。本轮将它明确归入服务商计费/额度限制，并只向 UI 交付经过长度、URL query 与凭据样式过滤的纯文本摘要。真正的 SSE 协议校验没有放宽：错误分类解决的是误导性的失败说明，不是把失败响应当作成功流。
- 自动化起点：冻结前 `timeout 300 swift test` 必须保持 244/244；source archive 需要逐文件绑定前两轮的 11 个安全/UX 文件，及本轮 `OpenAICompatibleProvider`、`ModelProvider`、`ModelRunOrchestrator`、`V02ErrorPresentation` 和相关测试。任一 hash、DMG verify、readonly mount、checksum、ContractTests 或 gate 失败都不得产生 READY 候选。
- 失败与恢复：保留 r3-fix2 及更早候选作为历史证据，不修改其中既有文件；若 r4 gate 失败，仅保留新的 audit/review 诊断并停止，不用更改安全门禁、读取真实凭据或覆盖历史候选来恢复。Syc 的真实 BYOK 结果是人工产品证据，不替代自动化 gate。
- 可选跟做（5–10 分钟）：在 r4 gate 成功后，只读对照 `BUILD_MANIFEST.json` 的 source archive hash、`SHA256SUMS` 的 DMG hash 与本条描述，观察“真实用户闭环”和“可复验构建输入”如何在同一候选中交接；不是关闭任务的答题门槛。

### 任务 039 追加：r4 实际冻结与 r4 复审 BLOCK

- r4 实际冻结结果：2026-07-18 的装箱前 `timeout 300 swift test` 为 **244/244 PASS**；独立 local-test gate 为 **76 assertions PASS / DMG 内 ContractTests 10/10 PASS**；候选复制件 `SHA256SUMS` 为 **13/13 OK**。DMG SHA-256 是 `bea271a731adfdf04590639e8676b1d064efafedb9227df171d4b9875ab0d38e`，source archive SHA-256 是 `528691b7ea34e4861f133906465a5ca35c683b77546bbc23a1aba566f1523673`。`BUILD_MANIFEST.json` 标记 `READY_FOR_MANUAL_OPEN`，产品与公开发布仍为 `BLOCKED`。
- 独立复审结果：**BLOCK（P0=0 / P1=1 / P2=1）**。P1 发现摘要净化先压平换行，导致“普通文字 + 换行 + `Key: 值`”不再满足行首 header 形状而可能进入 RunState/UI；`key=值` 也未被显式拒绝。P2 指出本任务原记录只写了冻结计划，缺少实际 76/10、hash、13/13 与 BLOCK 事实。
- 修复交接：r4 保留为 **SUPERSEDED** 历史候选且不改写其内容。r4-fix1 将在压平前检查 credential/header 形状，并拒绝 key/secret/token/password 赋值和 URL userinfo；任何疑似值整段丢弃，连接与正式生成都只显示固定安全文案。r4-fix1 的最终 PASS 证据在新候选 gate 完成后追加。

### 任务 039 追加：r4-fix1 最终冻结 PASS

- r4-fix1 实际结果：全量 `timeout 300 swift test` 为 **247/247 PASS**；新增的 Adapter **11/11**、连接 Settings **21/21**、正式 AppViewModel **33/33** 均通过；debug/release build 均 PASS。独立 local-test gate 为 **76 assertions PASS / ContractTests 10/10 PASS**，复制候选 `SHA256SUMS` 为 **13/13 OK**，readonly mount 为 true、residual mount 为 false。
- 新入口：`release/loop6-candidate-20260717-r4-fix1/LinkDigest-0.1.0-local-test/`。DMG SHA-256 是 `30a1061cf0aab69590a34a995dcda87d5098a57f87a500af7198405a42ac2365`，source archive SHA-256 是 `d3b9101dcba1806a89377420eef0374b6156382d0d7111aafd75d7f81719a9af`。manifest 是 `READY_FOR_MANUAL_OPEN`；独立 gate 仍诚实标记 `LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER`，产品/公开发布继续 `BLOCKED`。
- P1 关闭证据：净化器按“原文 → URL query/fragment 去除 → 保留换行边界 → whitespace 折叠”多次检查；命中 `Key:`、key/secret/token/password 赋值、两种 URL userinfo 或 `?key=` 时，整段 `providerSummary` 为 nil。Adapter、连接测试和正式生成以同一组 8 类 fixture 断言泄漏标记不进入 failure/RunState/状态文本/结果文本/错误文案；固定恢复文案仍可见。
- 失败恢复：若后续同一 reviewer 发现新绕过，不改写 r4 或 r4-fix1；保留 audit/review 根，并以新候选名重建。不得为了保留服务商原文而改成部分遮蔽或允许可疑摘要。

### 任务 039 追加：r4-fix1 残余净化绕过 BLOCK 与 r4-fix2 收敛

- r4-fix1 的独立复审结果：**BLOCK（P0=0 / P1=1 / P2=0）**。虽然上轮的裸 key、query、userinfo 等 8 类 fixture 已关闭，但 `access_token`、`client_secret`、`privateKey`、`refreshToken` 等复合字段名仍可因 `_` 与驼峰的边界规则绕过；折行的 `https://user:\nsecret@host` 也因原文与压平文本各自看不到完整 authority 而漏过。r4-fix1 现为 **SUPERSEDED** 历史候选，目录不改写。
- 收敛方式：`ModelProviderErrorSummary` 不再在原文、去 query 文本、压平文本上运行不同规则。它只建立一次检测副本：小写化、移除控制字符（折行 URL 连续）、将空白/`_`/`-` 合并为统一分隔符；所有 credential 规则只读取该副本。字段赋值取规范化字段名并检查是否包含 key/secret/token/password/pwd/base64，故 snake_case、kebab-case、空白分隔、驼峰和 JSON 引号形式都进入同一 fail-closed 规则；`sk-proj-*` 随规范化后的多段形式一并覆盖。
- 新的三路径证据：Adapter 本地 422、连接测试、正式 RunState 使用相同 22 类 fixture。除复审列出的 access_token、client_secret、privateKey、refreshToken、JSON client_secret、折行 userinfo 外，还覆盖 accessKey、X_API_KEY、api-key、sessionToken、裸 Bearer、pwd=、Base64 前缀和规范化 `sk-proj`；每项都断言 sentinel 不进入 failure/RunState/状态文本/结果文本/错误文案。定向 **11/11、21/21、33/33**，全量 **247/247**，debug/release build 均 PASS。
- 下一步：r4-fix2 的 76 项 gate、DMG 内 ContractTests、checksum 与 archive binding 成功后，再在本条追加实际 candidate hash 和 PASS；任一失败仍停止并保留 audit/review 证据。

### 任务 039 追加：r4-fix2 最终冻结 PASS

- r4-fix2 实际结果：`timeout 300 swift test` 为 **247/247 PASS**；定向 Adapter **11/11**、连接 **21/21**、正式运行 **33/33** 均 PASS；debug/release build 均 PASS。独立 local-test gate 为 **76 assertions PASS / ContractTests 10/10 PASS**，复制候选 `SHA256SUMS` 为 **13/13 OK**，readonly mount 为 true、residual mount 为 false。
- 新入口：`release/loop6-candidate-20260717-r4-fix2/LinkDigest-0.1.0-local-test/`。DMG SHA-256 是 `c0b948544954507d34d630f6834a1d05b055504b212806c07b53929fe6dd51a3`，source archive SHA-256 是 `271dee60762a784184d1c43e673f79168c0de5d6eea5fb3d10c2f3505171c8a0`。manifest 为 `READY_FOR_MANUAL_OPEN`；独立 gate 仍诚实标记 `LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER`，产品/公开发布保持 `BLOCKED`。
- P1 收口证据：22 类相同 fixture 已在 Adapter、连接和正式生成三路径运行；复审列出的复合字段、JSON 与折行 URL userinfo，以及冗余的 X_API_KEY、api-key、sessionToken、Bearer、pwd、Base64、sk-proj 都被统一检测副本拒绝。该设计特意允许字段名包含 credential 词时误杀摘要，安全优先于保留服务商原文。

### 任务 039 追加：r4-fix2 第三次 BLOCK 与 r4-fix3 code-only 错误边界

- r4-fix2 的独立复审结果：**BLOCK（P0=0 / P1=1 / P2=0）**。单一规范化检测副本和 22 类 fixture 已正确，但复审指出 Provider-neutral 的自由 body 文本仍有未封闭语法类别（非 HTTP URI userinfo、嵌套赋值、自然语言标签、Unicode 兼容形式）。这不是再加一条正则能证明关闭的边界，因此 r4-fix2 现为 **SUPERSEDED** 历史候选，目录不改写。
- 主控决策与架构收敛：取消 `providerSummary`、`ModelProviderErrorSummary` 和“服务商说明”路径。Adapter 的 response body 只在内存中短暂读取，且仅供 HTTP/结构化 error `code` 分类；`ModelProviderFailure`、RunState、连接状态、历史、导出与日志不再有任意 Provider 字符串槽位。UI 按稳定内部 code 显示固定本地化文案，402 仍引导到服务商控制台检查支付/余额/额度，404 模型/接口两种固定文案保留。
- 404 取舍：明确的 `error.code/detail.code/code` 为 model-not-found 时才显示“模型不存在”；未知 code 或仅包含“model not found” message 的 404 保守显示“接口不存在”。这放弃了 message 猜测，换取“body 绝不跨 Adapter 边界”的可证明合同。
- 自动化起点：Adapter 以真实 402、结构化 model 404、message-only 404、422、未分类 4xx、503 body 与 22 类任意 body fixture 验证只产出稳定 code；Settings/正式运行验证固定文案及 body marker 零出现。全量 **249/249 PASS**，debug/release build PASS。r4-fix3 的 gate、checksum、archive binding 成功后再追加实际候选 hash 与 PASS。

### 任务 039 追加：r4-fix3 最终冻结 PASS

- 实际结果：Adapter 定向 **12/12 PASS**、连接 Settings **21/21 PASS**、正式运行 AppViewModel **34/34 PASS**；全量 `timeout 300 swift test` 为 **249/249 PASS，0 failures**，debug/release build 均 PASS。原始 Provider body 的 402、两类 404、422、未分类 4xx、503、网络中断与 22 类凭据形态 fixture 都只交付稳定内部 code；任何 body marker 或 sentinel 均不进入 failure、RunState、连接状态、错误文案、结果或历史。
- 新入口：`release/loop6-candidate-20260717-r4-fix3/LinkDigest-0.1.0-local-test/`。独立 local-test gate 为 **76 assertions PASS / DMG 内 ContractTests 10/10 PASS**，复制候选 `SHA256SUMS` 为 **13/13 OK**；readonly mount 为 true、residual mount 为 false。DMG SHA-256 是 `b8fd3ceed8ea952c355bb6d6c38ceb33d65fbf4fe9da7091c3ed24ec8330fa7c`，source archive SHA-256 是 `347d3b918fd4d9eb71aeea465dc9ac7ced99becc85ab4d4d61b7879c72d1495a`。
- 交付与状态：18 个既有安全、UX、图标与错误映射源/测试文件 archive ↔ worktree **18/18 MATCH**。`r4-fix2` 是 **SUPERSEDED** 历史候选，目录既有文件未改写。manifest 允许 `READY_FOR_MANUAL_OPEN`，但 gate 仍是 `LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER`，产品与公开发布保持 `BLOCKED`；它是等待独立复审的本地人工验收入口，不是公开发布。
- 失败与恢复：若复审再发现问题，保留 r4-fix3 与 `/private/tmp` audit/review 证据，使用新候选名；不得重新引入 body 摘要透传或以更长 denylist 替代固定文案边界。

## 任务 040：Loop 6.5 GitHub 仓库来源适配器

- 日期：2026-07-18
- 场景 → 角色与交接：学习时用户把 `github.com/owner/repo` 粘贴进 LinkDigest。`SourceAdapting` 像资料入口的分拣员，只回答“这条链接我是否接管”与“交出哪份 `CapturedDocument`”；GitHub Adapter 从公开 README API 交出原始 Markdown，`CaptureIngestService` 仍先完成 SQLite commit，才把 TaskID/SnapshotID 交给图片缓存与 UI。总结/翻译接收的始终是 README 正文，不依赖图片成功。
- 本次新名词：来源适配器（特定链接的最小分拣器）、raw README（GitHub API 直接给出的 Markdown 材料）、任务级图片缓存（TaskID/SnapshotID 名下的本地附件）。它们分别位于 `LinkDigestCore/SourceAdapter.swift`、`GitHubRepositorySourceAdapter.swift` 与 `GitHubREADMEImageCache`；没有这个边界，后续 arXiv/博客会把特例混进通用 HTML 抓取，或让 History 在展示时重新联网。
- 安全工作流：只有严格两段的 HTTPS `github.com/owner/repo` 接管；README 与允许的 GitHub 图片都复用 `ProxyAwareWebPageFetcher` 的 PeerBound/系统代理 admission、TLS 与逐跳 redirect 门禁。404、403/429 只显示固定中文；README body 不作为错误透传。图片只处理仓库相对路径和 GitHub/GitHubusercontent HTTPS 地址，外部 badge 不请求；每图 5 MiB、最多 20，MIME 与 PNG/JPEG/GIF/WebP 魔数必须一致，并在每个 redirect hop 与最终 URL 重新检查 GitHub host 白名单。
- 本地数据与恢复：图片先用 capture request ID 暂存，commit 后原子提升到 Application Support 的 `TaskID/SnapshotID` 子目录；History 用 manifest 中的本地 `NSImage` 读取，绝不远程加载。Task 删除成功后清理整项缓存；缓存、图片、外部地址或 MIME 失败只丢附件，不阻断 README 的保存、总结或翻译。若入库失败或取消，暂存目录清理。
- 自动证据（冻结前）：Adapter/路由/图片定向测试覆盖严格路径、raw Accept、404/403/429、相对地址、外部跳过、单图超限、20 张截断、MIME/RIFF 伪造、redirect 外域拒绝、本地展示与 Task 删除清理；真实 GitHub 抽样由 ManualSampleVerifier 记录 PowerToys（相对图片 README）、VS Code 与不存在仓库。全量与候选 gate 的最终数字在冻结完成后追加。

### 任务 040 追加：Loop 6.5 冻结 PASS

- 工程验证：定向 GitHub Adapter、SourceAdapter 路由、ManualLinkViewModel、History 缓存/删除与 ProxyAware resource routing 均 PASS；全量 `timeout 300 swift test --disable-sandbox` 为 **261/261 PASS，0 failures**。debug/release build 均 PASS；doctor 为 **87 PASS / 1 dirty-worktree WARN / 0 FAIL**。
- 真实抽样（仅 GitHub 三域）：`microsoft/PowerToys`（README 含相对图片）成功，`microsoft/vscode` 成功，明确不存在的仓库稳定返回 `githubRepositoryUnavailable`；结果 JSON 位于本轮 `/private/tmp/linkdigest-loop65-github-samples-20260718.json` 证据根，未用认证或真实凭据。
- 冻结入口：`release/loop65-candidate-20260718/LinkDigest-0.1.0-local-test/`。独立 gate **76 assertions PASS / ContractTests 10/10 PASS**，复制候选 `SHA256SUMS` **13/13 OK**，readonly mount=true、residual=false。DMG SHA-256：`abe33f3f11174f01ba743228be98e076e007c4bb4a216f58951faa49ba89ce1d`；source archive SHA-256：`d94385a5bbc32b8eb406564e4f5e4c43163ae6bc60b4edc82ce997b217434cc6`。
- 状态与恢复：manifest 为 `READY_FOR_MANUAL_OPEN`，独立 gate 为 `LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER`；产品与公开发布仍 `BLOCKED`。后续若复审失败，保留本候选和 audit/review 根，以新名称重建；不得为外部图片、私有仓库或兼容性便利绕过来源/图片 host 门禁。

## 任务 041：Loop 6.6 历史详情精修

- 日期：2026-07-18
- 场景 → 角色与交接：用户回看一条已完成的总结或翻译时，需要知道“做了什么、用的什么模型、何时完成、是否完成、消耗多少 Token”，而不是从当前设置猜测过去。SSE 解码器像快递单的末尾计数页：正文 delta 交给结果流，usage 尾块只交给 `ModelRunOrchestrator`，它在完成 Run 时写入已有 SQLite usage 字段；History 详情再从 Task/Run 证据显示这些值。旧流没有这张计数页时保留“—”，不伪造数据。
- 本次新名词：usage 尾块（流结束前的 token 计数）、运行元数据（Run 已保存的操作/模型/状态）、host 级缓存（同网站多条历史共用的本地 favicon）。它们分别位于 `ChatCompletionsStreamDecoder`/`ModelRunOrchestrator`、`HistoryContentView` 与 `WebsiteFaviconCache`；若把 usage 当正文，会污染结果，若从当前配置回填历史，会把过去记录改写成今天的设置。
- 安全工作流：favicon 不是 UI 的远程图片能力。它从已捕获 URL 仅构造同 host 的 `/favicon.ico`，再经同一 `SafeResourceFetching`/`ProxyAwareWebPageFetcher` admission、peer/TLS 和 redirect 检查；每 host 64 KiB，MIME 与魔数双验，redirect 不得跨 host。缓存失败、超限、非图片和网络失败都显示本地通用文档图标；GitHub 使用固定图标，不联网。缓存只在 Application Support，30 天未使用即清、最多保留最近 128 host；Task 删除不误删其它任务可复用的共享 favicon。
- 取舍：费用行整体不显示。BYOK 的模型价格、缓存计费、区域/套餐和币种没有本机可验证的统一价格表，“估算费用”因此从路线图裁剪；Token 显示服务商明确给出的计数，但不推算货币金额。
- 自动证据起点：usage-only SSE（含无 `choices` 的兼容和负 token fail-closed）、无 usage 旧流、重启后 Run usage/模型/状态、详情元数据绑定、本地化今天/更早时间、favicon 超限/错误 MIME/失败回退/同 host redirect 与本地命中均有 fixture 测试。定向 **40/40 PASS**，全量 `timeout 300 swift test --disable-sandbox` 为 **268/268 PASS，0 failures**；后续 Debug/Release、doctor 和候选 gate 结果在冻结完成后追加。

### 任务 041 追加：验证完成、冻结流水线 PARTIAL

- 工程验证：`timeout 300 swift build --disable-sandbox -c debug` 与 `-c release` 均 PASS；doctor 为 **87 PASS / 1 dirty-worktree WARN / 0 FAIL**。首次默认 SwiftPM sandbox 被环境 `sandbox-exec` 拒绝，按既有 `--disable-sandbox` 本地路径重跑后，测试与构建均正常；这不是产品代码失败。
- 冻结诊断：两次全新 `/private/tmp/linkdigest-r4b-local-test.loop66*` audit 根均成功留下 source/dependency deterministic archive、roundtrip 与 Swift scratch，却在产生 DMG/handoff 前静默停止；第二次将 stdout/stderr 写入独立日志后仍为空。没有 `BUILD_MANIFEST`、DMG、`SHA256SUMS`、readonly mount 或 76 项 gate 结果，因此 `release/loop66-candidate-20260718/` 只保存 PARTIAL 报告，**没有** `READY_FOR_MANUAL_OPEN` 候选。
- 停止与恢复：这已是同一流水线停点连续两次，按停止条件不再第三次重跑、不手工拼装 DMG 或绕过 gate。保留两个 audit 根和空诊断日志；后续在可观察该 Python 子进程退出状态的环境中用新的 audit/review 根定位后，再执行既有独立 gate。源码的 268/268 自动证据不替代冻结产物的完整性证据。

### 任务 041 追加：复审 P1 usage 容错旁路

- 复审结论：Loop 6.6 的 favicon、migration、时间格式与费用口径均通过；唯一 **P1 BLOCK** 是把服务商的可选 usage 尾块误当成正文流的必需协议。负数、类型错误、`Int64` 溢出或部分字段异常会在 delta 后阻断 `[DONE]`，把本应完成的 Run 误写成失败。
- 修复交接：`ChatCompletionsStreamDecoder` 先解析必需 choices/delta，再独立、容错地读 usage。畸形 usage-only 事件返回 nil 继续等 `[DONE]`；同事件有有效 delta 时优先交付 delta。`RunUsageCost` 的默认构造器对无效 Provider 计量整段回退 `.unknown`，而 SQLite/import 边界仍通过显式 `validated(...)` 严格拒绝损坏持久化数据，避免“容错网络元数据”反向放宽本地数据完整性。
- 自动证据：真实 OpenAI-compatible loopback Provider 与原始 SSE→decoder→持久化 Orchestrator 两条链路都覆盖负数、字符串类型、超出 `Int64`、部分字段异常。每类均断言 valid delta + malformed usage + `[DONE]` 后 Run 为 completed、正文完整、usage unknown、没有 failed/incomplete 状态；有效 usage 的重启落库测试保留。定向 **30/30 PASS**；全量 `timeout 300 swift test --disable-sandbox` 为 **270/270 PASS，0 failures**；Debug/Release build 均 PASS。随后只会尝试一次新候选冻结；若环境再在旧停点静默停止，交主控装箱，不重复重试。

### 任务 041 追加：r6.6-fix1 装箱交主控执行

- 单次尝试：`/private/tmp/linkdigest-r4b-local-test.loop66-fix1-20260718` 再次只留下 `working/TOOL_HASHES.json` 与中间工作目录；没有 handoff、DMG、`BUILD_MANIFEST.json`、`SHA256SUMS` 或 gate JSON，调用层仍无 stdout/stderr/exit 诊断。该结果与上轮两个 audit 根同一停点一致。
- 停止边界：按本轮“再次停在同一点即交主控执行”的明确规则，不创建 `release/loop66-candidate-20260718-fix1/` 伪候选、不重试、不手工复制中间产物。主控应从新的 audit/review 根执行既有 pipeline 与独立 76 项 gate；在其全绿前不得标 `READY_FOR_MANUAL_OPEN`。P1 源码修复的 270/270 证据不替代 DMG 绑定证据。

## 任务 042：Loop 6.8 设置页重构与模型体验

- 日期：2026-07-18
- 当前状态：**工程实现完成，冻结交主控执行。** 本轮只改设置、运行选择和展示层，不新建 Provider、授权、价格或同步数据面；DMG/local-test gate 未在本 Agent 环境执行，不能据此标候选 ready。
- 场景 → 角色与交接：用户先在“模型服务”选择一个无 Key 的厂商预设、保存可编辑 Base URL/模型与 Keychain API Key；需要时由同一 `OpenAICompatibleProvider` 读取 `/models`，只把最多 500 个 id 交给设置下拉。随后“生成与数据”把自定义 prompt、全局输出语言和可选翻译模型作为 `ModelPreferences` 交给 App。运行前 `AppViewModel` 把保存 profile 身份与实际（可能不同）翻译/临时模型身份分别冻结：前者防配置竞态，后者用于用户发送确认；`ModelRunOrchestrator` 最终只用短时 Key 和那个实际模型发请求。
- 本次新名词：厂商预设、模型目录、输出语言、临时模型；均已进入 `docs/GLOSSARY.md`。预设像地址簿模板，不是密钥；模型目录像只抄菜单菜名的受限读取；输出语言是总结和翻译共用的成品语言要求；临时模型只影响一条重生成，不能改写长期设置。
- 安全边界：预设永不含 Key；`/models` 复用现有 Provider session、Base URL 校验、同源 redirect guard、大小上限与固定错误码，不保留 response body；失败/超时只回退手填。设置保存仅显式允许 `http://127.0.0.1`，`localhost` 和其它私网 HTTP 仍拒绝。独立翻译/临时模型会成为实际目的地身份并触发新确认，不能借既有总结模型确认绕过。历史重新生成只取本机 snapshot，不重新抓取。
- 小步体验：主按钮旁显示可点击的当前模型名并打开设置；可识别的同语言内容禁用翻译且动作入口也拒绝直调，短文/混合/未知语言保持可翻译；`visible_only`/`selection_only` 捕获在详情显示截断提示。费用仍不显示，因为 BYOK 没有可靠本地价格事实。
- 自动化起点：本地 loopback `/models` 成功/503/超时/500 条截断、预设覆盖编辑、设置目录失败手填回退、旧偏好迁移、exact loopback、输出语言注入、独立翻译模型重启与重新确认、同语言直调门禁、历史临时重生成/截断结构均有定向测试。全量、Debug/Release 与 doctor 的实测数字在本条后续追加报告中记录。
- 失败与恢复：目录、短时 Key 或配置读取失败不改变已保存模型，用户可手填并保存；目录 response body 不可见。若要回滚，只撤销本轮设置/偏好/运行选择/展示和测试文档，不触碰 Keychain、系统代理、真实服务、历史候选或 Brain。

### 任务 042 追加：工程验证与冻结交接

- 自动化结果：`OpenAICompatibleProviderTests` **16/16**、`ProviderSettingsViewModelTests` **25/25**、`ProviderStoreTests` **9/9**、`AppViewModelTests` **36/36**、`HistoryContentViewTests` **9/9**、`ModelPreferencesTests` **1/1**、`CapturedContentLanguageTests` **1/1**、`ModelRunOrchestratorTests`（连 Persistent）**27/27** 均 PASS；最终 `timeout 300 swift test --disable-sandbox` 是 **283/283 PASS，0 failures**。首次全量暴露一条旧断言仍期待未追加输出语言的默认总结 prompt；更新断言后同一全量复跑通过，未改变运行安全门禁。
- 构建/健康：`timeout 300 swift build --disable-sandbox -c debug`、`-c release` 均 PASS；`./scripts/doctor` 为 **PASS=87 / WARN=1 / FAIL=0**，唯一 WARN 是预期 dirty worktree。`git diff --check` 无输出。
- 冻结交接：按本轮授权，不运行 DMG 流水线、不创建 `READY_FOR_MANUAL_OPEN` 候选。主控应从当前 worktree 按既有 76 项 local-test gate 另建冻结候选并绑定本轮设置、模型目录、偏好/运行选择与测试文件；在 gate 全绿前不得标记人工验收 ready。

### 任务 042 追加：复审 P1×2/P2×1 修复

- P1-1：`canSavePreferences` 现在是“非 loading 且非 saving”的唯一规则，SwiftUI 保存按钮与 `savePreferences()` 方法入口共用它。可阻塞 `ModelPreferencesStore` 让 `load()` 停在半途；测试直接调保存，确认零写入、持久化旧 prompt/输出语言/翻译模型不变，完成加载后才恢复旧偏好到 ViewModel。
- P1-2：同语言门禁从“哪个脚本计数最大”收敛为“唯一且清楚领先”。中文/韩文/拉丁需要至少 12 个字符且不少于第二名两倍；任何少量假名都先视为中日歧义，只有假名本身足够、相对汉字显著且整体领先才认作日文。混合比例、并列、少量假名夹杂和未知脚本均返回 nil，因此 UI 与方法入口都放行翻译。取舍是宁可多显示一次翻译按钮，绝不误禁用户动作。
- P2-1：删除重生成的源码字符串契约。新的 AppViewModel 测试从 `HistoryDetailProjection` 的本地 snapshot 发起临时模型总结：确认前 Provider 为零调用；确认后正文等于 snapshot、模型为临时模型、创建新 Run，`HistoryRepository.acceptCapture` 仍为零，证明没有重新进入 capture/fetch 链路。
- 自动化证据：Settings **26/26**、语言 Core **2/2**、App **38/38**、History UI **9/9**；最终 `timeout 300 swift test --disable-sandbox` 为 **287/287 PASS，0 failures**。Debug/Release build 均 PASS；按本轮要求未执行 doctor 或 DMG 冻结。

### 任务 042 追加：unknown Unicode 竞争边界修复

- 剩余 P1 根因：旧检测器只认识汉字/假名/韩文/拉丁，阿拉伯文、西里尔文、天城文等其它字母会被忽略；正文主体因此在统计中“消失”，夹带的 12 个英文品牌名或 URL 字符就可能被误判为拉丁、错误禁用 English 翻译。
- 收敛规则：现在每个 alphabetic Unicode scalar 都计数。四类已识别脚本各自计数，其余字母进入 `unknown`；目标只有在至少 12 个字母、占全部字母至少 60%、并相对每个其它已识别脚本和 unknown 都不少于两倍时才返回语言。日文仍先要求假名足够显著以避免把中日混合当成日文，并用相同 unknown/占比门槛复核。证据不足一律返回 nil、放行翻译。
- 自动化证据：阿拉伯/西里尔/天城文主体各夹 `OpenAIBrandURL` 拉丁标记的 Core 断言均为 nil，真实 `AppViewModel.translate()` 三条路径均调用 Provider。既有混合比例、并列、少量假名与纯 unknown 回归保留。语言 Core **3/3**、App **39/39**、全量 **289/289 PASS**；Debug/Release build PASS。按本轮要求未执行 doctor、DMG 或 gate，冻结交主控。

## 任务 043：Loop 6.9 标签与看板筛选

- 日期：2026-07-18
- 当前状态：**工程实现完成，冻结交主控执行。** 本轮只增加本地 History 标签元数据和展示/查询，不引入账号、云同步、外部标签服务或新的数据目的地确认；DMG/local-test gate 仍由主控从当前 worktree 冻结。
- 场景 → 角色与交接：一条总结成功后，`ModelRunOrchestrator` 把已完成的总结文本（不是网页全文）交给同一已确认 Provider/模型的轻量标签请求；`HistoryTagNormalizer` 只交出首行逗号标签；`HistoryRepository` 再把规范化标签写入本机 SQLite。详情页把手动增删与已有标签建议交给 `HistoryViewModel`，侧边栏把选中的标签和搜索词作为同一个 SQL 查询条件交给仓储。这样模型失败不会让摘要失败，UI 也不会先加载整页再做不可靠的内存筛选。
- 本次新名词：标签规范化、任务标签关联、SQL 交集筛选，已加入 `docs/GLOSSARY.md`。它们分别像统一索引卡写法、书与主题的登记表、同时满足多张索引卡的检索；对应 `HistoryTagNormalizer`、`tags/task_tags` 和 `GRDBHistoryRepository.historyPage(...filter:)`。没有这些边界会产生大小写重复、删除残留或分页/搜索不一致。
- 失败与安全边界：自动标签是完成总结后的 fail-open 旁路；任何网络、JSON、空首行或解析失败都不改写 completed Run、不显示 Provider body、不创建新的数据目的地确认。请求复用完成总结的 profile/model/短时 Key，响应只在内存中解析后转成标签。翻译 Run 不触发自动标签；每 Task 最多 10 个，单次自动最多 5 个；删除 Task 由 SQLite 外键级联清理关联。
- 可选跟做（5–10 分钟）：打开一条历史详情，手动添加两个标签；在侧边栏单击一个标签，再按住 Command 单击第二个，观察列表从单标签变成两者交集。搜索框继续可用且不清空标签选择；这不是任务关闭前置条件。
- 恢复边界：若后续冻结或复审失败，保留当前 worktree 与历史候选，使用新候选名重新冻结；不得把自动标签改成主链路阻断、把筛选退回内存过滤，或通过读取真实 Keychain/外网来调试。

### 任务 043 追加：工程验证与冻结交接

- 定向证据：`OpenAICompatibleProviderTests` **17/17 PASS**（含非流式固定 prompt/model/max_tokens 请求）、`ModelRunOrchestratorTests` 与 Persistent **29/29 PASS**（含成功、失败/空解析 fail-open、翻译不打标签）、迁移 **6/6 PASS**、标签持久化 **3/3 PASS**、导出 **11/11 PASS**、History ViewModel **12/12 PASS**、History View **10/10 PASS**。覆盖 v1→v2、大小写/超长/上限、SQL 单选/交集/空集及搜索独立、手动增删、任务删除级联和三种导出。
- 全量与构建：`timeout 300 swift test --disable-sandbox` 实测 **300 executed / 299 passed / 1 allowed environment failure**；唯一失败为既知 `ProviderStoreTests.testKeychainWriteReadReplaceAndDeleteUsesIsolatedService` 的 Keychain write `status 100001`，未触碰真实 Keychain。`timeout 300 swift build --disable-sandbox -c debug` 与 `-c release` 均 PASS；`./scripts/doctor` 为 **PASS=87 / WARN=1 / FAIL=0**，唯一 WARN 是预期 dirty worktree；`git diff --check` 无输出。
- 冻结交接：按本轮授权停止于源码、测试、文档和报告；不执行 DMG/gate，不创建 `READY_FOR_MANUAL_OPEN` 候选。主控冻结时应将新增 `HistoryTags.swift`、`Migration002.swift`、仓储/编排/UI/Provider 与对应测试一并绑定到 source archive，且只有 gate 全绿后才可人工验收。

### 任务 043 追加：复审 P1 自动标签 UI 交接修复

- 复审根因：自动标签在 `.completed` 已交给 Run/UI 后才落库；此前没有第二条本地交接，详情的 `detail.tags` 和侧边栏的 `availableTags` 只是旧快照。用户必须切换记录、搜索或重启才看得到新标签。
- 修复交接：`ModelRunOrchestrator` 在 `history.addTags(...)` 成功提交后才发出 `HistoryMetadataChangedHandler(taskID:)`；它不是 `RunState`、不携带 Provider body，也不在失败时发出。组合根把它交给 `HistoryViewModel.historyMetadataChanged(taskID:)`：仅按该 TaskID 读取详情、读取全局标签；不运行分页列表查询、不改 completed/错误状态。像入库后的取件通知，通知只让展示层取已提交的本地元数据。
- 自动证据：执行级 `testAutomaticTagCommitRefreshesCurrentDetailAndAvailableChipsWithoutNavigation` 使用真实 GRDB 与 Orchestrator，断言总结完成后不切换记录或搜索即出现详情标签和 chips；`testAutomaticTagFailurePublishesNoMetadataEventAndLeavesHistoryUIUnchanged` 断言请求失败时通知数为零、详情/chips/RunState 不变。`HistoryViewModelTests` **14/14 PASS**，Orchestrator（含 Persistent）**29/29 PASS**；全量 `timeout 300 swift test --disable-sandbox` 为 **302 executed / 301 passed / 1 allowed environment failure**，唯一仍是 Keychain status `100001`。Debug/Release build PASS；doctor **87 PASS / 1 dirty-worktree WARN / 0 FAIL**。
- 冻结交接：本轮按授权停止在源码和验证，不修改旧候选、不创建新 DMG。主控以新 Loop 6.9 候选名冻结时，需绑定本次 metadata-handler、组合根、HistoryViewModel 与执行级测试；gate 全绿前不得标人工验收 ready。

### 任务 043 追加：复审 P1 metadata 事件所有权竞态收敛

- 复审根因：上一轮的 metadata 通知虽然只读本地 detail/chips，却仍为 metadata 读取维护了独立 Task 与 request ID。于是 Task B 的通知可取消正在查看的 Task A 的 metadata 读取；同时一个较早的普通详情读取可以在较新的 metadata 读取之后返回并覆盖标签。
- 修复交接：`historyMetadataChanged(taskID:)` 先异步刷新全局标签 chips；仅当该 ID 仍是当前 `selectedTaskID` 时才发起详情读取。普通选择读取与 metadata 读取现在共用 `detailTask` 和单一 `detailRequestID`，像同一个详情柜台的取号机：新号到来会使旧号结果失效，非当前 Task 的通知则只更新公共标签墙，不能碰当前柜台。
- 确定性自动证据：三个 semaphore barrier 测试分别验证：(A) A 的详情刷新被阻塞时收到 B 通知，A 仍完成刷新而 chips 同时含 A/B；(B) 旧普通读取晚于 metadata 返回时，旧空标签快照不能覆盖新标签；(C) 快速 A/B 自动标签通知后，当前选择、detail.taskID 与 detail.tags 始终同属 B。既有真实 GRDB 总结→自动标签→UI 和失败 fail-open 执行级测试继续覆盖事件来源与失败不更新 UI。
- 工程验证：`timeout 120 swift test --filter HistoryViewModelTests` **17/17 PASS**；全量 `timeout 300 swift test` **305/305 PASS，0 failures**；`swift build --disable-sandbox -c debug` 与 `-c release` 均 PASS；doctor 为 **PASS=87 / WARN=1 / FAIL=0**，唯一 WARN 是预期 dirty worktree。
- 冻结交接：本轮仍按授权停止于源码、测试和文档，不创建候选或 DMG。主控冻结时应绑定 `HistoryViewModel.swift` 与 `HistoryViewModelTests.swift` 的本次所有权收敛；gate 全绿前不得标记人工验收 ready。

### 任务 043 追加：复审 P1 metadata 接管状态机收尾

- 复审根因：上一轮已把普通与 metadata 读取收敛到同一 request identity，但 metadata 成功分支只替换 `detail`，没有完成 `detailState`。当它接管一个正在 `.loading` 的普通读取时，真实界面仍按状态机显示 spinner，尽管新标签已在内存 detail 中。
- 修复交接：metadata 接管现在直接使用普通详情的唯一 completion 分支。成功统一写入 `detailState = .loaded` 并清除旧 `detailErrorCode`；本地详情读取失败统一进入 `.failed`，`retryDetail()` 可再走正常详情读取，绝不会停留在无所有者的 `.loading`。
- 确定性自动证据：既有多任务、旧普通读取晚到和快速 A/B barrier 测试均追加最终 `.loaded` 断言；新增 `testMetadataTakeoverOfLoadingDetailFailureLeavesRetryableFailedState`：阻塞普通 A 读取使 UI 进入 `.loading`，让 metadata 接管后的本地读取确定性失败，断言变为 `.failed` 且有 error code，随后重试恢复 `.loaded`。
- 工程验证：`timeout 120 swift test --filter HistoryViewModelTests` **18/18 PASS**；全量 `timeout 300 swift test` **306/306 PASS，0 failures**；`swift build --disable-sandbox -c debug` 与 `-c release` 均 PASS。
- 冻结交接：按本轮授权停止于源码、测试和文档，不创建 DMG。主控应绑定本次 `HistoryViewModel` 状态机与测试变更，在完整 gate 全绿前不得标记人工验收 ready。

## 任务 044：Loop 7 Extension Identity Artifact

- 日期：2026-07-18
- 当前状态：**工程实现完成，冻结交主控执行。** 本轮冻结的是浏览器扩展的技术身份，不是最终产品命名、更不是商店发布签名；不安装扩展/Host、不访问真实 browser profile。
- 场景 → 角色与交接：用户在 Chrome、Brave 或 Edge 手动加载扩展时，浏览器用 manifest public key 推导固定 ID；Native Host 只接受该 ID 的 origin；WXT output 交给确定性 zip 工具，zip/模板与 ID/version/hash 再交给 local-test handoff。App/UI 只从 `product-display.json` 读当前工作名，不参与身份判断。像“产品标签”和“设备序列号”：改标签不改变能否打开对应的门。
- 本次新名词：扩展技术身份、确定性工件、显示名边界，已加入 `docs/GLOSSARY.md`。它们分别位于 `extension-identity.json`、`extension_identity_artifact.py`/`identity-artifact` 和 `product-display.json`；没有这些边界，改名会改 Host trust，或候选无法证明拿到的是哪份扩展。
- 密钥边界：只生成了一把开发身份 key，位于 `/Users/song/Library/Developer/LinkDigest/extension-identity/linkdigest-loop7-development-extension.pem`、权限 **0600**，不在 Git、候选、Keychain 或 Application Support。仓库只保存 public manifest key、其派生 ID `fbpjhlcpfheecigibjghhodhhkgjdgma` 与 SHA-256；未来商店 key 由 Syc 单独管理，本轮不生成、不读取、不导出。
- 自动证据：`pnpm browser:build` 生成 WXT manifest（version `0.1.0` 与 public key）；`pnpm browser:identity:check` 从同一 output 双次压缩并确认 zip 字节一致，校验 key→ID、manifest、三浏览器 exact `allowed_origins`、0644/固定 mtime/排序 entry 与显示名接线。local-test config/packer/gate 将 zip、identity config 和 Chrome/Brave/Edge placeholder templates 放入 exact handoff，并在 source archive、BUILD_MANIFEST、SHA256SUMS 和 gate result 间交叉绑定；不从 `.output` 或被 snapshot 排除的旧 `artifacts/` 取文件。
- 可选跟做（5–10 分钟）：只读打开 `config/extension-identity.json` 与 `apps/browser-extension/.output/chrome-mv3/manifest.json`，可观察两者的 public key 相同；再查看 `identity-artifact` 三个模板的唯一 `chrome-extension://…/` origin。不要打开、复制或上传 `.pem`；这不是任务关闭条件。

### 任务 044 追加：独立 gate 清单字段修复

- 根因：Loop 7 gate 同时读取两类清单。`BUILD_MANIFEST.browserExtension` 的 artifact/template 使用 `sha256` 字段，而 source archive 的 portable tree records 一直使用 `hash` 字段。扩展断言误把 source record 当成前者读取 `sha256`，主控装箱虽成功，独立 gate 却以 `KeyError('sha256')` exit 70 崩溃。
- 修复交接：source record 现在显式要求 `hash` 键，再与解包 source 文件的 SHA-256 比较；`BUILD_MANIFEST.browserExtension` 仍显式要求 `sha256`。缺任一必需键会变为带上下文的 `CheckFailure`，不会 `.get()` 静默放过或再抛 INTERNAL。
- 真正证据：对主控 immutable audit `/private/tmp/linkdigest-r4b-local-test.loop7-main2-20260718` 重跑 gate，结果为 **102 assertions PASS / ContractTests 10/10**；readonly mount=true、residual=false，gate-result 同时记录 extension artifact hash、ID、version 与三浏览器模板 hash。旧 `loop69-fix3` audit 仍在，按新版 exact tree 合同明确失败 `handoff tree is not exact`，没有误 PASS 或 INTERNAL。
- FAKE_SECRET 教训：release preflight 的测试用 Key 形态字面量也会被 source snapshot secret scanner 正确拒绝；主控已改成运行时拼接，保留测试语义但避免把秘密形态写入静态源码。今后 fixture/测试要验证 secret hygiene 时，必须动态构造 marker，不能把可识别 Key 形态直接写成源码常量。
- 回归：`timeout 300 swift test` **307/307 PASS**；`pnpm check:web` PASS，含 secret hygiene 和 doctor **87 PASS / 1 dirty-worktree WARN / 0 FAIL**。按授权不重新冻结，交主控从当前 worktree 重建候选。

## 任务 045：Loop 8 Browser Support Installer

- 当前状态：**实施中；工程验证只使用隔离 HOME，冻结交主控。**
- 场景 → 角色与交接：用户在 Settings 的“浏览器支持”查看 Chrome、Brave、Edge 的 manifest 状态并主动点击动作；`BrowserSupportViewModel` 负责把按钮、确认框和执行中的状态收在 MainActor；`BrowserSupportInstaller` 接收浏览器与明确确认，先校验 Loop 7 冻结模板/嵌入 Host，再把 rendered manifest hash、Host hash、版本交给自有 receipt。像物业报修：前台只收确认，施工员只动标着本户的设施，最后把维修单存回本户档案。
- 本次新名词：浏览器支持收据、原子发布、冻结模板绑定，已加入 GLOSSARY。它们分别解决“我能不能删这份文件”“读者会不会看到半份 JSON”“App 模板会不会和扩展 ID 漂移”三个不同问题。
- 安全边界：Python clean-room installer 仍不支持 real HOME；Swift 产品服务的 HOME 是显式注入，自动测试均创建 `/private/tmp/linkdigest-browser-support-tests-…/isolated-home`，并检查 fixture 的非 HOME 部分 hash 不变。没有改变进程 HOME、没有读取/写入真实 `~/Library`、浏览器 profile、Keychain 或系统设置。
- 当前自动证据：Core fixture 覆盖目录缺失、Chrome/Brave shared target、Edge、首装/no-op、未知同名确认+备份+恢复、漂移修复、漂移卸载拒绝、模板 hash 拒绝和 receipt 前故障回滚；App ViewModel 覆盖未知 manifest 的确认门禁、执行中零排队、Chrome 动作同步 Brave 与直接入口 guard。`pnpm browser:identity:check` 也开始逐字节校验 App resource 模板与 Loop 7 handoff 一致。
- 可选跟做（5–10 分钟）：只读比较 `apps/browser-extension/identity-artifact/native-host-manifests/chrome.json` 与 Core resource 中同名文件，再在 Settings 打开“浏览器支持”观察“未检测到浏览器”状态；不要点击安装，也不要把工程测试目录替换为真实 HOME。这不是任务关闭条件。

### 任务 045 追加：独立安全复审未决项

- 复审确认了隔离 HOME、共享 target、确认 fingerprint、receipt 无效 fail-closed、FIFO 拒绝、rollback 与候选 gate focused test 接线；但冻结前仍必须补两条所有权证据：receipt 要绑定其具体 takeover backup 的文件名与 SHA-256，且要绑定完整 Native Host package/resource bundle digest，而不只绑定 executable。否则恢复可能选错备份，Host resource 漂移也可能被误报为一致。
- 因此当前学习结论不是“安装器完成”，而是“收据是所有权真相，任何可恢复副本和运行依赖都必须进入同一张收据”。本轮报告保持 PARTIAL，主控不得冻结。

### 任务 045 追加：receipt 绑定强度 P1 收口

- P1-1（备份绑定）：接管或修复产生 backup 时，receipt 现在保存精确 basename 与 SHA-256。恢复先读取有效 receipt 的当前 target entry，再同时核验该文件名和文件内容哈希；改名、替换、缺失或任何未收据绑定的同前缀文件都会明确拒绝，不再以时间戳或目录扫描猜测“最新”备份。
- P1-2（完整包漂移）：receipt 除 executable hash 外，新增完整 Native Host package/resource tree digest。它排序并绑定每个目录路径、文件路径与文件内容哈希，遇到 symlink 或特殊文件 fail closed；因此 `LinkDigestCore` resource bundle 内任意资源新增、删除或修改都会使状态变成“漂移”，无法卸载，必须走确认修复。
- 自动证据：`BrowserSupportInstallerTests` 新增 backup 改名拒绝、backup 内容哈希不符拒绝、Host resource marker 漂移拒绝卸载三条；定向结果 **16/16 PASS**。测试持续使用唯一 `/private/tmp/.../isolated-home`，没有读写真实 HOME、浏览器目录、系统设置或凭据。
- 完整验证数字、preflight 结果与冻结交接将在本条后续报告追加；本 Agent 不运行候选冻结。

### 任务 045 追加：最终验证与冻结交接

- 最终验证：`timeout 300 swift test --disable-sandbox` 为 **327 executed / 326 passed / 1 allowed environment failure**；唯一允许项仍是隔离 Keychain 的 `ProviderStoreTests.testKeychainWriteReadReplaceAndDeleteUsesIsolatedService` write status `100001`。新增 Core 安装器套件 **16/16 PASS**。`pnpm check:web` PASS（shared/browser **20/20**），Debug/Release build 均 PASS，`./scripts/doctor` 为 **87 PASS / 1 dirty-worktree WARN / 0 FAIL**，静止 worktree `pnpm native-host:release:preflight:check` 为 **101 assertions PASS**，`git diff --check` 无输出。
- 交接结论：两条 receipt P1 已由负向测试锁定；本 Agent 按授权不运行 DMG/gate 冻结，也不创建 `READY_FOR_MANUAL_OPEN`。主控应从当前 dirty worktree 重新冻结并执行完整 local-test gate；全绿才可进入人工验收。整个工程验证继续只使用 `/private/tmp` 隔离 HOME，未碰真实浏览器目录、系统设置、Keychain 或凭据。

### 任务 045 追加：进程终止恢复与叶节点竞态修复

- 新的交接物是 `operation-v1.json`：它像施工中的交接单，保存动作、目标、manifest/receipt 的前后精确字节、backup/quarantine hash 与阶段。live receipt 才是正式入账点：崩溃前恢复回旧 manifest，崩溃后只完成清理；journal 内容不完整或 live 文件不是 before/after 的任一种就保留现场、停止猜测。
- 叶节点不再在原 basename 上“先看 A、后替换”。installer 先把 A 以 no-replace rename 移入唯一 quarantine，随后验证移动后的 inode/内容；新文件也只能 no-overwrite 发布。若同 UID 的外部 B 在此时出现，B 不会被覆盖或删除，事务保持 fail closed。
- 自动证据：三条独立 subprocess 测试让 install/uninstall/restore 分别在“manifest 已变、receipt 未提交”处以 exit 86 终止；新进程的 `inspect()` 自动 recover 到稳定态并清 journal。两条 deterministic barrier 测试在 detach 后放入 B，确认 install 不覆盖 B、uninstall 不删除 B。另有 receipt 存在但 manifest 缺失时的确认修复测试，证明 UI 不会永久无入口。定向结果为 Installer **22/22** + ViewModel **4/4 PASS**；后续全量验证结果写入本轮报告。

### 任务 045 追加：事务合同最终收敛（r4）

- 复审场景与结论：上轮 journal 会在同一事务里更新 phase，旧 receipt 又会在替换时短暂离开 canonical 路径；进程若刚好终止，恢复器没有一张不可变、可验证的“旧 receipt 在哪里”的交接单。本轮把交接单收敛为一次发布：`operation-v1.json` 的初始 before/after 快照就是唯一恢复依据，之后不再改写 phase。可以把它理解为纸质交接单先盖章入柜，再施工；施工过程不涂改那张单。
- receipt 接管：任何已有 receipt 的 mutation 都在 journal 发布前记录精确 `receiptQuarantineFilename` 和该旧 receipt 的 SHA-256。receipt 切换使用 no-replace detach → no-overwrite publish；若在两步之间终止，重启时只接受 journal 绑定的同名、同 hash 旧 receipt，恢复 canonical receipt 后回滚 manifest。hash、名称、live receipt 或 manifest 任何一项不属于 before/after 合同就 fail closed，而不是猜测文件。
- 恢复与完成责任：receipt 已到 after 即向前清理；仍为 before 即回滚；已有旧 receipt 被 detach 而新 receipt 尚未发布时先精确恢复 before。receipt 删除的 after 为 nil 则视为已提交删除、只完成清理。journal 从不再有“detach 后发布新 phase”的第二个写窗口；完成时的 journal 删除不参与业务恢复决策。
- 自动证据：`BrowserSupportInstallerTests` 增至 **26/26 PASS**。新增子进程 exit-86 crash barrier 覆盖：(1) journal 发布后、任何 target mutation 前；(2) 既有 receipt 的 Chrome repair 在旧 receipt detach 后/新 receipt publish 前；(3) 第二 target 安装的同一 receipt 间隙；(4) 多 target restore 的同一 receipt 间隙。每条都由新进程 `inspect()` 恢复，断言所有浏览器入口回到 installed/notInstalled/unknownManifest 的正常状态且 journal 消失，没有 `invalidReceipt` 或永久无操作状态。
- flake 收敛：先前全量记录中的两项“barrier 类”时序失败没有保留到可定位测试名，因此本轮对现有 `HistoryViewModelTests` 的所有相关 barrier 统一改为显式 entered/release rendezvous：被测后台读取先通知“已进入”，测试再明确放行；删除 `Task.yield()`、固定 10/30ms 等待和 1 秒 semaphore deadline。这样测试验证的是交接顺序，不是机器调度速度。
- 工程验证：连续两次 `timeout 300 swift test --disable-sandbox` 均为 **337 executed / 336 passed / 1 allowed environment failure**；唯一允许项是隔离 Keychain `ProviderStoreTests.testKeychainWriteReadReplaceAndDeleteUsesIsolatedService` 的 write status `100001`。`pnpm check:web` PASS；Debug/Release build PASS；`./scripts/doctor` 为 **87 PASS / 1 dirty-worktree WARN / 0 FAIL**；静止 worktree `pnpm native-host:release:preflight:check` 为 **101 assertions PASS**。
- 冻结交接：local-test gate 的 focused expectation 已精确更新为 Contract 10 + Installer 26 + ViewModel 4 = **40**，没有放宽任何断言。按授权停止在源码、测试、文档和报告；不运行 DMG/gate，不创建 ready 候选。所有自动化仍只用 `/private/tmp` 隔离 HOME，未读写真实 HOME、浏览器 profile、Keychain、系统设置或凭据。

### 任务 045 追加：P1×2 最终验证与冻结交接

- `timeout 300 swift test --disable-sandbox` 为 **333 executed / 332 passed / 1 allowed environment failure**；唯一允许项仍是隔离 Keychain status `100001`。`pnpm check:web` PASS（20/20 web tests），Debug/Release build PASS，doctor **87 PASS / 1 dirty WARN / 0 FAIL**，静止 worktree preflight **101 assertions PASS**。`git diff --check` 无输出。
- 本 Agent 停在源码、测试与文档，不运行 DMG/gate 冻结；主控使用新候选名 `loop8-fix2` 重新冻结。所有新 subprocess 都只接收 fixture 的 `/private/tmp/.../isolated-home` 和 test Host 路径；没有读取/写入真实 HOME、浏览器 profile、Keychain 或系统设置。

### 任务 045 追加：focused gate 环境差异诊断

- 根因不是 SwiftPM 的隔离 HOME 本身，而是测试错误把“当前工作目录的默认 `.build`”当作 crash harness 的位置。gate 的 `--scratch-path` 正确把 binary 放在独立目录，干净 source archive 因此三个 subprocess 测试都找不到 harness；主控手动运行曾生成默认 `.build`，才暂时掩盖差异。
- 修复后的测试从正在运行的 xctest bundle 反推同级 debug products，像从当前教室找同层的演示器，不再猜项目根目录。对 gate 原样 `env -i`、受限 PATH、独立 HOME/TMPDIR/config/cache/security/scratch 的复现：旧代码三条失败，替换这一定位后 **22/22 PASS**；当前 worktree 全量 **333 / 332 pass / 1 allowed Keychain 100001**。本轮不改变 gate 断言或安全边界，冻结交主控。

## 任务 046：Loop 9 Integrated Full DMG

- 日期：2026-07-18
- 当前状态：**工程实现与验证完成，冻结交主控执行。** 这不是 Developer ID、公证、商店或真实浏览器/BYOK 验收完成；新候选只有在主控装箱和独立 gate 全绿后才能标记 `READY_FOR_MANUAL_OPEN`。
- 场景 → 角色与交接：`config/local-test-release.json` 像一张总装箱单，固定 0.2.0 的 App、Host、extension zip、源码 archive 与总检指南来源；`local_test_release.py` 只从 live nofollow source snapshot 把这些物品装进同一 exact handoff tree；`local_test_release_check.py` 用独立 review root 再核对 hash、DMG readonly mount 与 focused 测试。Syc 拿到候选后按 `ACCEPTANCE_GUIDE.md` 做真实操作和价值记录，而不是把 fixture 绿灯当成人工使用结论。
- 本次新名词：集成交付、总检指南，已加入 `docs/GLOSSARY.md`。前者像“产品、配件、说明书、质检单同箱且每件有封条”，对应 candidate exact tree、`BUILD_MANIFEST` 和 `SHA256SUMS`；后者像“开箱检查单”，对应 `docs/ACCEPTANCE_GUIDE.md`。没有前者，分别通过的 App/Host/zip 可能被混搭；没有后者，人工总检只剩零散截图，无法回到 PRD 指标。
- 版本与命名：App、Native Host、extension identity/artifact、local-test DMG/source tree 和 package metadata 都推进到 **0.2.0**；显示名仍只从 `product-display.json` 读取，extension ID 与唯一 allowed origin 不变。版本是 P0 功能集完整的工程语义，不是发布/公证声明。
- 集成自动证据：gate focused 组现在精确为 **62** 项：Contract 10、无 GUI App composition 9、隔离 HOME 的 BrowserSupportInstaller 27、BrowserSupportViewModel 4、真实 GRDB + fixture Provider 的 summary → automatic tags → translate 12。新增浏览器矩阵在 `/private/tmp` 中覆盖 Chrome/Brave shared target 与 Edge 的 install、drift repair、uninstall；新增 BYOK fixture 断言两次 Run、usage、标签和正文均落库，不触网、不读取真实 Keychain、不创建数据去向确认。
- 候选指南：`ACCEPTANCE_GUIDE.md` 将被逐字节复制到候选根目录，gate 回链候选 hash、build manifest、source archive record 与 0.2.0 标记。它要求总检前先核验 `SHA256SUMS`，按 DMG/App、三浏览器支持、开发者模式 extension、X/登录页捕获、BYOK、标签/History/导出、卸载的顺序执行，并附 PRD §11.1 五项价值指标的人工记录表。Token 可从 History 详情读取；BYOK 费用不估算。
- 工程验证：两遍 `timeout 300 swift test --disable-sandbox` 均为 **339 executed / 338 passed / 1 allowed environment failure**；唯一允许项仍是隔离 Keychain `ProviderStoreTests.testKeychainWriteReadReplaceAndDeleteUsesIsolatedService` 的 write status `100001`。`pnpm check:web` PASS（shared/browser tests 20/20、extension identity 0.2.0）；Debug/Release build PASS；doctor **88 PASS / 1 dirty-worktree WARN / 0 FAIL**；静止 worktree preflight **101 assertions PASS**。
- 总检边界：自动化只读挂载 DMG、验证 App/Host/resources/extension/source/evidence binding，并使用 fixture。真实 Chrome/Brave/Edge 安装、登录页面捕获、真实模型 API 和价值指标由 Syc 主动完成；反馈中不得包含 Key、Cookie、Authorization、Provider body 或私人页面正文。

### 任务 046 追加：终审 P1×2 收口

- 复审发现同一固定 extension ID 的 `0.1.0` 与 `0.2.0` zip 同时处在 active `identity-artifact`，旧 zip 仍可被浏览器加载；这说明“handoff 只复制当前 zip”不等于“源码交付没有旧可执行工件”。现已移除旧 zip，并把 `LinkDigest-extension-*-chromium.zip` 的**恰好一项**规则下沉到构建验证和独立 gate：路径、内部 manifest version 与 SHA-256 都必须绑定当前冻结配置。
- 复审还发现总检表把“首次价值时间”从 PRD 的“安装与模型配置完成后”改成了“开始安装/配置”。现在总检表逐项保留 PRD §11.1 五个目标和验证方法；首次价值仅从安装与模型配置均完成的时刻开始计时。安装/配置耗时可单列观察，但不参与该指标。
- 角色与交接：artifact directory 是“只放当前可交付扩展的一格货架”，构建器与 gate 都点数；`ACCEPTANCE_GUIDE.md` 是“照 PRD 填写的验收表”，gate 逐项比对目标与验证方法。两者让总检不会因旧工件或换口径而得到错误结论。
- 验证：双 zip 临时 fixture 被“恰好一项”规则明确拒绝；旧的“开始安装/配置”计时 fixture 被 PRD 表格合同拒绝；当前唯一 `0.2.0` zip 的 deterministic double-build/hash 校验通过。全量 Swift 连续两遍各为 **339 executed / 338 passed / 1 allowed environment failure**（隔离 Keychain write status `100001`）；`pnpm check:web`、Debug/Release build、doctor（**88 PASS / 1 dirty WARN / 0 FAIL**）与静止 worktree preflight（**101 assertions PASS**）均通过。重新装箱和独立 gate 仍交主控执行。
- 最终只读复核曾捕获 source-manifest 正则多写一个反斜杠、会把合法 zip 误判为零项；已更正为精确的 `chromium\.zip` 匹配并以真实 0.2.0 路径与 `.zip.bak` 反例复验。随后再跑两遍全量 Swift、web check、Debug/Release build 和 preflight，结果不变。
- 修正后的最终独立复审 **PASS**：active 目录唯一工件、生产/独立 gate 的路径/version/hash 绑定、失败非 INTERNAL 语义，以及五项 PRD 指标表均确认闭合。剩余动作仅是主控从当前 worktree 重新装箱和执行完整独立 gate。

### 任务 047：Syc 总检修复批次一/二（容量切片：Brave 独立目标）

- 现场只读证据：`~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts` 在 Syc 本机存在；因此原先把 Brave 映射到 Chrome 目录的口径错误，不能继续作为兼容假设。
- 已完成的交接：`BrowserSupportInstaller` 的 receipt/backup/journal target 从旧的共享目标拆为 `chrome`、`brave`、`edge`；Brave 固定写入自己的 `BraveSoftware/Brave-Browser/NativeMessagingHosts`。release policy、preflight receipt/target evaluator、clean-room transaction role、开发安装/卸载脚本、App 提示、隔离 HOME 测试和总检指南同步为三独立目录。
- 自动证据：`BrowserSupportInstallerTests` **27/27 PASS**，其中 Chrome 安装后 Brave 仍为未安装，随后 Brave 独立安装且 receipt 有两个独立 entry；`pnpm native-host:release:preflight:check` **101 assertions PASS**；`bash scripts/native-host/check-dev.sh` PASS，失败注入的临时文件仅在隔离 Brave 目录。
- 本轮按容量边界暂停，未开始的清单：验证页拒绝/X 噪音过滤、Markdown 富文本与纯文本切换、标题/预设回显、run 元数据即时刷新、URL/图标、翻译自动标签、安装后引导、生成与数据页 Form 重排，以及整批全量验证/冻结。没有以当前局部结果宣称 Loop 9 总检修复完成。

### 任务 048：Syc 总检修复批次（输入可信性、生成元数据与展示层）

- 当前状态：**PARTIAL；已完成输入可信性、标题兜底、Markdown 展示、URL 动作、翻译自动标签与运行元数据刷新；图标包、安装后引导和 Settings Form 重排尚未完成。**
- 场景 → 角色与交接：手动链接先交给 `ManualLinkCaptureService` 提取文本，再由 `VerificationPagePolicy` 和 `XTrailingCounterNoiseFilter` 判定是否可入库；持久化 `CapturedDocument` 在同一边界补标题；历史详情把保存的文本交给 `MarkdownPresentation`，只负责展示、不改变导出原文。生成完成时 `ModelRunOrchestrator` 先提交 Run，再把 taskID 交给 `HistoryViewModel` 的既有代际刷新机制；自动标签则是独立的 fail-open 后续交接。像快递分拣：危险件在入库门口退回，标签与货物分开贴，货架展示不会改写仓库原单。
- 本次新名词：验证页特征表（L2）、Markdown 展示层（L3）、运行元数据事件（L3）、fail-open 自动标签（L2）。它们分别防止反爬页面污染历史、避免原始 HTML 出现在界面、让已完成 Run 不必切换记录也能更新字段，以及保证标签失败不影响已保存结果。
- 已交付：`captcha`/`verify` 路径段与“环境异常 + 完成验证后即可继续访问”的高置信组合以可维护常量拒绝，固定文案不泄漏网页内容；X/Twitter 只去除末尾至少六个单字符数字节点，正常文章数字不受影响；空标题以 host 与最多两段路径兜底；HTML 映射失败时只显示“[已省略 HTML 片段]”，远程图片不加载，GitHub 已缓存本地图片仍单独内联；详情 URL 通过既有 PublicWeb URL 语法门禁后才打开默认浏览器，且可复制；总结和翻译都走同一模型/上限的自动标签管线。
- 过程证据：`ManualLinkCaptureTests` **13/13 PASS**；`ModelRunOrchestratorTests`（含 Persistent）**29/29 PASS**；`HistoryContentViewTests` **10/10 PASS**。首次全量 Swift 发现集成 fixture 仍断言翻译不打标，已更新为新产品合同；随后 SwiftPM `.build` 被 PID 69012 连续两次占用，按任务停止条件没有清理、终止或重试第三次。
- 可选跟做（5–10 分钟）：在详情中观察同一段 Markdown 的“查看纯文本”切换；可核对 HTML 片段是否只显示固定占位。此观察不是工程继续的前置条件。

### 任务 048 追加：平台资产、浏览器引导与 Settings Form

- 平台图标交接：`PlatformIconCatalog` 以 host 映射 `x.com/twitter.com`、微信、GitHub、知乎、B 站、YouTube、Reddit、Medium 到 `apps/desktop/Assets/PlatformIcons` 的本地 SVG；列表先读取该包，长尾网站才交给既有本地 favicon 缓存。GitHub 使用内置 mark，渲染路径不引入 `AsyncImage` 或远程请求。
- 装箱交接：release unit 把 8 个图标作为精确 `Contents/Resources/PlatformIcons` 资源集复制，并逐个核验 source/embedded hash；local-test readonly verifier 还把图标 hash 表绑定进 unit。这样“图标文件在源码里”与“图标实际进入候选包”是同一条可失败合同。
- 浏览器引导：安装或修复成功会显示打开对应浏览器、在 Finder 显示 extension 文件与开发者模式加载三步；卸载与恢复也给固定结果反馈。ViewModel 在动作入口成功后才发布 result，仍保留原有 install/repair/uninstall/restore guard 与隔离 HOME 测试边界。
- 设置页面：生成与数据 tab 使用 grouped Form、LabeledContent 对齐控件，数据去向成为正式卡片；模型与发送目的地的内容边界不变。
- 验证：定向 Swift 组首次发现旧测试仍断言 GitHub SF Symbol，更新为内置图标优先合同后通过。随后全量第一遍完成；第二遍被 SwiftPM PID 71337 占锁，连续两次无侵入启动均未取得锁，按停止条件未继续 web/build/doctor/preflight。

### 任务 048 追加：新增 manifest 键与独立 gate

- 教训：给 r4a 的 App facts 新增 `platformIcons` 后，r4b 的 `verify_app_bundle`、local-test unit/BUILD_MANIFEST 生成与独立 checker 必须同一轮接线。checker 读取任何嵌套事实时先走 `required_key`，缺失要报“哪个对象缺哪个必填键”的明确 fail-closed 信息，绝不能让 `KeyError` 落入 exit 70 INTERNAL。
- 修复：r4b verifier 现调用 r4a 的 `verify_platform_icons` 并写入 App facts；新 unit 会绑定该字段。对已封箱、字段诞生前的 audit，不修改其 sealed unit，而是由独立 gate 对 mounted App 与 source 重新逐项计算八个图标 hash；mounted App facts 本身缺键仍明确 FAIL。
- 验证边界：对 `/private/tmp/linkdigest-r4b-local-test.loop9-fix-20260718` 的两次独立 gate 均在 readonly DMG attach 的“attach state cannot be bound to one exact DMG/mount device”处停止，尚未抵达平台图标断言；保留两个 review root 现场，未改 audit、未 detach/清理历史挂载、未执行后置 Swift 回归。

### 任务 048 追加：封箱 App 与 source archive 必须同证

- 后续 gate 到达图标检查后证明：audit 的 sealed App `Contents/Resources/PlatformIcons` 八项均存在、目录与文件权限正确；但候选 source archive 内的 `apps/desktop/Assets/PlatformIcons` 缺失。这不是 checker 路径误判，而是“二进制装入了资产、可复现 source archive 没有该资产”的候选不一致。
- 处理：`verify_platform_icons` 现在分别报告 `embedded ... is missing/unsafe` 与 `source ... is missing/unsafe`。真实 audit 的定向调用得到 exit 2、`source platform icon directory is missing`；不再把真实封箱缺项概括成 unavailable，更不会用当前 worktree 资产覆盖或修补 sealed archive。
- 相关回归：`local_test_release.py check-config` PASS，冻结 r4a hash 同步为 `147f1f469d99d9103e141f7ec4e154c2ef95599583232cad6e9b533e8b75670e`。因为 worktree 已更新，需主控重新装箱后再运行完整独立 gate；这不是可直接放行旧 audit 的情形。

### 任务 048 追加：展示投影与三浏览器脚本合同复审

- 场景 → 角色与交接：持久化正文像仓库原单，`MarkdownPresentation` 像面向用户的陈列标签；纯文本和富文本都必须从同一份已净化标签生成，不能让纯文本切换绕过陈列规则而露出 HTML。安装脚本像三个独立投递柜：Chrome、Brave、Edge 各有一把钥匙和一张 receipt 条目，事务层核对“申请了哪几个柜子”与“实际登记了哪几个角色”完全相等。
- 新名词：展示投影（L3）、角色集合合同（L3）、前后状态断言（L2）。展示投影不改原单、只为 UI 生成安全副本；角色集合合同阻止两个浏览器被静默合并；前后状态断言比较 CLI 前后文件树，能区分本次副作用与共享工作树的既有文件。
- 已交付：纯文本改走 `plainTextPresentation`，与富文本同样不显示原始 HTML；Chrome、Brave、Edge 在 stable host、transaction receipt、clean-room 断言和 release target probe 中均为独立路径/角色。卸载和实现文档同步，并把旧 Brave→Chrome 说明显式标为被 2026-07-18 决策取代。
- 过程证据：Markdown 执行测试 **1/1 PASS**；全量 Swift **342/343**，唯一允许的环境失败是隔离 Keychain status `100001`；web check、doctor（88/1/0）与 preflight（101 assertions）通过。transaction clean-room 在三角色矩阵完成后，两次都被共享 worktree 指纹门禁中止；没有删除、重置或放宽该门禁。

### 任务 048 追加：release target probe 的精确 token 合同

- 场景 → 角色与交接：release target probe 像装箱前的点名册；“一共六人”不足以证明到场的是正确六人。`release_unit.py` 现在保管固定顺序的六个 token，r4a/r4b checker 各自把 probe 返回的名单逐项与之对照。
- 新名词：精确 token 合同（L3）。它要求名字、数量和顺序同时匹配；若只检查数量，Chrome/Brave 合并后的旧 token 仍可能伪装成一个合格的六项列表。
- 证据：六 token 正例通过，少 Brave 的反例明确失败；冻结哈希配置检查和 doctor（88/1/0）通过。历史 release 目录中的旧候选和执行日志按不可改边界保留，活动源码不再出现旧共享 token。

### 任务 048 追加：引号感知的 HTML 展示扫描

- 场景 → 角色与交接：HTML 属性像带引号的快递备注，备注中可出现 `>`；展示层必须等引号关闭后才判断标签结束。`MarkdownPresentation` 现在先把完整 token 交给安全映射表，无法完整交接的 token 连同其余截断文本直接交给固定占位，原始快递单仍只留在导出路径。
- 新名词：引号感知扫描（L3）、截断降级（L3）。前者在单遍扫描中跟踪单双引号，避免把属性内容误拆；后者让未闭合标签从起点到文本末尾都不进入 UI，而不是留下半截属性。
- 证据：属性内 `>`、多行属性、截断标签三类用例均在富/纯两态断言 tag/attribute sentinel 不可见；`MarkdownPresentationTests` **4/4 PASS**，全量 Swift **345/346**，唯一允许环境失败为隔离 Keychain status `100001`。

## 任务 049：浏览器来源识别、X 帖文交接与日用构建覆盖

- 日期：2026-07-19
- 当前状态：**工程与日用部署完成。** 本轮只补全 Capture 合同、扩展提取与日用构建覆盖；不安装浏览器 manifest、不读取 Cookie/Profile/Keychain、不创建 DMG 或发布候选。
- 场景 → 角色与交接：用户在浏览器主动发送当前页时，`platform.ts` 像发件处的分拣员，按 URL 把 `wechat`、`x`、`github` 或 `generic` 交给 `background.ts`；它随同正文写进版本化 Capture JSON。Swift 的内嵌 schema 像收货规则，只有同步后才接受 `github`；X 的 status 页由提取器把已渲染帖文正文交成标题和正文根，避免把浏览器页签 chrome 当作内容。最后 `build-and-deploy-local.py` 在 `/private/tmp` 验证完整 App/Host/扩展后，才原子替换两个明确的日用目录。
- 本次新名词：来源平台（L3）、原子本机部署（L3）。来源平台是采集时确定的事实，不是模型猜测；原子部署意味着任一构建或验证失败时原 App/扩展不变。两者均已进入 `docs/GLOSSARY.md`。
- 被证据修正的一点：根合同增加 `github` 后，首次 Swift 合同测试仍正确拒绝它；原因是 App resource bundle 内的 schema 副本尚未同步。运行既有 `scripts/sync-contracts.sh` 后，桌面端与扩展恢复为同一合同，而不是放宽桌面校验。
- 工程验证：扩展 TypeScript typecheck 通过、Vitest **20/20 PASS**；Swift `ContractTests` **11/11 PASS**（含 GitHub 平台接受用例）；`git diff --check` 通过。部署后已核对 `/Users/song/Applications/LinkDigest.app` 版本为 **0.2.0**、`codesign --verify --deep --strict` 通过，扩展 manifest 为 **0.2.0** 且含 `background.js`。
- 来源默认标签：新的微信 / X / GitHub Capture 在同一 SQLite 入库事务中，分别获得 `公众号` / `X` / `GitHub`；这一步发生在模型请求之前，模型失败或不配置模型也不影响来源筛选。重放同一 delivery 只复用原 Task，不会重复创建标签。领域与 SQLite 定向测试 **11/11 PASS**。
- 失败与恢复：首次部署因 macOS `/tmp` 到 `/private/tmp` 的 symlink 被 Host 打包器拒绝，发生在任何替换前；脚本改用真实 `/private/tmp` 后成功。后续若构建/签名/合同校验失败，脚本不会交换日用目录；可重新运行 `python3 scripts/build-and-deploy-local.py --replace`。不应通过删除 App、清空浏览器 Profile 或放宽 Host 路径门禁来恢复。
- 可选跟做（5 分钟）：在 Brave 扩展管理页对 `LinkDigest-extension-0.2.0` 点击“重新加载”，然后打开一条已登录可见的 X 帖文并主动发送；History 应保存帖文正文标题而不是浏览器页签标题。这是共同观察入口，不是任务关闭前置条件。

### 任务 049 追加：扩展发送时自动拉起桌面 App

- 日期：2026-07-19
- 场景 → 角色与交接：用户点扩展「发送」时，Chrome 会起 `LinkDigestNativeHost`，但以前不会起 GUI。Host 现在像门铃：先敲 `/tmp/linkdigest-<uid>.sock`；没人应门就只打开**同包** `LinkDigest.app`，等 socket 就绪再递交 Capture JSON。扩展超时改为 20s，给冷启动留预算。
- 新名词：冷启动转发（L3）。Host 只负责打开同包 App + 等 socket，不入库、不跑模型；禁用可用 `LINKDIGEST_DISABLE_AUTO_LAUNCH=1`。
- 证据：Transport 定位/连通测试 **7/7 PASS**；日用路径已 `build-and-deploy-local.py --replace` 覆盖。
- 可选跟做：完全退出 LinkDigest 后，在 Brave 重载扩展并对任意可捕获页点发送，应自动出现 App 并入库。

### 任务 049 追加：X 长文章文图树序交接

- 日期：2026-07-19
- 当前状态：**工程与日用扩展部署完成；等待 Syc 在 Brave 重新加载后重抓目标帖做用户侧验收。**
- 场景 → 角色与交接：目标 X status 实际是长文章，不提供普通帖的 `tweetText`，而把标题、正文和八张配图交错放在 `twitterArticleReadView`。提取器现在只在这个最小阅读容器内单次递归：文字进入当前段落缓冲，遇到 `tweetPhoto`/`videoPlayer` 就先交出文字再原位交出媒体；metadata 仍单独进入 YAML frontmatter。像照着书页从上到下抄写，不能先抄完整本字再统一贴图。
- 被现场证据修正的一点：原先以为目标会暴露 `tweetText → tweetPhoto` 语义节点列表；真实 Brave DOM 中该主帖为 `article[data-testid='tweet']`，正文约 3,124 字，但语义列表只有八个 `tweetPhoto`，没有 `tweetText`。旧“清洗全文后前插、再追加全部图片”因此必然打平顺序；不能简单删除兜底，否则会重新丢失长文。
- 工程实现：`collectXStatusBlocksInOrder` 与 `extractPageInIsolatedWorld` 都新增 `twitterArticleReadView` 树序遍历；普通 X 帖仍走单次 `tweetText/tweetPhoto/videoPlayer` 文档序列表。媒体按 media id 去重，更大尺寸只替换第一次出现位置上的 URL；标题继续使用短 hook；头像、作者壳和互动 chrome 不进入正文。`background.ts` 未修改，富化仍只处理纯图无字或缩短标题，不重排 body。
- 自动证据：新增“封面图 → 标题/导语 → 图 → 章节文字 → 图 → 后续文字”长文章夹具，并断言可测路径与真实隔离世界注入路径输出完全一致；既有短标题、正文+配图、头像过滤、作者 frontmatter、无作者壳和 media id 去重回归继续通过。扩展 `typecheck` PASS；Vitest **30/30 PASS**；WXT Chrome MV3 production build PASS；`git diff --check` PASS。
- 失败与恢复：若 X 将来移除 `twitterArticleReadView`，普通帖语义路径仍保留；两类语义都缺失时才进入保守清洗兜底。旧 History 不会回写，必须重新发送生成新条目。若新条目仍是“全文后全图”，先在 DevTools 核对主帖阅读容器自身是否已经是该顺序，再区分平台 DOM 变化与提取回归；不要用 History UI 重排掩盖 capture markdown 的错误。
- 可选跟做（5 分钟）：在 `brave://extensions` 对 `/Users/song/Applications/LinkDigest-extension-0.2.0` 重新加载，打开 `https://x.com/Zesee/status/2077723280534851786` 再发送；新 History 应为短标题，正文从封面图开始并在“一、整条链路怎么分工”“三、素材准备”等章节间保留原位配图。该观察不是工程代码关闭的前置条件。

### 任务 049 追加：X 长文章富文本语义恢复

- 日期：2026-07-19
- 当前状态：**工程与日用扩展部署完成；等待 Brave 重载后重抓做用户侧验收。**
- 用户反馈修正：文图顺序修复后，章节标题仍显示为普通段落，代码块语言栏 `markdown` 混入正文，目录树被当作普通文本换行；说明“顺序正确”不等于“格式语义正确”。问题仍在 capture markdown 提取层，不由 History UI 假重排。
- 现场 DOM 证据：目标页章节使用真实 `<h2 class="longform-header-two">`；代码区使用稳定 `[data-testid='markdown-code-block']`，内部为 `<pre><code class="language-markdown">`，其 `textContent` 完整保留目录树换行和缩进；页面中的 `markdown` 是语言栏，不是正文。目标正文没有语义 `ul/ol/li`，清单横线已存在于可复制文本。
- 工程实现：同一 `twitterArticleReadView` 树序遍历现在把文章标题映射为 `#`、`h1...h6` 映射为对应 Markdown 标题、代码区映射为带语言的 fenced code block，并兼容 bare `pre`、blockquote 和语义列表。代码围栏长度会避开正文已有反引号；最终 X body 不再使用会压缩连续空格的通用归一化，代码缩进保持原样。媒体仍在遍历到的位置立即输出。
- 被测试修正的一点：首次加入代码围栏后，测试发现最终 `normalizeMarkdownWhitespace` 仍把 `│   ├──` 压成 `│ ├──`；因此 X block 拼接改为只统一 CRLF 并裁剪首尾，不再压缩 fenced code 内部空格。
- 自动证据：长文章夹具联合断言 `#` 文章标题、`##` 章节、` ```markdown ` 围栏、目录树原始缩进、语言栏不作为独立正文、文图相对位置，以及模块路径与隔离世界注入路径逐字一致。扩展 `typecheck` PASS；Vitest **30/30 PASS**；WXT MV3 production build PASS；构建产物已 ditto 到 `/Users/song/Applications/LinkDigest-extension-0.2.0` 并逐文件比对主要入口一致。
- 失败与恢复：旧 History 不回写，必须重抓。若新条目标题或代码块仍扁平，先确认 Brave 已重新加载当前目录；再检查新 capture markdown 是否包含 `## 四、怎么放进 Codex 执行` 和 ` ```markdown `。若 capture 已正确而 UI 仍扁平，才转入 MarkdownPresentation 显示层排查。

### 任务 049 追加：APP 块级富文本渲染器

- 日期：2026-07-19
- 当前状态：**工程、全量验证与日用 App 部署完成；等待重新启动 App 做用户侧视觉验收。**
- 用户反馈修正：扩展已输出章节语义后，History 中标题与列表能显示层级，但 `markdown` 语言栏、目录树和 ` ```text ` 仍落入普通段落。真实根因是 `MarkdownPresentation.Block` 只有 heading/paragraph/list/quote，没有 code 类型；解析器因此调用 `joinParagraphLines` 把代码行拼平。继续重载扩展不会修复这个 APP 展示缺口。
- 角色与交接：SQLite 继续原样保存 capture markdown；`MarkdownPresentation` 负责把 Markdown 解析成块；`MarkdownContentView` 负责为每种块选择 SwiftUI 视图。新增 code block 像给排版员补上“代码框”工种：语言栏、原始换行、缩进、等宽字体、横向滚动、文本选择和复制按钮都只发生在展示投影，不回写历史正文或导出原文。
- 工程实现：Block 新增 `code(language:content:)` 与 `orderedList`；解析器支持反引号/波浪线 fenced code、语言名、未闭合围栏的保守代码块、数字有序列表，以及旧 X capture 的“单独语言栏 + 明显目录树”兼容识别。现有标题、普通/有序/无序列表、引用、粗体、斜体、行内代码和安全外链继续保留。代码卡使用独立背景、边框、monospaced 字体和复制动作。
- 被测试修正的两点：第一次编译暴露 SwiftUI `ForEach` 与 GRDB `Array(cursor)` 的类型推断冲突，最终把块 switch 收敛到独立 `@ViewBuilder markdownBlock`；第一次视图源码断言放在只读取 `HistoryContentView.swift` 的测试中，已移动到真正拥有代码卡的 `MarkdownPresentationTests`，没有为了绿灯伪造路径。
- 自动证据：`MarkdownPresentationTests` **9/9 PASS**，覆盖围栏语言、目录树缩进、围栏移除、后续段落、旧 X 语言栏修复、有序列表和代码卡结构；`HistoryContentViewTests` **13/13 PASS**；Swift 全量 **367/367 PASS**。`build-and-deploy-local.py --replace` 完成 Release build、ad-hoc 签名、结构验证与原子替换；`codesign --verify --deep --strict` PASS，部署后二进制包含 `history-content-code-block`，唯一 App 版本为 0.2.0。
- 失败与恢复：正在运行的旧进程不会因磁盘 App 被替换而热更新；必须完全退出 LinkDigest 后重新打开。旧 14:36 记录中的“markdown + 目录树”可由展示兼容直接恢复；新捕获则优先使用规范 fenced code。若重启后仍不显示代码卡，再检查该记录是否处于“纯文本查看正文”模式，而不是继续改扩展。

## 任务 050：乳白磨砂玻璃 App 图标

- 日期：2026-07-19
- 当前状态：**项目图标资产、唯一日用 App 定向部署与 Finder 系统解析验收完成；等待 LinkDigest 下次完全退出并重新打开后观察正在运行的 Dock 项。** 本轮没有重建或替换浏览器扩展，没有修改冻结候选的 manifest/hash，也没有提交、推送或发布。
- 场景 → 角色与交接：`appicon-1024.png` 是所有尺寸的源图母版；图层合成把现有黑色丝带与乳白玻璃底交成一张保留透明边界的 PNG；`iconutil` 再把 16–1024 px 的十个槽位装入 `AppIcon.icns`；App bundle 只接收新的 ICNS 并重新 ad-hoc 签名。像先完成一张高分辨率证件照，再冲洗不同尺寸，最后换进产品外箱，不能只换母版而让 Finder 继续读旧相册。
- 本次新名词：源图（L2）、ICNS（L2）、光学缩放（L2）。源图是所有图标尺寸的母版；ICNS 是 macOS 使用的多尺寸图标包；光学缩放按视觉重量而非机械坐标判断标志是否显得过大或过小。项目已有“App Bundle Icon”词条，本轮一次性设计词不再扩大 `docs/GLOSSARY.md`。
- 设计与工具决策：先按 `apple-design` 的材质原则确定“克制边缘高光、内部雾化、柔和投影、高对比中心标志”，再尝试图片编辑服务。StepFun 返回“无有效 Step Plan 图片订阅”，Hermes Web UI `127.0.0.1:8648` 未启动；两条路线都在写项目文件前失败。经 Syc 选择后改用 ImageMagick 确定性合成，保留原丝带像素，用灰度遮罩分离标志，并重建乳白灰蓝渐变、双层高光和轻阴影。这样不依赖模型猜测标志形状，代价是玻璃纹理比生成式方案更克制。
- 迭代修正：临时第 1 版更像白瓷面板；第 2 版的透明渐变产生明显灰色曲面；第 3 版的模糊高光越过透明边界。三版都没有写入项目。第 4 版把高光/暗部裁进原 tile alpha，32/64 px 下仍可识别后才成为正式母版。
- 自动证据：正式 PNG 为 1024×1024、PNG、含 alpha；新 ICNS 可被 `iconutil` 完整反解，反解后的 `icon_512x512@2x.png` 与母版像素差为 **0**。macOS `NSWorkspace.shared.icon(forFile:)` 已从部署后的 App 成功解析出含透明通道的新玻璃图标，证明 Finder 使用的系统入口能识别该资源；32/64 px 缩略图仍可辨认丝带。新母版 SHA-256 为 `6e654303096be9d8975a22ad8de32112bea650bb3d90932d9c70f0eae418ac1c`，新 ICNS 为 `535ec83b13d97108b5f0047c699cdb86c9440e7431a16e6ad90cec7d4434b2fe`；旧 ICNS 为 `3537cae0c60ea78992f729f47c2d3ac8b77d7ae880982f172de3fe9f9d298775`。
- 定向部署：没有运行会同时覆盖扩展的 `build-and-deploy-local.py`。现有 `/Users/song/Applications/LinkDigest.app` 先复制到暂存目录，只替换 `Contents/Resources/AppIcon.icns`，以 `com.syc.linkdigest` 重新 ad-hoc 签名并通过 `codesign --verify --deep --strict` 后再交换；live App 图标 hash 与项目 ICNS 一致，扩展目录未动。首次交换命令因 Python 换行转义在真正交换前报错；复用已验证暂存包后以可立即回滚的两段交换完成，没有留下半更新 App。
- 恢复与边界：旧母版和旧 ICNS 的会话级恢复材料位于 OpenCode 临时目录，macOS 清理临时文件前可重装旧图标；因为 `apps/desktop/Assets/` 当前尚未进入 Git，不能把 `git restore` 当作长期回滚。`config/local-test-release.json` 仍冻结旧候选的图标 hash，下一次正式装箱必须重新生成候选证据，不能手改旧 sealed candidate 来冒充一致。当前 App 进程仍在运行，Dock 可能缓存启动时图标；下一次正常退出并重开后观察即可，不需要清空 Dock/Finder 缓存。
- 可选跟做（2 分钟）：完全退出 LinkDigest 后从 `/Users/song/Applications/LinkDigest.app` 重新打开，分别观察 Finder 大图和 Dock 小图：外层应是乳白双层玻璃边，中央黑色丝带在小尺寸仍清晰。若仍显示旧图，先等待 Finder 刷新或移除后重新拖入 Dock，不要删除 App 或重置系统图标缓存。

## 任务 051：抖音本机视频“下载到本地”

- 日期：2026-07-19
- 当前状态：**工程实现与定向自动验证完成；尚未把本轮源码部署到日用 App，也未在真实保存面板中做人工点击验收。** 本轮只补 History 播放器旁的本机导出，不重新请求抖音远程 URL，不增加下载器、转写、合同或模型链路。
- 场景 → 角色与交接：用户在已有本机视频的 History 详情点击“下载到本地”；`HistoryVideoPlayerCard` 先把缓存 `fileURL` 交给 macOS `NSSavePanel`，由用户选择文件名和目录；`LocalMediaExport` 再把同一个本机 MP4/MOV 复制到目标位置。播放器卡只有在文件 URL、扩展名和文件存在性都通过时才出现；取消保存面板不产生错误，成功显示短暂“已保存”，失败显示中文恢复提示。
- 工作流：`HistoryViewModel.localMediaFileURL`（已有文件）→ View 再校验本机文件与 MP4/MOV → `NSSavePanel`（用户选择目标）→ 目标目录内临时副本 → 已有目标用原子替换、空目标用同目录移动 → 成功/失败反馈。源容器类型保持不变：MP4 只能保存为 `.mp4`，MOV 只能保存为 `.mov`；这是字节复制，不把改后缀冒充转码。
- 工具协同与技术选择：SwiftUI 保管按钮和反馈状态，AppKit 的 `NSSavePanel` 提供原生目录/文件名选择，`FileManager` 只做本机 copy、replace/move。没有加入 `URLSession`、`downloadTask` 或第三方依赖。沿用 `GLOSSARY.md` 已有的 Atomic Publish / 原子发布概念；`NSSavePanel` 是本任务一次性 macOS 工具名，仅讲到 L1，不新增词条。
- 实施检查点与证据：源码断言锁定按钮文案、`history-video-save-local` 标识、`NSSavePanel`、本机 `copyItem`、原子 `replaceItemAt`，并明确排除远程会话和下载任务；真实临时目录测试覆盖“已有目标内容被完整替换、源文件保持不变、无临时残留”，另覆盖远程 URL、WebM 和 MOV→MP4 假改格式拒绝。首次定向 `HistoryContentViewTests` 为 **17/17 PASS**；容器同后缀门禁加入后的最终结果见本任务交接报告。
- 失败与恢复：用户取消时不写文件也不提示失败；复制失败时，原缓存文件不动，已有目标不会被预先删除，用户可改选有权限且空间足够的目录后重试。若缓存文件已被外部移走，卡片初次渲染不会出现；若它在卡片显示后才消失，点击会被再次校验并显示中文失败提示。不要通过重新请求签名 URL 或删除目标文件来“恢复”。
- 可选跟做（5 分钟）：在后续由主控部署并打开 App 后，进入一条已缓存的抖音 History，点击播放器旁“下载到本地”，先取消一次确认无报错，再保存到临时目录并用 Finder 播放副本；也可选择一个已有同名副本，确认替换成功且 History 内原视频仍能播放。这是人工观察入口，不是本轮自动工程验收的前置条件。

### 任务 051 复审修正：三处异步所有权 fail-closed

- 删除后媒体清理：Task 已删除不等于共享内容一定无人引用。`HistoryViewModel` 现在只有在 repository 引用查询明确成功后才把布尔结果交给 `LocalMediaStore`；查询抛错时保留文件，等待以后有可靠证据再清理。真实临时文件测试让 repository 在 `isMediaContentReferenced` 抛错，确认 Task 删除完成但共享 MP4 仍存在。
- 抖音注入一致性：第一次注入锁定 A 的 `awemeId`、正文和 canonical URL；第二次注入返回 media 后，后台会同时检查其 `awemeId`（若有）和 canonical URL 可解析出的 ID，所有已返回身份都必须等于 A。若用户期间切换到 B，B 的 title/author/description/video URL 整体不附到 A，A 的单条文本和 URL仍保留；不读取 Cookie 数据库、不扩大页面逆向。
- 保存反馈所有权：每次成功保存会先取消旧的延时清除任务，再把新任务保存在卡片状态中；旧任务被取消后不能清除新一轮“已保存”。卡片离开视图时也取消并释放任务，避免离开后继续改 UI 状态。
- 定向证据：扩展 Vitest **44/44 PASS**（含 A/B 错配与 A/A 匹配），`tsc` PASS；Swift `HistoryViewModelTests + HistoryContentViewTests` **37/37 PASS**（含引用查询失败保留共享文件、反馈任务取消所有权）。本轮未部署日用 App、未提交、未新增 GLOSSARY 词条。

### 任务 051 追加：AVKit 运行时链接修复

- 真实视频崩溃：Syc 已成功抓取一条抖音单条内容并把约 67 MB 视频保存到本机；重启 Debug App、History 创建 SwiftUI `VideoPlayer` 时进程崩溃，错误为 `failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'`，调用栈位于 `_AVKit_SwiftUI`。这证明本机视频与入库链路已经交接成功，故障发生在播放器视图初始化阶段。
- 根因与修复：崩溃前的 `LinkDigestApp` 成品依赖包含 AVFoundation、AppKit、SwiftUI 和 `_AVKit_SwiftUI`，但没有 `AVKit.framework`；`VideoPlayerView` 的 AppKit 父类因此无法在运行时解析。`Package.swift` 现在只为 `LinkDigestApp` executable target 增加 `linkerSettings: [.linkedFramework("AVKit")]`，不修改播放器代码、不扩大到扩展、下载或模型链路。
- 恢复与证据：源码回归锁定 App target 的显式 AVKit 链接；现有 Release 成品检查也用 `otool -L` 要求出现精确的 `/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit`。`HistoryContentViewTests` **19/19 PASS**，Debug 与 Release `LinkDigestApp` 均构建通过，两份成品的 `otool -L` 都出现该精确 AVKit 路径，Release test-seam 成品检查 PASS。本轮不部署日用 App、不修改冻结候选或 hash、不新增 GLOSSARY 词条；若构建失败，删除本次单一 linker setting 即可回到修复前配置，但真实视频播放崩溃也会随之恢复。

## 任务 052：Loop V-2 本机中文视频转写与真实比例播放

- 日期：2026-07-19
- 当前状态：**最小工程闭环与定向自动验证完成；尚未部署日用 App，也没有完成 Loop V-2 的三条真实中文样本质量门和断网人工门，因此不得宣称 V-2/V-3 验收完成。**
- 场景 → 角色与交接：用户打开已保存的视频 History；`AVAssetTrack` 先把 Natural Size 与 Preferred Transform 交给 `VideoDisplayGeometry`，播放器据此保持真实 Aspect Ratio。用户点「转写」后，`HistoryViewModel` 只检查 Apple 中文离线模型；需要资产时先停在明确确认，第二次点「下载并转写」才允许 `AssetInventory` 安装。`AppleSpeechVideoTranscriber` 用 AVFoundation 把本机 MP4/MOV 音轨导出到临时 M4A，再交给 SpeechAnalyzer；Partial Result 实时回到卡片，final 文本由 History service 作为同一 canonical URL 的新 ContentSnapshot 入库，最后刷新详情。
- 角色与交接物：视频轨道只交显示尺寸/方向，不处理正文；SwiftUI 视频卡只显示作者、时长、`已保存到本机 · 大小`、转写/取消/重试和「另存一份」，且这些事实与操作都位于视频上方；转写 adapter 只交阶段事件与文字，不接触 SQLite；History repository 只更新 `media_assets.transcription_status` 并保存 `.localTranscription` / `speech_analyzer_local` 快照；现有总结、翻译和导出继续读取 `snapshots.last`，无需新增 wire contract。
- 本次新名词：Natural Size（L3）是文件轨道原始像素尺寸；Preferred Transform（随 Natural Size 一起讲，不单独扩词条）像相机附带的旋转说明；Aspect Ratio（L3）是不可被拉伸的相框比例；On-device Recognition（L3）表示音频不上传；Partial Result（L3）是识别中的可更新草稿，只有 final 才入库。
- 技术选择：视频比例取 `naturalSize + preferredTransform`，加载完成前显示“正在读取视频尺寸”占位，不假装固定 16:9；最大可视高度限制为 520pt，但使用 `.fit` 保持原比例。音轨使用系统 `AVAssetExportSession` 的 Apple M4A preset，不使用 ffmpeg；识别使用 macOS 26 SpeechAnalyzer，Package 仍保持 macOS 15，通过 `#available(macOS 26.0, *)` 给旧系统人话失败。没有新增第三方依赖、云 Provider 或合同字段。
- 失败与恢复：只读历史会直接解释“不能保存转写结果”；旧系统、Speech 不可用、无 zh_CN、模型准备失败、文件缺失、无音轨、提取失败、识别失败和空文本都有独立中文消息。用户取消会取消 adapter 工作、删除临时音频并把媒体状态恢复为 `none`；失败标记 `failed`，重试会重新走状态机；成功才标记 `completed`。原视频始终不修改，另存失败也不会破坏媒体库副本。
- 自动证据：`LinkDigestApp` Debug 与 Release target 均构建通过；复审后的转写/视频/持久化定向测试 **57/57 PASS**，覆盖 2880×2160=4:3、90° 旋转竖屏、等比最大高度、父级与卡内信息/按钮顺序、无旧 220/360 固定播放器、显式模型二次确认且首次检查不安装、A/B 选择隔离、挂起下载与 typed cancel、volatile 替换/空撤销/final 覆盖、partial→final、原子 snapshot+media completed、事务回滚、latest snapshot 导出、失败→重试、read-only、无效本机文件和人话错误。最终 Swift 全量 **406/406 PASS**，`git diff --check` PASS。
- 现场 API 探针：macOS 26.5.2，`SpeechTranscriber.isAvailable=true`，supportedLocales 与 installedLocales 都含 `zh_CN`，progressive preset 的 installation request 可创建。任务输入记录的首个现场状态为 `supported`；本轮未调用 `downloadAndInstall` 的只读复核时状态已为 `installed`。这只证明 API/locale/资产可用，不证明中文转写质量。
- 可选跟做（10 分钟）：后续由主控部署后，打开同一条 2880×2160 视频，确认画面是 4:3 且无裁切；点「转写」观察模型确认（若系统已安装模型可能直接进入提取），转写中应看到实时文字，取消后可重试。该观察服务理解，不是关闭工程实现的前置作业。

### 任务 052 复审修正：选择所有权、渐进结果与原子完成

- 选择所有权：切换 History 选择时立即换掉转写 request ID、取消旧任务、关闭模型确认、清空 context/partial/UI state；旧 Task 的 durable 状态由独立 repository 清理恢复为 `none`，不会回写新选择的界面。测试覆盖 A 正在转写与 A 等待模型确认两种切 B 场景，B 都可立即开始且看不到 A partial。
- 取消语义：adapter 保留原始 `CancellationError`；ViewModel 同时把系统取消和 typed `.cancelled` 映射为 `media_assets.none + UI.cancelled`，不再误记 `failed`。测试覆盖挂起模型下载后取消、挂起 stream 取消和显式 typed cancel。
- 渐进结果：`TimedTranscriptionAccumulator` 按 CMTimeRange 管理 finalized/volatile；新 volatile 替换重叠草稿，空 volatile 撤销草稿，final 覆盖相交旧值。UI 可读 finalized+volatile，持久化只读取 finalized，避免重复、撤销文字入库或时间乱序。
- 原子完成：`completeMediaTranscription` 在一个 GRDB transaction 内校验 canonical/task、本机转写来源与 media，插入或复用 snapshot，更新最新 media 为 completed，再更新时间。中途故障注入与无 media 测试均证明不会留下“snapshot 已有但 status 未完成”的半提交。

## 任务 M0：本机转写终态一致性与独立完成证据

- 日期：2026-07-19
- 当前状态：**M0 工程实现、定向验收、Debug/Release 构建完成；全量测试在当前受限环境中有既有 Keychain、loopback listener、Unix socket 与磁盘容量探针失败。本轮未部署、打包、修改真实数据库或调用真实 Provider。**
- 用户场景：A 视频的本机转写刚完成时，用户切换到 B；A 必须保持 `completed`。如果转写正文恰好和原捕获正文相同，应复用已有快照，同时仍能证明它由哪种本机引擎、哪个 locale、何时完成。
- 角色与交接：`HistoryViewModel` 负责选择/UI 所有权，并为每次 request 生成单独 attempt token；`HistoryRepository` 是 durable 状态门卫，只接受当前 attempt 的 pending/running/none/failed/completion；`completeMediaTranscription` 接收 final 文档和最小完成证据；GRDB transaction 把 snapshot ID、append-only evidence 行、media `completed` 与 task 更新时间一次提交。失败时用户不会看到半完成状态，原媒体与已有历史保持不变。
- 工作流：Apple SpeechAnalyzer final 文本 → ViewModel 组装 attempt、locale=`zh_CN`、language=`zh` 的事实证据 → Repository 按 `(task_id, body_sha256)` 复用或插入 snapshot → 追加 `media_transcription_evidence` → 标记 media completed → 更新 task 时间。切换选择产生的 `none` cleanup 只匹配同 attempt 的 `pending/running`；旧 attempt 的任何迟到写入都是 no-op，真实缺 media 仍返回 `notFound`。读取时不改 snapshot 的 source/sequence，只把最新成功 evidence 指向的 snapshot 放到 projection 最后，统一成为详情、搜索、总结/翻译与导出的有效 latest。
- 工具协同：XCTest 的同步 barrier 把完成事务停在 `beforeTerminalCommit`，主线程此时切到 B，再放行并明确等待 cleanup 返回；GRDB fault injection 在 evidence 写入后抛错，验证 snapshot/evidence/completed 一起回滚；Migration 测试分别从空库直达 v4、从真实结构 v3 升到 v4，并用 v5 证明 future schema 仍只读。
- 本次核心名词（不新增 Glossary）：**状态门禁（L3）**像仓库保安同时核对取件码，只接受当前 attempt 的状态，位置在 repository SQL 条件；没有它，旧请求会覆盖新结果。**原子事务（L3）**像一张必须整单盖章的入库单，位置在 `completeMediaTranscription`；没有它会留下快照、证据或状态之一先成功的半记录。**转写证据（L3）**像不复印正文的质检标签，位置在 Migration004 新表；每次成功 attempt 独立保留 source/engine、nullable provider/model/locale/language、完成时间与关联 snapshot，没有它就无法区分多次转写。已有 Migration、On-device Recognition 与原子类词条足以承接，因此本轮不扩大 `GLOSSARY.md`。
- 两个根因：其一，串行 worker 只保证执行顺序，不保证旧 cleanup 的语义仍有效；完成事务提交后，无条件 `UPDATE ... SET none` 会倒写终态。其二，旧复用分支把“正文 hash 相同”错误等同于“既有 snapshot 必须也是 local_transcription”，所以原捕获正文与转写相同时抛 `invalidInput`，且没有独立位置保存转写事实。
- 红灯证据：实现前两条最小测试稳定失败——`completed → none` 实际变回 `none`；相同正文完成调用抛 `The history request is invalid.`。首次测试命令因 sandbox 禁止 `~/.cache/clang/ModuleCache` 写入没有进入逻辑，改用 `/private/tmp/linkdigest-m0-*` cache 后得到上述真实红灯。
- 绿灯证据：最终规定定向命令 `MediaTranscriptionPersistenceTests|HistoryViewModelTests` **36/36 PASS**；Migration **8/8 PASS**；`AppViewModelTests|HistoryExportRendererTests` **51/51 PASS**。覆盖 attempt 状态门禁、迟到 readiness failure、较旧 snapshot 的有效 latest 投影、summary/translate snapshot、Markdown export、两次成功 evidence 追加、旧 attempt 重放幂等和跨 task 外键拒绝。`LinkDigestApp` Debug 与 Release build 均 PASS。
- 全量测试边界：`swift test --disable-sandbox` 执行 **415** 项，**375 PASS / 40 环境性失败**；失败仍全部位于本轮未修改的环境依赖：1 个 LocalMediaStore 容量探针、1 个 Keychain、36 个禁止启动 loopback listener 的网络测试、2 个受限 Unix socket。M0、Migration、AppViewModel 与 Export 相关 suites 在同一环境中保持全绿，没有读取真实 Keychain、用户数据库或 Provider。
- 失败与恢复：若 v4 升级失败，`LocalDatabase` 关闭写连接并以 `migrationFailed` 只读打开，不继续写半结构。本轮尚未部署或触碰真实用户库，因此当前源码回滚可反向移除 Migration004 接线、证据类型/写入、状态条件和对应测试/日志；一旦未来真实库已升到 v4，旧 v3 二进制会按 future schema 只读，届时必须保留 v4 兼容或做新的向前修复，绝不能下调 `PRAGMA user_version`。不得修改已落地的 Migration001/002/003。本轮未执行 commit、push、部署或打包。
- 未完成边界：M1–M6 的 V2 合同、远程播放、TranscriptionTemp、云 ASR、PromptPreset、新平台、真实三样本质量门、断网人工门、日用 App 部署与 DMG 均未进入 M0。
- 可选跟做（5 分钟）：打开 barrier 测试，观察“停在提交前 → 切到 B → 放行 → 等 cleanup 返回 → A 仍 completed”五步；它用于理解 UI 所有权与 durable 状态门禁的分工，不是任务关闭前置条件。

## 任务 M1 首轮复审返修：原子页面快照、瞬态端口与 V2 provenance

- 日期：2026-07-20
- 当前状态：**7 条复审 finding 的最小工程修正与定向自动验收完成；未部署、未打包、未触碰真实用户数据库、Cookie/Profile、凭据或真实 Provider。M2–M6 与真实/人工门仍未完成。**
- 场景 → 角色与交接：抖音单条页的正文与媒体现在由同一次 `executeScript` 读取，避免用户在两次注入之间从 A 切到 B；扩展把同一快照组成 V2。`CaptureReceiver` 校验后立即拆成两份：`CapturedDocument` 只含允许入库的页面事实，`MediaDescriptor` 只留在 `CurrentCapture` 供当前进程下一步使用。`HistoryApplicationService` 与 `AcceptCaptureCommand` 只收到持久文档和整数合同版本，不再能观察临时播放地址或过期时间。
- 工作流与工具协同：V2 wire → 同次快照身份核对 → persistent document + transient descriptor 分流 → Repository 写页面与 `capture_contract_version=2` → UI 收到 transient descriptor。Migration005 只重建 `capture_deliveries` 的版本 CHECK 为 `{1,2}`，复制所有旧 V1 行并重建原索引；Migration001–004 hash 保持不变。fixture manifest 为每条 V2 fixture 声明 V2 schema，扩展/shared/Swift runner 都按声明选择验证器。
- 失败与恢复：多于 1000 个 `<video>` 时在读取 geometry 前 fail closed 为 `multiple_candidates/ambiguous`，并省略无法在 schema 上限内如实表达的 candidateCount；候选比较改用循环，避免大数组 spread 导致 RangeError。Migration005 失败沿用 `migrationFailed` 只读恢复，未来 v6 仍只读。若需撤回本轮，移除 Migration005 注册并回退本轮端口/测试即可；一旦真实库未来升到 v5，旧 v4 二进制会按 future schema 只读，不能下调 user_version。
- 自动证据：扩展定向 **13/13 PASS**、扩展全量 **52/52 PASS**、shared contract **11/11 PASS**、双方 TypeScript typecheck PASS；Swift 定向 **38/38 PASS**、完整 XCTest **432/432 PASS**，Release `LinkDigestApp` build PASS。SQLite/WAL/SHM、export 与 `media_assets` sentinel 扫描保持无泄漏，仓储 spy 遍历命令描述也看不到临时 URL；contract sync、generated validator 与 `git diff --check` 均 PASS。
- 本次名词：沿用已有 **CaptureEnvelopeV2、MediaDescriptor、Ephemeral Playback URL、Deterministic Media Selection、Migration、Fail Closed**，没有新增词条。
- 可选跟做（5 分钟）：看 `CaptureIngestService` 中同一 V2 如何在 commit 前只交文档/版本给 History、commit 后才把完整 descriptor 发布给 `CurrentCapture`；这是理解端口隔离的观察入口，不是关闭任务的前置条件。

### M0 Reviewer 返修：有效 latest、attempt ownership 与 append-only evidence

- Reviewer 红灯：S1=A、S2=B、final=A 时，详情/导出仍把 B 当 latest；旧 readiness failure 在 request guard 前写 `failed`，把新 attempt 的 completed 覆盖；v4 evidence 只有 `media_id` 主键与 Apple-only CHECK，无法保留两次成功。三条确定性测试分别出现 **4、1、4** 个断言失败。
- Finding 1：Repository projection 查询最新成功 evidence；若它指向较旧 snapshot，只移动投影数组位置，不修改数据库 sequence/source。History row 的 title/source/search、detail、summary/translate 和 export 因而共享同一有效 latest=A。
- Finding 2：attempt token 同时含 UUID 与 ViewModel 内单调时间；pending 以较新 token 建立 ownership，后续 running/none/failed/completion 都用同一 token 做 SQL 条件。ViewModel 在每个 durable 副作用前先核对 request ID，Repository 再把旧 token 写入变成 no-op。无 sleep barrier 证明旧 readiness 迟到于新完成后，最终仍 completed，evidence attempt 属于新请求。
- Finding 3：Migration004 在尚未部署前改为独立 evidence UUID + `UNIQUE(media_id, attempt_id)`，同 media 多次成功保留多行，同 attempt 重放不重复；source/engine 改为有界非空事实字段，provider/model/locale/language 分离且 nullable。`(media_id, task_id)` 与 `(task_id, snapshot_id)` 两组外键拒绝跨 task 拼接；没有新增云请求或 Provider 调用。

### 新 M0 修复周期：SQLite generation owner 与 completed 单一入口

- 日期：2026-07-20
- 当前状态：**两个 P1 的工程实现、focused 验收和 Debug/Release 构建完成；当前共有 426 个 XCTest，managed 环境为 386/426，通过普通 macOS 权限排除唯一 Keychain 测试后为 425/425。Keychain 仍是独立环境门。未部署 Migration004，真实用户库仍为 v3。** 本周期只修 M0，不进入 M1–M6。
- 场景 → 角色与交接：用户对同一视频连续转写，或 App/ViewModel 重建、系统时间回退时，`HistoryViewModel` 不再自己发顺序号；它把当前 `taskID + mediaID` 交给 `HistoryRepository`。GRDB 在一个 write transaction 中验证 media 属于 task，从当前 owner generation 与 append-only evidence generation 的最大值分配 `+1`，原子写入 pending owner，提交后才返回 token。后续 Apple ASR 只拿 token 工作；SQLite 是最终验票员，旧 token 的 running/none/failed/completion 只返回 stale，不改变新 owner。
- 工作流与工具协同：点击转写 → worker 调用 `beginMediaTranscription(taskID:mediaID:)` → DB 返回 `{attempt UUID, mediaID, generation}` → 只有 begin 成功且 request identity 仍有效才调用 modelState；running 返回 applied 后才启动 transcribe → final 交给唯一 `completeMediaTranscription` transaction → snapshot 复用/插入、evidence append、media completed、task 时间一次提交。XCTest 使用同步 barrier 控制“begin 已提交但 UI request 已失效”和“completion 正在 terminal hook”两个交接点，不用 sleep 猜竞态；两个独立 repository 并发 begin 直接验证 SQLite 串行发号。
- 本次核心名词（沿用项目概念，不扩 GLOSSARY）：**generation（L3）**是数据库持久化的递增排队号，像银行叫号，不是墙上时钟；位置在 `media_assets.transcription_attempt_generation` 与 evidence 的 `attempt_generation`，没有它，ViewModel 重建或时钟回退会让旧请求重新夺权。**owner（L3）**是当前 `(mediaID, attempt UUID, generation)` 三元组，像同时核对柜台、取件码和轮次；没有它，迟到写入会覆盖新结果。**stale no-op（L3）**表示数据库明确认出旧 token 并返回“未应用”，不是把 0 行 UPDATE 当成功。**replay（L2）**只允许当前已完成 attempt 重放并复用原 evidence；owner 已被替换时返回 stale。
- P1-1 修复：`TranscriptionAttemptToken` 保留 UUID，并新增 mediaID 与 DB generation；ViewModel 的内存/wall-clock 顺序生成已删除。Migration004 仍是 v4，把 started-at 顺序列替换为正整数 generation，evidence 增加 `attempt_generation`，并用 task 级唯一约束/索引约束 generation。effective snapshot 与 History 列表按 `attempt_generation DESC` 选最终正文；`completed_at_ms` 只记录事实时间。连续 begin、两个 repository 并发、close/reopen 后接管均证明 generation 唯一且严格递增；同一 XCTest 用两个隔离临时数据库分别验证重建 ViewModel 后 wall-clock 相同（100→100）和回退（100→50），两者都得到 generation `[1,2]`、新 transcript/evidence 入库且 effective final 指向新 attempt；溢出路径 fail closed。
- P1-2 修复：`attachMedia` 只接受初始 `.none`；通用状态接口改成只含 running/none/failed 的窄枚举，并显式返回 applied/stale，pending 与 completed 在类型上不可表达。生产源码唯一 `SET transcription_status = 'completed'` 位于 completion transaction。completion 返回 accepted/replay/stale；只有 accepted 会让 ViewModel 显示 completed。相同 hash 复用 snapshot，但每个新 generation 仍追加独立 evidence；当前 attempt 重放不重复 evidence，旧 owner 重放为 stale。
- Migration/事务不变量：v3→v4 测试保留既有 task 与 media 数据；evidence 继续使用独立 UUID、`UNIQUE(media_id, attempt_id)`、provider-neutral nullable 字段和两组复合外键，并新增 `UNIQUE(task_id, attempt_generation)`。completion 的 snapshot、evidence、completed、task time 仍在一个 transaction；`beforeTerminalCommit` 在 evidence 后抛错时四者全部回滚。Migration001/002/003 SHA 复核保持 `2402fd0d… / e92f20df… / 74043ff0…`。
- 红灯与恢复：首次隔离 scratch 因无网络、无法重新 clone 已有 GRDB checkout，没有进入测试；按既定环境门复用仓库完整 `.build` 后，新增旁路测试得到 **46 项 / 4 个断言失败**：`attachMedia(.completed)` 实际插行，通用状态更新实际写 completed 且 evidence 为 0。实现中新增 barrier 测试首次把 `.none` 误推断为 `Optional.none` 而失败，改为显式 `TranscriptionStatus.none` 后通过；这属于测试断言修正，不是产品重试。
- 最终自动证据：focused `HistoryMigrationAndFaultTests|MediaTranscriptionPersistenceTests|HistoryViewModelTests` 为 **55/55 PASS**。覆盖 v3→v4、连续/并发 begin、generation 溢出 fail closed 且不替换 owner、重开接管、旧 token 全状态 stale、ViewModel 重建与时钟回退、begin notFound/readOnly/注入失败的 modelState/download/transcribe 全 0、begin 已提交后 request 失效的 best-effort none、completed 旁路关闭、唯一原子 complete、current replay、相同 hash 二次 evidence、generation effective final、迟到 failure、原 barrier 与 terminal fault rollback。
- 全量与构建：当前共有 **426 个 XCTest**。managed 全量为 **426 executed / 386 PASS / 40 环境失败**：1 个隔离 Keychain、1 个 LocalMedia 容量探针、36 个 loopback listener 与 2 个 Unix socket 环境限制；普通 macOS 权限排除唯一 Keychain 测试后，外部能力相关 39 项转绿，结果为 **425/425 PASS**。Keychain 证据保持分层：实施环境曾观察写入 status `-60006`；独立 QA 的 managed 环境观察为 `-50`；独立 QA 在普通 macOS 隔离复跑时约 10 秒未返回后人工中断，因此没有独立复现 `-60006`，不得把该值写成独立确认。Debug 与 Release `LinkDigestApp` 均构建成功，`git diff --check` 无输出；整体不得写成 426/426 全绿。
- 真实数据与 dirty 保护：所有写测试使用临时根与隔离 HOME/cache；没有调用真实 Provider、下载模型、读凭据/Cookie/Profile、写真实用户数据库、部署、打包、覆盖 DMG、修改 Brain、commit 或 push。真实 `/Users/song/Library/Application Support/LinkDigest/history.sqlite` 只用 `sqlite3 -readonly` 读取 metadata：`user_version=3`、`quick_check=ok`、尚无 generation 列；读取前后 size=`364544`、mtime=`1784438050`、inode=`84391384` 完全相同。目标外 dirty 文件保持原状。
- 失败与回滚：源码尚未部署且真实库仍是 v3，可通过反向撤销本周期 8 个源码/测试文件和本日志追加恢复到交接前；不得修改 Migration001/002/003。若未来任何真实库已运行新 Migration004，就不能回滚为旧 v4 定义或下调 `user_version`，只能保留当前 v4 合同或新增向前 migration。DB begin 失败时不调用模型；begin 后 request 失效则尝试用返回 token 清理 none，新 owner 已接管时 stale 即为安全完成。
- 未完成边界：M1–M6 的 V2 wire、远程播放、按需临时媒体、云 ASR、PromptPreset、多平台、真实三样本质量门、断网人工门、日用 App 部署、DMG 冻结/覆盖均未进入本周期；唯一全量未绿项是既有隔离 Keychain 环境门。
- 可选跟做（5–10 分钟）：打开 `testSelectionChangeAfterBeginCommitCleansReturnedTokenBeforeModelCheck`，按“DB begin 提交 → barrier 暂停返回 → 切到 B → 放行 → A 变 none、模型调用仍 0”观察 UI request identity 与 DB owner 的双层门禁；这是理解入口，不是关闭任务的作业。

### 新 M0 独立 Reviewer / QA 唯一返修

- Finding A（P1 测试覆盖）：`testRebuiltViewModelWithSameOrBackwardClockStillCompletesHigherGeneration` 保持一个 XCTest 数量不变，内部参数化 `secondNow=[100, 50]`，每个值都新建独立 fixture/临时数据库。两条子场景都真实完成第一次和重建后的第二次转写，断言 effective final 为新正文、evidence generation 为 `[1,2]`、事实时间分别为 `[100,100]` 与 `[100,50]`。相同 wall-clock 场景在现有实现上直接通过，这是新增覆盖，不伪造产品红灯。
- Finding B（P2 回归门）：测试先改为读取 `TranscriptionStatusMutation.allCases`，在生产 conformance 加入前真实编译红灯为 `type 'TranscriptionStatusMutation' has no member 'allCases'`。随后仅给该枚举增加 `CaseIterable`；精确断言 allCases raw values 等于 `running/none/failed`。未来若新增 pending/completed 或其它 case，门禁会真实失败；没有改变状态语义。
- Finding C（P2 证据口径）：总数修正为 426；managed 结果记录为 386/426，普通 macOS 排除 Keychain 后记录为 425/425。39 个外部能力环境失败已在普通权限转绿；Keychain 仍单列为环境门，并明确区分实施环境 `-60006`、独立 QA managed `-50`、独立 QA 普通隔离复跑未返回且人工中断三份证据，不再把 `-60006` 写成独立确认。

### M1 复审返修：原子抖音快照与闭合 delivery provenance

- 日期：2026-07-20
- 当前状态：**四项复审缺口已完成本地最小返修与自动验收；未部署、打包、写真实用户数据库或进入 M2–M6。** 本轮没有修改 Migration001–005、合同、fixture、生成 validator、依赖、PRD、GLOSSARY 或 Brain。
- 场景 → 角色与交接：用户可能在抖音脚本执行前把页面从 A 切到 B。后台现在完整接收同一次注入返回的 B 页面事实，不再用注入前旧 tab URL 覆盖其中的 `media.pageURL`。进入桌面端后，V1/V2 wire 在应用服务入口立即生成不可任意拼装的 `CaptureDeliveryProvenance`；Repository 只接收持久文档、闭合 provenance 和接收时间，不再同时观察 raw wire、裸版本号或 `MediaDescriptor`。
- 工作流与工具协同：同次抖音快照 → V1/V2 typed command constructor → 在边界计算 delivery key、contract version 与 semantic digest → GRDB 只消费这份 provenance → 同 key/同 digest replay，同 key/不同 digest conflict。Vitest 用 A→B 定时切换复现跨页面拼接；XCTest 枚举 V2 每个安全媒体字段与两个瞬态字段；SQLite/WAL/SHM 扫描证明交给 Repository 与落盘的数据中不存在临时播放地址、过期时间或 poster 原文。
- 本次名词（沿用既有概念，不扩 GLOSSARY）：**原子快照（L3）**像一次按下快门，正文、来源页和媒体身份必须属于同一画面；**safe semantic digest（L3）**像只给允许持久化的事实盖指纹，安全事实变化会冲突，瞬态取货码变化只会重放；**delivery provenance（L3）**像封好的交接回执，把 delivery key、合同版本和摘要绑定在一起，Repository 不能再自行猜版本或把 V2 文档配成 V1；**双重真相（L3）**表示 wire schema 与落库 provenance 各自只负责自己的边界，不靠 `CapturedDocument.wireVersion` 形成第二套可漂移版本来源。
- 安全摘要精确边界：V2 digest 使用固定长度前缀和固定顺序覆盖 namespace/version、createdAt、source、capture、evidence，以及 media 的 kind/pageURL/canonicalURL/platform/mimeType/posterURL/durationSeconds/author/transcriptionCapability/failureReason/candidateCount/selectionReason/playbackState。它明确排除 requestId、idempotencyKey、ephemeralPlaybackURL 和 expiresAt。任一被覆盖字段变化都返回 idempotency conflict；只有这四个交付/瞬态字段变化时才 replay。
- 红灯证据：抖音 A→B 测试首次 **4 项中 1 项失败**，实际把旧 A 写进 media pageURL；V2 安全字段参数化测试首次 **1 项执行、13 个断言失败**，说明 13 个安全媒体字段变化都被误判 replay；V2 document 配裸 V1 version 的门禁首次 **1 项、1 个失败**，证明双重版本真相确实可构造。
- 绿灯证据：抖音定向 **4/4 PASS**；扩展全量 **52/52 PASS**、TypeScript typecheck PASS、WXT production build PASS（119.47 kB）。shared contracts **11/11 PASS** 且 typecheck PASS。Swift focused **24/24 PASS**、扩大定向 **84/84 PASS**、全量 **434/434 PASS**；Debug/Release `LinkDigestApp` build PASS。合同同步、generated validator `--check` 均 PASS。V1 typed constructor、V2 typed constructor、local/manual document 分别稳定产出 `capture:v1`/1、`capture:v2`/2、`manual:v1`/1；Migration005 的 V2 accept/replay 与既有 V1 validation/golden 均通过。
- 被实现过程修正的一点：新增 provenance 值布局后，Swift 增量缓存曾以 signal 10 退出；使用本轮独立编译条件强制完整重编后暴露一个真实模块可见性错误。最终没有把内部校验状态扩大成 public API，而是让非法 V1 provenance 生成不可接受的空摘要，由 Repository 统一映射为 `invalidInput`。后续完整 434 项通过，确认不是业务逻辑崩溃。
- 失败与恢复：代码尚未部署，回滚只需反向撤销本轮白名单文件中的 provenance、抖音覆盖修正、测试与两段文档增量，再重跑相同门禁；不得恢复或覆盖其它 dirty 内容，也不得修改 Migration001–005。Repository 若收到摘要长度异常会 fail closed 为 `invalidInput`，不会猜测 wire 版本继续写入。
- 真实数据与边界：所有数据库测试使用 `/private/tmp` 隔离库；未读取或修改真实用户数据库、Provider、凭据、Cookie/Profile，未安装依赖、部署、打包、覆盖 DMG、修改 Brain、commit 或 push。M2 远程播放、M3 临时媒体与 Apple ASR 真实三样本/断网人工门、M4 云 ASR、M5 PromptPreset、M6 新平台以及日用部署仍未开始。
- 可选跟做（5–10 分钟）：先看抖音 A→B 测试中旧 tab A 与注入快照 B 的断言，再看 V2 safe-field 表驱动测试如何逐项把 media fact 改成 conflict、把 ephemeral URL 与 expiresAt 改成 replay；这是理解“快照一致性”和“持久化边界”的共同观察入口，不是关闭任务作业。

### M1 首轮 Reviewer findings 返修：validated typed ingress

- 日期：2026-07-20
- 复审起点：独立 QA 对首轮实现给出 PASS：Extension **52/52**、shared **11/11**、Swift focused **84/84**，managed full 为 **434 executed / 394 PASS / 40 既有环境门**，Debug/Release、sync、validator 与 diff 均通过；Reviewer 仍给出 **FAIL：P0=0 / P1=2 / P2=1**。原因不是已有验证结果虚假，而是测试没有覆盖 public typed API 可直接构造非法 V2，以及 browser document 可改挂 manual namespace 的入口。
- 场景 → 角色与交接：`CaptureReceiver` 先按 wire version 解码；`CaptureIngestService` 的 V1/V2 typed overload 再在 App 边界完整验 schema 与 semantic rules，成功后才创建 closed `AcceptCaptureCommand`；local document 入口只接受非 browser origin。`HistoryApplicationService` 像只收封好回执的传递窗口，只接受 command；`GRDBHistoryRepository` 像仓库门卫，只核对 digest 形状与 provenance/document 的 namespace、version、origin、delivery suffix 是否一致，不重新接收已经被降维丢弃的 descriptor。
- 实际修复：V1/V2 provenance factory 和 command initializer 都改为 throwing、对 wrong version 与非法 schema 对称 fail closed，并统一映射 `RepositoryFailure.invalidInput`；local factory 验证 document 且拒绝 `.browserCapture`。`CaptureIngestService` 删除 document + optional V1 + optional V2 签名，改成两个 envelope overload 与一个 local-only document overload；`CaptureReceiver` 按 enum case 直接调用对应 envelope overload。`HistoryApplicationService` 删除 envelope/document overload，只保留 `acceptCapture(_ command:)`。完整 V2 descriptor 只在 `CaptureIngestService` commit 前用于验证和摘要、commit 后用于构造 `CurrentCapture`，不跨 History service。
- 合法 safe-field 矩阵：原测试基准是 `unsupported + ephemeralPlaybackURL`，违反 V2 schema，确实掩盖了入口缺校验。返修后 13 个字段都使用 schema-valid before/after pair：kind 用 directFile→hls；failureReason 用两条无 URL 的 browserSessionOnly；其余字段使用带 HTTPS URL、无 failureReason 的 directFile。每对先分别通过 command validation，再以相同 delivery key 证明字段变化 conflict；ephemeralPlaybackURL 与 expiresAt 变化仍 replay。
- 红灯证据：同一 `CaptureReceiverTests|HistoryRepositoryCaptureTests` 共 **20 项 / 14 个失败**。其中 programmatic invalid V2 未抛错且 Repository 调用为 1（2 个失败）；wrong-version V1、schema-invalid V2、wrong-version V2、browserCapture→manual 四项均未拒绝（4 个失败）；旧 optional 混装入口与 `HistoryApplicationService` full input overload 的边界门共 8 个失败。测试来自普通 `import LinkDigestCore` 的 persistence test target，证明 public API 问题不依赖 `@testable`。
- 绿灯证据：与红灯相同的 selected **20/20 PASS**；再加入 GRDB malformed provenance 零写入防御门后为 **21/21 PASS**；包含合法 safe-field matrix 的首轮定向 **27/27 PASS**；最终扩大 focused **88/88 PASS**。外部 Swift compile probe 调用旧 `HistoryApplicationService.acceptCapture(V2, receivedAtMilliseconds:)` 明确编译失败，错误为 expected `AcceptCaptureCommand` 与 extra argument。Extension **52/52**、typecheck、production build PASS（119.47 kB）；shared **11/11**、typecheck PASS；contract sync 与 generated validator check PASS；Debug/Release `LinkDigestApp` build PASS。
- 全量与环境边界：managed 环境绕过 SwiftPM 自身 cache/sandbox 启动限制、直接执行已构建 XCTest bundle 后为 **438 executed / 398 PASS / 40 环境失败**；40 项与既有基线同类，仍是 1 个 Keychain、1 个 LocalMedia 容量探针、36 个 loopback listener 与 2 个 Unix socket。普通 macOS 权限完整 `swift test` 为 **438/438 PASS**。两次直接 managed `swift test` 分别在 manifest 编译的用户 module cache、嵌套 `sandbox-exec` 阶段退出，均发生在测试开始前；因此环境分类采用实际执行完整 438 项的 xctest 结果，不把启动失败计作产品失败。
- 文件与范围：本轮没有需要三个受控机械适配文件；benchmark、Loop verifier、GRDB integration 与 HistoryViewModel 只被全量编译验证，未修改。Migration001–005、LocalDatabase、SQL/schema、JSON contract、fixture、generated validator、Models wire types、PRD、GLOSSARY、Brain、依赖和 M2–M6 均未修改。
- 失败与恢复：若需撤回，只能反向撤销本轮 typed validation、三入口拆分、command-only service、GRDB 防御检查、三处测试与两段文档增量；不得 `restore`/`reset` 覆盖共享 dirty 内容，也不得改动 Migration001–005。非法 input 的恢复方式是回到合法 wire 重新发送，不能绕过 validator 或伪造 provenance。
- 未完成边界与可选跟做：M2 远程播放、M3 临时媒体和 Apple ASR 真实三样本/断网人工门、M4 云 ASR、M5 PromptPreset、M6 新平台、日用部署与 DMG 均未进入。可选观察 `testPublicCaptureCommandFactoriesRejectInvalidWireAndBrowserDocumentManualization`：依次把错误版本、directFile 无 URL、browser document 伪装 manual 送进入口，三类都在 Repository 前停止；这是 L3 共同观察入口，不是关闭任务作业。

## 任务 M1：V2 合同与通用媒体识别

- 日期：2026-07-20
- 当前状态：**M1 本地工程实现、跨语言合同同步、定向测试、扩展全量、Swift managed 全量分类与 Debug/Release 构建完成；未部署、打包或进入 M2–M6。**
- 场景 → 角色与交接：用户在当前 Chromium 页面主动发送；content script 先提取页面正文，通用媒体检测器只读当前 DOM 的 `video/source`、播放状态和可见几何。无目标视频继续交 V1；有已分类视频才交独立 V2。Native Host 与 `CaptureReceiver` 按 `version` 选择同一份 bundled schema，正文交给现有 History，`MediaDescriptor` 只留 `CurrentCapture` 当前进程内存。
- 工作流：`<video>` candidates → playing / 当前焦点可证明交互 / 可见交集面积 / 视口中心距离 → directFile、hls、browserSessionOnly 或 unsupported → V2 JSON → Host 校验 → APP 校验 → `CapturedDocument`。完全并列返回 `multiple_candidates`；blob/MSE 返回 `browserSessionOnly + blob_or_mse`；没有可靠交互历史时直接跳到面积规则，不增加权限或常驻全站监听。
- 工具协同：JSON Schema 是真相源；Ajv 2020 生成 MV3 静态 V1/V2 判别 validator；Swift `CaptureWireContractSchema` 按版本加载资源；同一 fixture manifest 覆盖 V1、direct MOV、HLS、blob/MSE、多视频歧义、unsupported/DRM、Douyin DOM direct 与 invalid direct without URL。`sync-contracts.sh` 复制到 Swift resources，`check-contract-sync.sh` 与 generator `--check` 防漂移。
- 核心名词（L3）：**CaptureEnvelopeV2** 像另起一张新版海关单，不能在 V1 上涂改；**MediaDescriptor** 像媒体能力卡，说明可移交性与失败原因，不是媒体资产；**ephemeralPlaybackURL** 像一次性取货码，只留进程内存；**确定性媒体选择**像按固定规则选监控主画面，完全平局就明确歧义。四项已进入 `GLOSSARY.md`。
- 两个关键安全不变量：第一，direct/hls 必须有 HTTPS 临时地址且无 failureReason，browserSessionOnly/unsupported 必须无临时地址且有稳定 failureReason；第二，V2 映射时旧 `CapturedDocument.media` 保持 nil，临时地址从持久化 fingerprint、SQLite/WAL/SHM、导出、错误详情和旧下载/`media_assets` 接缝中排除。
- 私有端点清除：`extract.ts` 与 `background.ts` 已删除两套 `/aweme/v1/web/aweme/detail/` + `credentials: include` 路径。M1 抖音只取当前 DOM 的公开 `video/source` 和页面 metadata；direct 进入 V2，blob/MSE 诚实降级。源码门禁测试会扫描这两个生产文件，防止私有端点或 credentialed fetch 回归。
- 红灯证据：扩展新增测试首次为 0 tests / module missing，合同 fixture 因 V2 文件不存在失败，Douyin 安全测试直接命中私有端点；Swift 首次编译因 `CaptureEnvelopeV2Validator`、`MediaFailureReason` 等类型不存在失败。实现后一次 Swift 增量产物因新增值类型布局陈旧，在复制 `CurrentCapture` 时 SIGBUS；以独立编译条件强制全量重编后，冻结 V1 golden 与所有 focused tests 通过，确认不是合同逻辑失败。
- 绿灯证据：扩展 Vitest **50/50 PASS**，typecheck PASS，production build PASS（4 个产物，117.54 kB）；shared contracts **10/10 PASS** 且 typecheck PASS；Swift focused `ContractTests|CaptureMediaContractTests|AppCompositionTests|CaptureReceiverTests|V1 golden` **39/39 PASS**；其中 V2 临时地址内存可见但 SQLite/WAL/SHM、export 与 `media_assets` 均无 sentinel 的负向测试 **2/2 PASS**。V1 frozen golden hash `21cdaa…44c0` 保持 PASS。Debug/Release `LinkDigestApp` build PASS。
- Swift 全量边界：managed 全量执行 **431** 项，**391 PASS / 40 环境失败**；失败数量与 M0 基线一致，仍为既有 1 个 Keychain、1 个 LocalMedia 容量探针、36 个禁止 loopback listener 的网络测试和 2 个 Unix socket，M1 新增 5 项全部通过。不得写成 431/431 全绿。
- 失败与恢复：V2 schema、fixtures、TS/Swift 模型、检测/接收接线和文档均为独立增量；源码未部署且无数据库 migration。回滚时只反向撤销 M1 白名单文件的这些增量并重跑 sync，禁止恢复/覆盖其它 dirty 内容；V1 schema/fixtures、Migration、Repository、Brain、DMG 不在回滚范围。
- 真实数据与 dirty 保护：fixtures 全部使用 `example.test`；所有 SQLite/sentinel 测试只写 `/private/tmp`，未读取真实 Provider、凭据、Cookie/Profile 或真实用户数据库，未下载依赖/模型，未部署、打包、覆盖 DMG、改 Brain、commit 或 push。现有高度 dirty 文件只以局部补丁叠加，白名单外源码未修改。
- 未完成边界：M2 远程 AVPlayer/HLS/embed/收藏，M3 TranscriptionTemp 与 Apple ASR 真实三样本/断网门，M4 云 ASR，M5 PromptPreset，M6 新平台适配与真实样本，日用部署和 DMG 冻结均未进入 M1。
- 可选跟做（5–10 分钟）：打开 `media-detection.test.ts`，观察两条完全同面积/同中心距离的视频如何返回 `multiple_candidates`；再看 `PersistenceWiringTests` 的 sentinel 扫描，理解“当前内存可见”和“持久化零出现”的交接边界。这是理解入口，不是任务关闭作业。

## 任务 M2 快线：当前捕获视频速览与显式收藏

- 日期：2026-07-20
- 当前状态：**可见 Debug 快线工程实现、focused 自动验收与 Debug build 已完成；未部署、未打包、未覆盖日用 APP/DMG，也未完成真实浏览器 MP4/HLS 首帧人工门。** M3 临时转写媒体、M4 云 ASR、M5 PromptPreset、M6 新平台均未进入。
- 场景 → 角色与交接：浏览器把合法可见视频的 `MediaDescriptor` 交给 APP 后，History 详情先展示页面标题、来源、总结/翻译入口，再在正文上方展示“视频速览”。`CurrentCapture` 像手上仍有效的临时取货单，只把 `ephemeralPlaybackURL` 交给远程播放器；History/Repository 仍只持久化页面事实。用户点击“收藏到本机”后，`HistoryViewModel` 才把直连 descriptor 短时转为 `CaptureMedia`，交给既有下载器、`LocalMediaStore` 和 `attachMedia`，成功后本地播放器接管。
- 工作流与工具协同：`showsCurrentCapture + mediaDescriptor + no local asset` → pure preview projection 判断可播放/过期/降级 → direct MP4/MOV 或 HLS 立即构造 `AVPlayer` → 后台读取 `naturalSize + preferredTransform` 修正真实比例 → 切换/离开时 pause + replace item nil + release。收藏链路为用户点击 → direct eligibility → 既有安全下载/容器/容量门 → content hash 本地文件 → `media_assets` → detail reload → `HistoryVideoPlayerCard` 离线播放；HLS 只播放并显示“暂不支持保存 HLS”。
- 本次核心名词（沿用现有词条，不扩 GLOSSARY）：**Ephemeral Playback URL（L3）**像一次性取货码，只用于当前 player；**preferredTransform（L2）**像手机视频附带的旋转说明纸，和 naturalSize 一起决定横竖比例；**degradation（L2）**像无法办理时的原因单，明确 kind、原因和下一步；**favorite eligibility（L2）**像收藏柜台的资格判断，本轮只允许 directFile。
- 可见行为矩阵：directFile 可速览、可显式收藏；HLS 可速览、不可收藏；embed 只显示承接骨架与返回浏览器，不加载 WebView；browserSessionOnly/unsupported 不建 player。blob/MSE 提示“只能在原浏览器会话观看”；DRM、多个视频、视频未加载、登录会话依赖和媒体格式不支持各自显示稳定中文动作。过期地址不建 player、不静默重解析；运行期失败只提供重试/回浏览器重新发送，不回显或保存 URL。
- 红灯与恢复：首轮 focused 编译明确因 M2 pure preview、player controller 与 favorite API 不存在失败；实现后 UI 28 项中 1 个源码结构断言需改为实际局部变量名。收藏集成首次在 managed 沙盒命中既有 LocalMedia 容量探针环境门，显示 `insufficientDiskSpace`；随后只给 `HistoryViewModel` 增加测试下载边界，生产仍使用真实 `VideoMediaDownloader`，测试以 `/private/tmp` 脱敏 MP4 验证下载调用一次、真实 `attachMedia`、本地文件和 detail 刷新。
- 自动证据：M2 focused **29/29 PASS**（History 内容/纯模型/生命周期 28 + direct 收藏真实 attach 1）；M1 临时地址负向门 **2/2 PASS**，同时证明 URL 只在 `CurrentCapture` 可见，Repository input、SQLite/WAL/SHM、export 和旧 `media_assets` 均无 sentinel，V2 接收不自动下载。Debug `LinkDigestApp` build PASS；`git diff --check` 在任务关闭前单独复核。
- 安全与 dirty 保护：未新增依赖、权限、WebView、Cookie、私有 API、schema、Migration、Repository 合同或永久 URL 字段；未读取真实用户数据库、Provider、凭据、Cookie/Profile，未联网成功、未部署、打包、修改 Brain、commit 或 push。所有 M2 写入局限在四个 App 源码/测试文件与两份允许文档的局部增量，保留共享高度 dirty 的既有内容。
- 失败与回滚：远程播放失败只释放当前 player 并保留正文、总结、翻译和页面 History；收藏失败不附加 asset，用户可重试或回浏览器重新发送。若撤回 M2，只反向移除本日志/架构增量、preview projection/card/player controller、favorite UI state/测试下载 seam 与 focused tests；不得 restore/reset 覆盖同文件其它 dirty 修改。
- 可选跟做（5–10 分钟）：在 Debug 候选中发送一条 direct MP4，再观察“速览立即出现 → 点击收藏 → 远程卡消失 → 本地播放器出现”；随后切换到另一条 History，确认前一个远程 player 停止。这是理解角色交接的观察入口，不是任务关闭作业。

## 任务 M3 快线：当前 V2 direct 视频按需临时媒体与 Apple 本机转写

- 日期：2026-07-20
- 当前状态：**directFile 的可测试 Debug 工程链已完成；未部署、未打包、未覆盖日用 APP/DMG。三条真实中文口播、断网、真实浏览器签名 URL 与 GUI 人工门仍未完成，因此不得宣称 M3 正式验收完成。HLS 转写明确留在后续。**
- 场景 → 角色与交接：用户先在 current V2 卡片速览，播放本身不下载转写媒体；只有点击“本机转写”后，Repository 先发 durable generation，`TranscriptionTempStore` 才建立一次性目录并安全下载 direct MP4/MOV，Apple SpeechAnalyzer 只读取该文件，partial 只交给 UI，final 才交回一个 GRDB 原子事务成为最新正文。任何终态由 TempStore 清场，失败时把“重试清理”交还用户。
- 工作流：directFile + supported/conditional + 未过期 + 可写 DB → begin task attempt（失败则零 network/ASR）→ `TranscriptionTemp/<UUID>` → HTTPS/SSRF/redirect≤4/120s/200MB/magic/磁盘/120min 门 → 模型检查与明确安装确认 → 音频提取 → partial/final → snapshot/evidence/completed/task time 同事务 → 清理。HLS、browser-only、unsupported/embed 不进入该路径；HLS 可播放但显示“当前 Debug 暂不支持 HLS 转写”。
- 核心名词（L3，不扩 GLOSSARY）：**transient attempt** 像一次性中转单，只服务本次转写；**durable generation** 像数据库发出的防串单号，旧请求迟到只能 no-op；**final snapshot** 是搜索、总结、翻译和导出真正读取的最终正文；**terminal cleanup** 表示成功、失败、取消、模型失败和空结果都必须清场。没有 generation 会把旧文字串到新 History；没有原子事务会留下“正文已换、证据或状态未换”的半成品。
- 技术选择：新增 task-scoped Migration006，而不是向 `media_assets` 塞虚拟文件。M0 永久媒体与 M3 临时媒体共用 Task 的单调 generation，两类 evidence 合并选择 effective latest；相同正文 hash 复用 snapshot 但继续追加来源证据。临时路径、remote URL 与签名参数不进入 Migration006、Repository command、SQLite 或导出。
- 红绿证据：首轮沙盒外编译在 App target 出现 1 个根因/3 个同源诊断（把非 Error 的 `StorageErrorCode` 用作 `Result.Failure`），修复为明确结果枚举后 Debug App build PASS。最终 focused **37/37 PASS**：Migration 9、既有 M0 media 转写 14、M3 task owner/原子/effective latest 4、TempStore 4、remote ViewModel 4、remote UI/播放器 2；另单独 URL/temp path SQLite/WAL/SHM 负向扫描 **1/1 PASS**。覆盖 begin 零网络/ASR、success/model unavailable/cancel、History switch isolation、同 hash、跨 M0/M3 generation、事务回滚和 UI a11y。
- 生命周期矩阵：成功、识别失败、空转写、取消、模型不可用/安装失败、History 切换都调用 attempt cleanup；启动清理整个 TranscriptionTemp；正常退出再次清理；清理失败保留目录、显示明确状态并允许重试，不静默吞掉。TempStore 不产生 `MediaAsset`，播放器 `onAppear` 和 AVPlayer 准备路径也没有 TempStore/fetch 调用。
- 失败与恢复：网络/容器/大小/磁盘/时长/音轨/模型/识别错误保留 History 与页面正文，attempt 进入失败或取消终态，用户可重试；原子提交故障回滚 snapshot、evidence 和 completed。若需撤回，只反向移除 Migration006、task-scoped port/Repository 接缝、TempStore、remote UI/DI、focused tests 与本段文档增量；不得修改 M001–005、restore/reset 共享 dirty 内容或删除用户数据。
- 安全与未完成边界：fixture 全部使用 `example.test` 和 `/private/tmp` 隔离根；未读取真实用户数据库、Provider、Keychain、凭据、Cookie/Profile，未保存 URL/path，未安装依赖、联网真实平台、部署、打包、改 Brain、commit 或 push。真实横屏/竖屏/较长中文三样本、模型已安装后的断网全程、真实取消/崩溃恢复和 GUI a11y 仍是人工未完成门；云 ASR、PromptPreset、新平台与 HLS 音轨获取不在本轮。
- 可选跟做（5–10 分钟）：在隔离 Debug 候选中打开一条 current direct MP4，先确认仅播放时 `TranscriptionTemp` 为空，再点“本机转写”观察“准备临时媒体 → 检查模型 → 提取音频 → partial → final → 目录归零”；处理中切换 History，确认 partial 和状态立即清空。这是 L3 共同观察入口，不是任务关闭作业。

### M3 最终 QA P2：SIGTERM 与正常退出显式清理 capture socket

- QA 事实与根因：隔离候选在自定义 `LINKDIGEST_SOCKET_PATH` 下启动、SQLite ready、SIGTERM 后进程退出且转写临时目录安全，但 socket 文件节点残留。原 `UnixSocketServer` 只在 `deinit` close/unlink，而 server 被 detached accept loop 捕获，App composition 没有可在终止阶段调用的生命周期 owner；进程被信号结束前不能依赖 ARC 恰好执行 deinit。
- 最小修复：`UnixSocketServer.stop()` 以锁交换 listening fd，幂等执行 shutdown/close，并只 unlink 实例持有的精确 `path`；deinit 复用 stop。`UnixSocketServerLifecycle` 强持有 server 与 accept Task，stop 同时 cancel accept loop 和关闭 socket。正常 App 退出由 `NSApplication.willTerminateNotification` 调 stop；SIGTERM 使用强持有的 `DispatchSourceSignal` 在普通队列执行相同清理，随后恢复 `SIG_DFL` 并重新发送 SIGTERM，避免在 async-signal-unsafe raw handler 中操作对象或文件，同时保留信号终止语义。
- 自动证据：focused **9/9 PASS**（`UnixSocketTests` 8 + App lifecycle 1），覆盖精确 socket 创建、connect/round-trip 回归、stop 立即 unlink、重复 stop、同 owner restart 和 App lifecycle stop 幂等。Debug build 与 `git diff --check` 见最终交接报告；主控负责生成新候选，原 QA 负责真实进程 TERM smoke。
- 边界与恢复：没有持久化测试 socket path，没有扫描或删除任意目录，没有改变 Native Host 默认路径、数据库、转写、Provider、日用 App 或 DMG。若需撤回，只反向移除 stop/lifecycle/TERM 接线、两项 focused 测试和本段日志；恢复后旧的“下次启动先 unlink”行为仍在，但 SIGTERM 残留 P2 会重新出现。

## 任务 M3 快线追加：三个可测试性阻断闭环

- 日期：2026-07-20
- 当前状态：**三个工程阻断均已修复并通过主控最终自动验收；隔离 Debug 候选 `/private/tmp/LinkDigest-Debug-Usability-20260720` 已生成，完成双项结构、codesign、同次 WXT extension 字节与 identity 核验；尚未在 GUI 启动，也未完成真实浏览器或 Provider 验收。** 本轮解决的是：GitHub README 中 `book/xxx.pdf` 等相对链接被安全校验拒绝；首次模型配置要求先手填模型、再读取模型列表，流程前后倒置；Debug App 没有携带与自身匹配的已解压扩展，浏览器支持页因 Host 内容漂移而无法形成可信测试入口。

### 场景 → 角色与交接

1. **相对链接链**：用户点击 History 正文或模型结果中的 Markdown 链接 → `MarkdownContentView` 把“原始目标 + 当前记录 sourceURL”交给 `MarkdownLinkResolver` → resolver 将普通相对链接按来源页补全，将 GitHub 仓库 README 文件映射到 `blob/HEAD`（目录映射到 `tree/HEAD`）→ 最终绝对 URL 仍交给 `PublicWebURLPolicy.validateSyntax` 检查 scheme、userinfo、host 与端口 → 通过后才交给默认浏览器。失败时只显示固定“未通过安全校验”，不放宽危险协议。
2. **首次模型发现链**：用户依次填写 Base URL 与 API Key → `ProviderSettingsViewModel.loadModels(apiKey:)` 只把经 `ProviderProfile.validatedBaseURL` 验证的地址和当次短生命周期 Key 交给 `ModelCatalogLoading` → `OpenAICompatibleProvider` 请求同源 `/models`，执行 1 MiB、500 项、JSON 协议与固定错误门 → 模型 ID 列表交给 Picker，用户显式选择后再保存。成功不会自动选择第一项；只有 `/models` 失败后才出现“高级：手动填写模型名”。已保存配置仍可从 Keychain 短时读取 Key 后刷新列表和测试连接。
3. **Debug 交付链**：主控给出一个尚不存在的 `/private/tmp` 直属输出目录 → `build-debug-candidate.py` 先运行当前 pnpm/WXT build，核对 manifest 的 name、description、version、key 与 permissions，再以 nofollow 方式复制 `.output/chrome-mv3` → 同次构建、改写隔离 bundle id/数据根并 ad-hoc 签名 `LinkDigest Debug.app` → 最终目录固定只含 `LinkDigest Debug.app` 与 `extension/`。`BrowserSupportSettingsView` 始终提供“在 Finder 中显示测试扩展”，优先 App 相邻 extension，源码运行才回退 WXT 输出；日用 Host 与测试版 Host 不同时明确提示“修复会先备份、临时切换、之后可恢复”。

### 核心名词（本轮不扩 `GLOSSARY.md`）

| 名词 | 人话解释 | 生活类比 | 项目位置 | 缺失时的可见失效 |
|---|---|---|---|---|
| 链接解析 | 在做安全判断前，用来源页把不完整的相对地址补成可检查的绝对地址 | 信封只写“隔壁 3 号楼”时，邮局先结合寄件地点补齐城市和街道 | `MarkdownLinkResolver`，位于 Markdown 点击与 `PublicWebURLPolicy` 之间 | 合法 PDF/目录因没有 host 被拒；若直接放行，又会绕过危险 scheme、userinfo 或异常端口门 |
| 模型发现 | 用服务商的 `/models` 清单确认端点与 Key 可用，再让用户选择真实模型 ID | 先看餐厅当天菜单，再点菜，而不是先猜一道菜名才能进门 | `ModelCatalogLoading`、`OpenAICompatibleProvider`、`ProviderSettingsViewModel` 与设置页 Picker | 首次配置形成“先要模型名才能读取模型名”的死循环，或把不存在的模型静默保存 |
| 内容漂移 | 浏览器 manifest 当前指向的 Host 内容与正在测试的 App Host 不同 | 门牌还挂着日用办公室，但测试人员已经搬到临时实验室 | Browser Support 状态、备份/修复/恢复提示与 Debug 候选相邻 extension | 用户加载的扩展、Native Host 和 Debug App 不是同一套产物，测试结果无法归因，修复时也不知道如何恢复日用状态 |

### 实际修复与决策

- Markdown 展示层新增可独立测试的 resolver，并让源文与模型结果都携带同一条记录的 `sourceURL`；绝对 HTTP/HTTPS 保持不变，普通相对链接按来源页，GitHub 仓库 README 文件/目录分别使用 `blob/HEAD` / `tree/HEAD`。最终仍复用现有公共 URL 语法策略，没有在 UI 自建较弱白名单。
- `/models` 协议不再要求包含模型名的完整 `ProviderProfile`，只接收验证后的 Base URL 与当次 Key。可观察状态仅保存请求 ID、草稿代次、非敏感 Base URL 和固定错误码；Base URL 或 API Key 草稿变化会令旧列表失效。错误文案本地固定区分 auth、404、network、limit 与 protocol，不显示 Provider body。
- Debug 脚本改为 no-clobber 的 `/private/tmp` 直属交付目录，同次构建并校验解压扩展后再构建/签名隔离 App；不自动部署。Browser Support 只改展示与测试扩展定位，没有改 `BrowserSupportInstaller` 的算法、真实 manifest 或 receipt。

### 主控最终证据

- Swift 定向：`MarkdownPresentationTests` **13/13 PASS**；`ProviderSettingsViewModelTests` **29/29 PASS**；`OpenAICompatibleProviderTests` **18/18 PASS**；`HistoryContentViewTests` **29/29 PASS**；`BrowserSupportViewModelTests` **4/4 PASS**；`BrowserSupportInstallerTests` **28/28 PASS**。
- 浏览器扩展：Vitest **52/52 PASS**；TypeScript typecheck PASS；WXT production build PASS。
- 构建与静态门：Debug `LinkDigestApp` build PASS；Debug App ad-hoc `codesign --verify --deep --strict` PASS；`python3 -m py_compile scripts/build-debug-candidate.py` PASS；`git diff --check` PASS。
- 环境说明：managed 默认 sandbox 禁止本机 listener，`OpenAICompatibleProviderTests` 的 Fake Server 因此统一表现为 `startFailed`，不是 Provider 产品逻辑失败；允许仅绑定本机回环后同一 suite 为 **18/18 PASS**。裸 GUI 启动在沙箱内仍以 exit 1 结束，保留为真实桌面会话中的人工门，不把“进程被沙箱拒绝”写成 UI 已验收。

### 安全边界、失败与恢复

- API Key 只作为 `loadModels(apiKey:)` 的当次参数进入 adapter，不持久化到 `@Published`、请求状态或日志；测试仅使用 fake key。错误状态只携带固定本地 code/copy，不回显 Provider body。
- 自动构建与候选核验阶段未读取或修改真实浏览器 Profile、Cookie、Keychain 内容，也未写真实 Native Messaging manifest/receipt；隔离 Debug 候选 `/private/tmp/LinkDigest-Debug-Usability-20260720` 已生成，但未覆盖日用 `/Users/song/Applications/LinkDigest.app`、日用扩展或 DMG，未部署、提交或推送。后续浏览器人工门属于有状态操作，必须遵守下方确认、备份与恢复要求。
- 链接解析失败时保留正文并拒绝打开，修复来源页或目标链接后可重试；撤回 resolver 会恢复“相对链接被拒”的旧表现，但不得放宽公共 URL 策略作为替代。
- `/models` 失败时保留 Base URL 草稿与固定诊断，用户可重试或显式展开高级手填；草稿变化会清空旧列表，避免把旧站点模型带到新站点。撤回模型发现改动会恢复首次配置倒置，不影响已保存 Keychain secret。
- Debug 装箱任一步失败都会在交付目录出现前停止；目标已存在时 no-clobber 拒绝覆盖。Host 漂移修复由 installer 先做时间戳备份，测试后使用“恢复备份”回到原日用 Host；不要手删真实 manifest 或 receipt。

### 人工测试入口（未完成门，不阻塞工程证据）

1. 在真实桌面会话启动主控生成的隔离 Debug 候选，打开 GitHub 仓库 History，分别点击 `book/xxx.pdf`、普通相对链接与绝对 HTTPS，确认合法目标进入默认浏览器，`javascript:` 等危险目标仍被拒绝。
2. 使用 fake/专用测试 Provider 从空配置开始，按 Base URL → API Key → “读取并验证模型” → Picker → 保存的顺序操作；确认成功时不自动选第一项，修改 URL/Key 后旧列表消失，auth/404/network/limit/protocol 各显示固定本地文案，只有失败后才出现高级手填。
3. 建议新建并使用隔离测试 Profile，再在候选 App 的“浏览器支持”点击“在 Finder 中显示测试扩展”，确认打开候选相邻 `extension/`。加载已解压扩展会写入所选浏览器 Profile；若执行 Host 修复，还会写入对应浏览器的 Native Messaging manifest 与 LinkDigest receipt，因此必须先获得用户确认、确认时间戳备份已创建，并在测试结束后使用“恢复备份”回到原 Host。不要把裸沙箱 GUI exit 1 当成产品失败，也不要在未确认和无恢复路径时直接操作日用 Profile。

## 任务：公众号图文主体与 CDN 图片防盗链修复

- 日期：2026-07-21
- 当前状态：**两个显示 bug 的最小源码修复、扩展定向测试、Debug 构建与指定本地调试产物部署完成；仍需在 Brave 扩展页手动重新加载，并用真实公众号样本做最终人工观察。** 未修改正式 `~/Applications`、抖音活动视频锚定、session-detail iframe fetch、`RemotePlaybackAsset`、合同、数据库、依赖或 Brain。
- 场景 → 角色与交接：Brave 扩展从 `#js_content/#img-content` 读取公众号正文，把 `img[data-src]` 转成 Markdown 图片并随 V2 页面事实交给桌面端；桌面端把有实质正文的 WeChat 记录判为“文章主体”，先显示阅读页，再显示内嵌视频，同时在标题下的元数据区保留视频类型、时长和格式/大小。图片暂存器从 Markdown 提取绝对 HTTPS URL，按 CDN host 附加浏览器 UA 与站点 Referer，再由安全资源请求链下载到本机缓存；失败只丢图片，不影响正文与历史入库。
- 技术取舍：保留 WeChat 的 `MediaDescriptor`，不把 V2 降回 V1，也不删除内嵌视频；只改变桌面端顺序和图片暂存门禁。这样视频仍可在当前会话速览/保存，而文章不会被大播放器淹没。纯抖音/普通视频继续跳过装饰性图片；共享策略会先剥离图片 Markdown、HTML 图片和裸 URL，只有 `platform=wechat` 且实际字母数字正文不少于 40 字符时获得例外，图片-only 海报不会因长 CDN URL 被误判成文章。
- 核心名词与目标等级：沿用已有 **MediaDescriptor（L3）** 与 **CaptureEnvelopeV2（L3）**。本轮一次性认识 **Referer（L1）**：像 CDN 检查的来访凭条，缺失时微信/抖音 CDN 可返回 403；**User-Agent（L1）**：像浏览器工牌，和 Referer 一起放在图片安全资源请求头。两者只服务当前 HTTP 兼容点，因此不扩 `GLOSSARY.md`。
- 自动证据：`pnpm exec vitest run tests/extract.test.ts` **16/16 PASS**，锁定公众号 `data-src → ![alt](url)`；`pnpm build` PASS，产出 `background.js`；Swift Debug `swift build --disable-sandbox --package-path apps/desktop -c debug` PASS，覆盖 `GitHubRepositorySourceAdapter`、`ManualLinkViewModel`、`LinkDigestApp` 与 `HistoryContentView` 编译。两处扩展部署文件 SHA-256 均为 `7f3375bffd832df547dae1995aa5ece4a55add5c278c9c8b9c8b5cf2ec581551`；Debug App 重签后 `codesign --verify --deep --strict` PASS 并已重开。
- 测试边界：Swift 定向 XCTest runner 被本任务外的本地转写协议旧签名阻断：`AppleSpeechVideoTranscriberTests.swift` 缺少现有 `workspaceURL` 参数，`HistoryViewModelTests.swift` 的两个 fake transcriber 也未实现该参数；未越界修改这些测试。单独构建 test targets 时，本轮 `GitHubRepositorySourceAdapterTests.swift`、`ManualLinkViewModelTests.swift` 与 `HistoryContentViewTests.swift` 均已进入编译，最终只在上述旧签名处失败；产品源码已成功构建。扩展额外 typecheck 被本任务外、且明确禁止改动的抖音 stats optional 类型错误阻断。误跑的扩展全量中，本次公众号测试通过，7 个失败均在既有 `background-douyin.test.ts` 的锚定/调用次数断言，本轮未修改。
- 失败与恢复：微信图片请求仍被拒时，正文继续可读；检查目标 URL host 是否落在 `qpic.cn/qlogo.cn/qq.com` 后缀映射并重新发送。视频地址失效时只影响次要媒体区，回到浏览器重新发送即可。撤回时只反向移除本任务的文章优先条件、顶部视频摘要、WeChat 图片暂存例外、图片请求头映射与对应测试/本段日志；不要恢复或覆盖工作区其它 dirty 内容。
- 可选跟做（5–10 分钟）：在 `brave://extensions` 重新加载 LinkDigest，重新发送一篇带视频和 `mmbiz.qpic.cn` 图片的公众号文章；观察顺序应为“顶部属性/视频摘要 → 图文正文 → 次要视频区”，图片应逐张出现。再打开原抖音样本确认当前视频标题/作者仍跟随滚动项、播放仍可用。该观察是理解入口，不是源码完成的作业门槛。

### 追加：抖音简介重复展示去重

- 现场根因：抖音捕获正文保存为 `# title + description`，当二者相同时，History 的独立页面标题、Markdown 标题和普通 description 共显示三遍。捕获数据本身仍用于搜索、总结与导出，不在扩展端删除。
- 最小修复：`CapturedSourceBodyPresentation` 忽略 Markdown 标记、空格与标点，把抖音正文与页面标题规范化比较；正文只是标题重复一次或多次时，History 不创建阅读卡。若 description 含标题之外的新字符，阅读卡仍显示；非抖音平台永不命中该去重门禁。
- 验证：新增 pure projection 测试覆盖“重复两遍隐藏 / 多一段新信息保留 / WeChat 不受影响”，`HistoryContentViewTests.swift` 已进入 test target 编译；test module 最终仍被任务外 `HistoryViewModelTests.swift` 两个旧 `LocalVideoTranscribing` fake 缺少 `workspaceURL` 参数阻断。Swift Debug 产品 build PASS，`git diff --check` PASS。
- 失败与恢复：误隐藏时只需让 description 带上标题之外的真实正文即可恢复显示；撤回本追加只需移除 `hasPresentableSourceBody/showsReadingSurface` 门禁、pure projection 与对应测试/本段记录，不改捕获、抖音锚定、媒体下载或播放。

### 纠正：公众号不展示内嵌视频

- 产品结论：公众号记录是图文来源，正文图片属于文章内联内容；页面中的 `<video>` 不再升级整条记录为视频 V2，也不显示播放器、视频失败提示或顶部视频元数据。此前“正文在前、视频降为次要区块”的取舍被真实界面证据推翻。
- 根因与交接：插件原来先提取正文，再无条件把 `detectMediaInPage` 的命中附加到 generic capture；这不是完整的 article/video/image classifier，只是“正文 + 可选媒体附件”。现在 `attachDetectedMedia` 在交接前拒绝 `platform=wechat` 的媒体附件，抖音 hard fork 不经过该规则；App 同时以 `suppressEmbeddedMedia` 防御旧扩展或旧当前会话传来的 WeChat media。
- 验证：扩展定向 **17/17 PASS**，覆盖 WeChat media 被抑制、generic media 仍保留；WXT production build PASS；Swift Debug 产品 build PASS；`HistoryContentViewTests.swift` 已进入 test target 编译，最终仍被任务外 `HistoryViewModelTests.swift` 两个旧转写 fake 缺少 `workspaceURL` 参数阻断；`git diff --check` PASS。
- 边界与恢复：没有新增跨语言 `contentKind` 字段或修改合同；若未来要支持公众号纯视频产品形态，应单独版本化该分类，而不是重新启用“发现任意 video 即附加”的旧逻辑。撤回本纠正只需移除扩展 merge 门禁、App 防御门禁、对应测试与本段记录。

### 追加：详情内容柱居中与抖音互动属性

- 场景与布局：详情内部仍使用 `maxWidth=680` 的左对齐稿纸，但外层从 leading 改为 center，固定左右边距合并为对称 horizontal padding。窗口拉宽时内容柱保持居中，正文自身仍按阅读习惯左对齐。
- 数据交接：当前视频 identity container → bounded DOM stats（feed/browse/video selector 或同容器 aria-label）→ locked `aweme_id` SSR stats → defined-only merge → Markdown frontmatter 的 `likes/comments/shares/collects` → `MarkdownNoteFrontmatter` → 顶部 engagement strip。App 同时允许“只有互动字段、没有作者/发布时间”的属性条显示。
- 安全门：多视频页面绝不使用 document-wide 计数；active scope 缺字段时宁可缺失，也不从别的卡片补数。MAIN-world stats 函数保持 self-contained，不调用模块 helper；SSR 只接受相同 `aweme_id`，空壳候选继续寻找，同 ID 有效候选逐字段聚合，只有定义值才能覆盖 DOM fallback。
- 自动证据：新增 stats focused **4/4 PASS**，覆盖 active scope、另一卡片污染、document 全局 999 不回填、partial SSR defined-only merge 与注入自包含门；公众号/通用提取 **17/17 PASS**；TypeScript typecheck、WXT build、Swift Debug product build、Core test target（含四互动字段 parser）和 `git diff --check` PASS。App test target 的新布局测试已编译，最终仍被任务外 `HistoryViewModelTests.swift` 两个旧转写 fake 缺少 `workspaceURL` 参数阻断。
- 人工观察：内容柱居中对已有记录立即生效；历史记录没有保存过的互动字段无法凭空补回，必须在重载扩展后重新发送抖音当前视频，才会看到点赞、评论、分享、收藏。平台未公开某项计数时保持缺失，不显示假 `0`。
- 恢复：撤回时只反向移除 center frame/对称 padding、属性入口条件、bounded stats fallback/defined merge、对应测试与本段记录；不得回退当前视频锚定、session-detail iframe fetch 或媒体播放请求头。

## 任务：统一模型设置、本机 OCR 与在线分片转写

- 日期：2026-07-21
- 当前状态：**源码实现、Debug 产品构建与 108 项相关定向测试已通过；当时等待 Debug App 部署后的真实设置页、公众号 OCR 和大抖音视频在线转写人工观察。后续 daily Release 已部署，详见“日用 App/扩展部署：用于抖音元数据复测”。** 历史工程阶段未读取真实 API Key、Keychain 值、浏览器 Cookie/Profile 或用户数据库，未修改公众号/抖音提取算法、`RemotePlaybackAsset`、正式 App 或 DMG。
- 场景 → 角色与交接：网页正文由扩展/手动抓取交给本机 History；用户点总结或翻译时，正文经已确认的数据去向交给 OpenAI-compatible `/chat/completions`。视频默认由 AVFoundation 提取音频并交给 Apple Speech 本机识别；超过 200MB 的直连视频可在用户二次确认后，由 `OpenAICompatibleAudioTranscriber` 带站点 Referer 流式读取音轨、在临时目录切成 5 分钟 M4A，再逐片交给 `/audio/transcriptions`，最终文字沿既有 task transcription transaction 保存成最新原文。正文缓存图片由 Apple Vision 在本机 OCR，当前结果可阅读和复制，不上传原图。
- 设置页取舍：水平 Tab Form 改成左侧导航；“模型与识别”先显示总结/翻译、视频转写、图片 OCR 三张能力卡，再以 App 内置字标色块呈现 OpenAI、DeepSeek、DeepInfra、OpenRouter、Groq、SiliconFlow、阿里云百炼、智谱、Ollama 和自定义。字标不联网加载第三方 logo，避免设置页追踪与商标素材许可不清。Base URL、总结模型、翻译模型和在线转写模型分别呈现；Key 继续只进 Keychain。`/models` 只有在官方推荐模型真实出现在账户清单或清单仅一项时自动选择，不任意选第一个模型。
- 新名词与理解：**OCR（L3）** 是本机看图抄字；**ASR（L3）** 是把人声变成文字；**Multimodal/多模态（L1）** 表示模型能直接接收图片/音频等不同输入，本轮没有把原图或整段视频塞进聊天模型；**Base URL（沿用 L3）** 是 API 根地址；**Provider Preset（沿用 L3）** 是不含 Key 的服务地址模板。
- 安全边界：在线转写必须每次确认；完整视频与带签名视频 URL 不发送给模型商家，临时分片结束后删除；请求使用 ephemeral session、无 Cookie/缓存、Bearer Key 只在短时局部变量，跨 origin redirect 被拒。OCR 不创建网络请求。在线接口返回 404、鉴权失败、额度/模型拒绝和网络中断均映射为固定本地文案，不显示响应正文。
- 自动证据：Swift Debug product build PASS。`HistoryContentViewTests + HistoryViewModelTests + ProviderPresetTests + ProviderSettingsViewModelTests + RecognitionAdaptersTests` **108/108 PASS**；另有 ModelPreferences/Provider store 迁移与 round-trip **6/6 PASS**。为恢复 test target 编译，只同步修正同一转写协议范围内 1 个 Apple Speech 测试和 2 个 fake 的 `workspaceURL` 参数，没有改生产 Apple Speech 算法。`git diff --check` PASS。
- 失败与恢复：没有在线转写模型时菜单项禁用；端点没有 `/audio/transcriptions` 时提示切换兼容服务；CDN 音轨读取失败或地址过期时回浏览器重新发送；任一分片失败不会保存半份正文。OCR 无文字时保留原图和原文。撤回时移除在线转写适配器/偏好字段/入口与 Vision OCR 卡即可，既有本机 Apple Speech、总结/翻译、Keychain 配置不受影响。
- 可选跟做（5–15 分钟）：打开设置 → 模型与识别，选择服务商、填 Base URL/Key、点“验证并配置模型”，在生成偏好填写在线转写模型并保存。公众号记录点“识别文字”观察本机结果；超过 200MB 的抖音直连视频从“转写”菜单选“在线转写”，确认上传后观察分片状态和最新原文。该观察用于理解和真实服务验收，不是源码完成的作业门槛。

## 纠正：Brave Native Messaging 共享 Chrome active target

- 日期：2026-07-21
- 场景 → 角色与交接：Chrome 与 Brave 在 Settings 中继续是两条便于用户操作的支持行；`BrowserSupportViewModel` 把任一行的动作交给 `BrowserSupportInstaller`，后者把 Brave 的新 install/inspect/repair/uninstall/restore 解析为 Chrome active key 和 `Google/Chrome/NativeMessagingHosts` leaf，再由唯一 `chrome` receipt entry、backup 与 journal 交接所有权。Edge 保持独立。像两个门铃接到同一户门：任一门铃都能触发同一份登记，不能各自登记一份不同地址。
- 现场事实与根因：Brave 150.1.92.141 的 LinkDigest popup 在抖音 V2 样本和公众号图文 V1 样本中都报 `native_transport` / `NATIVE_HOST_NOT_FOUND`；公众号已成功提取 15009 字符，因此这两份跨合同版本、跨内容适配器的样本共同把失败定位到 Native Messaging 交接点，而不是抖音/公众号适配器或 V1/V2 合同。Brave 自有目录的 leaf 指向当前 Host，但 Google/Chrome 目录的 leaf 指向已删除旧 Host；Brave 官方 macOS 启动路径使用后者，原先 App 因检查 BraveSoftware leaf 而假绿。
- 工作流/工具协同：冻结资源仍由 `BrowserSupportInstaller` 校验；Swift fixture 只在 `/private/tmp` 隔离 HOME 验证 Chrome→Brave、Brave→Chrome 的第二次动作 no-op 且 mtime 不变，漂移修复、卸载与恢复同步两行，并验证 legacy `brave` receipt + BraveSoftware leaf 不能授权接管 unknown Chrome manifest。开发 install/uninstall、stable clean-room、release policy/preflight 与总检指南共同使用同一 shared target；旧 `brave` key/leaf 只保留 decode/recovery，既不静默删除，也不显示为当前已安装。
- 自动验证与未完成项：定向 `BrowserSupportInstallerTests` **30/30 PASS**、`BrowserSupportViewModelTests` **5/5 PASS**（均使用 `/private/tmp` Swift module cache）；`bash scripts/native-host/check-dev.sh` PASS，`python3 scripts/native-host/release_preflight_check.py` **101 assertions PASS**。`stable_host_check.py` 在受限环境的 Node Unix socket bind 报 `EPERM`，因此未完成；它记录的真实 HOME metadata digest 前后相同。真实 Brave 修复仍未执行。r2 transaction matrix 与 r4 release-unit/local-test probe 仍保留 legacy independent-Brave role，不能证明 active shared mapping，必须在下一次 candidate freeze 前完成版本化 release-contract 迁移。恢复路径是：若真实 Brave 仍无法连接，先在 App 的 Chrome 或 Brave 任一行检查/修复 shared active leaf；不要手删 legacy Brave leaf、backup 或 receipt entry，保留现场后再诊断。

## 日用 App/扩展部署：用于抖音元数据复测

- 日期：2026-07-21
- 当前状态：**日用 App/扩展已部署，Host 修复和人工抖音验收待完成；数据库回滚边界未关闭。** 启动 daily App 后发现本机数据库从 `user_version` 3 迁移到 8；本次仅复核版本与 WAL metadata，未读取正文。未读取或修改浏览器 Profile/Cookie、Keychain、Provider、Native Messaging manifest 或 receipt；没有 commit、push、发布或 DMG。
- 场景 → 角色与交接：旧 r2 Debug App 先退出，日用 App 与扩展先完整备份；`build-and-deploy-local.py` 在 `/private/tmp` 完成 WXT、合同同步、Swift Release、Host 装箱与 ad-hoc 签名后，才原子交换 `/Users/song/Applications/LinkDigest.app` 和 `/Users/song/Applications/LinkDigest-extension-0.2.0`。用户随后从日用 App 的 Browser Support 主动触发“修复”，由既有 installer 在其 own/backup/receipt 规则下把共享 Chrome/Brave Host 指向同一套日用产物；本次没有越过该交接手改它。
- 备份与恢复：no-clobber 备份为 `/Users/song/Applications/LinkDigest-deploy-backup-20260721T131737`，其中 App `codesign --verify --deep --strict` PASS，bundle `com.syc.linkdigest` / `0.2.0`；备份扩展为 MV3 `LinkDigest` / `0.2.0`，固定 public manifest key，核心 SHA-256：App executable `bd78d636627c26d7b716435716b6226f8a20870ae141abb0647b472f7f4d8f22`、manifest `4ce33c8fbdb6a0099d8706320af1f83c506b5166e33362e33c3c4ff9306e7401`。该备份只支持 App/扩展二进制恢复；部署前没有 pre-migration 数据库备份，**禁止直接回滚旧 App 并假设数据库兼容**。不得删除备份、手改 manifest/receipt 或清理用户数据；数据库回滚需要单独的兼容性与恢复方案。
- 构建与校验证据：部署脚本成功完成 WXT production build、固定 extension ID `fbpjhlcpfheecigibjghhodhhkgjdgma` 工件、Swift Release build、Host package、ad-hoc sign 与原子替换。部署后日用 App/扩展均为真实目录而非 symlink；`codesign --verify --deep --strict` PASS，bundle `com.syc.linkdigest` / `0.2.0`；Host 可执行文件存在且可执行于 `Contents/Resources/NativeHost/LinkDigestNativeHost-0.2.0-macos-arm64/LinkDigestNativeHost`。扩展为 MV3 / `0.2.0`、含 `nativeMessaging`、manifest key 与 `config/extension-identity.json` 一致；安装 manifest/background SHA-256 分别为 `b1f1af15d53197c698af61acbf919684f5ea062ca693ad83d816fc9a55e13fb6` / `70979b8bad2bc18ea8a5a3560a2ffd75d35b12f3c5f36b7468aab7e283065a10`，与 `apps/browser-extension/.output/chrome-mv3` 完全一致，目录逐文件比较 PASS。`contract-sync: OK` 与 `git diff --check` PASS；工作区原有合同/生成文件 dirty 状态仅报告、未清理。
- 当前 Host 未修复与用户下一步：只读确认 Chrome/Brave shared Native Messaging manifest 仍指向旧 `/tmp/LinkDigest-Debug-BraveShared-20260721-r2/LinkDigest Debug.app/.../LinkDigestNativeHost`，因此新日用扩展尚不能靠它把捕获交给新日用 App。Syc 下一步是在新 App 的 Browser Support 中，对 Chrome 或 Brave 任一行主动点击一次“修复”，再在 Brave 扩展页重新加载 LinkDigest，打开一条抖音详情并发送，观察作者、发布时间、点赞/评论/分享/收藏是否进入 History。这个人工观察不阻塞已完成的部署，但它是两项 P2 元数据证据补强的入口。

### 返修追加：真实抖音单页缺失发布时间与互动字段

- 日期：2026-07-21
- 截图证据与已知现象：日用 App/extension 捕获 `https://www.douyin.com/video/7645705016711384362` 时，作者与播放能力已成功进入展示链，但发布时间、点赞、评论、分享、收藏缺失。该截图只证明“字段缺失、Swift 展示链已生效”，不构成修复后人工通过证据；当前环境没有可用的 `computer-use` runtime，公开 HTML 也未取得。
- 角色与交接：content script 先锁定 URL 的 aweme ID 与当前 DOM 视频。已有带同 ID 的 `safeItemScopes` 继续独占作者；只在精确 canonical `/video/{id}`、无 query item ID、并且一个视频可视面积唯一或至少为第二名四倍且占视口 20% 时，identity-less `dedicatedMetadataScopes` 才把日期与互动计数交给同一份 metadata。background 的 MAIN-world 读取器再从固定 globals、`RENDER_DATA`、`__NEXT_DATA__` 和同名精确 ID 的 JSON 根中，按相同 aweme ID 合并定义字段；最终仍由既有 frontmatter/Swift 展示链呈现。
- 安全门：feed/modal URL、接近大小的双可视视频、scope 内第二个可视视频、冲突 ID、超过 120 个 identity 节点、无可枚举节点均 fail closed；作者从不走 dedicated fallback。MAIN-world 不扫任意 inline script，不读 Network/Cookie/storage/performance；每个脚本最多 2 MiB、脚本总量最多 4 MiB、最多 8 roots，且 depth/enqueue/dequeue/visited/child examination 在全部 roots 间共享 1200 上限。真实 `0` 与已定义字段可合并，错误/缺失 ID 不贡献字段。
- 自动证据：`background-douyin.test.ts` 定向回归为 **9 files / 133 tests PASS**，覆盖 canonical identity-less 成功、feed/modal 拒绝、接近双视频拒绝、冲突 ID、旧 A/B 与第 121 identity 拒绝、allowlisted globals/scripts、encoded `RENDER_DATA`、malformed/oversize/wrong ID、1201st traversal 拒绝，以及 directFile 仍使用 DOM playback、只补 MAIN metadata、不会调用 session-detail 或标记 `usedCookie`。
- 部署与人工验收待做：本次只改扩展源码/测试/本学习记录，未部署、未改 App/manifest/receipt、未读取 Profile/Cookie/Keychain/Provider/用户数据库。需要先按上一节的既有 Host 修复与扩展重新加载步骤，再用上述真实 URL 新捕获，观察五个字段；旧截图/旧 History 记录不会自动补填，必须重发。若字段仍缺失，应保留脱敏截图和当前 UI 状态后继续诊断，不把本段自动化证据写成真实人工通过。

### 首轮抖音元数据 Review 返关

- Review 发现与修复：首轮 reviewer 指出两类 P1/P2 风险：safe/dedicated 两套 identity descendant selector 没有覆盖相同 URL 形式，且 metadata SCRIPT source/UTF-8/own-ID 边界仍可被不严格形态绕开。本轮将所有 scope 共用同一 identity selector，覆盖全部既有 data attributes 与 `/video/`、`/note/`、`/share/video/`、`modal_id/aweme_id/item_id/video_id/group_id` 链接；canonical fallback 在把 NodeList 转成数组前拒绝超过 1000 个视频。MAIN-world 只接受 `tagName === SCRIPT` 的 exact-ID element，以 `TextEncoder` 的 UTF-8 bytes 执行 raw/每次 decode/累计上限，并要求对象 own `aweme_id`/`awemeId` 至少一项存在、每一项都是同一个 locked string。
- 返关证据：新增 A dominant video + shared ancestor 隐藏 B `/note/B` 与 `item_id=B` 的回归，B 的 author/time/stats 均不会进入结果；1001 video、same-ID DIV、约 70 万 CJK 字符、numeric/empty/conflicting ID aliases、跨 roots 共享 1200 预算均拒绝。`extractDouyinMetadataFromInitialStateInMainWorld.toString()` 经 `new Function` 重建后仍成功读取合法 metadata，证明注入函数自包含而非只靠源码文本断言。定向结果为 **9 files / 139 tests PASS**；全量 extension、typecheck、production build 与 diff 门禁仍待本轮后续执行。
- 真实验收状态：这些证据只关闭源码审查项，不等于真实抖音页面已通过；不部署、不读浏览器 Profile/Cookie/Keychain/Provider/用户数据库，仍须在获授权的既有 daily Host 修复与扩展 reload 后重新发送样本。

### 返修追加：抖音元数据缺失的 popup-only 脱敏诊断

- 当前状态：**源码与自动化验证完成，尚未部署，也尚未在真实抖音页面确认修复通过。** 本轮不改变既有 DOM/SSR 取数、视频选择或 fail-closed 路径；不改 Swift、跨语言合同、schema、Native Host 或数据库。
- 场景 → 角色与交接：当一条单视频页缺发布时间或任一互动字段时，已有 DOM 读取器只额外交出“是否命中”的计数/位图，MAIN world 在同一批 fixed roots + BFS 中交出同样有限的 SSR 观察值。background 先照旧合并真实 metadata，再计算缺失位；只有仍缺失时才把 `DouyinMetadataDiagnostic` 交给 popup。它像体温计只报温区，不把病历交出去：`DouyinCaptureAttempt` 是旁路交接，`CaptureEnvelope` 仍是唯一 native wire 交接物。
- 新名词（L2）：**allowlist sanitizer** 是一份只准许固定形状字段通过的门卫；本项目位于 extension content/background 边界，不用它就可能把页面文字或 URL 当诊断带进 popup。**位图** 是用四个固定开关表示点赞/评论/分享/收藏哪些缺失，像四盏故障灯，不记录其数值；位于 popup formatter 输入，避免扩大跨语言协议。
- 隐私与失败表现：诊断只允许 route/video/scope/SSR 的固定码、布尔和范围受限整数；净化器逐字段重建、忽略未知字段。未知/非法码在 UI 仅显示“未知安全码”，不回显原始值。完整 metadata 时诊断隐藏；发送时进行新鲜捕获，并更新或清空独立 `<pre>`。`sendNativeMessage(HOST_NAME, wireEnvelope)` 的第二参数始终只有 wire envelope，V1/V2 降级与截断同样不会携带任一 diagnostic；本抖音路径不输出 console 诊断日志。
- 自动证据：新增 sanitizer sentinel/JSON 审计、范围/枚举拒绝、partial/full/unknown 固定中文 formatter，以及实际 `sendCapture` 的递归 wire 检查。MAIN 注入函数以 `toString()` + `new Function` 重建后仍读取合法 metadata，并在同一次 roots/BFS 返回 `exactHit` 与 limit/reject 码。
- 可选跟做（5 分钟）：重新加载后打开真实单视频页；若预览缺字段，popup 会出现“元数据诊断（仅当前弹窗，不发送、不保存）”，可观察缺失项与 DOM/SSR 命中数量。点击发送后它会按新的当前页面结果刷新；此观察不是本轮工程完成的前置条件。

### 最终复核返修：native wire、popup 新鲜状态与原型安全

- 修复交接：native 交接继续只接收 `wireEnvelope`，但这次以实际 `sendCapture → sendNativeMessage` 第二参数逐条验证 V1、直连 V2、无效 V2 降级、超 3 MiB media 剥离，以及第二次新鲜发送；诊断对象内的 URL/title/author/time/count/raw JSON/DOM/selector/host/Cookie/storage/network sentinel 都不能出现在 wire。正文等业务字段仍按合同允许传输，测试不会把它们误当隐私旁路。
- popup 状态机：预览可显示诊断；用户点击发送后在 await 前立即隐藏并清空 `<pre>`，成功只显示本次新鲜结果，异常也保持清空。完整 metadata（无发布时间缺失且缺失位图为 0）返回 `null`，不会显示“缺失项：无”。这像寄快递前先取下旧的便签，只等本次包裹检查完成后再贴新便签。
- 安全细节：五类诊断码表均使用 null-prototype map + `Object.hasOwn` 查询；普通未知值及 `constructor`、`toString`、`__proto__` 等原型键一律显示固定“未知安全码”，不回显输入。顺带机械修复全仓五处 lint（无用 host 初值、两处解构未用变量、末位排序自增、未用测试 import），不改变抓取或媒体行为。
- 自动验收与真实状态：extension 全量 **12 files / 147 tests PASS**，typecheck、production build、lint、shared tests、identity artifact check 与 `git diff --check` 均通过；执行级 popup reject 测试验证“预览显示 → send pending 已清空 → reject 后隐藏/空”，native 参数化和 truncation fail-closed 测试覆盖上述路径。完整 `pnpm check:web` 已实际运行到 doctor：仅被两个本任务外的既有门禁阻断，`r4b local-test` 的 frozen r4a `apps/desktop/Assets/AppIcon.icns` compatibility hash drift，以及 `ProviderSettingsViewModel.swift` 的 `unknown-code-visible-sink` secret-hygiene rule；本轮没有越界改动 desktop/release 配置来掩盖它们。尚未部署、未读取 Profile/Cookie/Keychain/Provider/真实数据库，也未在真实抖音页面宣称通过；真实页面仍需在扩展重载后由 Syc 自主观察。

## 任务：桌面端 UI 第一轮修复（favicon、阅读与三栏导航）

- 日期：2026-07-21
- 场景 → 角色与交接：History 左栏把用户选择的“全部 / 最近 / 未总结 / 平台 / 标签”交给 `HistoryViewModel`，它将 `HistoryListFilter` 交给 `HistoryApplicationService`，再由 GRDB 在 SQLite 内组合平台、标签、时间范围和搜索条件；中栏只接收分页结果，右栏只展示选中详情。图标路径则由 `HistoryViewModel` 最多并行 6 个 favicon 请求，逐个把安全获取到的本地 URL 回填给列表；`WebsiteFaviconCache` 负责正/负磁盘缓存，SwiftUI 的进程内缓存负责已解码位图。
- 核心名词：**负缓存（L3）** 记录“这个 host 暂时没有可用 favicon”，像快递站记录某地址今天无人签收；24 小时内不再重复等网络超时，过期后才重试。**SQLite 聚合（L3）** 是让仓库直接数出平台/标签/未总结数量，像让仓库管理员报库存，不把所有箱子先搬到前台。**host 归一化（L2）** 把 `www.`、`www2.`、`m.` 等同站前缀收为一个站点名，避免同一来源分散成多项。
- 实现选择：favicon 失败写入同样受 30 天留存和 128 host 上限治理的 `.miss` 标记；内置 SVG 优先于网络 favicon，未知来源稳定显示 host 首字母彩色标记。标题改为 22pt、自然高度超过三行时才在固定三行高的内层滚动区阅读；总结/正文 picker 只要任一内容存在即固定展示，空 pane 给出“尚未生成总结”或“本条没有抓取到正文”。`isRedundantDouyinBody` 仍只影响默认 pane，不再隐藏有 frontmatter 价值的正文。
- 自动证据：`swift build 2>&1 | tail -20` PASS（仅既有未使用 `videoURL` 局部变量 warning）。相关 `swift test --filter "(HistoryContentViewTests|HistoryTagPersistenceTests|GitHubRepositorySourceAdapterTests)"` **58/58 PASS**，覆盖负缓存 TTL、6 路 favicon 调度与 generation guard、SVG/host 归一化、三行标题、固定 picker、SQLite 导航计数、未总结 `NOT EXISTS` 与平台+标签+搜索 AND。完整 `swift test 2>&1 | tail -40` 实际执行，但 **507 tests / 9 failures**：均在本任务明确禁止修改的 V2 临时播放地址/媒体持久化隔离既有测试；本轮未触碰播放链路。装箱图标集静态校验确认 `release_unit.py`、`local_test_release.py` 的 `PLATFORM_ICON_FILES` 与 `Assets/PlatformIcons` 实际集合一致。
- 失败与恢复：host favicon 不可用时 UI 立即使用确定性的首字母标记；如果站点后来提供图标，负缓存 TTL 到期后会自动重试。SQLite 只读或不可用时导航计数返回空值，不阻断原列表。若需撤回，本轮只反向移除 favicon 缓存/导航过滤/阅读 pane 与对应测试；不要改动 browser-extension、`MediaDescriptor`、`publishedAt`、`DouyinSessionDetail` 或任何播放 URL 白名单。
- 可选跟做（5–10 分钟）：在 History 中打开一条没有总结的记录，确认“总结 / 正文”仍在且点总结显示提示；再切换左栏“未总结”、任一平台和一个标签，观察中栏为空时显示“该分类下暂无内容”。这用于共同观察，不是任务完成前置条件。

## 任务：桌面端 UI R4（长任务生命周期、原文流式展示、自动保存与批量删除）

- 日期：2026-07-21
- 场景 → 角色与交接：App 启动门闩只把同一 `HistoryApplicationService` 配置一次；`HistoryViewModel` 为转写和 OCR 保存 owner TaskID，因此用户切换窗口、侧栏或选中条目时，长任务仍继续并把结果交还发起条目。History 列表把原生 `Set<TaskID>` 选择集交给删除确认层，后者先排除 Run、转写与 OCR 中的受保护任务，再把可删除集合一次交给仓储事务。
- 工作流与工具协同：转写 partial/final 都进入“原文”阅读 pane，视频卡只保留状态、进度与取消动作；`MarkdownPresentation` 的共享正文常量同时服务 Markdown、流式转写和 OCR。设置页的“抓取视频后自动保存到本地”默认关闭，开启后只对当前捕获中的可直连视频复用既有 `ingestCapturedMedia`，仍经过保存上限与磁盘预检，临时播放 URL 不入库。
- 核心名词与目标等级：**Selection Set / 选择集（L3）** 表达 0/1/多条原生选择；**Task Ownership / 任务归属（L3）** 把异步状态和结果固定到发起 Task；**Batch Delete Transaction / 批量删除事务（L3）** 让一组数据库删除整体提交或整体回滚；**Typography Token / 排版常量（L3）** 让流式与最终正文共享同一排版尺度。启动幂等沿用既有 Idempotency 概念。
- 自动证据：14 条本轮新增测试均已逐条单独跑通；`HistoryContentViewTests` **46/46 PASS**，浏览器扩展 **12 files / 156 tests PASS**，隔离缓存下 Swift Debug build PASS。仓储测试覆盖 missing ID 的部分失败报告和第二条删除触发异常时整组回滚；ViewModel 测试覆盖重复 configure、跨选择转写/OCR 归属、受保护任务跳过、部分失败文案，以及自动保存失败可见、后台完成不接管当前选择。
- 图标边界：仅尝试平台自身公开入口；当前执行环境禁止取得官方二进制资源，因此按 R3 降级规则保留抖音、小红书、微博、头条、豆瓣现有手绘 SVG，未用第三方或仿制资源顶替。现有 14 个资产已通过与 App 相同 AppKit crisp 路径的 16×16 拼图自检，无空白或黑块；这项不宣称官方位图替换完成。
- 失败与恢复：完整 `swift test` 在当前外层沙箱中会因本机 socket bind、Keychain 与缓存权限产生环境失败，规定的原始 Swift 命令也无法写 `~/.cache/clang`；报告保留真实末尾输出，并另列 `--disable-sandbox` 加 `/private/tmp` 缓存后的构建与定向绿灯。批量删除若仓储抛错会整事务回滚并如实显示失败数；自动保存失败沿用已有保存错误与重试通路。撤回时只反向移除本轮门闩、owner 状态、共享排版、自动保存偏好、批量删除入口和对应测试，不改抖音提取、播放准入、互动数据、原文选择规则或 V2 临时 URL 隔离。
- 可选跟做（5–10 分钟）：在一条视频开始转写后切换到另一条，再切回观察文字仍持续写入原文 pane；随后 Cmd 选中多条记录并尝试删除，确认运行中的条目在确认框中标为跳过。该观察是共同理解入口，不是任务完成条件。

## 任务：UI R2 — 抖音元数据、转写原文与本地媒体边界

- 日期：2026-07-21
- 场景 → 角色与交接：扩展先在固定 SSR 根中以有界 BFS 寻找锁定 `aweme_id`，并只在同一安全条目作用域内给互动数字补上语义标签；它交接的仍是 metadata，不改变发布时间或播放准入。桌面端把抖音“原文”改为只读已保存的本机转写，临时视频下载交给 `TranscriptionTempStore`，音轨导出后再交给 `AppleSpeechVideoTranscriber`，最终清理整个 attempt 目录。
- 核心名词：**BFS（L3）** 是逐层翻找固定资料柜，像从外层抽屉到内层抽屉找同一编号；20,000/16 的边界防止一页状态无限占用时间，完整 author/stats/createTime 一旦齐全就提前交卷。**语义信号（L3）** 是数字旁“点赞/评论/分享/收藏”的用途标签，像仓库箱签；没有箱签的 `999` 不会被猜成互动数。**attempt-scoped（L3）** 是一次转写专属的临时文件夹，像一次性工作台，成功、失败或取消都收走视频和 M4A，不进入 `Media/`，也不建立 `MediaAsset`。**音轨导出（L2）** 是从视频取出更轻的人声文件；导出失败时仍把原视频交给本机识别，不改用在线转写。
- 技术取舍：永久本地媒体仍是 200MB；仅本机转写临时输入是 2GB，并在磁盘空间不足时明确提示。在线 `OpenAICompatibleAudioTranscriber` 没有接入这条链路，因而本机转写不会上传音频。抖音没有转写时不会显示“原文”分段；若没有总结，则保留“尚未转写 / 点击上方的『转写』开始”的空状态。非抖音来源保持原有正文行为，互动属性仍在阅读区上方。
- 图标边界：仅查询各平台自己的 favicon/manifest/CDN。掘金官方 CDN 的 `safari-pinned-tab.svg` 已转为本地 16×16 path-only 资源；抖音、小红书、微博、头条、豆瓣公开入口只提供 ICO/PNG，未用第三方仿制或运行时网络资源，保留现有本地 SVG 并记录为待官方矢量源。六个文件均已渲染为 16×16 PNG；catalog/发布冻结元组契约测试通过。
- 自动证据：扩展 `pnpm typecheck` PASS，`pnpm test` **154/154 PASS**，新增 SSR 预算/提前退出、语义统计正反例、标题前缀与空回退。桌面 `swift build` PASS；完整 `swift test` 的 9 条断言仍只属于既有禁止的四个 V2 临时播放/持久化隔离用例，新增临时上限、M4A 清理、抖音转写原文和图标契约测试均通过。
- 失败与恢复：真实页面若仍没有互动字段，popup 的既有有限诊断会说明是否命中，而不会把页面正文带出；没有语义标签的数字继续显示为缺失。音轨导出失败会自动回退原视频；磁盘不足时释放空间后重新发起转写。若要撤回，只移除本轮 BFS 边界/提前退出、语义回退、抖音转写-pane 选择、临时音轨和图标替换；不要改动 `publishedAt`、播放 URL 准入、`DouyinSessionDetail` 或既有四个失败区域。
- 可选跟做（5–10 分钟）：重新加载扩展后打开一条抖音单视频页，观察有 author/stats/createTime 的页面会很快结束 SSR 查找；在桌面端选择一条带直连视频的抖音记录，未转写时只看见总结或“尚未转写”提示，点“转写”后观察“提取音频 → 本机转写”，完成后原文显示转写文字。该观察帮助理解交接，不是完成条件。

## 任务：桌面端 UI R5（默认留存完成；自动转写触发停止条件）

- 日期：2026-07-21
- 当前状态：**项目 1 工程完成；项目 2 命中任务规格停止条件后停止，项目 3 未继续实施。** 没有改动抖音提取、播放 URL 准入、`DouyinSessionDetail`、互动展示、持久化/导出临时 URL 隔离、本地保存上限或磁盘预检。
- 场景 → 角色与交接：设置存储先判断 `UserDefaults` 的键是否真实存在；新用户没有键时把“抓取视频后自动保存到本地”交给 UI 为开启，已有用户明确写入的 `false` 原样交回。像酒店默认含早餐，但住客主动取消过就尊重取消；只读 `bool(forKey:)` 会把“没回答”和“回答否”混成同一个 `false`。
- 实现与用户结果：`UserDefaultsMediaStoragePreferenceStore.autoSaveCapturedVideo` 改为 `object(forKey:) == nil ? true : bool(forKey:)`；设置 ViewModel 初值同步为 `true`，footer 明确默认开启会占用所选文件夹磁盘空间，且仍受单视频上限和磁盘预检约束。新增三条测试分别锁定“未设置=true / 显式 false 保持 / 显式 true 保持”。
- 停止原因与方案边界：自动转写要求一个全局并发 1、手动优先、自动队列上限 20、逐 Task 状态和取消语义的调度器；现有 `HistoryViewModel` 只有一组 `transcriptionState/text/taskID`、一个 `transcriptionTask` 和单例 pending context，后发请求会取消前一请求。严格实现会把单 owner 模型重构为 TaskID keyed scheduler，命中规格“若与现有 `transcriptionTask` 单任务模型冲突到需要大改架构，先停并报告方案”。因此没有留下会显示但不工作的自动转写开关，也没有开始抖音项目 3。
- 自动证据：使用 `/private/tmp/linkdigest-ui-r5-clang` 模块缓存和 `--disable-sandbox` 后，`MediaStoragePreferenceStoreTests|MediaStorageSettingsViewModelTests` **11/11 PASS**，其中本轮三条新增默认值测试逐条执行并通过；Swift Debug build PASS。扩展基线 `pnpm typecheck` PASS、`pnpm test` **12 files / 156 tests PASS**。完整 Swift 测试在外层受限沙箱执行为 **535 tests / 60 failures**，大量失败是本地 server/socket `startFailed` / `Address already in use`，不能证明规格要求的“仅既有四个用例”；请求外层放权重跑被策略拒绝，没有绕过。
- 失败与恢复：如果用户不希望以后自动保存，只需在设置里明确关闭，重启后仍保持关闭。撤回项目 1 只需把 getter 和 ViewModel 初值改回 `false`、恢复旧 footer，并删除三条默认值测试；不要清理工作区其它 dirty 内容。项目 2 继续前应先批准独立的 `TranscriptionScheduler` 设计任务；项目 3 可在停止条件解除后单独实现“冲突前停止并保留更深安全作用域”。
- 新名词与可选跟做：本轮只讲到 **显式默认值（L2）**，没有把尚未落地的优先队列/背压写入 `GLOSSARY.md`。可选 5 分钟观察：打开设置确认自动保存默认开启，关闭后重启 App 再确认仍关闭；这不是任务关闭门槛。
## 任务：R6 — App 内置 WKWebView 抓取公众号最小可行性验证

- 日期：2026-07-21
- 当前状态：**工程安全边界、10 项新增测试、完整 build/test 基线与唯一一次真实公众号验证已完成；真实样本在 1.487708375 秒命中验证页，正文 0 字符，因此可行性结论为负，不继续尝试绕过。** 完整报告见任务指定的 `report-ui-r6.md`。
- 用户场景：用户把一个公开公众号链接贴进 App，希望不打开浏览器、不依赖扩展就取得全文；本轮只验证这条最薄链路，不扩大到抖音、小红书或登录。

### 场景 → 角色与交接

```text
用户提交 URL
  → ManualLinkViewModel：只判断是否为精确 mp.weixin.qq.com
  → WeChatWKWebViewCaptureService：一次性加载、逐跳校验、等待 #js_content
  → WeChatWebCapturePolicy：只接收经类型/长度校验的 title + text
  → CaptureIngestService：沿既有顺序先提交本机历史、再发布 UI
```

- 正常交接物是 `CapturedDocument`；host、网络、超时、空正文、非法形状、内容过大或验证页都会在入库前变成固定 `ManualLinkError`。
- 其它 host 完全保留原 generic fetcher；浏览器扩展、Douyin adapter、转写、持久化、导出、批量删除和 V2 临时 URL 隔离链均未被本轮修改。

### 核心名词与理解等级

- **WKWebView（L3）**：App 内的临时网页抄录员；每次新建、隐藏运行、完成即销毁。
- **Navigation Allowlist（L3）**：初始 URL 和每次导航/响应都重新查的门卫名单；只准 `https://mp.weixin.qq.com`。
- **Non-persistent Website Data Store（L3）**：不把 Cookie/缓存留到下一次的临时访客柜。
- **Return Shape Validation（L3）**：页面只可交出 string `title/text`，多余字段丢弃、错类型或超大内容拒绝。

### 实施、验证与证据

- WebKit 配置使用 non-persistent store，禁止 JS 新窗口和媒体自动播放，关闭 legacy plug-in，非 server-trust 认证 challenge 取消；请求不使用共享 Cookie。
- 同一纯策略校验初始 URL、`WKNavigationAction`、`WKNavigationResponse` 和提取前最终 URL；允许的同 host 客户端新导航用 polling generation 让旧轮询静默退出，外 host fail-closed。
- 全局 20 秒硬 deadline；`didFinish` 后每 200ms 检查 `#js_content`；title + text 总计不超过 2,000,000 Unicode scalars；所有终态通过单一 finish gate 销毁 WebView。
- 新增 Core 6 项、Adapters 2 项、App 2 项，共 **10/10 PASS**。最终 `swift build` PASS；完整 `swift test` 为 **545 tests / 9 failures**，仍仅属于任务开始前的 4 个既有失败用例，修改前基线为 535 / 9。
- 唯一真实 URL 结果：`verificationRequired`、1.487708375 秒、验证页=true、正文 0 字符；按停止条件没有换链接、改 UA、复用 Cookie、引入登录或尝试绕过。真实样本只验证了安全失败路径，没有证明成功正文路径。
- 只读终审首次发现同 host 新导航会把旧 poll 的内部取消误报为用户取消；用 generation 修复并补测后，复审 **PASS，无阻断**。

### 决策、失败与恢复

- 当前“无登录、App 内隐藏 WKWebView”路线不值得继续产品化投入；一次公开样本迅速命中验证页，正是本轮要尽早暴露的平台风险。
- 不扩抖音/小红书，不新增登录/Cookie/验证码或规避平台限制。未来只有出现官方、合法、稳定读取方式时再评估；当前可靠入口仍是用户在已打开浏览器中主动通过扩展发送 DOM。
- `WKNavigationDelegate` 约束 navigation/redirect，不覆盖图片、脚本、CSS、XHR 等全部子资源；本轮不夸大为“所有出站 host 均受限”。
- 撤回只反向移除 R6 的 WebKit adapter、Core policy/error、手动链接分流、最小 UI 文案、验证器 mode 与对应测试/本段文档；不得 reset/stash 整个 dirty 工作区。
- 可选跟做（5–10 分钟）：阅读 `report-ui-r6.md` 的安全矩阵，再对照 `WeChatWKWebViewCaptureService.swift` 的 configuration、navigation delegate 与 finish gate。该观察用于理解边界，不是关闭任务的前置条件；不要再用真实链接尝试绕过验证。

## 任务：History 视频播放器纵向滚动路由

- 日期：2026-07-22
- 场景 → 角色与交接：用户把光标放在 History 的任一视频卡上竖向滚动时，希望阅读页移动而视频时间不跳。`VideoScrollWheelAnchor` 是覆盖三处原生 `VideoPlayer` 的透明范围标记，既不参加命中测试也不碰 AVKit；它在真正进入 `NSWindow` 后向共享 `VideoScrollWheelBroker` 登记范围。broker 在本窗口的 local event monitor 中判断手势首个有效方向：纵向把原始事件交给该锚点的外层 `NSScrollView`，横向仍原样交给 AVKit。像商场的分流员只在入口把上楼客流送往楼梯，店铺里的播放、暂停、键盘和进度条服务仍完全由店铺负责。
- 工作流与工具协同：滚轮事件 → `VideoScrollGestureAxisLock`（纵向/横向锁定，普通手势结束后保留给可能的惯性段）→ `VideoScrollWheelRoutePlanner`（共享的可测试路由决策）→ broker 找同窗口且位于 anchor `bounds/visibleRect` 的外层滚动视图 → `scrollWheel(with:)` 直接转交或放行给系统 `VideoPlayer`。新的普通 `.began` 会清除旧目标再按当前 delta 重判；无 phase 的鼠标滚轮逐事件判定。broker 有弱锚点表、离窗注销和 `isForwarding` 防重入，不重投递、不合成事件，也不依赖 AVKit 私有类名。
- 技术取舍与失败恢复：先前实测已证明最深 AVKit 内容视图会消费事件并 seek，而 local monitor 可稳定收到每个事件；因此选 monitor + 无命中范围锚点，不用 overlay 捕获或 `AVPlayerView` 子类。未做 P2 控件样式调整：`.inline` 曾造成系统图标不同步，和 P0 无关。若未来要撤回，只移除 broker、三个 anchor modifier 和对应测试；不要改播放器、seek、焦点、按键或视频资源生命周期。
- 自动证据：`HistoryContentViewTests` 新增轴向锁测试覆盖纵向带横向抖动与惯性、横向带纵向抖动、结束后的新手势重置、phase-less 逐事件判断；可执行路由测试覆盖“锚点外纵向开始后进入”、窗口/范围/隐藏/无外层滚动视图放行、重复登记、移除非活跃锚点和移除活跃锚点清锁、以及转交中的防重入。结构守卫锁定三处同一锚点、local monitor 生命周期和九轮失败方案不得回归。构建/测试实际输出见本次任务报告。
- 核心名词：新增 **Local Event Monitor / 本地事件监视器（L3）**；其余为已有 AppKit Bridge 与 AVKit 本地播放卡概念。
- 可选跟做（5–10 分钟）：运行 App 后在任一 History 视频上先竖向滚动，观察页面移动且时间不变；再横向滑动，观察系统进度擦洗仍可用。这个观察用于共同验证交接，不是任务完成前置条件。

## 任务：浅色主题切换为 Claude 编辑阅读风格

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 在日用 App 部署后进行主观视觉确认。** 本轮只修改浅色主题与阅读区排版；系统玻璃、深色主题、平台/标签、数据、抓取、模型、播放、存储和导出逻辑均未改变，也未部署或提交。
- 场景 → 角色与交接：用户在设置中选择“浅色”后，`AppearanceTheme` 把 Claude 官方公开色值与“阅读区使用衬线体”标记交给 `HistoryContentView`；它保持侧栏、按钮、日期和状态为 SF Pro/苹方无衬线，只把标记与阅读色交给 `HistoryDetailView` 和 `MarkdownContentView`。标题、正文、列表、引用、纯文本和实时转写使用 macOS 原生 serif design；代码卡仍独立使用 monospaced。历史 Markdown 和导出内容不发生改写。
- 核心名词：**Design Token / 设计令牌（L2）** 是集中保存背景、文字、边线与强调色的色卡，像装修时全屋共用的一张编号油漆表；位于 `AppearanceTheme.swift`，没有它会让不同视图各自写近似色并逐渐漂移。**字体分工（L2）** 是 UI 无衬线、阅读区衬线、代码等宽三条职责边界；没有分工会让按钮像书页或代码失去列对齐。
- 技术取舍：浅色主题采用 `#FAF9F5` 背景、`#141413` 主文字、`#B0AEA5` 次级色、`#E8E6DC` 边线/弱背景与 `#D97757` 强调色。没有安装、下载或捆绑 Anthropic 字体；使用 Apple 原生光学 serif design，让英文落到 New York 风格、中文由系统衬线字体回退，保持 macOS-native 与字体授权边界。系统与深色主题继续使用原生无衬线。
- 自动证据：`swift build --disable-sandbox` PASS；`MarkdownPresentationTests` **16/16 PASS**，锁定五个 Claude 色值、只有浅色启用 serif、正文 serif 路径与代码 monospaced 不变；`HistoryContentViewTests` **60/60 PASS**，覆盖三栏、标题、阅读 pane、实时转写、视频和既有结构守卫。构建只有既有 WebKit delegate 与未使用 `videoURL` warning，本轮没有新增编译错误。
- 失败与恢复：若衬线中文在实际长文中显得过密，可只调整浅色主题的字号/行距或改回系统无衬线，不需要修改数据；若橙色强调过强，只改 `ClaudePalette.orange` 的使用角色，不应散改视图。撤回时仅反向移除浅色 Claude tokens、`usesEditorialReadingTypography` 交接和对应测试/本段记录，不得 reset 整个 dirty 工作区。
- 可选跟做（5–10 分钟）：部署候选版后，在设置切换“系统 → 浅色 → 深色”，打开同一条含标题、正文、引用和代码块的记录；观察只有浅色的阅读文字变为衬线，UI 控件仍为无衬线，代码仍等宽。该观察用于确认个人审美，不是工程完成门槛。

## 任务：History 三栏默认比例收窄

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 在独立候选版中进行主观比例确认。** 本轮只调整 History 三栏的启动建议宽度，不修改列表内容、搜索、筛选、详情数据或用户拖动能力。
- 场景 → 角色与交接：`NavigationSplitView` 先读取三栏的最小、建议和最大宽度，再把窗口剩余空间交给右侧详情。左侧导航栏继续使用 `150 / 170 / 200`；中间链接列表由 `240 / 300 / 380` 收窄为 `170 / 190 / 260`，因此首次打开时与左栏接近，同时长标题仍可手动拖宽。
- 核心名词：**Ideal Column Width / 建议栏宽（L2）** 是系统首次排版时优先参考的尺寸，像书架默认格宽；它不是锁死宽度。最小值和最大值负责限制可拖动边界，没有这组约束时辅助栏可能抢走正文空间或被压到无法使用。
- 技术取舍与失败恢复：没有把两栏写成完全相同的固定宽度，因为中间栏要承载搜索框和链接标题；保留 20pt 的默认差距和 260pt 上限，在视觉均衡与可读性之间留出弹性。若真实使用中标题截断过多，可只提高中间栏 `ideal` 或 `max`；撤回时恢复这一处宽度元组与对应结构测试，不触碰其它 dirty 修改。
- 自动证据：隔离模块缓存下 `HistoryContentViewTests` **60/60 PASS**，Swift Debug build PASS；候选版已输出到 `/private/tmp/LinkDigest-Claude-Theme-Columns-20260722-1618`，`codesign --verify --deep --strict` PASS，Bundle ID 为 `com.syc.linkdigest.debug.fastlane`，浅色主题偏好为 `paper`。构建只出现既有 SwiftPM 用户缓存只读提示和未使用 `videoURL` warning，本轮没有新增编译错误。
- 可选跟做（5 分钟）：启动候选版观察左栏与中栏初始比例，再拖动中间分隔线确认仍可在 170–260pt 范围调整。该观察用于确认个人使用手感，不是任务关闭门槛。

## 任务：Claude 浅色工具栏融合与分栏边界恢复

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 在新候选版中进行主观视觉确认。** 本轮修正上一版视觉验收暴露的两处问题：顶部工具栏仍为系统白，左栏与中栏同色后缺少可见边界。
- 场景 → 角色与交接：浅色或深色主题先把画布色交给 `HistoryWindowToolbarThemeModifier`，让系统 `windowToolbar` 与正文使用同一层背景；三栏内容再各自把 `hairline` 交给右侧 1pt 边界，明确“这一栏到这里结束”。系统玻璃主题不套自定义工具栏色和边线，继续交给 macOS material。
- 核心名词：**Window Toolbar Background / 窗口工具栏背景（L2）** 是交通灯与顶部操作按钮所在的系统区域底色，像整张桌面的上沿；没有主题交接就会在米黄页面上留下独立白条。**Column Divider / 分栏边界（L2）** 是相邻工作区之间不参与点击的 1pt 视觉标记，像书页的装订线；没有它时两块同色区域会被误读成一整块。
- 技术取舍与失败恢复：继续保留原生 `NavigationSplitView` 和可拖动分栏，只叠加主题背景与 `.allowsHitTesting(false)` 的细线，不自绘分栏交互。若系统版本上的 toolbar 不接受 SwiftUI 主题色，撤回 modifier 并改走局部 AppKit window appearance bridge；不要改成隐藏标题栏或重做交通灯。
- 自动证据：隔离模块缓存下 `HistoryContentViewTests` **60/60 PASS**，候选版构建中的 Swift Debug build PASS；新候选版已输出到 `/private/tmp/LinkDigest-Claude-Theme-Fused-Chrome-20260722-1624`，`codesign --verify --deep --strict` PASS，Bundle ID 为 `com.syc.linkdigest.debug.fastlane`，主题偏好为 `paper`。构建只出现既有 SwiftPM 用户缓存只读提示和未使用 `videoURL` warning，本轮没有新增编译错误。
- 可选跟做（5 分钟）：打开候选版观察顶部白条是否消失，再沿左栏—中栏和中栏—详情两条边界查看细线是否连续清晰；拖动两处分隔确认栏宽仍可调整。这不是任务关闭门槛。

## 任务：分栏细线贯通到窗口顶

- 日期：2026-07-22
- 当前状态：**工程完成，Syc 待在候选版中复核。** 修正上一版视觉验收发现的"细线未到顶部"：分栏线原是叠在栏内容上的 overlay，而栏内容从工具栏下方开始，顶部 safe area 被系统工具栏占据。
- 场景 → 角色与交接：`themedColumnDivider` 在保持 1pt、不参与命中测试的前提下追加 `.ignoresSafeArea(.container, edges: .top)`，让细线穿过主题化工具栏直达窗口顶；系统玻璃主题不渲染该细线，不受影响。
- 核心名词：**Safe Area / 安全区（L2）** 是系统为工具栏、刘海等保留的边缘区域，内容默认从它内侧开始排版；没有显式穿透声明时，任何"顶到边"的视觉元素都会在安全区边界处被截断。
- 自动证据：`swift build --disable-sandbox` PASS；`HistoryContentViewTests` 60/60 PASS，新增断言锁定细线必须带顶部 safe area 穿透。候选版 `/private/tmp/LinkDigest-Claude-Theme-Divider-Top-20260722-1645`，codesign PASS。
- 失败与恢复：若未来 macOS 版本改变工具栏与安全区关系导致细线过长或重影，仅调整该修饰符，不改 broker、播放或栏宽逻辑。

## 任务：阅读字体用户可选与图片白色衬卡

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 视觉与交互确认。** Syc 确认规格：5 选项字体全套 + 图片白色衬卡与细边线（含右键保存/拷贝）。
- 场景 → 角色与交接：设置「外观」新增「阅读字体」菜单（跟随主题/衬线/无衬线/宋体/楷体），偏好经 `ReadingFontPreference`（AppStorage）解析为 `ResolvedReadingFont`（系统 design 或命名 family），统一交给标题、正文、纯文本与实时转写；UI 控件保持无衬线，代码块保持等宽。阅读区内联图片改坐白色圆角衬卡 + 1pt 细边线，右键提供「存储图片为…」（NSSavePanel，按 magic bytes 推断扩展名）与「拷贝图片」。
- 核心名词：**Font Family 回退（L2）**：命名字体（Songti SC/Kaiti SC）是 macOS 内置 family，不捆绑不下载；解析失败时回退系统字体避免空白渲染。**Magic Bytes / 文件头嗅探（L2）**：缓存图片文件名是内容哈希无扩展名，保存时按 JPEG/PNG/GIF/WebP 文件头给出可用默认文件名。
- 技术取舍：沿用既有 `usesEditorialReadingTypography` 作为「跟随主题」的回落信号，不新增主题分支；白色衬卡在深色主题下同样使用纯白，保证白底截图边界永远清晰。移除布尔 `usesSerifTypography` 接缝，测试锁定其不得回归。
- 自动证据：`swift build --disable-sandbox` PASS；`MarkdownPresentationTests` 19/19、`HistoryContentViewTests` 60/60、`ProviderSettingsPresentationTests` 5/5，合计 84/84 PASS。候选版 `/private/tmp/LinkDigest-Reading-Font-Image-Card-20260722-1656`，codesign PASS。
- 失败与恢复：若宋体/楷体长文观感不佳，只调整字号/行距或从清单移除该项，不改数据；撤回时反向移除 `ReadingFont.swift`、设置行、图片衬卡与对应测试，不得 reset 整个 dirty 工作区。
- 可选跟做（5 分钟）：设置 → 外观切换五种阅读字体，观察仅阅读区变化；在含白底图片的文章上确认衬卡边界，右键保存一张图到 ~/Downloads 并打开验证。

## 任务：列表行时间改为发布/创建两排

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 视觉确认。** 列表行灰色时间从单排「发布 + 更新」改为两排：第一排发布时间，第二排创建时间；发布时间未抓取到时整排消失，只留创建。
- 场景 → 角色与交接：`HistoryRowProjection` 新增可选 `createdAtMilliseconds`（tasks 表 `created_at_ms`，旧序列化数据缺失时解码为 nil 并回退 updatedAt），列表 SQL 增选一列；`HistoryRowView` 用 VStack 两排渲染，前缀「发布 / 创建」与详情页语义一致。
- 技术取舍：不再展示「更新」时间——列表关心内容坐标（何时发布）与个人坐标（何时收藏），任务更新时间对浏览无决策价值；详情页仍完整保留。字段做成可选而非默认 0，避免旧 JSON 解码失败或伪造 1970 时间。
- 自动证据：`swift build --disable-sandbox` PASS；`HistoryContentViewTests` 60/60 PASS（含新的两排结构锁与「更新不得回归」断言）。`LinkDigestPersistenceTests` 61 项中 1 例失败为 7/21-22 未提交转写原子性 WIP 的既有失败（HEAD 中无该测试），与本任务无关。候选版 `/private/tmp/LinkDigest-Row-Times-20260722-1704`，codesign PASS。
- 失败与恢复：撤回时反向移除 projection 字段、SQL 列与两排视图及测试锁；不影响数据库 schema（未新增迁移）。

## 任务：转写校对编辑、分段兜底与公众号代码块保留

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测确认。** 三个子改动：本机转写文本可原地编辑；无句号口播的分段兜底；公众号代码块以 fenced code 完整保留。
- 场景 → 角色与交接：详情页原文面板中，本机转写 snapshot 顶部出现「编辑转写」；TextEditor 校对后点保存，`HistoryViewModel.saveEditedSnapshotText` 经 `HistoryApplicationService` 调 `HistoryRepository.updateSnapshotBodyText`（新协议方法，旧测试替身默认 unavailable），GRDB 原地更新正文与派生列（字数、SHA-256 指纹）并抬升任务 updated_at；frontmatter 保留，只有正文被替换；此后总结/翻译/导出全部使用校对稿。网页捕获正文保持只读。切换条目丢弃未保存草稿。
- 分段兜底：`TimedTranscriptionAccumulator.splitLongParagraph` 新增软终止符（，、；：）断段——中文 ASR 常整段只有逗号，超过两倍软上限（340 字）后允许在逗号处断段，不再输出文字墙。注意：已入库的旧转写不会自动重排，需重新转写或手动编辑。
- 公众号代码块：通用 DOM→Markdown `walk`（模块版与 isolated 版同步）新增 `pre` 分支——微信 code-snippet 每行一个 `<code>`，按行拼接还原换行并输出 fenced code；行号栏 `code-snippet__line-index` 按 chrome 丢弃；两个 normalize 改为 fence 感知，代码缩进不再被空格折叠破坏。
- 自动证据：Swift `SnapshotBodyEditTests` 2/2（含派生列与 notFound 行为）、`LocalVideoTranscriptionTests` 7/7（新增逗号断段）、App 三套件 128/128；扩展 Vitest 全量 **167/167**（新增微信 code-snippet fixture）。候选版 `/private/tmp/LinkDigest-Edit-CodeBlock-20260722-1800`，codesign PASS，已启动验证不崩溃。
- 失败与恢复：编辑保存失败走人话 alert 且不丢草稿之外的数据；撤回时反向移除协议方法、GRDB 实现、编辑 UI、pre 分支与对应测试。旧文章的代码块需重新用扩展抓取一次才能享受新提取。

## 任务：手动链接路径的代码块保留（桌面侧）

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 用手动链接重抓验证。** 上一轮只修了扩展提取器；Syc 指出该文章是手动粘链接进来的——桌面侧两条提取路径同样没有 `<pre>` 分支。
- 场景 → 角色与交接：`MinimalHTMLExtractor.markdown(from:)` 在所有标签重写前先把 `<pre>` 整体摘出为 fenced code 并用 `«CODEBLOCKn»` 占位符保护，归一化完成后原样还原；微信 code-snippet 每行一个 `<code>` 按行拼接，行号 `<ul>` 先行丢弃。`WeChatWKWebViewCaptureService` 的 TreeWalker JS 同步新增 PRE → fenced code、行号栏 skipRoot 子树跳过、normalize fence 感知。`normalizeMarkdownWhitespace` 与 `stripBoilerplateLines` 均改为 fence 感知——此前还原后的代码缩进会被 per-line trim 摧毁（调试中现场复现）。
- 核心名词：**占位符保护（L2）**：多阶段文本管线里，先摘出不可破坏片段、以稳定 token 顶替、末端还原，是让"逐行归一化"与"逐字节保真"共存的标准手法；没有它任何一步 trim 都可能毁掉代码。
- 自动证据：`ManualLinkCaptureTests` 16/16（新增微信 code-snippet + 普通 pre + 实体解码 + 行号不漏），`WeChatWKWebViewCaptureServiceTests` 新增脚本结构锁；四套件合计 **100/100 PASS**。候选版 `/private/tmp/LinkDigest-ManualCode-20260722-1830`，codesign PASS，已启动。
- 失败与恢复：旧入库文章不会自动重排——同一链接重新粘贴一次即产生带代码块的新快照。撤回时反向移除 pre 摘出、两处 fence 感知与 JS 分支及测试。

## 任务：X 推广条过滤、拷贝全文与 PDF/Word 导出

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。** 三个子改动：X 长文捕获不再混入「想发布自己的文章？升级为 Premium」推广条；分享菜单新增「拷贝全文」；新增按 App 阅读排版的 PDF (.pdf) 与 Word (.docx) 导出。
- 场景 → 角色与交接：扩展 X read-view 提取完成后按整块过滤中英文 Premium upsell（模块版与注入版同步，fixture 加断言锁）。App 侧 `HistoryViewModel.composeExportMarkdown` 复用 `HistoryExportRenderer` 的 .md 组合作为唯一全文来源；「拷贝全文」把正文（剥 YAML 头）写入剪贴板；`ReadingDocumentExport` 把 Markdown blocks 按阅读区字号体系（标题 19/16/14、正文 13、代码等宽 11、引用缩进、列表圆点）渲染为 NSAttributedString，PDF 走纯 CoreText A4 分页（不经打印系统、可离线单测），Word 走 AppKit 原生 OOXML（零第三方依赖）。
- 核心名词：**CTFramesetter 分页（L2）**：CoreText 的排版机把长富文本按页框逐段消费，`CTFrameGetVisibleStringRange` 告诉你这页吃掉了多少字符，循环即分页；不需要 WebView 或打印面板。**officeOpenXML DocumentType（L2）**：AppKit 内建的 .docx 写出口，NSAttributedString 直接落 PK zip。
- 自动证据：扩展 Vitest **169/169**（X upsell fixture + 断言）；Swift 新增 `ReadingDocumentExportTests` 3/3（排版字号/等宽、%PDF 与 PK 魔数、长文多页），四套件合计 **131/131 PASS**。候选版 `/private/tmp/LinkDigest-Copy-Export-20260722-1940`，codesign PASS，扩展已同步至 Brave 加载目录。
- 边界与恢复：PDF/Word 是展示层导出，不改 Core 合同与存储；图片以链接文本形式出现（本地图片嵌入另立任务）。撤回时反向移除 upsell 过滤、菜单项、`ReadingDocumentExport` 与测试。

## 任务：X 推广条拆块过滤、图片异步加载与主流灯箱

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。** 上一轮 upsell 过滤只匹配合并成单块的形态；真实 DOM 把「想发布自己的文章？」与「升级为 Premium」拆成两个独立块（隔离库字节层证实），过滤改为逐块匹配两种拆分形态（中英文），fixture 同步拆块。
- 图片性能：此前每次渲染都在主线程同步 `NSImage(contentsOf:)` 逐张解码，26 张大图卡几十秒。现在 `InlineArticleImageView` 占位 → 后台 `CGImageSource` 缩略下采样（≤1600px，解码成本挂钩目标尺寸而非原图）→ `NSCache`（256MB 上限）；滚动往返零重复解码。
- 灯箱（替换 sheet）：`InlineImageLightboxController`（全局单例状态）+ 窗口级 overlay。主流行为齐备——点击图外暗区即退出、Esc 退出、右上 ✕ 次入口；触控板捏合（MagnificationGesture）与鼠标滚轮（local monitor，开灯箱期间独占滚轮、关闭即移除）自由缩放 0.25–8x；放大后拖拽平移；双击在适应窗口 ↔ 2x 间切换。灯箱内加载原图（非下采样缓存）。
- 核心名词：**下采样解码（L2）**：`kCGImageSourceThumbnailMaxPixelSize` 让解码器只产出目标尺寸位图，大图内存与耗时都按需付费。**Local Event Monitor 生命周期（L2）**：滚轮独占必须与灯箱可见性严格同生共死，否则关掉灯箱后滚轮仍被吞。
- 自动证据：扩展 Vitest 22/22（拆块 fixture）；Swift `MarkdownPresentationTests` 新结构锁（异步组件、下采样、灯箱手势、监视器移除）+ 三套件 82/82 PASS。候选版 `/private/tmp/LinkDigest-Lightbox-20260722-2000`，codesign PASS，扩展已同步。
- 失败与恢复：旧 X 记录需重抓才会去掉推广条。撤回时反向移除 `ArticleImageViewing.swift`、overlay 挂载与测试锁，恢复旧内联 Image 分支。

## 任务：灯箱框内约束返工与识别文字

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。** 两轮改动：灯箱返工为带边框查看框（修正细线压图、无框、丢失存储按钮三处回归），随后加入 Apple Vision 识别文字。
- 查看框：圆角边框卡片（86% 窗宽）承载图片，图片与手势 `.clipped()` 在框内；底部工具条含操作提示、「识别文字」「存储为…」「完成」。滚轮缩放改为 `LightboxWheelZoomCatcher`（NSView 局部监视器 + 自身 bounds 判定）：光标在框内才消费滚轮，框外照常滚动页面，随视图离窗自动解绑。窗口级分栏细线在灯箱打开期间传 nil 移除，关闭恢复。
- 识别文字：复用详情页同一 `AppleVisionTextRecognizer`（zh-Hans/zh-Hant/en-US，本机零网络）。按钮在「存储为…」左侧；识别中有进度态；完成后框内右侧 38% 宽文字面板，正文可划选（textSelection），带「拷贝全部」；失败给人话文案；「收起文字」还原纯图模式。
- 核心名词：**局部事件监视器 + bounds 判定（L2）**：把"全局独占"降为"区域独占"的标准做法——监视器仍是窗口级，但只有命中自身 frame 才消费事件，其余原样放行。
- 自动证据：`MarkdownPresentationTests` 结构锁更新（clipped/捕捉器/bounds 判定/OCR 接线/拷贝全部），两套件 79/79 PASS。候选版 `/private/tmp/LinkDigest-Lightbox-OCR-20260722-2025`，codesign PASS。
- 失败与恢复：OCR 结果不落库、不进导出，仅剪贴板交付；撤回时反向移除识别面板与按钮，不影响查看框主体。

## 任务：YouTube 单视频抓取适配器

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 真实页面验证。** Syc 确认范围：元数据 + 简介 + 公开字幕。此前 YouTube 落通用页面路径，正文混入推荐/评论噪音。
- 场景 → 角色与交接：background 在通用路径前按 `isYouTubeWatchURL` 分流（watch/shorts/live/youtu.be，canonical 归一到 /watch?v=）。MAIN world 读取页面自己的 `ytInitialPlayerResponse`（标题/频道/发布日期/播放/点赞/简介/字幕轨列表；SPA 站内跳转会留旧 response，videoId 与地址栏不符即拒用并回退通用路径）。字幕轨按 zh > en > 其它、人工轨优先于 ASR 选择，在页面 origin 内 fetch 该视频自己的公开 timedtext（fmt=json3，credentials omit），cue 按 ≥4s 停顿分段、CJK 感知拼接为「## 字幕」正文；无字幕优雅降级为元数据+简介。frontmatter 键沿用抖音（author/published/likes），App 侧解析零改动。
- 边界：仅用户正在看的单个视频；不碰私有端点、不下载媒体、不绕登录墙；无 V2 media（YouTube 是 MSE 流，本 Loop 不做播放）。`activeTab` 权限点击即生效，无需新增 host 权限。
- 自动证据：新增 `youtube.test.ts` 4 组（URL 识别/字幕轨优选/json3 分段/markdown 组装），扩展全量 **173/173 PASS**，`tsc --noEmit` 干净。候选版 `/private/tmp/LinkDigest-YouTube-20260722-2040`，codesign PASS，扩展已同步。
- 失败与恢复：player response 缺失或 videoId 不符时自动回退通用抓取（不比现状差）；撤回时移除 youtube.ts、background 分流与测试。

## 任务：列表挤行根治与 YouTube SPA 抓取修复

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。** 两处返修：新到卡片挤扁（第二次）与 YouTube 抓成首页大杂烩。
- 挤行：`fixedSize + 行 id` 不足以让 NSTableView 重算插入行行高；观察到初始构建/重启的测量始终正确，故改为**新条目登顶时整表重建**（List `.id(rows.first?.taskID)`）——新行本就在顶部，滚动位置无损，行高恢复真实内容测量。
- YouTube：根因是 SPA——`window.ytInitialPlayerResponse` 只反映首次整页加载，从首页点进视频时缺失/陈旧 → 回退通用抓取刮下 SPA 外壳（feed/侧栏/头像）。修复三层：① MAIN world 优先 `#movie_player.getPlayerResponse()`（实时、SPA 安全），window 全局仅作冷加载兜底；② videoId 与地址栏不符即弃用；③ watch URL **永不落通用路径**——DOM 兜底（标题/频道/简介）仍是单视频，最差也不是 feed 垃圾。
- 核心名词：**SPA 全局变量陷阱（L2）**：单页应用的 `window.*Initial*` 只在整页加载时写入，站内路由后即为陈旧数据；必须从活组件 API 取实时状态。
- 自动证据：扩展 173/173、tsc 干净；Swift HistoryContentViewTests 60/60。候选版 `/private/tmp/LinkDigest-YT-Fix-20260722-2055`，codesign PASS，扩展已同步。
- 失败与恢复：DOM 兜底也拿不到标题时报 CAPTURE_CONTENT_EMPTY（人话错误），不产出垃圾条目。

## 任务：YouTube 官方嵌入播放卡

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测播放。** 元数据/简介/字幕抓取验证通过后，Syc 要求视频本身可看。YouTube 是加密 MSE 流不落盘，采用官方 embed 通道在 App 内播放。
- 场景 → 角色与交接：`YouTubeWatchLink.videoID` 从 canonical URL 解析视频 ID（与扩展适配器同规则，App 侧无需合同变更）；详情页媒体位（抖音本地视频卡同一位置）挂 `YouTubeEmbedPlayerCard`——16:9 WKWebView 加载 `youtube-nocookie.com/embed/<id>`，标题栏带「在浏览器打开」。
- 安全边界：WKWebView 非持久数据存储（零 Cookie/缓存留存）；主框架导航仅允许 embed 自身路径，跳出（视频标题/Logo/推荐）一律 cancel；window.open 拒绝；播放需用户点击（不自动播）。不下载媒体、不注入脚本、不逆向流地址。
- 自动证据：`YouTubeEmbedPlayerTests` 2 组（URL 解析矩阵 + 导航/存储锁结构断言），与 HistoryContentViewTests 合计 62/62 PASS。候选版 `/private/tmp/LinkDigest-YT-Embed-20260722-2110`，codesign PASS。
- 失败与恢复：断网或 embed 被墙时卡片空白但不影响正文阅读；撤回时移除 YouTubeEmbedPlayer.swift 与详情页分支。

## 任务：YouTube 字幕为正文与 embed 播放修复

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 重抓验证字幕。** 两个子改动：embed 错误 153 修复；「原文」以字幕为主体。
- 播放：直接加载 embed URL 缺来源页触发 YouTube 错误 153；改为带 baseURL 的宿主页包 iframe（原生 App 嵌 YouTube 的标准做法），实测可播。安全约束不变（nonPersistent、导航锁定 /embed/、window.open 拒绝、点击才播）。
- 字幕为正文：`buildYouTubeMarkdown` 把「## 字幕」排在「## 简介」之前——口播正文优先，简介多为推广链接；无字幕时输出明确提示行而非静默缺失。字幕获取加固：json3 失败或空 events 时回退默认 timedtext XML（`<text start>` 解析 + 实体解码 + 4s 停顿分段）。
- 自动证据：扩展 **174/174**（新增 XML 回退与排序断言），tsc 干净。候选版 `/private/tmp/LinkDigest-YT-Transcript-20260722-2130`，codesign PASS，扩展已同步。
- 失败与恢复：两种格式都拿不到时正文显示"该视频未提供字幕"提示；旧记录需重抓才有字幕正文。

## 任务：YouTube 字幕获取——pot 令牌封锁与面板回退

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 重抓验证。** 连续两条有 CC 的视频抓不到字幕；用 CDP 浏览器现场探针确诊并落地新通道。
- 现场证据（chrome-devtools CDP，真实 watch 页）：captionTracks 存在（en + en-asr，baseUrl 齐全），但 `/api/timedtext` 无论 json3/XML/带凭据均返回 **200 空体**；播放器自己的请求带 `pot=` 来源证明令牌，重放同 URL 依然空体（令牌单次绑定）；innertube `get_transcript` 直连报 Precondition failed。结论：2025 起 timedtext 对非播放器请求全面封锁。
- 可行通道（已现场验证 32 段全出）：页面自己的「文字记录」面板——注入脚本点开面板（必要时先展开简介）→ 轮询 `transcript-segment-view-model`（2025 UI；旧 UI `ytd-transcript-segment-renderer` 兼容）→ 读时间戳与文本 → 点关闭按钮还原界面。全程页面自身机制 + 用户会话，仅当前视频可见内容。
- 落地：`collectYouTubeTranscriptFromPanelInPage`（自包含注入）+ `transcriptFromPanelSegments`（"m:ss"→秒，≥8s 停顿或 >500 字换段，CJK 感知拼接）。background 链路：timedtext（留作旧环境兜底）→ 面板回退 → 两者皆空才写"未提供字幕"提示。
- 核心名词：**pot / Proof-of-Origin Token（L2）**：平台把资源 URL 与一次性来源令牌绑定，裸重放即失效；对抗它的正解不是伪造令牌，而是改走用户界面已经渲染的数据。
- 自动证据：扩展 **175/175**（新增面板分段测试），tsc 干净。候选版 `/private/tmp/LinkDigest-YT-Panel-20260722-2200`，codesign PASS，扩展已同步。
- 失败与恢复：面板打开约 1-2s（首次最多 10s 轮询），抓取后自动关闭；无文字记录入口的视频正确落"未提供字幕"。

## 任务：YouTube 面板字幕的三类脏数据清洗

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 重抓验证。** 面板通道打通后暴露三类质量问题：混语言（快照抓在 YouTube 渐进套用自动翻译的中途）、直播 rollup 字幕逐条重带上一行导致句句重复、`>>` 说话人标记未处理。
- 修复：① 采集稳定环——连续两次读取指纹一致才收，避免"前半翻译后半原文"中间态（最长 12s）；② 后缀-前缀重叠去重（≥8 字符才算重叠，从长到短匹配，上限 120），消掉 CEA-608 rollup 的重复行；③ `>>` 拆为说话人切换、转为换段。原 ≥8s 停顿与超长换段保留。
- 边界：转写语言跟随用户在 YouTube 的字幕语言偏好（含自动翻译）——采集的是"用户看见的字幕"；不在扩展里强改语言菜单（DOM 易碎且违反最小干预）。
- 自动证据：扩展 **176/176**（新增 rollup 去重与 >> 换段用例）。候选版 `/private/tmp/LinkDigest-YT-Clean-20260722-2215`，codesign PASS，扩展已同步。

## 任务：YouTube 字幕只抓原始语言

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 重抓验证。** Syc 拍板：只抓视频原始语言字幕、不抓自动翻译，语言一致性从源头解决。
- 实现：面板抓取前经播放器官方 API（MAIN world `setOption("captions","track",{languageCode})`）把字幕轨切到已选原始轨（`captionTracks` 内均为原始轨，翻译不在其中），文字记录面板跟随播放器轨道；抓取完成后恢复用户此前状态（含关闭态与翻译语言组合，best-effort）。
- 自动证据：扩展 176/176、tsc 干净。候选版 `/private/tmp/LinkDigest-YT-Original-20260722-2225`，codesign PASS，扩展已同步。
- 失败与恢复：播放器 API 不可用时退回"抓用户当前所见"，不阻断抓取；恢复失败不影响正文内容。

## 任务：阅读区跨段连续文本选择

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测拖选。** SwiftUI `Text` 的 `.textSelection` 每块是独立选择孤岛，只能一行/一段内选；用户要求光标连续跟随。
- 场景 → 角色与交接：`ReadingTextComposer` 把相邻文本块（标题/段落/列表/引用）按阅读排版字号（23/19.5/17/16.5、行距 11、引用缩进、列表圆点）合成一个 NSAttributedString；`SelectableReadingTextView`（自适应高度非编辑 NSTextView）整块渲染——同一选择上下文，拖选随光标连续伸展，与备忘录/浏览器一致。代码块仍由 SwiftUI 卡片独立渲染（复制按钮保留），图片处自然分段。纯文本模式同样切换。链接保留 `.link` 属性，点击经 delegate 交回 `openValidated`（PublicWebURLPolicy 校验不旁路）。
- 核心名词：**选择上下文（L2）**：连续选择的单位是"一个文本视图"而非"一个窗口"；SwiftUI 多 Text 无法合并选择上下文，AppKit NSTextView 一个 textStorage 即一个完整选择域。**自适应高度 NSTextView（L2）**：intrinsicContentSize 上报 layoutManager usedRect，宽度变化时 invalidate 重排。
- 自动证据：`MarkdownPresentationTests` 19/19（新结构锁：合成器/连续视图/链接回调/intrinsic 高度），HistoryContentViewTests 60/60。候选版 `/private/tmp/LinkDigest-Selection-20260722-2250`，codesign PASS。
- 失败与恢复：若长文排版出现高度错位，先查 `SelfSizingTextView.setFrameSize` 的重排失效；撤回时恢复 `markdownBlock` 逐块渲染路径（保留在 git 历史）。

## 任务：设置窗口浅色主题接管（侧栏/工具栏/全 tab 背景）

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 视觉确认。** 设置窗口此前保持系统灰侧栏 + 蓝色选中，与纸质主题脱节；按 Syc 指示只改浅色，系统与深色不动。
- 实现：`isPaperTheme` 分支——侧栏换自定义行（画布底色、主窗口同款橙色 selectionFill/selectionText、隐藏系统分隔线）；窗口工具栏 `toolbarBackground(canvas)`；视频存储与浏览器支持两个 tab 由外层 `scrollContentBackground(.hidden)`（环境传播）+ 画布背景统一接主题。其它主题走原生 List(selection:) 原样保留。
- 自动证据：build PASS，`ProviderSettingsPresentationTests` 5/5。候选版 `/private/tmp/LinkDigest-Settings-Paper-20260722-2300`，codesign PASS。

## 任务：YouTube 无字幕视频的内嵌播放音频实时转写

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 真机验证音频捕获质量与权限流。** Syc 拍板走 App 内实时转写路线。
- 技术现实：YouTube 是加密签名流，音频文件拿不到（下载需逆向签名，越安全边界）。因此不能像抖音"下载→离线转写"，只能边播边转——耗时≈视频时长。
- 实现：`AppAudioLiveTranscriber`（actor）用 **ScreenCaptureKit 捕获本 App 自己进程的音频**（`excludesCurrentProcessAudio=false` + SCContentFilter 限当前应用），SCStream 音频 buffer → 16kHz 单声道 PCM → SpeechAnalyzer 流式 `start(inputSequence:)` → 逐段 partial。`HistoryViewModel.startLivePlaybackTranscription` 复用抖音的 begin/save 落库路径，文本存为 localTranscription snapshot；YouTube 卡在无「## 字幕」时显示「实时转写」按钮 + 实时文本区 + 权限提示。
- 边界：只捕获本进程音频、不录麦克风/其它 App；首次需系统「屏幕录制」授权（系统音频捕获入口）；全程本机零网络。与文件转写器互补而非替代。
- 核心名词：**进程内音频捕获（L3）**：SCK 按应用过滤 + 不排除本进程，等于"录我自己播的声音"，是 macOS 上转写内嵌加密流的唯一合规路径。
- 自动证据：`AppAudioLiveTranscriber` 编译通过；`HistoryViewModelTests` 新增实时转写落库测试（注入桩流），50/50 PASS；App 四套件全绿。候选版 `/private/tmp/LinkDigest-YT-LiveASR-20260722-2330`，codesign PASS。
- 待验证（非工程可自证）：真机屏幕录制授权弹窗、进程音频捕获实际到流、中文识别质量、与视频等时长的耗时体验。撤回时移除 AppAudioLiveTranscriber、VM 方法、卡片控件与测试。

## 任务：真实 bug 批量修复（转写收声 / 平台降级 / 导出嵌图）

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。** 按核查出的真实清单顺序修复。
- **#1 YouTube 转写完成视频不自动停**：转写自然完成/失败/停止后视频仍后台出声。加 `pauseToken`——转写从 active 转非 active 时 postMessage `pauseVideo`；点「停止转写」也立即暂停。
- **#2 小红书/B站只声明未实现**：contract 枚举有 xiaohongshu/bilibili 但 background 无适配器，通用抓取会刮 SPA 外壳垃圾。`sendCapture` 前置 `isUnimplementedPlatformHost` 拦截，返回结构化 `PLATFORM_NOT_SUPPORTED` 错误，popup 显示人话降级（引导浏览器打开/复制到桌面 App）。
- **#3 自动标签**：核查发现**早已完整实现**——`ModelRunOrchestrator.applyAutomaticTags`（模型 `SummaryTagGenerating` 产出 + 启发式回退）总结完成即调用，5 测试文件覆盖。此前被详情页手动补全的 `suggestedTags` 误导。无需做。
- **#4 PDF/Word 导出嵌本地图片**：`attributedDocument` 加 `localImageURLs` 参数，按图片标记切段、在标记处插 `NSTextAttachment`（≤460pt 等比缩放）。docx 走系统 OOXML 原生嵌图。**PDF 关键**：CoreText `CTFrameDraw` 不画附件图片，改用 `NSLayoutManager` 多容器分页渲染（原生画附件 + PDF 坐标翻转）。
- 核心名词：**CTFrameDraw 不绘附件（L3）**：纯 CoreText 只排文字字形，NSTextAttachment 图片需 NSLayoutManager `drawGlyphs` 才落墨；要图文混排 PDF 必须走 layout manager 而非 framesetter。
- 自动证据：扩展 **178/178**（新增平台降级用例）；Swift `ReadingDocumentExportTests` 4/4（新增嵌图断言：U+FFFC 附件字符、docx 体积增大）、App 三套件全绿。候选部署到 `~/Applications`（Apple Development 证书），扩展已同步。

## 任务：撤除 YouTube 本机实时转写 UI 入口

- 日期：2026-07-22
- 当前状态：**工程完成。** Syc 实测否决本机实时转写方案（2x 错字 40-50% + 漏字，1x 太慢，速度质量双输）。
- 根因：Apple 实时引擎为低延迟牺牲准确度（+volatile 中间结果雪上加霜）；加速播放让音频特征失真、识别雪崩。是"边播边实时转"这条路的天花板，非调参可救。
- 处理：移除 YouTube 卡的「实时转写」控件、倍速选择、进度/文本区、权限提示；无字幕改为诚实提示「此视频无字幕，暂无法提取文字，可在浏览器中打开观看」。WebView 恢复简洁 embed（`mediaTypesRequiringUserActionForPlayback = .all`、去掉 autoplay/pause/onStateChange 机械）。
- **保留**：`AppAudioLiveTranscriber`、ViewModel 的 `startLivePlaybackTranscription`/`stopLivePlaybackTranscription`/落库路径、优雅停止机制、`HistoryViewModelTests` 测试——第三方 API Loop 时复用「转写文本 → localTranscription snapshot」落库路径。
- 决策记入 brain `youtube-source-adapter`（reversal）：高质量转写待第三方 API（发 URL + 服务器端 Whisper，非实时可批处理）独立 Loop。
- 自动证据：`YouTubeEmbedPlayerTests`/`HistoryContentViewTests` 62/62、`HistoryViewModelTests` 50/50。候选部署 `~/Applications`（Apple Development 证书）。

## 任务：YouTube 全屏 + 导出改为干净正文

- 日期：2026-07-22
- 当前状态：**工程完成，待 Syc 实测。**
- **全屏**：WKWebView 默认禁用元素全屏，YouTube 全屏按钮无反应。开 `configuration.preferences.isElementFullscreenEnabled = true`，播放器可进原生全屏。
- **导出格式**：Syc 反馈导出的 .md/.pdf 带一堆内部元数据（YAML、来源/标签/导出版本/UTC 时间、## 最近原文、捕获时间/完整性），不是阅读区干净正文，字体也"不对"。根因：`composeExportMarkdown` 用了 Core 的 `HistoryExportRenderer`（完整档案格式），`MarkdownNoteFrontmatter.parse().body` 只剥 YAML 剥不掉元数据行。
- 修复：`composeExportMarkdown` 重写为**干净正文**——取原文 snapshot（非转写）的 body、最小 frontmatter（title/source/author/published）+ 标题 + 正文，不含运行记录/导出版本/UTC 捕获时间。菜单：md/txt 走干净正文（`exportCleanText`，txt 再剥 Markdown 标记），PDF/Word 走 `exportStyledDocument`（同源 + `readingFont` 主题字体），JSON 保留为「导出完整数据」（结构化档案）。字体本就传 `readingFont`，之前"字体不对"是元数据污染的观感。
- 自动证据：`ReadingDocumentExportTests` 4/4、`HistoryContentViewTests`/`HistoryViewModelTests` 114/114。候选部署 `~/Applications`（Apple Development 证书）。

## 任务：YouTube 影院模式修复 + 泛化为全视频底层能力

- 日期：2026-07-23
- 当前状态：**Syc 已实测验收。**
- **影院黑屏根因**：overlay 新建 `WKWebView(frame: .zero)` 后立即 `loadHTMLString`，零尺寸首帧渲染黑屏。修复：`YouTubeEmbedWebViewPool` 单实例复用——同一 videoID 全程一个 webview（非零初始 frame 1280x720），卡片 ↔ 影院之间搬移挂载，放大/还原播放进度不丢。delegate 由池强持有（WKWebView 对 navigationDelegate 是弱引用，提顶层后必须显式持有 + `@MainActor` + 新版 SDK `@Sendable` 闭包签名）。
- **边框悬空根因**：stroke 描在 `.frame(maxWidth:maxHeight:)` 外框而非 `.aspectRatio` 后的内容上。修复：GeometryReader 手动算 fitted 尺寸给确定 frame，描边贴内容。
- **泛化（Syc 提出「放大是底层能力」）**：`YouTubeCinemaController` → `VideoCinemaController`，Content 枚举二分：`.youTube(videoID)` 走共享 webview、`.player(AVPlayer, aspectRatio)` 直接移交引用（进度声音天然连续）。overlay 按视频自身宽高比 fit（竖屏抖音不再塞 16:9）。三种视频卡（YouTube 嵌入 / 本机视频 / 流媒体）统一「放大」按钮，位置：视频正下方右对齐（Syc 选定）。影院期间卡内占位防双渲染；切条目/换文件自动 dismiss。
- 自动证据：`YouTubeEmbedPlayerTests` 2/2、`HistoryViewModelTests` 59/59。orca 无障碍实测影院打开/关闭。

## 任务：转写标点精准度之战（三回合）+ 流式卡顿 + 在线转写通本机文件

- 日期：2026-07-23
- 当前状态：**工程完成，Syc 已验收方向。**
- **回合一（preset）**：实测 dump SDK preset——`.progressiveTranscription` 含 `.fastResults`（快速通道牺牲质量）。去掉后实测**输出与批量模式完全一致**：3520 字仅 9 逗号 1 句号。结论：Apple 中文模型本身标点就稀疏，preset 不是根因。改为自定义选项集（`.volatileResults` + `.audioTimeRange`，无 fastResults）保留。
- **回合二（停顿启发式）**：字级时间戳停顿补标点（≥0.5s 句号 / ≥0.15s 逗号）。实测快语速口播 3286 个 run 里 99.4% 间隔 <0.05s，全片仅 ~20 个可判定停顿——聊胜于无，Syc 实测**比模型原生更差，已全部回退**。Apple Intelligence 本机模型（FoundationModels）此机 `deviceNotEligible`，本机 LLM 路线不通。
- **回合三（在线转写，采纳）**：`OpenAICompatibleAudioTranscriber` 本来就是「本机提取音频分片再上传」，只有一行 https scheme 检查挡住本地文件。放行 `isFileURL` + 本机视频卡加「在线转写」按钮（`requestOnlineTranscriptionFromLocalMedia`，与捕获现场共用同意弹窗和 `beginTaskTranscription`/`saveOnlineTaskTranscription` 保存链路）。Whisper 级接口文字+标点一步到位。**前提：设置页需配置「在线转写模型」**。
- **流式卡顿根因**：文件分析比实时快得多，volatile 每秒几十条，每条都 O(n log n) 全文重排 + SwiftUI 重排几千字 Text。修复：accumulator 拆出不算全文的 `merge`，adapter 节流（定稿必推、草稿 ≤3 次/秒）。重新转写不流式的根因：视图只在「无历史 snapshot」时走流式分支——改为转写 active 即走流式（旧文本立即清空）。
- 核心名词：**fastResults（L2）**：SpeechTranscriber ReportingOption，更快出定稿、降低质量；文件转写无需低延迟，不该用。
- 自动证据：`LocalVideoTranscriptionTests` 7/7、`HistoryViewModelTests` 50/50、桌面全量 609 中仅 9 个预先存在的契约失败（见 HANDOFF 未关账）。

## 任务：空格播放失灵（焦点机制级修复）

- 日期：2026-07-23
- 当前状态：**orca 实测验证通过（elapsed 00:00→00:02→00:04），Syc 待真键盘确认。**
- 根因（orca 无障碍现场确认）：空格播放依赖 AVPlayerView 持有 first responder；窗口焦点常态空置或停在搜索框（SwiftUI FocusState 拿到焦点后点击静态内容**不会**交出），空格要么无人接收、要么打进搜索框。阅读区视图切换（转写流式面板出现/消失）让焦点更易被清空，把脆弱依赖暴露成必现。
- 修复（机制级兜底，不再依赖偶然焦点）：`PlayerSpaceKeyToggle`（NSViewRepresentable + 窗口级 keyDown 监视）——焦点在可编辑 NSText 或 NSControl 时空格原样放行，否则切换本卡播放器。附带 leftMouseDown：点击输入框外区域自动 `makeFirstResponder(nil)`。本机卡、流媒体卡、影院占位均挂载。
- 核心名词：**SwiftUI FocusState 不因点击静态内容而释放（L2）**：AppKit 只在新 first responder 出现时换焦点；点不可聚焦区域时文本框保持编辑态，需手动 resign。

## 任务：转写稿 LLM 整理 + 数字接缝修复 + token 摘要（7/23 白天批次）

- 执行：Claude 主控直接实施（Syc 指定不走 Codex）。
- 当前状态：**工程完成，已部署日用 App，待 Syc 总测。** 622 测试，失败仅已知 9 个基线（receipt/manifest 漂移和解遗留）。
- **数字接缝**：本机转写把"9.7"腰斩成"9。/ 7"的根因有二——`splitLongParagraph` 把小数点当句末标点切段 + 停顿分段纯看时间不看内容。`TimedTranscriptionAccumulator` 新增 `isNumberSeam` 三处守卫（停顿断段、join 补空格、超长切段）。
- **整理链路**：`TranscriptTidying`（Core 协议）+ `OpenAICompatibleTranscriptTidier`（分片 ≤6000 字不切段中间；单片失败保原文，全片失败才报错）+ provider 非流式 `tidyTranscriptChunk`。落库复用 task 转写 seam：method `openai_compatible_chat_tidy`（GRDB task 白名单加一项）、evidence `.onlineTextTidy`（engine 与语音转写区分）、原稿保留为历史 snapshot。
- **排版归一化**：模型输出有"每句一行"与"空行分段+段内硬换行"两种方言，Markdown 阅读区把单换行折叠成空格 → "句号后一坨空格 + 不分段"。`TranscriptTidyNormalizer` 确定性归一 + 清 CJK 字符间空格（中西文之间保留）。不赌 prompt 被遵守。
- **token 摘要**：chat usage 分片累计（nil 不当 0），完成状态行显示"N tokens（输入/输出）"。evidence 表列固定，入库需迁移，留独立任务。
- 核心名词：**数字接缝（L2）**：数字与相邻数字/小数点之间的边界，任何分段、切分、补空格都不得落在这里。
- 环境事故：系统重启清 `/tmp`，三浏览器 NMH manifest 指向 tmp 构建目录 → 扩展全断。改指 `~/Applications` 日用 App。manifest 不得指向 tmp 构建目录。

## 任务：脑图输出 + 标签叠加筛选 + token 总账（7/23 晚间批次）

- 执行：Claude 主控直接实施。当前状态：**工程完成，已部署日用 App，632 测试仅余 9 个已知基线失败。**
- **脑图（方案 B：结构+本地渲染）**：LLM 只输出受约束大纲 JSON（≤8 分支、每支 ≤6 要点、围栏容错、超长截断），`MindMapLayout` 确定性布局 + `MindMapSVGRenderer` 渲染，两主题（极简浅色/暗色代码风）换肤零 token。Migration009 `task_mind_maps` 每任务一图存大纲+主题+token；SVG 永不入库。UI 位于媒体卡与原文之间：主题切换/重新生成/表单编辑（错别字）/导出 SVG/脑图+原文 HTML；视口固定高带边框双轴滚动，单击栅格化 2x PNG 进图片灯箱。
- **灯箱 preparedText**：本地渲染图自带文本，「识别文字」秒回大纲清单，不再对大位图跑几十秒 Vision OCR；普通图片 OCR 不变。
- **标签**：侧栏点击语义翻转——普通点击=叠加（AND 交集缩小，SQL 早已支持），⌘点击=只看此标签，新增「清空标签筛选」；脑图分支标题自动写入条目标签（零 token）。标签生成格局：总结时（已有）+ 脑图时（新增）+ 手动（兜底）；转写环节故意不打标。
- **token 总账**：Migration010 `task_token_usages` 台账表，整理/脑图每次成功记一笔；顶部元数据 Token = Runs（总结/翻译）+ 台账累计，capture-only 条目有花费也显示。分项用量仍在各功能状态行。
- 核心名词：**结构与皮肤分离（L2）**：模型产结构、本地产几何与样式，编辑/换肤/重渲染永久免费。
- 教训：部署脚本必须从仓库根目录跑；主控在 `apps/desktop` 里连续两次跑错路径并一度误删日用 App。部署序列待封装成单条脚本。
