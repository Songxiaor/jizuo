---
id: p0-release-candidate-goal
title: "P0 Release Candidate 最终交付目标"
category: decision
status: active
tags: [p0, release, workflow, quality]
created: "2026-07-15T11:27:22"
updated: "2026-07-16T14:05:07"
---

## compiled_truth

# 最终目标

LinkDigest 当前总目标是交付一套可由 Syc 在本机完整安装和验收的 macOS P0 Release Candidate，而非零散功能演示。交付版必须贯通 Chromium 当前页捕获、Native Messaging、SwiftUI、BYOK 总结与翻译、SQLite 本地历史、删除与恢复语义、Markdown/TXT/JSON 导出、原生交互、稳定 Host 安装/升级/卸载与完整回归测试。

签名、公证、商店提交、付费和真实 Provider 凭据仍属于重大外部节点；工程必须做到发布前就绪，但执行这些动作前仍需 Syc 明确授权。Q&A、云账号、同步、托管模型、Windows、Safari 和媒体下载不进入本轮 P0 RC。

## 当前 Loop 2 状态

- 单条 History Markdown、TXT、JSON 导出已完成工程实现：详情页保持既有 toolbar 顺序，由分享菜单进入三种格式；只读/future-schema History 继续可导出，作为数据逃生口。
- 独立复审发现的文件名 UTF-8 byte budget、Run 显示归属、启动待定删除保护、v1 JSON decoder 校验和 partial usage 展示问题已完成本地修复并通过最终独立复审，P0/P1/P2 均为 0。
- 建议文件名预留版本与扩展名后按 255 UTF-8 bytes 和完整 Character 边界截断；Markdown 使用可靠 UTI，三格式默认名固定保留 .md/.txt/.json。
- App 以 activeRunTaskID 保护活跃或 launch-pending Run 的真实 Task，以 visibleRunTaskID 约束状态、输出与停止入口的 Task 归属；createRun 前不提前发布 starting，pre-start failure 或无回调返回会清理待定映射。
- formatVersion 1 JSON decoder 校验 canonical typed UUID、非负且配对的 usage/cost，以及 Task/Snapshot/Run/Artifact 引用关系，同时保留合法 NUL、空字段和 partial/interrupted 内容。
- 本地门禁为 focused AppViewModel 15/15、完整 Swift 146/146、SwiftPM Debug/Release、Xcode App/Host Debug/Release 四目标、diff、migration 001 冻结 hash与无 Migration002 全部通过；工程仍未暂存、提交、发布。

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

- time: 2026-07-16T12:41:57
  kind: evidence
  summary: "Loop 2 完成单条 Markdown、TXT、JSON 本地导出工程：只读 future-schema 历史可作为逃生口导出，139/139 Swift tests 通过；未提交、未发布。"
  source: Loop 2 implementation and local Swift test 2026-07-16
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, sam-webpage-summarizer-reference]

- time: 2026-07-16T12:42:30
  kind: decision
  summary: "将 Loop 2 导出当前状态、脱敏边界与未发布状态写入 P0 RC 真相。"
  source: Loop 2 implementation and validation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:38:31
  kind: decision
  summary: "更新 Loop 2 独立复审修复状态与 143 项本地门禁，保持待复审口径。"
  source: Loop 2 independent review fixes 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:38:31
  kind: evidence
  summary: "独立复审发现的文件名字节预算、Run 归属、decoder 与 usage 问题已本地修复；focused 22/22、Swift 143/143、SwiftPM/Xcode/migration/diff 门禁通过，等待复审。"
  source: Loop 2 local verification 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:58:56
  kind: decision
  summary: "补齐 launch-pending 删除保护并更新至 Swift 146 项本地门禁，状态保持待最终复审。"
  source: Loop 2 final local fix 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:58:56
  kind: evidence
  summary: "launch-pending 在 createRun 前保护真实 Task，starting 接管且失败或无回调会清理；App focused 15/15、Swift 146/146 与完整构建门禁通过，待最终复审。"
  source: Loop 2 final local verification 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T14:05:07
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 2 final independent re-review 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T14:05:07
  kind: evidence
  summary: "Loop 2 最终独立复审 PASS：P0/P1/P2 均为 0；Swift 146/146、SwiftPM 与 Xcode 四目标、diff、migration 001 冻结 hash 和无 Migration002 证据通过。"
  source: Loop 2 final independent re-review 2026-07-16
  affects: [apps/desktop, docs/LEARNING_LOG.md]
