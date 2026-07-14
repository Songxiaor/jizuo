---
id: single-project-brain-and-doctor
title: "唯一 Project Brain 与 doctor 门禁"
category: decision
status: active
tags: [brain, governance, doctor]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T19:49:42"
---

## compiled_truth

## 当前结论

LinkDigest 只维护一套项目记忆：根 `BRAIN.md` 是协议，`brain/` 是数据，`./scripts/brain` 是所有 Agent 的统一读写入口。不得为 Codex、Claude、Cursor 等创建互相分叉的项目记忆。

## Doctor

`./scripts/doctor` 以只读方式检查入口文件、Brain 路径和根页面、坏链、架构与学习规则、敏感信息候选和 Git 基线。它只报告 PASS/WARN/FAIL，不自动修复、安装、提交或发送数据。

## 边界

- Project Brain 只保存半年后仍影响开发且难以从代码重建的决策。
- 完整产品行为在 PRD，当前组件边界在架构文档，容量公式在容量模型；Brain 保存决策原因和反转条件，不复制全文。
- Brain 只能通过 CLI 修改；反转必须追加 timeline reversal。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 唯一 Project Brain 与 doctor 门禁"
  source: Syc requested reference memory governance 2026-07-13
  affects: [single-project-brain-and-doctor]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "建立统一项目记忆入口和只读健康检查"
  source: Syc requested reference memory governance 2026-07-13
  affects: [single-project-brain-and-doctor]
