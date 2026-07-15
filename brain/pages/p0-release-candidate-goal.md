---
id: p0-release-candidate-goal
title: "P0 Release Candidate 最终交付目标"
category: decision
status: active
tags: [p0, release, workflow, quality]
created: "2026-07-15T11:27:22"
updated: "2026-07-15T16:56:54"
---

## compiled_truth

# 最终目标

LinkDigest 当前总目标是交付一套可由 Syc 在本机完整安装和验收的 macOS P0 Release Candidate，而非零散功能演示。交付版必须贯通 Chromium 当前页捕获、Native Messaging、SwiftUI、BYOK 总结与翻译、SQLite 本地历史、删除与恢复语义、Markdown/TXT/JSON 导出、原生交互、稳定 Host 安装/升级/卸载与完整回归测试。

签名、公证、商店提交、付费和真实 Provider 凭据仍属于重大外部节点；工程必须做到发布前就绪，但执行这些动作前仍需 Syc 明确授权。Q&A、云账号、同步、托管模型、Windows、Safari 和媒体下载不进入本轮 P0 RC。

## 质量门禁

- 跨语言 JSON Schema、Domain/Port/Adapter 边界和 local-first 原则不得为赶进度破坏。
- SQLite binding 先通过许可证、Release 构建、事务、迁移、备份与只读恢复 spike，再承载用户历史。
- migration 只向前；失败时保留原数据库并进入只读导出逃生口，不以删库恢复。
- 每个阶段由 Sol 规划、Luna 实施、Sol 审查；实施者拥有单一写入边界，审查不与实施并发写入。
- 每阶段必须通过自动测试、失败路径、安全检查和文档/Brain 一致性检查；阻断项在内部修复后才进入下一阶段。
- 最终交付前执行从干净安装到捕获、模型、历史、导出、重启恢复、升级和卸载的完整验收。

## 对重构风险的约束

不承诺未来永远不发生局部重构；承诺不把未经验证的核心依赖、不可迁移数据结构、混乱职责或临时测试路径包装成最终架构。产品细节优化可以迭代，基础边界失败必须在进入下游功能前被门禁拦截。

## 协作方式

Syc 不承担日常重复测试。HanaAgent 作为唯一总控，使用 Sub-agent 完成规划、实施和独立审查；普通开发与可逆修复自动推进，只有重大外部动作、产品路线反转或不可逆风险才请求确认。


## timeline

- time: 2026-07-15T11:27:22
  kind: decision
  summary: "Created this page: P0 Release Candidate 最终交付目标"
  source: Syc conversation 2026-07-15
  affects: [p0-release-candidate-goal]

- time: 2026-07-15T11:27:22
  kind: decision
  summary: "冻结 LinkDigest P0 RC 最终范围、质量门禁与多 Agent 交付方式。"
  source: Syc conversation 2026-07-15
  affects: [p0-release-candidate-goal]

- time: 2026-07-15T11:34:17
  kind: evidence
  summary: "Sol 完成 P0 RC 顺序化实施计划；主控补齐 Brain/git 基线并将全部 Sub-agent 路由修正为 Sol。"
  source: P0 RC planning subagent 2026-07-15
  affects: [p0-release-candidate-goal, planner-executor-review-loop]

- time: 2026-07-15T11:58:09
  kind: evidence
  summary: "V0.1 三浏览器工程门禁经 Sol xhigh 复审通过，允许进入 SQLite binding spike。"
  source: Sol xhigh re-review 2026-07-15
  affects: [p0-release-candidate-goal, native-macos-swiftui-hybrid]

- time: 2026-07-15T12:24:07
  kind: evidence
  summary: "SQLite binding/recovery spike ACCEPT；独立复审允许冻结 GRDB 7.11.1 并进入正式四模型与 migration 001。"
  source: Sol xhigh SQLite spike review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:32:27
  kind: decision
  summary: "以 Sam Webpage Summarizer 为 UI/产品架构对标：借鉴原生双栏、历史详情、local-first、rerun、usage/cost；不复制品牌，不引入 P0 Q&A/Safari。"
  source: Syc direction 2026-07-15
  affects: [p0-release-candidate-goal, sam-webpage-summarizer-reference, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:40:23
  kind: decision
  summary: "正式历史模型已冻结：canonical archive、正文版本 Snapshot、显式 Rerun、delivery ledger、Unicode scalar 与整数微货币 usage/cost。"
  source: P0-RC-02 planning 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, sam-webpage-summarizer-reference]

- time: 2026-07-15T13:44:47
  kind: evidence
  summary: "P0-RC-02A 正式领域、五表 migration 001 与 GRDB Repository 经独立复审通过；允许进入 02B App 接线。"
  source: Sol xhigh 02A re-review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T16:56:54
  kind: evidence
  summary: "P0-RC-02B App capture/run persistence wiring 经多轮MUST FIX与最终独立Sol复审PASS；共享StorageWriteGate、并发Capture permit queue、Run持久化与协议hardening关闭，主线程Swift 117/117、Web、SwiftPM与Xcode四目标通过。"
  source: P0-RC-02B final review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, planner-executor-review-loop]
