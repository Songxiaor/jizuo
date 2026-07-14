---
id: byok-managed-ai-split
title: "BYOK 与托管模型双路径"
category: decision
status: archived
tags: [llm, byok, billing]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T23:39:39"
---

## compiled_truth

## 当前结论

BYOK 请求由 Electron Main Process 直接发往用户配置的 Provider，LinkDigest 云端不经过、不计费、不记录 prompt。平台托管模型才进入 Cloud API，经过权益预留、队列、worker、Provider 和 Usage Ledger 结算/退款。

## 失败与成本

- 托管入口需要限流、套餐额度、全局预算和 Provider 级并发。
- 任务失败或取消必须自动释放或退款，ledger 只追加不覆盖。
- 云端或托管 Provider 不可用时，用户可切换 BYOK，已保存内容仍可导出。
- 原文送往托管路径前必须明确告知用户数据将离开本机及保留期限。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: BYOK 与托管模型双路径"
  source: Syc selected BYOK plus optional managed AI 2026-07-13
  affects: [byok-managed-ai-split]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固定模型隐私与成本的两条执行路径"
  source: Syc selected BYOK plus optional managed AI 2026-07-13
  affects: [byok-managed-ai-split]

- time: 2026-07-13T23:39:39
  kind: reversal
  summary: "P0 只实现本地 BYOK；托管模型和额度控制面退出当前 active 范围"
  source: brain archive-page
  affects: [byok-managed-ai-split]
