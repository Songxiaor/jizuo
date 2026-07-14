---
id: selective-encrypted-sync
title: "选择性端到端加密同步"
category: decision
status: archived
tags: [sync, encryption, privacy]
created: "2026-07-13T19:49:42"
updated: "2026-07-13T23:39:39"
---

## compiled_truth

## 当前结论

设置与同步索引可以进入云端；原文、摘要和翻译默认只保存在本地。用户主动选择同步内容时，客户端先加密，云端只保存 ciphertext、版本、校验和、大小、所有者和删除状态。

## 安全边界

- 不自创加密算法。
- 正式实现前单独完成威胁模型、经过审计的库选择、恢复密钥和设备撤销设计。
- PostgreSQL 不保存正文大字段；密文进入对象存储。
- 删除账号触发有时限的云端元数据与对象删除，本地数据仍由用户控制。

## 关联

本地与云端职责见 [[hybrid-local-first-cloud-boundary]]。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 选择性端到端加密同步"
  source: Syc selected recommended sync boundary 2026-07-13
  affects: [selective-encrypted-sync]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固定默认本地与主动加密上传边界"
  source: Syc selected recommended sync boundary 2026-07-13
  affects: [selective-encrypted-sync]

- time: 2026-07-13T23:39:39
  kind: reversal
  summary: "选择性加密同步退出 P0；完成本地闭环并重新验证需求与威胁模型后再决定"
  source: brain archive-page
  affects: [selective-encrypted-sync]
