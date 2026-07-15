---
id: sqlite-grdb-persistence-boundary
title: "SQLite GRDB 持久化边界"
category: decision
status: active
tags: [sqlite, grdb, migration, recovery]
created: "2026-07-15T12:24:07"
updated: "2026-07-15T13:44:47"
---

## compiled_truth

## 当前结论

LinkDigest P0 本地持久化使用 GRDB `7.11.1` exact，revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`，MIT。GRDB 只能存在于 Persistence Adapter，禁止进入 `LinkDigestCore`、SwiftUI、ViewModel 或 Application service 的公开类型。

P0-RC-02A 已经通过实施与独立 Sol xhigh 复审。修订后的 migration 001 是首个正式接受并冻结的 schema；旧候选从未独立通过、未进入用户数据库，因此阻断修复直接进入 001，没有创建 002。此后任何 schema 变化只能追加 002+，不得改写 001。

Xcode package resolution 仍被 Hana 外层 nested sandbox 阻断；clean-room RC 前必须补证，不能写成通过或 GRDB 失败。

## 正式领域与 archive 语义

- `Task` 是 conservative canonical URL 对应的本地 archive；P0 source identity 唯一。
- `ContentSnapshot` 是不可变正文版本；同 URL 且相同 UTF-8 body SHA-256 复用，正文变化才追加，不自动调用 Provider。
- `Run` 针对确定 Snapshot 执行 summarize/translate；显式 Rerun 新建 Run，旧结果不覆盖。
- `Artifact` 是 Run 的 0...1 complete/partial 结果。
- 技术表 `capture_deliveries` 单独承担 socket/Host 重试幂等与 payload conflict；URL 去重和内存 Set 不能冒充 delivery 幂等。
- 同链接再次添加默认打开已有 archive；新结果由显式 Rerun 产生。该语义参考 [[sam-webpage-summarizer-reference]]，不引入 Ask、Safari 或账号同步。

## migration 001 硬边界

- UUID 为小写 canonical 字符串并由 DB CHECK 独立拒绝 extra hyphen；时间为 UTC epoch milliseconds；领域层禁止暴露 rowid。
- Capture V1 `character_count` 为 Unicode scalar/code-point count，由 Core validator 保证；U+0000 合法，SQLite 不以 `length(body_text)` 定义合同。
- Snapshot 与 Artifact 的 TEXT 正文使用完整 UTF-8 Data 绑定，并以 BLOB bytes 严格解码，防止内嵌 NUL 截断。
- Snapshot 保存 UTF-8 body SHA-256；delivery 保存版本化 semantic payload SHA-256。
- Run 可空保存 token 与整数微货币成本/currency；禁止 REAL、API Key、Keychain reference、raw usage/body。
- terminal Run、Artifact 与 usage/cost 同事务；异常重启把 queued/running 转 interrupted 并保留 partial。
- Task 删除为物理 cascade；P0 不增加软删除、回收站或同步 tombstone。
- history 使用 keyset pagination；Task 排序时间只由新 Snapshot 或真正新建 Run/Rerun提升，stream/terminal/recovery不跳动；latest Run lifecycle time单独投影。
- Export projection 仅由用户显式动作构造并永久排除秘密、内部路径与 raw error。

## 已通过的正式门禁

- History 专项 24/24；Contract 5/5；Core 4/4。
- 双 DatabasePool capture/run 幂等竞态稳定传播 conflict。
- 1 writer + 8 readers start gate、overlap witness、2 秒 busy timeout 后有界收口。
- checkpoint PASSIVE 推进与 TRUNCATE 收口；Online Backup/restore、integrity 与五表计数。
- Release benchmark：10k Task、12k Snapshot、15k Run、15k Artifact，首页/详情各30 raw samples，p95 0.57275/0.129084 ms。
- Debug benchmark主动拒绝；SwiftPM Debug/Release、licenses、secret、Web和doctor门禁通过。

## Adapter 边界与下一阶段

数据库、`-wal`、`-shm` 位于 Application Support 专属目录；测试只用隔离临时目录。Repository实现可持有GRDB；Port、Domain、Application service与UI不得持有。下一阶段只通过 composition root 把已接受的Port接入现有 capture/run生命周期，不重写SwiftUI或socket framing。

正式任务包：`docs/specs/P0_RC_02_HISTORY_PLAN.md`。

## 关联

整体目标见 [[p0-release-candidate-goal]]；跨版本规则见 [[versioned-contracts-forward-migrations]]；商业依赖边界见 [[commercial-license-boundary]]；原生架构见 [[native-macos-swiftui-hybrid]]；产品参考见 [[sam-webpage-summarizer-reference]]。


## timeline

- time: 2026-07-15T12:24:07
  kind: decision
  summary: "Created this page: SQLite GRDB 持久化边界"
  source: P0-RC-01 spike and Sol xhigh review 2026-07-15
  affects: [sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:24:07
  kind: decision
  summary: "GRDB 7.11.1 spike 与独立复审通过，冻结 Persistence-only 边界。"
  source: P0-RC-01 implementation and Sol xhigh review 2026-07-15
  affects: [sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:40:23
  kind: decision
  summary: "冻结正式 archive/Snapshot/Run/Artifact、delivery ledger、Rerun、Unicode 与 usage/cost schema 001 语义。"
  source: "P0-RC-02 Sol xhigh planning + Sam calibration 2026-07-15"
  affects: [sqlite-grdb-persistence-boundary]

- time: 2026-07-15T13:44:47
  kind: decision
  summary: "独立复审通过，首次冻结修订后的 migration 001；记录 NUL、UUID、竞态和历史排序门禁。"
  source: "P0-RC-02A implementation + Sol xhigh re-review 2026-07-15"
  affects: [sqlite-grdb-persistence-boundary]
