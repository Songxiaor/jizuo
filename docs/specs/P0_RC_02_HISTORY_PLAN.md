# P0-RC-02 正式本地历史、Migration 001 与 Repository 计划

状态：**02A 已通过独立 Sol xhigh 复审；migration 001 已首次冻结；02B App 接线待实施**
日期：2026-07-15
规划/校准：Sol xhigh
对标：Sam Webpage Summarizer 的公开 UI、用户动作与隐私边界

## 1. 范围

本阶段只实现：

- 正式 `Task → ContentSnapshot → Run → Artifact` 领域模型。
- 技术表 `capture_deliveries`。
- GRDB migration 001、Repository Port/Adapter、Application service 基础。
- capture/run 幂等、状态机、异常重启恢复、分页、详情、删除和内存 Export projection。
- WAL、Online Backup、故障注入、正式五表 benchmark。
- App composition root 的最小接线（按 02A/02B 拆分，留给 02B；02A 不修改 `LinkDigestApp.swift`）。

本阶段不实现历史 Sidebar/详情视觉、文件导出、Ask、Safari/iOS、云同步、稳定 Host、签名、公证或发布。

## 2. Sam 对标约束

借鉴：

- macOS 原生双栏历史/详情信息层级。
- 来源、标题、URL、动作、模型、时间、tokens/cost 与结果正文。
- 单项删除、Rerun、本地 archive、Keychain、无账号/自建后端。
- 同一链接再次添加时打开已有 archive；新结果由显式 Rerun 产生。

保持差异：

- 输入仍为 Chromium Extension → Native Host → Unix socket → Swift App。
- P0 不加入 Ask、Safari/share extension、账号或同步。
- 不复制 Sam 的品牌、图标、文案、像素值；不推测其私有表结构或框架。

## 3. 冻结实体语义

### Task

一个 conservative canonical URL 对应的本地 archive。P0 中 `(canonicalization_version, canonical_url)` 唯一。

### ContentSnapshot

Task 下的一版不可变正文。相同 canonical URL 再捕获：

- UTF-8 SHA-256 相同，复用 Snapshot。
- 正文变化，追加 Snapshot。
- 新 Snapshot 不自动调用 Provider。

### Run

针对确定 Snapshot 的一次 `summarize` 或 `translate`。Rerun 创建新 Run，`rerun_of_run_id` 指向原 Run。

状态：`queued | running | completed | stopped | failed | interrupted`。终态不可再次转换。

### Artifact

Run 的 `0...1` 文本结果，可为 `complete | partial`，格式为 `plain_text | markdown`。

### capture_deliveries

持久化 transport 幂等 ledger，不是第五个领域实体。多个 delivery 可以指向同一 Task/Snapshot。

## 4. Canonical URL v1

只执行无争议、无网络的规范化：

1. scheme 与 host 小写。
2. 移除 fragment。
3. 移除默认端口 `http:80` / `https:443`。
4. 空 path 变为 `/`。
5. 保留 path、query 内容和顺序。
6. 不删除 tracking 参数，不排序 query，不追踪 redirect。

## 5. Capture V1 与指纹

- `character_count` 是 Unicode scalar/code-point 数：Swift `unicodeScalars.count`，TypeScript `[...text].length`。
- U+0000 合法；数据库不得用 `length(body_text)` 复验合同。
- 入库前必须重跑完整 Capture V1 validator。
- `body_sha256` 对正文完整 UTF-8 bytes 计算，包含内嵌 NUL。
- delivery key：
  - 有 idempotencyKey：`capture:v1:id:<value>`
  - 无 idempotencyKey：`capture:v1:req:<requestId>`
- `payload_sha256` 使用版本化、长度前缀 UTF-8 语义编码，包含 source/capture/evidence/时间，排除 requestId 与 idempotencyKey。
- 同 delivery key + 同 payload：返回原 Task/Snapshot。
- 同 delivery key + 不同 payload：`CAPTURE_IDEMPOTENCY_CONFLICT`。

## 6. Migration 001

所有领域 UUID 为小写 canonical UUID 字符串；时间为 UTC Unix epoch milliseconds `INTEGER/Int64`；正式领域表使用 `WITHOUT ROWID`；`foreign_keys = ON`。

### tasks

- `id TEXT PRIMARY KEY`
- `canonical_url TEXT NOT NULL`
- `canonicalization_version INTEGER NOT NULL CHECK = 1`
- `created_at_ms INTEGER NOT NULL`
- `updated_at_ms INTEGER NOT NULL`
- `UNIQUE(canonicalization_version, canonical_url)`
- index：`updated_at_ms DESC, id DESC`

### content_snapshots

- `id TEXT PRIMARY KEY`
- `task_id TEXT NOT NULL REFERENCES tasks ON DELETE CASCADE`
- `sequence INTEGER NOT NULL >= 1`
- envelope/captured timestamps
- source kind、原始 URL、可空 title、platform
- capture method、completeness
- `body_text TEXT NOT NULL`
- `character_count INTEGER NOT NULL 1...2_000_000`
- `body_sha256 TEXT NOT NULL`，64 位小写 hex
- source label、`used_cookie = 0`
- `UNIQUE(task_id, sequence)`
- `UNIQUE(task_id, body_sha256)`
- composite unique `(task_id, id)` 供 Run FK 使用

禁止 `character_count = length(body_text)`。

### capture_deliveries

- `delivery_key TEXT PRIMARY KEY`
- capture contract version、request ID
- `payload_sha256 TEXT NOT NULL`，64 位小写 hex
- `task_id`、`snapshot_id`
- `received_at_ms`
- composite FK `(task_id, snapshot_id) → content_snapshots(task_id, id) ON DELETE CASCADE`
- indexes：task/recent、snapshot/recent

### runs

- `id TEXT PRIMARY KEY`
- `task_id`、`snapshot_id`，composite FK 到 Snapshot
- `idempotency_key TEXT UNIQUE`
- `rerun_of_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL`
- kind、可空 target language、状态
- 可空 provider profile/kind/base URL/api mode/model；永久排除 key/secret reference/header/raw body
- created/started/finished timestamps
- 可空稳定 failure code/retryable
- 可空 `input_tokens`、`output_tokens`、`total_tokens`
- 可空 `cost_amount_micros` + `cost_currency_code`，必须成对出现
- 金额禁止 `REAL`；NULL 不显示为 0；当前 Provider 无 usage 时保持 NULL
- indexes：task/recent、snapshot/recent、rerun parent、非终态 partial index

### artifacts

- `id TEXT PRIMARY KEY`
- `run_id TEXT UNIQUE REFERENCES runs ON DELETE CASCADE`
- `content_format IN ('plain_text','markdown')`
- `completeness IN ('complete','partial')`
- 非空 body、created/updated timestamps

跨表不变量由同一 Repository 事务保证：

- completed Run 必须有 complete Artifact。
- partial Artifact 不能与 completed Run 共存。
- Artifact、终态、usage/cost 同事务提交。
- 旧 02A 候选未被独立接受、也未进入用户数据库；本轮直接修订 001，不创建无意义 002。修订后的 001 经独立复审接受后才进入“只追加 002+”阶段。

## 7. Capture 事务

一个 `DatabasePool.write`：

1. Core 校验、计算 delivery/payload/canonical/body 指纹。
2. 先查 delivery ledger：同 digest 幂等返回，不同 digest conflict。
3. 查 canonical Task；不存在则创建。
4. 查同 Task 的 body digest；相同复用 Snapshot，变化时追加连续 sequence 并更新 Task 时间。
5. 插入 delivery ledger。
6. 提交成功后才能更新 UI 或返回 `taskAccepted`。

新 Snapshot 不自动创建 Run。URL identity 与 delivery idempotency 是两条独立逻辑。

## 8. Run、Rerun 与恢复

- UI 动作生成 run idempotency key；持久化重试复用，用户再次 Rerun 生成新 key。
- queued 先落库；provider 开始前原子转 running 并快照非秘密 metadata。
- partial delta 成功持久化后才能发布对应 UI state。
- completed/stopped/failed/interrupted 的 Artifact 与终态同事务。
- App 启动、开始接收 socket 前，把遗留 queued/running 原子改为 interrupted，保留 partial，不自动重试 Provider。
- Rerun 针对选中/最新 Snapshot，新建 Run/Artifact，不覆盖旧记录，不复制旧 usage/cost。

## 9. 删除、分页与 Projection

- 删除 Task 为单事务物理 cascade；P0 无软删除、回收站或同步 tombstone。
- 首页使用 `(updated_at_ms, task_id)` keyset pagination，默认 50，不读取正文或 Artifact 全文。
- 详情在一个 read snapshot 中读取 Task、Snapshots、Runs、Artifacts。
- History row 支撑 title、URL、host、source label、latest action/status/model/date、可空 usage/cost、短 preview。
- Detail 支撑选中 Snapshot、所有 Run、Rerun 关系、provider/model/time、可空 usage/cost、Artifact。
- Export projection 只在用户显式动作构造，可含 URL/正文；永久排除 API Key、Keychain reference、Cookie、header/token、内部路径、SQL/raw error/raw Provider body。

## 10. Target 边界

### LinkDigestCore

领域模型、typed ID、状态机、projection、Repository Port、Application services。不得 import GRDB/SQLite/SwiftUI/FileManager。

### LinkDigestPersistence

GRDB Adapter、migration、database location/open/recovery、WAL、backup/checkpoint/integrity、fault injection seam。依赖 Core + GRDB。

### LinkDigestApp

composition root 组装同一个 Repository 实例并注入 capture/run/history service。View/ViewModel 不得持有 GRDB、DatabasePool/Queue 或 SQL。

对 `LinkDigestApp.swift` 只做手术式接线，不重写现有 UI、Provider 设置、socket framing。

## 11. Spike 演进

- 永久保留 V0.3 spike 文档与旧 benchmark JSON。
- 正式能力等价后移除 `SQLiteSpike*` 产品 API 与测试源码。
- benchmark 改为 `LinkDigestHistoryBenchmark`，复用 raw sample/percentile 框架。
- 不长期维护 spike schema 与正式 schema 两套产品代码。

## 12. 必须通过的测试

- migration：empty→001、001 reopen、注入失败零半表、future schema 只读。
- Unicode：emoji=1、组合字符=2、`a\0b`=3，Swift/TS fixture 一致，SQLite round-trip 完整。
- delivery：同 key 同 payload、同 key 冲突、重启后重放。
- canonical：大小写/默认端口/fragment 合并；query 内容/顺序/tracking 保持区分；无网络。
- 相同 canonical + 相同 body：Task/Snapshot 不增，ledger +1。
- 相同 canonical + 新 body：Task 不增，Snapshot +1，Run 不增。
- Run 状态机、Rerun、partial 保留、终态双写回滚、usage/cost 精确回滚。
- hard delete cascade，另一 Task 不变。
- 1 writer + 8 readers：统一 start gate、overlap witness、10 秒上限、安全收口。
- 注入 open/write/create-dir/backup/restore failure，不用 chmod 冒充真实失败。
- checkpoint：产生 frames、PASSIVE 推进、TRUNCATE 收口、业务计数不变。
- Online Backup/restore：integrity=ok，五表业务计数一致。
- error/projection secret hygiene。
- Release benchmark：10k Task、12k Snapshot、15k Run、15k Artifact、混合 usage/cost；首页/详情各 30 raw samples，p95 ≤ 300 ms。

## 13. 验证与停止条件

验证：Persistence/Core/App tests、完整 Swift suite、Debug/Release、正式 benchmark、Swift/JS licenses、secret scan、Web checks、doctor、diff check；Xcode sandbox 阻断必须如实分层。

立即停止：Brain/diff 冲突、真实用户数据被访问、Core/UI 需要 import GRDB、migration 留半表、幂等依赖内存 Set、终态与 Artifact 无法原子提交、新回归无法归因、benchmark 超门槛或 secret scan 命中。

## 14. 回滚

只撤销本阶段源码、Package 接线和文档；不删除数据库回滚，不触碰 V0.1/V0.2。future schema 永远只读；migration 失败保留原文件。旧 spike 证据继续保留。
