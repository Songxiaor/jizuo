---
id: v02-byok-provider-boundary
category: decision
status: active
tags: [byok, provider, keychain, local-first]
title: V0.2 BYOK Provider Boundary
created: "2026-07-14T13:17:43"
updated: "2026-07-14T17:37:54"
---

## compiled_truth

# V0.2 BYOK Provider Boundary

## 当前结论

V0.2 的目标是让用户在 macOS APP 内配置一个 OpenAI-compatible Chat Completions 连接，并对当前捕获正文生成总结或翻译。该阶段仍然 local-first、免登录，不实现 LinkDigest 账号、Cloud API、同步、托管模型、多 Provider 管理、Responses API、Ollama、Q&A、SQLite 历史或导出。

V0.2 的实现前置规划集中在 `docs/specs/V0.2_BYOK_PLAN.md`。该文档是规划，不代表全部 BYOK 已进入当前代码闭环。

## 当前实现状态

任务 A「Provider profile 与 Keychain secret boundary」已完成并经 MindMux 复核通过：

- Swift Package 新增 `LinkDigestAdapters` target。
- `LinkDigestCore/ProviderConfiguration.swift` 定义 `ProviderProfile`、`APIMode`、`SecretReference`、`ProviderProfileStore`、`SecretStore` 与 `ProviderConfigurationService`。
- `UserDefaultsProviderProfileStore` 只保存非敏感 profile 字段。
- `KeychainSecretStore` 使用 Apple Security framework 保存 API Key。
- SwiftUI APP 已接入最小模型配置 UI：Base URL、模型名、SecureField API Key、保存按钮和状态文案。

任务 B「OpenAI-compatible streaming adapter 与 fake server」已完成并经 MindMux 初步复核通过：

- `LinkDigestCore/ModelProvider.swift` 定义 `RunIntent.connectionTest`、`ModelStreamEvent`、`ModelProviderFailure` 与 `ModelProvider` port。
- `OpenAICompatibleProvider` 负责 Chat Completions 请求构造、URLSession streaming、有界重试、错误映射和取消传播。
- `ChatCompletionsStreamDecoder` 将 SSE `data:` 行翻译为 delta/completed。
- `FakeOpenAICompatibleServer` 使用本地 loopback + Network.framework 自动验证 path、method/header/body、delta、`[DONE]`、401/404/413、429/5xx、断流、malformed、错误 Content-Type、取消和 secret hygiene。
- Codex 报告 `swift test` 28 项通过、Debug/Release build 通过、doctor 为 `PASS=48 WARN=2 FAIL=0`。

当前仍没有：设置页连接测试 UI、总结/翻译正文 UI、完整 RunState、SQLite、导出、多 Provider、Responses API、Ollama、Q&A、真实 Provider 自动测试、Edge 安装、签名、公证或发布。

## 组件边界

- `ProviderProfile` 只保存非敏感配置：Base URL、模型名、API 模式和 opaque `secretReference`。
- `SecretStore` 是秘密存取 port；V0.2 的 adapter 是 `KeychainSecretStore`。
- `ModelProvider` 是模型请求 port；V0.2 的 adapter 是 `OpenAICompatibleProvider`。
- `ModelRunOrchestrator` 后续负责协调 profile、secret、请求、取消、错误映射和 `RunState`。
- SwiftUI View 只发送用户意图并渲染 ViewModel 状态，不直接访问 Keychain、URLSession、UserDefaults、SQLite、文件系统或 SSE 解析。

## 秘密与数据边界

API Key 只能进入 macOS Keychain。完整 Key 不得进入 UserDefaults、SQLite、日志、`safeDetail`、fixture、截图、导出、Git、ProviderProfile、RunState 或 SwiftUI 可观察对象。Keychain 写入失败时返回稳定错误，不能降级到明文、UserDefaults、SQLite、剪贴板缓存或文件。

当前实现中，`SecureField` 的输入只在 View 局部短时存在，提交后清空；ViewModel 不持有 API Key 属性；UserDefaults 只保存 Base URL、模型名、API 模式和 opaque reference。替换 Key 时按 staged save：写新 Key → 保存新 profile → best-effort 删除旧 Key。

任务 B 中，完整 Key 作为 `stream(profile:apiKey:intent:)` 的短时参数进入 Authorization header；fake server 丢弃 header value，只记录 present/matched 布尔值；`ModelProviderFailure.description` 只输出稳定 code。

旧 Keychain item 删除失败目前是 best-effort 后的 orphan 风险：新 profile 仍有效，但旧 item 可能暂时残留。该问题不阻塞任务 A/B；后续可在任务 D 或维护任务中评估清理队列/维护入口。

## 请求与恢复语义

V0.2 只支持 OpenAI-compatible Chat Completions streaming：Base URL 被视为 API root，仅接受生产 `https` 和测试 loopback `http://127.0.0.1`；请求路径为 `{baseURL}/chat/completions`。401/403 不自动重试；404 与 413 不自动重试；429/5xx 仅在尚未收到任何 delta 时允许最多额外 2 次重试；数字 `Retry-After` 最大限制为 10 秒；收到 delta 后中断必须保留 partial 并标记 `hadOutput=true`，不自动拼接续写。用户停止必须传播到底层 URLSession，并用后续 RunState/run identifier 丢弃迟到事件。

## 任务拆分

V0.2 后续代码任务按 A→B→C→D：

1. Provider profile 与 Keychain secret boundary。（已完成）
2. OpenAI-compatible streaming adapter 与 fake server。（已完成，设置页测试连接 UI 未接入）
3. 总结/翻译 RunState、streaming UI 与取消传播。（下一步建议；可包含连接测试 UI 的 Orchestrator 接入）
4. 错误语义、秘密门禁与 V0.2 验收收口。

任务 A/B 可作为隔离实现先行；在任务 C 做浏览器→模型集成验收前，应补齐 Edge，或由 Syc 明确接受 V0.1 Edge 与 V0.2 集成两条未关闭矩阵并分别保存证据。任何情况下都不能把 V0.1 标记为已关闭。

## 系统性取舍

短期收益是已经出现第一个 V0.2 可视化配置页面，并建立了 API Key 不落入普通存储的边界；同时模型 adapter 已被 fake server 验证，后续总结/翻译 UI 不需要直接面对原始 URLSession/SSE 复杂度。长期成本是任务 C 必须继续沿 Orchestrator/RunState 设计推进；如果 SwiftUI 直接读取 Keychain 或调用 `OpenAICompatibleProvider.stream`，会破坏任务 A/B 建立的边界。

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
