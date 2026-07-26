---
id: planner-executor-review-loop
category: decision
status: archived
tags: [workflow, codex, governance]
title: Planner–Executor–Review Loop
created: "2026-07-14T12:41:41"
updated: "2026-07-24T23:02:59"
---

## compiled_truth

# 决策

LinkDigest 采用 HanaAgent 单一总控、阶段循环和持续多 Sub-agent 协作。Multica 仅在出现长期独立队列时作为可选调度层，不成为第二真相源。

## 阶段循环

1. 总控读取 Brain、PRD、代码与证据，确定阶段最小成品、范围与风险。
2. 规划 Sub-agent 给出任务包、架构门禁与验收。
3. 一个实施 Sub-agent 持有单一写入边界；测试、安全、产品、并发、协议和集成席位可持续并行只读，提前发现返工点。
4. 实施完成后由独立审查 Sub-agent 复核；阻断项只回交原实施 Agent 修复再复审。
5. 常规读取、代码、测试、文档和可逆本地自动化默认连续推进；重大路线、破坏性操作、发布、付费、凭据、真实 Provider、首次 commit、远程写入、签名或公证才请求确认。
6. 最终只交付通过独立终审的验收版。

## 并行与稳定性

- 同一工作区同时只允许一个写入 Agent，禁止多写入者并发修改同一代码面。
- 只读席位必须职责不重叠且有明确产出；完成即回交结果并释放，下一阶段可复用席位。
- 主控在每次回复和关键节点检查状态；failed、aborted、卡住、越界或结论冲突时立即诊断、停止/续接/重建并反馈，不能等用户发现。
- 后台不流式展示时用状态摘要维持可见性，不做无意义高频轮询。

## 固定 Sub-agent 报告协议

凡当前阶段使用 Sub-agent，每次阶段性回复必须列出：

1. 当前开启数量、累计完成数量。
2. 每个席位名称、职责、read/write 权限。
3. 执行模型与推理深度（high/xhigh）。
4. 开始时间、当前状态、结束时间（完成时）。
5. ETA，并明确是估算。
6. 派发前预计 token 预算；运行中报告已使用与预计剩余；完成后报告真实 input、output、cacheRead、reasoning、totalTokens。token 从子会话 JSONL `message.usage` 聚合；平台不可观测时写“不可观测”，禁止估造。
7. 每个已完成 Agent 解决的问题、发现的风险、结论和主控纠偏动作。
8. 距离最终可测试发行 App 的完成百分比和剩余百分比，并列出权重依据、当前阻断项。百分比是门禁估算，不是工期承诺。

历史任务若派发时尚未记录预计 token，必须明确写“未预先记录”，不得事后伪造。

## 模型与深度

所有 Sub-agent 使用 `gpt-5.6-sol`。常规实现、测试、文档和明确审查用 high；架构、SQLite/migration、复杂并发、安全、恢复和终审用 xhigh。模型不可用时明确说明，不静默替换。

## 角色边界

- HanaAgent：唯一总控，负责路线、任务包、授权、集成、状态监控、token报告、进度估算、复核与耐久决策。
- 规划 Sol：只读，给出范围、边界、风险和验收。
- 实施 Sol：唯一写入者，不扩大范围、不手改 Brain。
- 测试/安全/产品/集成/协议/并发 Sol：持续只读并行，提供专项门禁。
- 审查 Sol：实施后独立复核，不与实施并发写入。
- Syc：保留产品判断与重大授权权；日常开发不承担重复测试。

## 防上下文压缩

本协议同时保存在 Hana pinned memory 与 active Project Brain `planner-executor-review-loop`。每次恢复任务先读该 active page；若会话摘要遗漏，以 Project Brain compiled truth 为准。

## 系统性取舍

速度来自“一写多读”的职责并行，稳定来自单一写入边界、阶段门禁和独立复审；不靠多个 Agent 同时改同一文件制造表面并发。


## timeline

- time: 2026-07-14T12:41:41
  kind: decision
  summary: Syc 明确采用 MindMux 规划/检查、Codex 执行的协作流程。
  source: Syc conversation on 2026-07-14
  affects: [planner-executor-review-loop]

- time: 2026-07-14T12:46:55
  kind: decision
  summary: 首轮 Codex 文档校准通过 MindMux 复核，下一步选择先规划 V0.2 BYOK 而非直接实现。
  source: Syc answer and review on 2026-07-14
  affects: [planner-executor-review-loop]

- time: 2026-07-15T10:30:31
  kind: decision
  summary: "Syc 确认由 HanaAgent 作为单一总控，采用阶段循环并减少常规确认。"
  source: Syc conversation 2026-07-15
  affects: [planner-executor-review-loop]

- time: 2026-07-15T11:23:12
  kind: decision
  summary: "修复 compiled_truth 转义格式，并记录 Syc 授权日常开发默认连续执行。"
  source: Syc conversation 2026-07-15
  affects: [planner-executor-review-loop]

- time: 2026-07-15T11:32:26
  kind: decision
  summary: "Syc 将所有 Sub-agent 统一为 Sol，推理深度由总控按风险选择。"
  source: Syc conversation 2026-07-15
  affects: [planner-executor-review-loop]

- time: 2026-07-15T14:52:16
  kind: decision
  summary: "加入持续一写多读协作、Sub-agent状态检查与每次阶段汇报数量/状态/ETA要求。"
  source: Syc workflow requirement 2026-07-15
  affects: [planner-executor-review-loop]

- time: 2026-07-15T15:00:30
  kind: decision
  summary: "固定模型/深度/token/解决问题/ETA/发行百分比的 Sub-agent 报告协议，并双重持久化防上下文压缩。"
  source: Syc reporting requirement 2026-07-15
  affects: [planner-executor-review-loop]

- time: 2026-07-24T23:02:59
  kind: reversal
  summary: "2026-07-24 Syc 明确改为正常开发流程：默认当前 Agent 直接完成，仅在明确需要时使用多 Agent，不再强制规划、持续并行、token/ETA/百分比汇报与独立终审。"
  source: brain archive-page
  affects: [planner-executor-review-loop]
