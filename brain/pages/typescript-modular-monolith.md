---
id: typescript-modular-monolith
title: "TypeScript 主干与模块化单体"
category: decision
status: archived
tags: [typescript, backend, architecture]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T23:39:38"
---

## compiled_truth

## 当前结论

扩展、Electron、本地领域核心、共享协议与云端服务使用 TypeScript 主干。云端从 Fastify modular monolith 起步：Identity、Entitlement、Sync、Managed AI、Usage Ledger 和 Remote Config 在同一代码库内隔离，API 与 worker 使用不同进程入口。

## 为什么

这让初期开发、事务、调试和学习保持简单，同时为按模块扩缩容保留边界。注册量增长本身不构成换语言或重写系统的理由。

## 拆分信号

只有独立资源曲线、故障隔离、团队所有权或 profiling 证明的局部性能瓶颈，才允许从稳定 contract 后拆服务。没有证据不创建微服务。

## 关联

容量信号见 [[scale-readiness-envelope]]；协议边界见 [[versioned-contracts-forward-migrations]]。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: TypeScript 主干与模块化单体"
  source: Syc-approved foundation plan 2026-07-13
  affects: [typescript-modular-monolith]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "确定共享 TypeScript 主干和先单体后按证据拆分"
  source: Syc-approved foundation plan 2026-07-13
  affects: [typescript-modular-monolith]

- time: 2026-07-13T23:39:38
  kind: reversal
  summary: "第一版收敛为 Apple-only 且原生 UI 是产品价值，桌面端改用 SwiftUI；TypeScript 仅保留在 Chromium 扩展和旧协议原型"
  source: brain archive-page
  affects: [typescript-modular-monolith]
