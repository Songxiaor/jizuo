---
id: brain-health-2026-07-24
type: brain-health
title: "Brain 健康检查 - 2026年7月24日"
checked_at: "2026-07-24T14:57:06"
updated: "2026-07-24T14:57:06"
active_page_count: 15
open_high_risk_count: 5
finding_count: 8
handled_count: 0
snoozed_count: 0
---

# Brain 健康检查 - 2026年7月24日

已检查 15 个 active 页面。发现 8 个问题，其中 5 个可能误导 AI；已处理 0 个，已暂缓 0 个。

检查摘要：检查了全部 15 个 active 决策/参考页、6 个 root 页与最近 6 次 commit 及 working tree。发现 Brain 严重滞后于代码现状:roadmap/架构/stack 仍停在 Loop 5-6 阶段,而代码已交付 Loop 6.5/6.6/6.8/6.9/7/8/9(含 Migration002-011、capture-envelope-v2、Douyin/X/微信/YouTube 适配器、BrowserSupportInstaller、扩展身份工件),多张 root 页与 compiled_truth 明显过时且会误导未来 AI。

## 可能误导 AI

- [ ] #1 root:architecture 与 stack 声称 migration 001 冻结,代码已到 Migration011 且新增 v2 合同
  Status: open
  Related: root:architecture, root:stack, sqlite-grdb-persistence-boundary, versioned-contracts-forward-migrations, apps/desktop/Sources/LinkDigestPersistence/Migration011.swift, contracts/capture-envelope-v2.schema.json
  架构页仍写「migration 001 SHA 固定…未来只能追加 002+」「migration 001 已冻结」,但代码已落地 Migration002-011 与 capture-envelope-v2.schema.json,持久化边界页也未更新。
  > root:architecture「migration 001 SHA-256 固定为 2402fd0…未来只能追加 002+」；code:LinkDigestPersistence/Migration002.swift…Migration011.swift、contracts/capture-envelope-v2.schema.json 均已新增
- [ ] #2 root:roadmap/mindmap 的 P0 非目标与已完成范围与代码严重冲突
  Status: open
  Related: root:background, root:mindmap, root:roadmap, apps/desktop/Sources/LinkDigestAdapters/DouyinSourceAdapter.swift, apps/desktop/Sources/LinkDigestAdapters/XTweetResolver.swift
  root:background 与 mindmap 把 YouTube/B站字幕、抖音、小红书、X 等列为 P0 非目标,但代码已交付 DouyinSourceAdapter、XTweetResolver/XBookmarksSync、YouTubeEmbedPlayer、WeChatWKWebViewCaptureService 等多平台适配器。
  > root:background「P0 非目标: …YouTube/B 站字幕、小红书、抖音、X 等专用平台适配」；code: DouyinSourceAdapter.swift、XTweetResolver.swift、XBookmarksSync.swift、YouTubeEmbedPlayer.swift、WeChatWKWebViewCaptureService.swift 已实现
- [ ] #3 p0-release-candidate-goal compiled_truth 停在 r4b/Loop 5,已远落后于 Loop 8-9 现状
  Status: open
  Related: p0-release-candidate-goal, root:roadmap, README.md, apps/desktop/Sources/LinkDigestCore/ManualLinkCapture.swift
  该页 compiled_truth 仍以 r4b GUI_BASELINE_PASS 与「Loop 5 首先执行」为最新结论,但 README 与代码显示 Loop 6-8 已收口、正在 Loop 9 / 0.2.0 integrated candidate,manual add/clipboard 也已不再 disabled。
  > page compiled_truth「因此,r4b 的准确状态调整为 GUI_BASELINE_PASS / PRODUCT_INCOMPLETE…Loop 5 首先执行」；README.md:16「Loop 8 的浏览器安装事务已独立复审 PASS。当前正在完成 Loop 9 / 0.2.0 integrated local-test candidate」；code: ManualLinkCapture.swift、ManualLinkViewModel.swift 已交付
- [ ] #4 stable-native-host-delivery 仍停在 r4b READY_FOR_MANUAL_OPEN,未反映 Loop 8 生产安装器已实现
  Status: open
  Related: stable-native-host-delivery, apps/desktop/Sources/LinkDigestCore/BrowserSupportInstaller.swift, apps/desktop/Sources/LinkDigestApp/BrowserSupportViewModel.swift
  该页结论为 r4b local-test DMG「产品和公开发布继续 BLOCKED」,但代码已交付 BrowserSupportInstaller、BrowserSupportViewModel、release_unit/local_test_release 等生产安装/发布工程,应回写。
  > page compiled_truth「当前状态为 READY_FOR_MANUAL_OPEN,尚未由 Syc 手工启动 App…manual add/clipboard 仍 disabled。产品和公开发布继续 BLOCKED」；code: BrowserSupportInstaller.swift(1266 行)、BrowserSupportViewModel.swift、scripts/native-host/release_unit.py 已实现
- [ ] #5 youtube-source-adapter reversal 与 working tree 新增 X bookmarks/timeline 未回写
  Status: open
  Related: youtube-source-adapter, apps/desktop/Sources/LinkDigestCore/XBookmarksSync.swift, apps/desktop/Sources/LinkDigestAdapters/XTweetResolver.swift
  YouTube 页最新 reversal 撤除本机实时转写并「待第三方 API Loop」,但 commit b8251a7 已引入 OpenAICompatibleAudioTranscriber/OnlineAudioTranscription;且 working tree 新增 XBookmarksSync、XTweetResolver、x-timeline/x-bookmarks 等未在任何 Brain 页记录的新来源适配器。
  > ?? apps/desktop/Sources/LinkDigestCore/XBookmarksSync.swift、apps/desktop/Sources/LinkDigestAdapters/XTweetResolver.swift、apps/browser-extension/src/content/x-bookmarks.ts 为未跟踪新文件,无对应决策页

## 值得检查

- [ ] #6 github-repo-source-adapter 仍为「Terra 实施中/待 Syc 人工验收」,代码已交付且被更大范围取代
  Status: open
  Related: github-repo-source-adapter, apps/desktop/Sources/LinkDigestAdapters/GitHubRepositorySourceAdapter.swift, apps/desktop/Sources/LinkDigestCore/SourceAdapter.swift
  该页 timeline 最新为 loop65-candidate 待验收,但代码已合入 GitHubRepositorySourceAdapter.swift(420 行)及 SourceAdapter 接缝,并已被后续多适配器体系覆盖,compiled_truth 应更新为已落地。
  > page timeline「候选 loop65-candidate-20260718…READY_FOR_MANUAL_OPEN,待 Syc 人工验收」；code: GitHubRepositorySourceAdapter.swift、SourceAdapter.swift 已实现
- [ ] #7 v02-byok-provider-boundary 声称多项能力「当前仍没有」,代码已实现 Ollama/多 Provider/连接测试
  Status: open
  Related: v02-byok-provider-boundary, apps/desktop/Sources/LinkDigestCore/ProviderPreset.swift, apps/desktop/Sources/LinkDigestApp/ProviderSettingsViewModel.swift
  该页写 V0.2「不实现…多 Provider 管理、Ollama…当前仍没有: 设置页连接测试 UI…多 Provider…Ollama」,但代码已交付 ProviderPreset(含 Ollama 本地)、ModelLibrary(GET /models)、ProviderSettingsViewModel 连接测试等。
  > page compiled_truth「当前仍没有: 设置页连接测试 UI…多 Provider、Responses API、Ollama」；code: ProviderPreset.swift、ModelLibrary.swift、ProviderSettingsViewModel.swift(626 行)已实现
- [ ] #8 root:flow 声称「02B 已关闭,下一阶段只能是 History Sidebar」与现状不符
  Status: open
  Related: root:flow, apps/desktop/Sources/LinkDigestApp/HistoryContentView.swift, apps/desktop/Sources/LinkDigestCore/HistoryTags.swift
  flow 根页仍表述当前阶段为 History Sidebar 尚未开始,但历史浏览/详情/导出/标签/思维导图等均已实现,流程图未覆盖 manual link、source adapter、media 等新路径。
  > root:flow「02B 已关闭。下一阶段只能是 History Sidebar、详情、单项删除与重启恢复的浏览交互;当前尚未开始」；code: HistoryContentView.swift(+3845 行)、HistoryTags.swift、MindMapStore.swift 已实现

## 时间线

- 14:57 - AI 检查完成：8 个发现（5 个高风险）。
