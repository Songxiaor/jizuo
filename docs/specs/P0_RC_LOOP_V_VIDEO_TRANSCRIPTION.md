# P0-RC Loop V：视频捕获与本机转写

> 状态（2026-07-27 复核）：工程实现完成并已在日用 App 中运行。断网门已由源码级
> 不变式测试接管；中文质量门与 GUI 全链路截图仍待 Syc 人工验收。
> 设计与验收责任人：Claude；原执行者：Grok；最终验收：Syc。
> 本 spec 由 Claude 于 2026-07-19 起草，Syc 已确认方案方向（双入口抓取 + 本机离线转写 + 复用 BYOK 生成管线）。

> **本 spec 起草后转写线发生了重大变化，读之前先看这一节。**
>
> 2026-07-26 新增了**在线流式转写**（阶跃 SSE，`StepAudioStreamingTranscriber`），
> 与本 spec 描述的本机离线转写**并存**，由 `OnlineAudioTranscriberRouter` 按服务
> 地址选路。也就是说下面「转写走网络 API：否（第一版禁止）」那条决策**已被后续
> 决策取代**——第一版确实没做，之后单独开了一条线做了，并按当时的约定做了数据
> 去向说明。本 spec 描述的是**本机离线**那一半，它仍然完整有效。
>
> 同期还发生的：B站 取音轨转写（只下音频 m4s，不合流）、在线转写从 36.4s 优化到
> 5.1s（下载改取音轨 + 流式分片与上传重叠）。这些都在本 spec 范围之外。

## 任务卡

- 用户场景：Syc 在抖音等平台看到口播视频，通过浏览器扩展发送**或**直接把分享链接丢进桌面 App；详情页顶部出现可播放的视频卡，点「转写」在本机把视频转成文字，随后用现有「总结/翻译」按钮处理转写文本。
- 本次只解决：抖音公开视频的双入口捕获 → 视频落库与播放 → 本机离线转写 → 转写文本接入现有生成与导出管线。
- 明确不做：Cookie/Profile 数据库读取、登录墙绕过、签名算法逆向、批量采集或下载队列、云端转写 API、B站/YouTube 等其它平台适配器（后续按同一接缝扩展）、直播流、弹幕/评论采集。

## 核心技术决策（已拍板，执行者不得擅自更换）

| 环节 | 选择 | 理由与备选 |
|---|---|---|
| 视频→音频 | AVFoundation（`AVAssetReader`/`AVAssetExportSession`） | 系统自带，零第三方依赖；**不引入 ffmpeg**。 |
| 音频→文字 | 首选 macOS 26 原生 `SpeechAnalyzer`/`SpeechTranscriber`；中文实测不达标则切 WhisperKit（MIT，CoreML） | 端上离线、免 Key、内容不出本机，贴合 local-first。Loop V-2 首步是中文质量验证门，结论必须写回本 spec 再继续。 |
| 文字→总结/翻译 | 现有 BYOK chat 管线 | 零改动复用 Provider、数据去向确认、流式卡、History。 |
| 转写走网络 API | 否（第一版禁止） | 新网络面需要单独的数据去向与 secret 边界审查，另立 Loop。 |

## 场景 → 角色与交接 → 工作流

```text
入口 A：抖音页内点扩展「发送」                入口 B：Syc 手动丢分享链接
  ↓ content script 取 <video> src /            ↓ v.douyin.com 短链跟随重定向，
    SSR JSON 播放地址 + 标题/作者/封面           解析 _ROUTER_DATA 类 SSR JSON
  ↓ CaptureEnvelope（media 块，v2 合同）        ↓ 命中风控/登录可见 → 人话错误：
CaptureReceiver / ManualLink 校验与映射          「请在浏览器打开后用扩展发送」
  ↓ 瞬态 MediaDescriptor 留在 CurrentCapture；CapturedDocument 只交持久页面字段
视频下载器：复用 PeerBound SSRF 门禁 + 200MB 上限 + 容器类型校验，签名 URL 立即下载
  ↓ 本地媒体文件（Application Support/LinkDigest/Media/）+ Migration003 元数据行
HistoryDetailView：顶部 AVKit 视频卡（封面/时长/播放）+「转写」按钮
  ↓ 点击转写（本机，无数据去向弹窗）
AVFoundation 抽音轨 → 转写引擎 → 进度复用流式运行卡样式
  ↓ 转写文本入库为该条目「原文」snapshot；完成后卡片收起（对齐总结收起行为）
现有 总结/翻译/导出 管线照常工作
```

## 抓取边界与可靠性分级

- 扩展路径可靠性最高：天然带用户自己的浏览器会话，只取用户当前看见的视频。
- 手动链接路径**尽力而为**：公开视频大多可解析；抖音风控（验证码/空数据）出现时不重试硬碰，直接走引导扩展的降级文案。这与 Loop 5 对客户端渲染页的降级模式一致。
- 播放地址带签名且会过期：解析成功后必须在同一流程内立即下载，不存储裸播放 URL 供以后使用。
- 下载器沿用 PeerBound 逐跳 URL/redirect/端口/私网检查；新增：单文件 200MB 上限、Content-Type 与文件头双重容器校验（mp4/mov）、磁盘余量检查。
- 平台适配只服务于用户主动提交的单条内容；任何批量化、队列化、定时化设计一律拒绝。

## 数据与合同变更

- `capture-envelope-v2` 是独立合同：V2 必须带 `MediaDescriptor`，V1 继续承载纯文本与冻结的旧 media 形态。改动必须经 `scripts/sync-contracts.sh` 双端同步，扩展 Vitest 与 Swift `ContractTests` 同步更新 fixtures；fixture manifest 逐条声明使用 V1 或 V2 schema。
- `Migration003`：媒体表（task 外键、文件相对路径、SHA-256、字节数、时长、转写状态）。遵循既有 GRDB migration 模式，只增不改旧表。
- 媒体文件存 `Application Support/LinkDigest/Media/`，文件名用内容 SHA-256；删除历史条目时连带删除媒体文件（走既有删除事务，不留孤儿文件）。
- 转写文本作为新的 ContentSnapshot 入库；视频条目导出时转写文本随 Markdown/JSON 一起导出。

## Loop 切分、验收与停止条件

### Loop V-1 抓取与落库
- 范围：合同 media 块 + 双端同步；抖音来源适配器（扩展 + 手动两入口）；视频下载器；Migration003；详情页顶部 AVKit 视频卡。
- 验收：≥3 条真实公开抖音链接（手动、扩展各至少 1 条）入库并可在 App 内播放；风控失败显示引导文案且不崩溃；Swift 全量 + 扩展 Vitest 全绿；`git diff --check` 干净。

### Loop V-2 本机转写
- **首步验证门**：用 ≥3 条真实中文口播音频实测 `SpeechTranscriber` 中文质量；结论（含 locale 支持情况）写回本 spec「验证记录」节。不达标 → 切 WhisperKit 并记录模型选型与磁盘占用。
- 范围：音轨抽取；转写引擎接入；转写进度 UI（复用流式运行卡样式）；转写文本入库为「原文」；完成收起。
- 验收：3 条真实口播视频转写可读；**断网状态下转写全程可完成**（证明零网络请求）；全量测试绿。

### Loop V-3 串接生成与导出
- 范围：转写文本接总结/翻译（含同语言检测、截断标注等既有小逻辑）；导出含转写文本；删除条目连带清理媒体文件的回归测试。
- 验收：完整链路「丢链接 → 播放 → 转写 → 总结 → 导出」一次跑通并留 GUI 截图；全量测试绿。

### 全局停止条件（对执行者生效）
- 每个 Loop 内实施最多两次尝试，第二次仍失败即停止并报告，不得扩大范围修复无关问题。
- 不得修改：Provider/Keychain 面、Native Host 安装器、release/装箱脚本、冻结候选的 config hash、`brain/` 目录（Brain 只能经 `./scripts/brain` 写入且本 Loop 不需要）。
- 不得提交/推送 Git、不得部署日用 App、不得调用真实云端 Provider——这些由主控（Syc/Claude）单独执行。
- 遇到需要新增第三方依赖（WhisperKit 之外）、改动 wire 合同结构超出 media 块、或任何安全边界拿不准的情况：停止并报告，等待确认。

## 验证记录

- 2026-07-19 现场系统/API 探针：macOS 26.5.2；`SpeechTranscriber.isAvailable=true`；`supportedLocales` 与 `installedLocales` 均包含 `zh_CN`；`SpeechTranscriber(locale: zh_CN, preset: .progressiveTranscription)` 可构造；`AssetInventory.assetInstallationRequest` 可用。
- 模型状态：任务开始的现场探针记录为 `supported`（需要显式安装请求）；本任务未调用 `downloadAndInstall`，完成代码后的只读复核显示为 `installed`。状态变化来源未知，不据此推断是本任务安装。
- 验证边界：目前只有 1 条真实视频（2880×2160，4:3）用于播放问题定位，尚未完成至少 3 条中文口播的质量对照，也未完成断网转写门；因此 **Loop V-2 中文质量验收与 Loop V-3 完整链路验收仍未完成**。当前继续保留 Apple SpeechAnalyzer 路线，不擅自切换 WhisperKit。

### 2026-07-27 复核

- **断网门已关闭，方式与原计划不同。** 原计划是人工拔网线跑一次。改成源码级
  不变式测试 `LocalTranscriptionOfflineTests`（3 项），钉住三条：转写适配器里没有
  任何网络类型；唯一会触网的 `downloadAndInstall` 只出现在显式的 `downloadModel`
  里；真正做识别的 `recognize` 先断言模型已安装，缺模型直接失败而不是去下载。
  改成测试的理由：一次性手工验证证明不了以后——任何人往转写路径上加个兜底请求，
  或让转写在模型缺失时顺手下载，断网就会重新失败，而这在联网的开发机上永远发现
  不了。现在每次 CI 都跑。
- **仍未完成，且只能由 Syc 做**：≥3 条真实中文口播的转写质量对照（判断是否需要切
  WhisperKit）、以及「丢链接 → 播放 → 转写 → 总结 → 导出」的 GUI 全链路截图。
  这两项需要人对着结果做主观质量判断，不是能自动化的门。
- 抖音双入口（Loop V-1）：扩展入口正常；手动链接入口在**未登录**时按设计引导用
  扩展。2026-07-27 加了抖音 App 自有会话后，带 Cookie 抓取能过风控，但实测服务端
  HTML（790KB）里没有任何 aweme 元数据——页面是客户端渲染的，静态抓取拿不到正文，
  现在诚实回落到「请用扩展」。渲染后抓取需要独立机制，未做。
- 工程回归证据：复审后本机转写/视频/持久化定向测试 **57/57 PASS**，Swift 全量 **406/406 PASS**，Debug/Release `LinkDigestApp` target 与 `git diff --check` 均通过。该证据只证明工程接线与失败恢复，不替代上述真实中文样本、断网和 GUI 质量门。
