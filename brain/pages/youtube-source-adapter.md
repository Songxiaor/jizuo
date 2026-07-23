---
id: youtube-source-adapter
title: "YouTube 来源适配器与转写策略"
category: decision
status: active
tags: [youtube, transcription, byok]
created: "2026-07-22T22:02:15"
updated: "2026-07-22T23:32:17"
---

## compiled_truth

## YouTube 抓取现状（2026-07-22 已交付）

- 单视频硬分流：watch/shorts/live/youtu.be 永不落通用抓取（SPA 陷阱：`ytInitialPlayerResponse` 陈旧，改从 `#movie_player.getPlayerResponse()` 取实时数据）。
- 元数据 + 简介 + 观看数（frontmatter `views`，顶部眼睛图标）。
- **有字幕**：只抓视频原始语言（抓取前经播放器 API 切原始轨，非翻译轨），面板通道绕过 2025 起 timedtext 的 pot 令牌封锁；rollup 去重、`>>` 说话人换段、重试按钮噪音过滤。
- **无字幕**：App 内实时音频转写——ScreenCaptureKit 捕获本进程播放音频 → SpeechAnalyzer（volatile 实时字幕）→ 落库为 localTranscription snapshot。自动播放 + 可选 2x/1.5x 倍速，免手动点播放。官方 embed 用带 baseURL 的 iframe 宿主页规避错误 153。用 Apple Development 证书签名让 TCC 授权跨重建保留。

## 转写策略决策（Syc 2026-07-22 拍板）

- **本机实时转写保留为默认兜底**——免费、全程本机、符合 local-first；缺点是必须出声、耗时≈视频时长（可 2x）。
- **第三方 API 转写作为可选 BYOK 独立 Loop**：市面 Supadata / YouTubeTranscript.dev 类"发 YouTube URL → 服务器端 Whisper 转写 → 收文本"，能做到不用播放、几十秒出结果、覆盖 100%。合规责任在服务商。
- 技术关键：只有"发 URL 给专门服务"这类能对 YouTube 无字幕免播放；通用 Whisper API 要先有音频文件，YouTube 本地拿不到。故该路径绑定专门 YouTube 转写服务商，非任意 OpenAI 兼容 endpoint。
- **开工前置**：URL/内容出本机 = 破 local-first，必须先做数据去向审查卡 + 新 BYOK secret 面 + 设置页配置，再动手；不在疲劳 session 末尾赶工。两条路并存，用户按需选。


## timeline

- time: 2026-07-22T22:02:15
  kind: decision
  summary: "Created this page: YouTube 来源适配器与转写策略"
  source: Syc 2026-07-22
  affects: [youtube-source-adapter]

- time: 2026-07-22T22:02:42
  kind: decision
  summary: "YouTube 抓取分两层：有字幕抓原始语言字幕、无字幕走本机实时转写；第三方 API 转写为可选 BYOK 独立 Loop"
  source: brain update-truth
  affects: [youtube-source-adapter]

- time: 2026-07-22T23:32:17
  kind: reversal
  summary: "本机实时转写(ScreenCaptureKit+Apple引擎)UI 入口已撤除：实测 2x 错字40-50%+漏字、1x 太慢，速度质量双输。转写器代码保留供第三方 API Loop 复用落库路径。YouTube 无字幕改为诚实提示。高质量转写待第三方 API(发URL+服务器Whisper)Loop"
  source: "Syc 2026-07-22 实测否决"
  affects: [youtube-source-adapter]
