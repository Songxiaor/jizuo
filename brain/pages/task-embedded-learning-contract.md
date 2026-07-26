---
id: task-embedded-learning-contract
title: Task-Embedded Learning Contract
category: decision
status: archived
tags: [learning, workflow, governance]
created: "2026-07-13T18:45:11"
updated: "2026-07-24T23:02:59"
---

## compiled_truth

# 决策

LinkDigest 的学习轨必须嵌入每个非平凡开发任务，并在对应组件实施时同步解释；它不是开发结束后的课后作业、考试或答题门槛。Syc 不需要先独立学完、复述答案或完成亲手验证，AI 才能继续主开发流程。

## 执行规则

- 任务开始前使用 `docs/TASK_TEMPLATE.md`，先解释场景、角色与交接、工作流和工具协同。
- 每个任务最多引入 3–5 个新名词；第一次出现时说明人话定义、类比、项目位置、必要性和失效表现。
- 开发过程中在组件真正出现的节点解释其职责、输入、输出、上下游、选择原因和失败表现，不能把解释集中到最后。
- 学习深度 L1–L4 描述项目已经提供到什么讲解深度，不是对 Syc 掌握程度的考试；核心架构概念应提供到共同观察验证的 L3。
- 5–15 分钟跟做动作是可选的理解辅助，不是任务关闭条件。Syc 想深入时可另开小窗口学习；主开发流程默认继续。
- 只有当 Syc 明确表示某个未知点会影响当前产品决策时，才暂停主流程补充解释。
- 任务完成以工程证据、过程讲解已经交付和学习日志更新为准，不以 Syc 交作业为准。
- 新名词进入 `docs/GLOSSARY.md`；已交付讲解、可选跟做和主动提出的待解释点进入 `docs/LEARNING_LOG.md`。

## 影响范围

此决策约束后续桌面端、浏览器扩展、提取器、模型层、服务端、部署和上架任务。纯拼写、格式和不引入新概念的微小修正可以免用完整模板。


## timeline

- time: 2026-07-13T18:45:11
  kind: decision
  summary: "Created this page: Task-Embedded Learning Contract"
  source: Syc confirmed in conversation on 2026-07-13
  affects: [task-embedded-learning-contract]

- time: 2026-07-13T18:45:46
  kind: decision
  summary: "将学习验收嵌入每个非平凡开发任务"
  source: Syc confirmed in conversation on 2026-07-13
  affects: [task-embedded-learning-contract]

- time: 2026-07-13T19:43:36
  kind: reversal
  summary: "取消以 Syc 课后答题或独立验证作为任务完成门槛"
  source: Syc clarified in conversation on 2026-07-13
  affects: [task-embedded-learning-contract]

- time: 2026-07-13T19:43:36
  kind: decision
  summary: "将学习闭环改为开发过程中同步讲解，跟做与深挖不阻塞主流程"
  source: Syc clarified in conversation on 2026-07-13
  affects: [task-embedded-learning-contract]

- time: 2026-07-24T23:02:59
  kind: reversal
  summary: "2026-07-24 Syc 明确取消强制学习闭环、学习日志与术语表；普通开发改为风险相称的最小验证。"
  source: brain archive-page
  affects: [task-embedded-learning-contract]
