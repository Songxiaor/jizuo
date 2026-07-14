---
slug: architecture
title: System architecture
role: system architecture
updated: "2026-07-15T01:47:01"
---

# System architecture

## MAS-first 目标系统

```mermaid
graph TD
  User[User] --> Input[SwiftUI independent input]
  Input --> Text[Pasted text]
  Input --> URL[Public HTTP(S) URL]
  Text --> Router[Versioned content input port]
  URL --> Fetch[Sandboxed public page fetcher]
  Fetch --> Router
  Router --> Core[Task Orchestrator / Domain]
  Core --> Keychain[Keychain SecretStore]
  Core --> Provider[OpenAI-compatible Provider]
  Core --> SQLite[SQLite Repository]
  Core --> Export[Markdown / TXT / JSON Exporter]
  Browser[Conditional WXT current DOM] -. sandbox + secure loopback gate .-> Router
```

Mac App 必须不安装扩展也能完成输入、原文核查、总结/简体中文翻译、历史、删除和导出。扩展只增加输入来源。

## 已实现并复用

| 区域 | 当前事实 |
|---|---|
| Contract | `CaptureEnvelopeV1` JSON Schema、共同 fixtures、Swift/TypeScript 双端执行 |
| Browser | WXT MV3 当前 DOM 捕获；Chrome/Brave 真实验收 |
| Development transport | Native Host、framing、大小/超时、Unix socket；不是 MAS 主路线 |
| BYOK | ProviderProfile、Keychain、Chat Completions streaming、重试、取消 |
| Application/UI | ModelRunOrchestrator、RunState、总结/简体中文翻译与错误恢复 |
| Safety | redaction、sentinel tests、secret hygiene 与 CI |

## 尚未实现

- 发布级 MAS target、entitlements 与 App Sandbox 证据。
- App 内粘贴文字、公开 URL 与统一内容输入 port。
- SQLite 历史、删除、迁移/只读恢复。
- Markdown、纯文本、JSON 导出。
- 扩展安全 loopback bridge。

## 依赖方向

SwiftUI View 只发送意图和渲染状态；Application 协调输入、模型、存储和导出；Domain 不依赖浏览器、Provider 品牌、SQLite binding 或运输层；Adapters 把平台错误映射为稳定 AppError。API Key 只进入 Keychain 和一次请求的短时内存。

## 发布边界

先在 sandboxed Release 中关闭独立闭环，再单独验证 loopback bridge。bridge 失败时首发移除扩展。Edge、稳定 Native Host、Developer ID 签名与公证属于未来增强/DMG 路线，不阻塞独立 MAS App。
