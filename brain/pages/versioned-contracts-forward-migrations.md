---
id: versioned-contracts-forward-migrations
title: "版本化协议与只向前迁移"
category: decision
status: active
tags: [contracts, migrations, compatibility]
created: "2026-07-13T19:49:42"
updated: "2026-07-14T00:50:40"
---

## compiled_truth

## 当前结论

`contracts/capture-envelope-v1.schema.json` 是 Swift APP、Native Host 与 TypeScript 扩展之间唯一的语言中立合同，使用 JSON Schema Draft 2020-12。TypeScript 由 Ajv 2020 执行；Swift 运行时加载打包后的同一 Schema 并执行 `required`、`const`、`enum`、类型、长度、pattern 和 format 规则。不能只同步 Schema 文件或复制类型后声称两端一致。

JSON Schema 无法直接表达的跨字段规则（当前为 `capture.characterCount` 等于正文 Unicode scalar 数）作为具名 semantic invariant，由 Swift 与 TypeScript 使用相同算法和 `contracts/fixtures/` 验证。`scripts/check-contract-sync.sh` 阻止 Swift Package resource 副本与根合同漂移。

## 兼容与失败规则

- 兼容字段只新增为可选；破坏性变化发布新 major version。
- 未知可选字段宽容读取；不支持 major version 返回 `PROTOCOL_VERSION_UNSUPPORTED`。
- URL 只接受 `http/https`；正文为空、字符数不一致和超限分别返回稳定错误。
- Native Messaging 使用 4-byte little-endian framing，frame 上限 4 MiB；半包、超限和超时必须分层处理。
- 重复 `requestId/idempotencyKey` 不得重复更新 Application inbox。
- Swift 与 TypeScript 的共同 fixtures 和各自 runtime tests 是合同是否真实一致的证据；单独一份手写 interface、Codable struct 或同步脚本都不够。

## P0 稳定模型

当前垂直切片只实现 `CaptureEnvelopeV1`、`NativeResponse` 与 `AppError`。`Task`、`ContentSnapshot`、`Run`、`Artifact` 保留为后续本地能力；云端模型不进入 P0 合同实现。

## 关联

桌面与扩展进程边界见 [[native-macos-swiftui-hybrid]]；本地边界见 [[hybrid-local-first-cloud-boundary]]。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 版本化协议与只向前迁移"
  source: Syc-approved foundation plan 2026-07-13
  affects: [versioned-contracts-forward-migrations]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固定跨边界协议和数据升级规则"
  source: Syc-approved foundation plan 2026-07-13
  affects: [versioned-contracts-forward-migrations]

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "将协议边界从 Electron/Cloud 主干收敛为 Swift 与 TypeScript 的语言中立 P0 合同"
  source: SwiftUI route approval 2026-07-13
  affects: [versioned-contracts-forward-migrations]

- time: 2026-07-14T00:50:40
  kind: decision
  summary: "V0.1 落地 JSON Schema 双端执行与共同 fixtures 门禁"
  source: LinkDigest V0.1 implementation and Sol final review 2026-07-14
  affects: [versioned-contracts-forward-migrations]
