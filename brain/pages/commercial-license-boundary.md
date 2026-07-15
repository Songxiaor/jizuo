---
id: commercial-license-boundary
title: "商业闭源与依赖许可证边界"
category: decision
status: active
tags: [commercial, license, supply-chain]
created: "2026-07-13T19:49:42"
updated: "2026-07-15T12:24:07"
---

## compiled_truth

## 当前结论

LinkDigest 按全球优先、商业闭源桌面产品设计。默认只采用许可证边界清晰且允许商业分发的依赖，优先 MIT、Apache-2.0、BSD 等宽松许可证。

## 门禁

- GPL、AGPL、仅限非商业学习和许可证不明的代码不得直接合入。
- 引入依赖前记录用途、许可证、维护状态、替换路径和供应链风险。
- 模型 Provider、身份服务、遥测和云基础设施的服务条款在接入前单独核对。
- 购买、创建账号、签名、公证、商店提交和发布必须再次获得 Syc 确认。


## timeline

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "Created this page: 商业闭源与依赖许可证边界"
  source: Syc selected commercial closed-source 2026-07-13
  affects: [commercial-license-boundary]

- time: 2026-07-13T19:49:42
  kind: decision
  summary: "固定商业产品的依赖准入规则"
  source: Syc selected commercial closed-source 2026-07-13
  affects: [commercial-license-boundary]

- time: 2026-07-15T12:24:07
  kind: decision
  summary: "GRDB 7.11.1 exact 通过 MIT、revision 和零 resolved 传递包门禁，可进入 Persistence Adapter；正式阶段继续校验。"
  source: SQLite spike and Sol xhigh review 2026-07-15
  affects: [commercial-license-boundary, sqlite-grdb-persistence-boundary]
