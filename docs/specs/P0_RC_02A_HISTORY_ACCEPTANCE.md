# P0-RC-02A History Domain 与 GRDB Repository 验收

> 当前工程结论：**实施 ACCEPT，待独立 Sol xhigh 复审**。上一版候选被独立复审判定 MUST FIX，未被接受、未进入用户数据库；本轮直接修订 migration 001，修订后的 001 才是首个候选。历史 UI、App composition、socket ACK 时序和真实 Provider wiring 属于 02B，均未启动。

## 已通过证据

- Core：typed IDs、领域模型、Run 状态机、usage/cost、CanonicalURL v1、长度前缀 semantic fingerprint、Repository Port、History/Detail/Export projections。
- migration 001：五表、约束、索引、WITHOUT ROWID、composite FK、零半表、future schema 只读。
- Repository：capture ledger replay/conflict、canonical Task、body reuse/new Snapshot、连续 sequence、Run idempotency/rerun/partial/terminal/recovery、keyset/detail/export/delete。
- 原子性：terminal + Artifact + nullable usage/cost 的事务中点注入失败后，Run 保持 running、Artifact 与 usage/cost 均未提交。
- Unicode：emoji=1、组合字符=2、Capture/Artifact `a\u0000b` 与 `\u0000a`；partial、terminal、reopen、recovery、detail、export 与 bounded preview 全链路一致。非法 Artifact UTF-8 映射 integrity failure。
- UUID：四领域主键同时检查固定连字符位置、去连字符后 32 位与纯小写 hex；指定 extra-hyphen 反例均由 DB 拒绝。
- 竞态：两个独立 DatabasePool 对 capture 同 payload 返回同一 Task/Snapshot；不同 payload 与不同 Run 语义分别稳定返回 capture/run conflict，不退化为 unavailable。
- 日期：Task 排序时间只由新 Snapshot 或真正新建 Run/Rerun 单调提升；stream/terminal/recovery 不改变排序，projection 单列 latest Run 时间。
- 故障与恢复：open/write/create-directory/backup/restore 注入；WAL PASSIVE/TRUNCATE；Online Backup/restore integrity、foreign key 与五表计数一致。
- 并发：统一 start gate，1 writer + 8 readers，明确 writer-start witness，10 秒总上限与 cancellation flag；120 条最终 Task 无丢写。

## 正式 Release benchmark

证据：`docs/evidence/P0_RC_02A_HISTORY_BENCHMARK_2026-07-15.json`

- 10,000 Task、12,000 Snapshot、15,000 Run、15,000 Artifact。
- 20% Task 有多 Snapshot；33.33% Run 为 rerun；usage/cost 混合独立 NULL；种子含一个 NUL Artifact，并在计时外经 detail 验证。
- 首页与详情各预热 1 次、30 raw samples，nearest-rank p95。
- 首页 p95 `0.57275 ms`；详情 p95 `0.129084 ms`；门槛 `300 ms`，PASS。
- stdout/evidence 不含正文、URL 或绝对路径。

## 验证命令

```bash
swift test --disable-sandbox --filter History
swift test --disable-sandbox
swift build -c debug --disable-sandbox
swift build -c release --disable-sandbox
swift run -c release --disable-sandbox LinkDigestHistoryBenchmark
pnpm check:web
./scripts/check-licenses
bash ./scripts/check-swift-licenses
pnpm secret:check
./scripts/doctor
git diff --check
pnpm xcode:build
```

最终执行结果：History 24/24；Contract 5/5；History Core 4/4；Swift Debug/Release PASS；Debug benchmark 按编译条件以 status 64 拒绝；正式 Release benchmark PASS。`pnpm check:web` PASS（shared 10/10、extension 10/10）。完整 Swift suite 共 71 项，61 通过；8 个 Network fake server `startFailed`、1 个 Keychain status 100001、1 个既有 Unix socket address-in-use，与前序环境基线一致。`pnpm xcode:build` 在首个 scheme 的 package resolution 被外层 nested sandbox `sandbox_apply: Operation not permitted` 阻断。没有削弱既有测试、修改全局 defaults 或把环境缺口写成产品通过。

## migration 001 状态

旧候选未被独立接受且没有用户数据库，因此四项阻断直接修入 001，没有创建 002。修订后的 migration 001 已通过独立 Sol xhigh 复审并首次冻结；从此只能追加 002+，不得改写 001。future schema 仍不降级，migration 失败仍不删库。
