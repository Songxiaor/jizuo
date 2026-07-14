---
id: scale-readiness-envelope
title: "10 万与 100 万注册容量目标"
category: decision
status: archived
tags: [scale, capacity, reliability]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T23:39:38"
---

## compiled_truth

## 当前结论

LinkDigest 从第一天以 10 万和 100 万注册用户的可演进边界设计，但不提前购买对应生产容量。10 万准备度使用 3 万 MAU、8 千 DAU、1 千峰值在线；100 万准备度使用 30 万 MAU、8 万 DAU、1 万峰值在线。云端压测上限为 1,000 RPS 短时突发、100 jobs/s 入口、100 万 User 和 1 亿条同步元数据。

## 边界

- 注册用户不等于并发；真实 MAU、DAU 和行为数据出现后更新模型，不推翻组件边界。
- 本地提取、BYOK 和 SQLite 操作不计入 LinkDigest 云端 RPS。
- 微服务、分区和多区域由测量触发，不由注册数字自动触发。
- 完整公式、SLO 和恢复目标以 `docs/CAPACITY_MODEL.md` 为真相源。

## 关联

与 [[typescript-modular-monolith]]、[[hybrid-local-first-cloud-boundary]] 共同约束架构。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 10 万与 100 万注册容量目标"
  source: Syc-approved foundation plan 2026-07-13
  affects: [scale-readiness-envelope]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固化注册规模、活跃假设与压测上限"
  source: Syc-approved foundation plan 2026-07-13
  affects: [scale-readiness-envelope]

- time: 2026-07-13T23:39:38
  kind: reversal
  summary: "百万容量模型保留为远期参考，不再作为 P0 active 决策或实施门槛"
  source: brain archive-page
  affects: [scale-readiness-envelope]
