---
id: v02-byok-provider-boundary
category: decision
status: active
tags: [byok, provider, keychain, local-first]
title: V0.2 BYOK Provider Boundary
created: "2026-07-14T13:17:43"
updated: "2026-07-15T01:47:01"
---

## compiled_truth

# V0.2 BYOK Provider Boundary

## 当前结论

V0.2 A–D 工程验收已完成，并作为 MAS-first 独立 Mac App 的复用基线：用户可以保存单个 OpenAI-compatible Chat Completions 配置，API Key 进入 Keychain，对当前内存正文执行总结或简体中文翻译，并观察 streaming、停止、完成、不完整和失败状态。自动验收使用 fake server，不调用真实 Provider。

## 已实现组件

- `ProviderProfile`、`SecretReference`、profile/secret ports 与 staged save。
- 非敏感 `UserDefaultsProviderProfileStore` 与 `KeychainSecretStore`。
- `ModelProvider`、`OpenAICompatibleProvider`、SSE decoder、有界重试与显式活动流取消。
- `ModelRunOrchestrator`、summarize/translate intent、RunState、stale-run 隔离和 SwiftUI 结果区。
- 22 个 stable code 的中文恢复目录、API Key redaction、sentinel tests 与独立 secret hygiene 门禁。

## MAS-first 复用方式

V0.2 的 Provider、Keychain、Orchestrator、RunState、错误和秘密边界直接复用。后续把“当前浏览器 capture”替换/扩展为 App 内粘贴文字与公开 URL，并把 Run/Artifact 接入 SQLite；不让 View 直接访问 Keychain、URLSession 或数据库。

Native Messaging、Host 与 Unix socket 不属于 BYOK 领域边界，只是当前 capture 的开发运输层。切换到 MAS 独立输入不需要重写模型 adapter 或状态机。

## 尚未完成

- 发布级 App Sandbox/MAS target 与 sandbox 中的 Keychain/URLSession 行为证据。
- App 内粘贴文字、公开 URL、SQLite 历史、删除和三种导出。
- 首次真实 Provider 发送前的数据去向提示。
- 单独连接测试 UI、Keychain orphan 维护入口与真实 Provider 抽样。

## 秘密与恢复

完整 API Key 不得进入 UserDefaults、SQLite、日志、safeDetail、fixture、截图、导出、ProviderProfile、RunState 或 SwiftUI 可观察对象。Keychain 失败不得降级明文。401 不自动重试；429/5xx 只在无输出时有限重试；流中断保留 partial 并标记 incomplete；停止必须传播到 Provider producer task。

## 关联

MAS-first 主路线见 [[native-macos-swiftui-hybrid]]；跨语言合同见 [[versioned-contracts-forward-migrations]]。


## timeline

- time: 2026-07-14T13:17:43
  kind: decision
  summary: 记录 V0.2 BYOK 规划的 Provider、Keychain、streaming、错误与任务拆分边界。
  source: docs/specs/V0.2_BYOK_PLAN.md created by Codex and reviewed by MindMux on 2026-07-14
  affects: [v02-byok-provider-boundary]

- time: 2026-07-14T17:18:18
  kind: decision
  summary: "compiled_truth updated: Codex 完成 V0.2 任务 A 后，更新 BYOK 边界页以记录 Provider profile 与 Keychain secret boundary 已实现。"
  affects: [v02-byok-provider-boundary]

- time: 2026-07-14T17:37:54
  kind: decision
  summary: "compiled_truth updated: Codex 完成 V0.2 任务 B 后，更新 BYOK 边界页以记录 OpenAI-compatible adapter 与 fake server 已实现。"
  affects: [v02-byok-provider-boundary]

- time: 2026-07-15T01:47:00
  kind: decision
  summary: Record A-D completion and MAS-first reuse boundary
  source: V0.2 acceptance plus Syc-confirmed MAS-first route 2026-07-15 / SYC-39
  affects: [v02-byok-provider-boundary]

- time: 2026-07-15T01:47:01
  kind: evidence
  summary: "V0.2 A-D 作为 MAS-first 独立 App 复用基线；只替换输入/运输并新增持久化与导出"
  source: docs/specs/V0.2_BYOK_ACCEPTANCE.md and SYC-39
  affects: [v02-byok-provider-boundary, native-macos-swiftui-hybrid]
