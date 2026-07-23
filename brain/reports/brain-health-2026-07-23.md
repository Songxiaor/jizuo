---
id: brain-health-2026-07-23
type: brain-health
title: "Brain 健康检查 - 2026年7月23日"
checked_at: "2026-07-23T12:34:03"
updated: "2026-07-23T12:34:03"
active_page_count: 15
open_high_risk_count: 5
finding_count: 7
handled_count: 0
snoozed_count: 0
---

# Brain 健康检查 - 2026年7月23日

已检查 15 个 active 页面。发现 7 个问题，其中 5 个可能误导 AI；已处理 0 个，已暂缓 0 个。

检查摘要：Checked all active Brain pages, root pages, timeline evidence, and current working-tree implementation signals. 发现多处会误导未来 AI 的知识衰减，主要集中在 YouTube 转写策略、P0/Loop 状态、协议版本、数据库迁移、BYOK/模型设置以及根页面未同步当前实现。

## 可能误导 AI

- [ ] #1 YouTube 转写 compiled_truth 与同页 reversal 直接冲突
  Status: open
  Related: page:youtube-source-adapter, apps/desktop/Sources/LinkDigestAdapters/AppAudioLiveTranscriber.swift, apps/desktop/Sources/LinkDigestAdapters/AppleSpeechVideoTranscriber.swift, apps/desktop/Sources/LinkDigestApp/YouTubeEmbedPlayer.swift, apps/browser-extension/src/content/youtube.ts
  `youtube-source-adapter` 的当前结论仍写着本机实时转写是默认兜底，但最新 reversal 明确说 UI 入口已撤除、无字幕改为诚实提示。
  > page:youtube-source-adapter compiled_truth 写道："本机实时转写保留为默认兜底"；同页 2026-07-22T23:32:17 reversal 写道："本机实时转写(ScreenCaptureKit+Apple引擎)UI 入口已撤除... YouTube 无字幕改为诚实提示。"
- [ ] #2 协议 Brain 仍声称唯一合同是 v1，但代码已引入 capture-envelope-v2
  Status: open
  Related: page:versioned-contracts-forward-migrations, contracts/capture-envelope-v2.schema.json, apps/desktop/Sources/LinkDigestCore/Resources/contracts/capture-envelope-v2.schema.json, apps/desktop/Tests/LinkDigestCoreTests/CaptureMediaContractTests.swift, apps/browser-extension/src/contract.ts
  `versioned-contracts-forward-migrations` 会让未来 AI 误以为当前只支持 `CaptureEnvelopeV1`，而实现证据显示 v2 schema、fixtures 与媒体合同已经出现。
  > page:versioned-contracts-forward-migrations compiled_truth 写道："contracts/capture-envelope-v1.schema.json 是 Swift APP、Native Host 与 TypeScript 扩展之间唯一的语言中立合同"、"当前垂直切片只实现 CaptureEnvelopeV1"；当前代码证据包含 `contracts/capture-envelope-v2.schema.json`、`apps/desktop/Sources/LinkDigestCore/Resources/contracts/capture-envelope-v2.schema.json`、`apps/desktop/Tests/LinkDigestCoreTests/CaptureMediaContractTests.swift`、`contracts/fixtures/v2-douyin-direct.json`。
- [ ] #3 SQLite 持久化边界未记录 002–008 迁移与标签/媒体等新数据面
  Status: open
  Related: page:sqlite-grdb-persistence-boundary, apps/desktop/Sources/LinkDigestPersistence/Migration002.swift, apps/desktop/Sources/LinkDigestPersistence/Migration003.swift, apps/desktop/Sources/LinkDigestPersistence/Migration008.swift, apps/desktop/Sources/LinkDigestCore/HistoryTags.swift, apps/desktop/Sources/LinkDigestCore/MediaModels.swift
  `sqlite-grdb-persistence-boundary` 仍停留在 migration 001 冻结后的下一阶段口径，但代码已出现多轮后续迁移和新的领域模型。
  > page:sqlite-grdb-persistence-boundary compiled_truth 写道："此后任何 schema 变化只能追加 002+，不得改写 001"，但没有记录后续迁移语义；当前代码证据包含 `apps/desktop/Sources/LinkDigestPersistence/Migration002.swift` 到 `Migration008.swift`、`apps/desktop/Sources/LinkDigestCore/HistoryTags.swift`、`apps/desktop/Sources/LinkDigestCore/MediaModels.swift`、`apps/desktop/Tests/LinkDigestCoreTests/HistoryDomainTests.swift` 大幅修改。
- [ ] #4 P0/Release 状态页面与 roadmap/root 当前状态明显不同步
  Status: open
  Related: page:p0-release-candidate-goal, root:roadmap, README.md, page:stable-native-host-delivery, docs/ACCEPTANCE_GUIDE.md
  `p0-release-candidate-goal` 的 compiled_truth 仍把完整可用 APP 概括为 Loop 5–9 的早期规划，而 root roadmap 与 README 已显示项目推进到 Loop 6.5/6.6/6.8/6.9、Loop 8 PASS、Loop 9 候选阶段。
  > page:p0-release-candidate-goal compiled_truth 写道："完整可用 APP 的五个产品 Loop"，且 Loop 7/8/9 仍是未来计划；root:roadmap 写道："Loop 6：工程侧已收口（2026-07-18 终审 PASS）"、"Loop 6.5 — GitHub 仓库适配器"、"Loop 6.8 — 设置页重构与模型体验"；README.md 当前写道："Loop 8 的浏览器安装事务已独立复审 PASS。当前正在完成 Loop 9 / 0.2.0 integrated local-test candidate"。
- [ ] #5 根页面仍保留 V0.1/capture bridge 早期世界观，未同步当前产品实现
  Status: open
  Related: root:mindmap, root:architecture, root:background, README.md, apps/desktop/Sources/LinkDigestApp/ManualLinkViewModel.swift, apps/desktop/Sources/LinkDigestCore/BrowserSupportInstaller.swift, apps/desktop/Sources/LinkDigestAdapters/DouyinSourceAdapter.swift
  多个 root 页面仍说当前重心是 capture bridge、BYOK/历史/导出尚未进入闭环或下一阶段是 History Sidebar，这与当前代码和 roadmap 的 Loop 9、媒体/来源适配器、浏览器安装事务实现不一致。
  > root:mindmap 写道："当前仓库的实际功能重心是 V0.1 capture bridge"、"P0 的 BYOK、SQLite、Keychain、历史和导出已经在 PRD/Architecture 中定界，但尚未进入当前代码闭环"；root:architecture 写道："下一阶段只能是 History Sidebar、详情、单项删除与重启恢复的浏览交互；当前尚未开始"；但 README.md 写道："History 浏览/详情/单项删除与单条 Markdown/纯文本/JSON 导出已完成"，代码中还有 `ManualLinkViewModel.swift`、`GitHubRepositorySourceAdapter.swift`、`DouyinSourceAdapter.swift`、`BrowserSupportInstaller.swift`、`ReadingDocumentExport.swift` 等新实现。

## 值得检查

- [ ] #6 V0.2 BYOK 边界页已被后续模型设置与 Provider 体验超越
  Status: open
  Related: page:v02-byok-provider-boundary, README.md, apps/desktop/Sources/LinkDigestCore/ProviderPreset.swift, apps/desktop/Sources/LinkDigestCore/ModelLibrary.swift, apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift, apps/desktop/Sources/LinkDigestApp/ProviderSettingsViewModel.swift
  `v02-byok-provider-boundary` 仍把多 Provider、Ollama、连接测试 UI、SQLite/导出等列为不存在或非当前能力，但代码和 README 显示设置页、模型库、Provider 预设和 Loop 6/6.8 已推进。
  > page:v02-byok-provider-boundary compiled_truth 写道："不实现... 多 Provider 管理、Responses API、Ollama、Q&A、SQLite 历史或导出"、"当前仍没有：设置页连接测试 UI"；README.md 写道："V0.2 已有完整本地工程证据；Loop 3 的发送前数据去向确认和设置页测试连接已经最终独立复审 PASS"；代码证据包含 `apps/desktop/Sources/LinkDigestCore/ProviderPreset.swift`、`apps/desktop/Sources/LinkDigestCore/ModelLibrary.swift`、`apps/desktop/Sources/LinkDigestAdapters/UserDefaultsModelLibraryStore.swift`、`apps/desktop/Sources/LinkDigestAdapters/UserDefaultsModelPreferencesStore.swift`。
- [ ] #7 GitHub 来源适配器 compiled_truth 停留在决策/未来态，未吸收工程落地证据
  Status: open
  Related: page:github-repo-source-adapter, apps/desktop/Sources/LinkDigestAdapters/GitHubRepositorySourceAdapter.swift, apps/desktop/Tests/LinkDigestAdaptersTests/GitHubRepositorySourceAdapterTests.swift, root:roadmap
  `github-repo-source-adapter` 的 compiled_truth 主要描述 Loop 6.5 将要做什么，而同页 timeline 和代码已显示工程侧通过并存在实现。
  > page:github-repo-source-adapter compiled_truth 写道："Loop 6.5:GitHub 专属适配器——公开仓库 README 原文获取..."；同页 timeline 2026-07-18T13:48:40 写道："Loop 6.5 工程侧一轮通过... reviewer 复审 PASS... READY_FOR_MANUAL_OPEN"；当前代码证据包含 `apps/desktop/Sources/LinkDigestAdapters/GitHubRepositorySourceAdapter.swift` 与 `apps/desktop/Tests/LinkDigestAdaptersTests/GitHubRepositorySourceAdapterTests.swift`。

## 时间线

- 12:34 - AI 检查完成：7 个发现（5 个高风险）。
