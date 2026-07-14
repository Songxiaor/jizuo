---
id: hybrid-local-first-cloud-boundary
title: "混合 local-first 与可选云端边界"
category: decision
status: active
tags: [local-first, cloud, privacy]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T23:39:38"
---

## compiled_truth

## 当前结论

LinkDigest P0 完全 local-first 且免登录：链接、原文、摘要、历史、BYOK 和导出都保存在本机或直接连接用户 Provider。P0 不实现 LinkDigest 账号、同步、托管模型或 Cloud API。

## 不可变行为

- API Key 只进入 macOS Keychain，不经过 LinkDigest 云端。
- 账号不能成为打开本地数据或运行 BYOK 的必要条件。
- 原文和结果未经用户明确操作不得上传 LinkDigest 服务。
- 云端、网络或未来商业服务不得阻止本地提取、历史和导出。

## 未来边界

账号、选择性加密同步和托管模型只作为 P0 后候选。进入该阶段时重新验证用户需求、安全模型、成本和技术栈；旧云端设计不自动恢复为当前任务。

## 关联

macOS 与扩展边界见 [[native-macos-swiftui-hybrid]]；协议规则见 [[versioned-contracts-forward-migrations]]。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 混合 local-first 与可选云端边界"
  source: Syc confirmed product direction 2026-07-13
  affects: [hybrid-local-first-cloud-boundary]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固定本地核心与云端控制面的职责"
  source: Syc confirmed product direction 2026-07-13
  affects: [hybrid-local-first-cloud-boundary]

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "把可选云端从 P0 控制面收敛为完成本地闭环后重新验证的候选能力"
  source: P0 scope reduction approved 2026-07-13
  affects: [hybrid-local-first-cloud-boundary]
