---
id: planner-executor-review-loop
category: decision
status: active
tags: [workflow, codex, governance]
title: Planner–Executor–Review Loop
created: "2026-07-14T12:41:41"
updated: "2026-07-14T12:46:55"
---

## compiled_truth

# Planner–Executor–Review Loop

## 决策

Syc 将 MindMux 作为总规划与系统检查者，将 Codex 作为具体执行者。默认流程是：

1. MindMux 先分析项目状态、边界、依赖和下游影响，给出可执行 prompt。
2. Syc 将 prompt 交给 Codex 执行具体修改、检查和产出证据。
3. Codex 返回修改摘要、diff/验证结果和未做事项。
4. MindMux 再审查 Codex 的结果：检查范围是否扩大、文档/代码是否一致、恢复路径是否清晰、Brain 规则是否被破坏，以及修改是否符合当前路线图。

## 角色边界

- MindMux 负责规划、Prompt 设计、系统性风险判断、结果审查和耐久知识写回。
- Codex 负责执行具体代码/文档改动、运行允许的检查、回报证据。
- Syc 保留授权权：安装外部软件、首次 commit、push、发布、签名、公证、远程写入和系统级修改都必须由 Syc 明确确认。

## 执行约束

- 给 Codex 的 prompt 必须写清楚：目标、范围、禁止事项、受影响文件、验证命令和输出格式。
- 对文档或代码修改的审查必须区分“当前已实现事实”和“未来产品目标”。
- 不允许 Codex 手改 `brain/`；长期决策和路线变化由 MindMux 通过 Brain 工具记录。
- 任何看似局部的优化都要检查下游影响，尤其是 Native Host 安装/恢复、跨语言合同、local-first、P0 非目标和学习轨约束。

## 系统性取舍

短期收益是 Syc 可以把执行工作交给 Codex，同时让 MindMux保持全局一致性和路线控制。长期成本是每轮都需要明确交接物和审查清单；如果 prompt 太模糊，Codex 可能按局部文档或代码误扩大范围。因此 prompt 模板和复核清单本身是这个工作流的关键基础设施。

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
