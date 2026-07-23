# 交接文档（2026-07-24 更新）

> 本文件是新会话的接手入口。7/23 深夜批次与 7/23 白天批次详情见 `docs/LEARNING_LOG.md` 末尾。

## 7/24 批次（详见 LEARNING_LOG 末条，含 python 补丁事故复盘——必读）

- 列表处理状态徽标（转写/总结/脑图）、重复链接拦截提示、摘录+我的笔记（Migration011）、微信抓取子框架修复、抓取队列（提交即关窗）、「已复制」药丸+选中即复制。
- **构建纪律（血泪版）**：SwiftPM 串行、`ps auxww` 查进程、0% CPU 主进程≠挂起、绝不超时杀构建、py 脚本改码禁用切片 replace、写后必查 wc -l。

## 7/23 晚间批次（Claude 主控，已部署未 commit 时段的续篇，详见 LEARNING_LOG 末条）

- **脑图输出**：媒体卡与原文之间新增脑图区；LLM 抽大纲 JSON + 本地布局渲染 SVG，两主题换肤零 token；可编辑/导出 SVG/脑图+原文 HTML；灯箱「识别文字」秒回大纲。Migration009。
- **标签叠加筛选**：侧栏普通点击=AND 叠加，⌘=只看此标签，可清空；脑图分支标题自动入标签。
- **token 总账**：Migration010 台账表；顶部 Token=全部 LLM 操作累计（Run+整理+脑图）。
- **自动处理管线已完成**：设置页四开关（默认全关），新内容自动 转写→整理→总结→脑图；勾选=持久授权不逐次弹窗。
- **P0 已修复**：日用 App 数据根曾被烤到 /private/tmp（重启即清空）；现默认写真实 `~/Library/Application Support/LinkDigest`，隔离根仅 `--isolated-data` 显式启用。**部署后验证 Info.plist 无 LSEnvironment 覆盖。**
- **标签体系已修正**：标签只来自"跨文章主题词"（总结 prompt + 脑图大纲 tags 字段，同次调用零额外成本），分支标题永不入标签；侧栏为 count 降序药丸云，点击叠加 AND。
- **钥匙串**：凭据会话级缓存，管线只读一次；首次弹窗请点「始终允许」。

## 7/23 白天批次（Claude 主控直接实施，已部署日用 App，全部已提交）

- **转写稿 LLM 整理**：视频卡「整理文稿」按钮把转写文字发给 BYOK 聊天模型修标点/分段/错别字（prompt 禁改写）；整理稿落库为最新 localTranscription snapshot，原稿保留。设置页新增「整理模型」（留空继承总结模型）与「转写后自动整理」（默认关，仍先弹发送确认）。
- **排版归一化**：`TranscriptTidyNormalizer` 确定性处理模型两种换行方言（每句一行 / 空行分段+硬换行）并清 CJK 间空格；根因是 Markdown 阅读区把单换行折叠成空格。
- **数字接缝修复**：`TimedTranscriptionAccumulator` 三处守卫（停顿断段、join 补空格、超长切段），"9.7" 不再被本机转写分段腰斩。
- **token 摘要**：整理完成状态行即时显示 chat usage（分片累计）；evidence 表列固定未入库，持久化需迁移，属独立任务。
- **环境事故修复**：系统重启清 `/tmp` 导致三浏览器 NMH manifest 指向失效构建目录、扩展全断；已改指 `~/Applications` 日用 App 并留时间戳备份。**教训：manifest 永远不要指向 tmp 构建目录。**

## 项目

- 路径：`/Users/song/Documents/Codex/link-summary-app`（macOS SwiftUI 桌面 App + WXT 浏览器扩展）
- 产品：local-first 链接理解工具。当前主线为 macOS 原生优先，扩展 ↔ App 走 Native Messaging。
- 详细规划见 `brain`（`./scripts/brain read-root roadmap`）；今晚逐条改动记在 `docs/LEARNING_LOG.md` 末尾。

## 日用候选与部署方式（务必照做，否则每次改动都要重新授权）

日用 App：`~/Applications/LinkDigest Debug.app`

```bash
cd /Users/song/Documents/Codex/link-summary-app
python3 scripts/build-debug-candidate.py --output /private/tmp/<名>
pkill -f "LinkDigest Debug.app"; sleep 2
rm -rf "$HOME/Applications/LinkDigest Debug.app"
cp -R "/private/tmp/<名>/LinkDigest Debug.app" "$HOME/Applications/"
# 稳定证书签名：保住屏幕录制等 TCC 授权跨重建不失效
codesign --force --deep --sign "Apple Development: 8617836997232 (AJRHNR449C)" "$HOME/Applications/LinkDigest Debug.app"
open "$HOME/Applications/LinkDigest Debug.app"
```

扩展同步到浏览器加载目录：

```bash
rsync -a --delete "/private/tmp/<名>/extension/" "/Users/song/Applications/LinkDigest-extension-0.2.0/"
```

构建 / 测试：

```bash
cd apps/desktop && swift build --disable-sandbox
cd apps/desktop && swift test --disable-sandbox --filter <SuiteName>
cd apps/browser-extension && npx vitest run
```

## 7/23 已完成并经 Syc 验收（细节在 LEARNING_LOG 末尾四条）

- **视频影院模式**：黑屏/边框 bug 修复后，按 Syc 要求泛化为全视频底层能力——`VideoCinemaController`（`YouTubeEmbedPlayer.swift`）支持 `.youTube(videoID)`（共享 WKWebView 池）与 `.player(AVPlayer, aspectRatio)`；YouTube 嵌入卡、本机视频卡、流媒体卡统一「放大」按钮（视频正下方右对齐）。
- **本机转写**：标点尝试全部回退（模型原生标点即当前上限，Apple Intelligence 此机不可用）；流式节流修卡顿；重新转写立即清旧文本流式上屏。
- **在线转写通本机文件**：本机视频卡新增「在线转写」（Whisper 级文字+标点）。**Syc 需在设置页配好「在线转写模型」才可用**（如 Groq whisper-large-v3-turbo）。
- **空格播放**：机制级兜底（`PlayerSpaceKeyToggle`），焦点空置时空格切换播放器；点击输入框外自动释放搜索框焦点。Syc 待真键盘最终确认。

## Syc 明早统一手动测试清单（7/23 深夜批次，全部已部署到日用 App）

1. **空格播放（真键盘）**：选中视频条目直接按空格应播/停；搜索框输入时空格应正常打字。
2. **三种视频卡「放大」**：抖音本机视频、YouTube 嵌入、流媒体卡都应有视频下方右对齐的「放大」；影院内边框贴合视频自身比例、Esc/暗区退出、进度不丢。
3. **YouTube 音频不再后台泄漏（深夜新修）**：YouTube 视频播放中切到别的条目，声音应立即停止。
4. **微信抓取回归（深夜动过导航锁定签名，建议抽一条公众号文章验证）**：桌面 App 手动添加微信链接应正常抓取。
5. **在线转写**：设置页配好「在线转写模型」后，本机视频卡「在线转写」应可用，产出带完整标点的文字。
6. **重新转写**：旧文本立即清空、流式上屏、滚动不卡。

## 已知失败（勿慌，是设计漂移不是回归）

桌面全量测试 609 中 **9 个失败**：`CaptureMediaContractTests`（2 例）+ `CaptureReceiverTests`（1 例）。根因已查明：分支未提交工作让 V2 `ephemeralPlaybackURL` 进入 `CapturedDocument.media`（本机视频下载功能依赖，见 `CapturedDocument.swift` `init(wire: CaptureEnvelopeV2)`），而这些测试仍断言下载功能之前的旧契约「V2 永不进 media seam / 瞬态字段不进持久化输入」。**属于 receipt/manifest 漂移和解的一部分，留 Loop 9 冻结前统一改契约测试**，不要顺手改断言。

## 今晚之前批次、待 Syc 验证（细节在 docs/LEARNING_LOG.md）

- **导出干净正文**：md/txt/pdf/docx 去掉 Core 档案元数据，只留标题+最小 frontmatter+正文；PDF/Word 用主题字体（`readingFont`）且嵌入本地图片（PDF 走 NSLayoutManager，CoreText 不画附件）；JSON 单列为「导出完整数据」档案。
  - `HistoryViewModel.composeExportMarkdown`、`HistoryContentView.exportCleanText/exportStyledDocument`、`ReadingDocumentExport`。
- **YouTube 本机实时转写已撤除**（实测 2x 错字 40-50%、1x 太慢，速度质量双输）。转写器代码保留（`AppAudioLiveTranscriber`、ViewModel `startLivePlaybackTranscription` 落库路径、`HistoryViewModelTests`）供第三方 API Loop 复用。
- **小红书/B站抓取降级**：扩展检测到这两个平台给人话提示，不落 SPA 外壳垃圾（`PLATFORM_NOT_SUPPORTED`）。
- **列表两排时间、图片灯箱+OCR、跨段连续选择、设置页浅色主题、X 推广条过滤、拷贝全文** 等前序批次。

## 未关的账

- **NMH manifest 防复发**：让浏览器内「Browser Support」安装流程与任何脚本渲染的 manifest 固定指向 `~/Applications` 日用 App 路径，禁止写 tmp 构建路径；下次重启前验证。
- **整理/转写 token 持久化**（可选）：现在只即时显示；要进历史需给 evidence 表加列（迁移）。

- **Loop V-2 断网转写门**：抖音三条真机、断网转写验证（工程侧早就绪，等真机）。
- **YouTube 第三方 API 转写 Loop**：Supadata 类「发 URL + 服务器端 Whisper」，快+准但破 local-first + 付费 key；开工前先做数据去向审查卡 + secret 面 + 设置页配置。决策记在 `brain` 页 `youtube-source-adapter`（含 reversal）。注：7/23 已给**本机文件**接通在线转写（`/audio/transcriptions` 分片上传，同意弹窗齐备），此 Loop 只剩 YouTube（加密流、无本地文件）场景。
- **receipt/manifest 漂移和解 + Edge 死路径**：留 Loop 9 冻结前统一处理（上方 9 个契约测试失败即其可见面）。
- **`AppAudioLiveTranscriber` 并发警告**：休眠代码的 Sendable 警告数条，复用该模块时一并清理。

## 工作约定（沿用 Syc 全局规则）

- 称呼 Syc，中文；技术标识/路径/命令保持原文。
- 依赖当前状态的结论先现场验证，区分事实/推断/未知。
- 改代码前读现有实现、匹配既有模式；改后跑与风险相称的测试。
- 不自动 `git add/commit/push`、不自动部署日用 App 之外的外部写入、不擅自花费/账号操作。
- 候选每次用同一 Apple Development 证书签名，保住 TCC 授权。
- 创建用户可见文件前确认保存位置（Syc 给出完整路径即视为已确认）。
