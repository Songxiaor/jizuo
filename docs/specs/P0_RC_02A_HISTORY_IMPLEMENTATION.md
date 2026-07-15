# P0-RC-02A History Domain 与 GRDB Repository 实施记录

> 状态：**独立 Sol xhigh 复审通过**。上一版 02A 候选未被独立接受，也未进入任何用户数据库；四项阻断直接修入 migration 001，没有创建 002。修订后的 001 是首个已接受并冻结的正式候选，后续变化只能追加 002+。

## 场景与边界

02A 把浏览器捕获转换为可长期保存的本地 archive，并为 02B 的 App composition/capture/run wiring 准备稳定 Port。本阶段没有修改 `LinkDigestApp.swift`、socket 返回时序、真实 Provider、真实 Application Support、浏览器资料或 Keychain。

```text
CaptureEnvelopeV1
  → Core validator / CanonicalURL v1 / semantic fingerprint
  → HistoryRepository Port
  → GRDBHistoryRepository 单事务
  → migration 001: Task / ContentSnapshot / Run / Artifact + capture_deliveries
```

Core 不依赖 GRDB、SQLite、SwiftUI 或 FileManager；GRDB 只存在于 `LinkDigestPersistence`。

## 正式领域与事务

- typed IDs 使用小写 canonical UUID；时间持久化为 UTC epoch milliseconds。
- Task 以 `(canonicalization_version, canonical_url)` 唯一；Snapshot 以 Task 下完整 UTF-8 body SHA-256 复用。
- delivery ledger 先查 payload digest，同 key 同 payload 返回旧结果，不同 payload 返回 `CAPTURE_IDEMPOTENCY_CONFLICT`。
- Run 状态为 queued/running/completed/stopped/failed/interrupted；终态不可修改。
- complete/partial Artifact、终态、独立 nullable token 与整数微货币 usage/cost 在同一事务提交。
- 重启恢复把 queued/running 改为 interrupted，保留 partial，不自动调用 Provider。
- history 使用 `(updated_at_ms, task_id)` keyset；detail 在单个 read snapshot 中读取；删除 Task 物理 cascade。

## Unicode 与指纹

Capture V1 继续使用 Unicode scalar 计数：emoji 1、组合字符 2、`a\u0000b` 3。U+0000 揭示了 Swift String 经 SQLite TEXT binding 的截断风险；正式 Adapter 使用完整 `Data(text.utf8)` 绑定后在 SQLite 内 cast 为 TEXT，读取时按 BLOB bytes 解码，确保正文、characterCount 与 SHA-256 一致。

semantic payload fingerprint 使用版本标记和长度前缀 UTF-8 字段编码，包含 source/capture/evidence/时间，排除 requestId/idempotencyKey；没有 hash 未规范化 JSON bytes。

## 数据库与恢复

- migration 001 的四个领域表使用 `WITHOUT ROWID`；delivery ledger 使用 composite FK。
- 数据库不以 `length(body_text)` 复验 Capture 字符合同，也不把正文长度上限交给 SQLite。
- future schema 与 migration failure 进入只读；migration 注入失败验证 user_version 仍为 0 且零半表。
- WAL 关闭 auto-checkpoint；维护接口提供 PASSIVE、TRUNCATE、integrity check、Online Backup 与受控 restore。
- opener、write、create-directory、migration、terminal transaction、backup、restore 均有真实注入 seam；正式测试不使用 chmod/POSIX bits 模拟失败。
- restore 先写同目录 staging 数据库，验证 integrity、foreign key 与五表计数后再移动到目标；现有目标不会被覆盖。

## 独立复审 MUST FIX 修订

- Artifact partial/terminal 全部以 UTF-8 Data 绑定并在 SQLite 内 cast 为 TEXT；detail/export 使用严格 BLOB→UTF-8 解码，非法 bytes 映射 integrity failure。
- History preview 只加载最多 960 bytes，再生成最长合法 UTF-8 前缀和最多 240 个 Unicode scalar；支持开头/中间 NUL。
- 四领域主键 CHECK 增加去连字符后恰好 32 位纯小写 hex 约束。
- 双 DatabasePool 竞态重读显式传播 capture/run conflict，不再由 `try?` 吞成 unavailable。
- Task 排序时间只由新 Snapshot 或真正新建 Run/Rerun 提升；projection 单列 latest Run 生命周期时间。

旧候选未被独立接受，因此以上修改直接进入 migration 001；修订后的 001 才是首个独立验收候选。

## Spike 演进与回滚

正式能力通过专项测试后，已移除 `SQLiteSpike*` 源码、测试和公开 API，benchmark executable 改为 `LinkDigestHistoryBenchmark`。`docs/specs/V0.3_SQLITE_SPIKE.md` 与旧 benchmark JSON 永久保留为历史证据。

回滚只删除本阶段新增 Core/Persistence/Tests/benchmark/fixtures/文档并恢复 Package 与 scripts；不删除或降级数据库，不触碰 V0.1/V0.2、Brain 或真实用户目录。
