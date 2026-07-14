---
id: native-macos-swiftui-hybrid
title: "macOS SwiftUI 与 Chromium 扩展混合架构"
category: decision
status: active
tags: [swiftui, appkit, extension, architecture]
created: "2026-07-13T23:39:38"
updated: "2026-07-15T01:47:00"
---

## compiled_truth

## 当前结论

LinkDigest 首发采用 MAS-first：macOS App 使用 Swift + SwiftUI，并且必须脱离 Chromium 扩展完成“粘贴文字或公开 URL → 核查来源与原文 → BYOK 总结/简体中文翻译 → 本地历史/删除 → Markdown、纯文本、JSON 导出”的独立闭环。Chromium 扩展继续使用 TypeScript/WXT，但只有 App Sandbox 与安全 loopback bridge 都有可复现证据后才进入 App Store 首发；否则扩展继续 backlog。

## 已有证据继续复用

V0.1 已验证 `CaptureEnvelopeV1`、WXT 当前 DOM 捕获、Swift/TypeScript 双端合同、结构化错误，以及 Chrome/Brave 当前页进入 SwiftUI。V0.2 已完成单 ProviderProfile、Keychain secret、OpenAI-compatible Chat Completions streaming、RunState、停止/不完整结果、中文恢复文案、redaction 与 secret hygiene。这些合同、Core、Adapter、UI 状态和测试继续复用，不从零重写。

## 运输层反转

当前 `LinkDigestNativeHost`、Native Messaging manifest、4-byte framing 与 `/tmp/linkdigest-<uid>.sock` 只作为开发证据，或未来公证 DMG 的候选运输层。它们没有 App Sandbox、MAS target、签名或商店审核证据，不是 MAS 主路线，也不能成为 Mac App 首次价值的前置条件。

Edge 尚未验收，但不再阻塞 MAS 独立闭环。Edge、稳定 Host 安装、Developer ID 签名和公证留在未来增强/DMG 路线，仍需 Syc 单独授权。

## 当前缺口

- App 内粘贴文字与公开 HTTP(S) URL 输入尚未实现。
- 发布级 MAS target、entitlements 与 sandbox 行为尚未验证。
- 扩展安全 loopback bridge 尚未实现；Provider fake server 的 loopback 测试不等于产品 bridge。
- SQLite 历史、删除、只读恢复和 Markdown/TXT/JSON 导出尚未实现。

## 不可变边界

- macOS 原生 SwiftUI、local-first、Provider-neutral。
- Swift 与 TypeScript 通过版本化语言中立合同交接。
- API Key 只进入 Keychain；Cookie、Token、私人正文与完整私人 URL不进入普通日志。
- Cookie、平台专用适配、媒体和云端保持 deferred。
- 路线反转先写入 Project Brain，再同步 PRD、Architecture、Roadmap 与验收。

## 关联

跨语言合同见 [[versioned-contracts-forward-migrations]]；BYOK 边界见 [[v02-byok-provider-boundary]]；本地与云边界见 [[hybrid-local-first-cloud-boundary]]。


## timeline

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "Created this page: macOS SwiftUI 与 Chromium 扩展混合架构"
  source: Syc confirmed Apple-only v0.1 direction 2026-07-13
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "确认 Apple-only 第一版采用 SwiftUI 主体与 TypeScript 扩展"
  source: Syc approval 2026-07-13
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-14T00:50:40
  kind: decision
  summary: "记录 V0.1 独立 Host 与 Unix socket 实施边界"
  source: LinkDigest V0.1 implementation and automated vertical smoke 2026-07-14
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-14T02:41:06
  kind: decision
  summary: "补录 Chrome/Brave 真实验收与 Native Host 安装门禁"
  source: LinkDigest V0.1 Chrome/Brave acceptance and Sol-reviewed installer gate 2026-07-14
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-15T01:47:00
  kind: decision
  summary: MAS-first replaces Native Messaging-first release route
  source: Syc-confirmed LinkDigest project route 2026-07-15 / SYC-39
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-15T01:47:00
  kind: reversal
  summary: "首发改为 MAS-first 独立 Mac App；Native Messaging 保留为开发证据或未来公证 DMG 候选"
  source: Syc-confirmed LinkDigest project route 2026-07-15 / SYC-39
  affects: [native-macos-swiftui-hybrid, v02-byok-provider-boundary]
