# P0-RC-02B App Capture / Run 持久化接线计划

状态：**冻结，待实施**
日期：2026-07-15
前置：P0-RC-02A 已通过独立复审；migration 001 已冻结，SHA-256 `2402fd0dcb8293010f3c080af583a98c50af661a200915c321e0faaccfb93b57`

## 1. 范围

本阶段只把现有 Capture 与 BYOK Run 生命周期接入已经冻结的 Repository Port：

- 唯一 App composition root 与 Repository 实例。
- 启动 recovery gate。
- Capture commit → UI → ACK。
- Run queued/running/partial/terminal 持久化。
- 取消、stale-run、storage failure 与错误脱敏。
- 最小 storage 状态与禁用逻辑。

不实现历史 Sidebar/详情、文件导出、Ask、Rerun UI、稳定 Host、签名公证或视觉重构。禁止修改 migration 001；字段不足时停止并提出 migration 002。

## 2. Composition root

新增 `AppComposition.swift`：

- 生产路径：用户 Application Support 下 `LinkDigest/history.sqlite`。
- 一次 App 生命周期只创建一个 `GRDBHistoryRepository` 和一个 `HistoryApplicationService`。
- View/ViewModel 不持有 GRDB、DatabasePool/Queue 或 SQL。
- Application Support root、Repository factory、clock 和 server starter可注入；所有测试只用 temp root/fake Port。
- 绝对路径不得进入日志、UI、safeDetail 或快照。

启动顺序：

```text
open Repository
  → 判断 accessMode
  → writable 时 recoverInterruptedRuns
  → recovery 完成后标记 write-ready
  → 启动 Unix socket accept loop
  → 允许新 Capture / Run
```

SwiftUI `.task` 重入不能重复 bootstrap/server。

read-only/open/recovery failure 时窗口仍可打开；socket 启动为结构化拒绝端，Capture/Run 禁写，不显示未落库内容。

## 3. Capture 接线

新增 `CaptureReceiver.swift`，保持 framing 与 NativeResponse 合同不变：

```text
frame
  → CaptureValidator.decode
  → HistoryApplicationService.acceptCapture
  → Repository commit
  → model.receive(envelope, taskID, snapshotID)
  → taskAccepted ACK
```

约束：

- 删除 `CaptureInbox` 的生产正确性职责。
- commit 前无 UI 更新、无成功 ACK。
- duplicate delivery 返回原 IDs，仍刷新当前单页并正常 ACK。
- idempotency conflict/storage failure 不更新 UI，返回稳定 AppError。
- decode 前未知 request ID 才使用固定 `app-receiver`。
- 02B 不向 ACK 新增 Task/Snapshot 字段。

当前 UI 内部保存 `CurrentCapture(envelope, taskID, snapshotID)`；现有标题、URL、正文与捕获元数据显示保持不变。

## 4. Run identity 与 orchestration

一次 UI 动作生成并冻结：

- 一个 `RunID`
- 一个 key：`run:v1:ui:<runID>`
- TaskID、SnapshotID、operation、language

同一动作内部重试复用；再次点击生成新 ID/key。`ModelRunOrchestrator` 不再另造 UUID。

时序：

```text
createRun queued commit
  → 发布 starting
  → 读取 profile / Keychain secret
  → credential failure 时提交 failed
  → markRunRunning(non-secret metadata) commit
  → Provider stream
  → 每次 delta 形成累计文本
  → savePartialArtifact commit
  → 发布 streaming
  → finishRun(status + Artifact + usage unknown) commit
  → 发布 terminal UI
```

当前 Provider 无 usage/cost 事件，全部保持 NULL；不估算价格。

Provider 零输出直接 completed 时，持久化为 failed `MODEL_STREAM_MALFORMED`，不创建空 complete Artifact。

## 5. 取消、stale 与 storage failure

### Stop

1. 先把当前 Run 标记 stopping/stale，拒绝迟到事件。
2. 发布 stopping。
3. `cancelActiveStreams()`。
4. 取消 producer Task。
5. 使用最后一次成功持久化的 partial 提交 stopped。
6. commit 成功后才发布 stopped。

### Partial 写失败

- candidate 不进入 committed partial。
- Run 变 stale，取消 Provider/Task。
- UI 只保留最后一次已持久化 partial。
- 显示 `STORAGE_WRITE_FAILED`。
- 不伪造 failed terminal；下次启动恢复 interrupted。

### Terminal/Stop 写失败

- 收口 Provider 与 Task。
- 不发布 completed/failed/stopped。
- 显示 storage failure。
- DB 保持 queued/running，等待启动 recovery。

每个 delta、terminal、persistence callback 都核对同一 RunID；旧 Run 不得覆盖新 Run。保留现有 500ms cancel 与 550ms 无迟到 delta 门禁。

## 6. Storage error codes

稳定映射：

- `STORAGE_UNAVAILABLE` / retry / retryable
- `STORAGE_WRITE_FAILED` / retry / retryable
- `STORAGE_FUTURE_SCHEMA` / upgrade_app / non-retryable
- `STORAGE_MIGRATION_FAILED` / retry / retryable
- `STORAGE_READ_ONLY` / none
- `STORAGE_INTEGRITY_FAILED` / none
- `STORAGE_STATE_CONFLICT` / none
- `CAPTURE_IDEMPOTENCY_CONFLICT` / none
- `RUN_IDEMPOTENCY_CONFLICT` / none

category 为 `storage`。storage safeDetail 默认 nil；永久排除路径、SQL/table、URL/正文、Key、secret reference、header/token、raw Provider body/error。

SwiftUI 只持有 stable code、映射文案和 storage availability，不持有 RepositoryFailure/raw Error。

## 7. 文件任务包

### Package

- App target 增加 `LinkDigestPersistence` 依赖。
- 需要 temp Adapter integration 时 AppTests 增加 Persistence；不直接依赖 GRDB product。

### Core

- 手术式扩展 `ModelRunOrchestrator`：注入 History service、显式 PersistentRunRequest、持久化时序、storage cancellation。
- 可新增 `StorageErrorCode.swift` 和纯映射。
- `HistoryRepository`/migration 原则上零改；无法表达时停止。

### App

- 新增 `AppComposition.swift`、`CaptureReceiver.swift`。
- `LinkDigestApp.swift` 只改 composition、CurrentCapture IDs、bootstrap、server delegation和必要禁用状态。
- 保留现有 ContentView、Provider Settings、socket framing。
- 不新增 PersistentRunCoordinator，避免两个 actor 争夺 terminal/cancel owner。

### Tests

- Fake Repository/clock/server recorder。
- `AppCompositionTests`、`CaptureReceiverTests`、持久化 Orchestrator tests。
- 真实 temp GRDB仅用于 restart/read-only/跨层事务；时序/取消优先 fake Port。

## 8. 必须通过的测试

- recovery 完成前 server 未启动；bootstrap 只执行一次。
- writable、future schema read-only、open/recovery failure。
- Capture commit 前无 UI/ACK；success/duplicate/conflict/storage failure。
- UI 保存正确 TaskID/SnapshotID。
- queued commit 早于 starting/provider；running commit 早于 stream。
- partial commit 早于 streaming；completed/failed/stopped正确保存。
- credentials failure、零输出 completed、terminal rollback。
- partial/terminal persistence failure取消 Provider且不伪造 terminal。
- 同一 UI 动作全链使用同一 RunID/key；再次点击新 key。
- stale old run、cancel <500ms、550ms 后无迟到 delta。
- usage/cost在当前 Provider下保持NULL。
- storage错误无路径/SQL/URL正文/Key/raw body。
- V0.1当前Capture显示、NativeHost/framing、V0.2 BYOK/secret/cancel回归。
- 所有 integration tests只用temp root，绝不访问真实 Application Support。

## 9. UX 边界

遵循 Sam 的内容优先与系统控件，但本阶段只允许：

- 简短 storage 状态。
- recovery/read-only 时禁用总结与翻译。
- 稳定错误文案。

禁止 Sidebar、NavigationSplitView、history row/detail、Share/Delete/Rerun UI、富文本、Ask、主题或图标重构。

## 10. 停止条件

- Brain/当前 diff 冲突或已有未知 App/socket 并行修改。
- migration 001 hash变化或需要改写 001。
- 冻结 Port 无法表达所需原子性/恢复。
- Core/ViewModel 被迫 import GRDB。
- recovery 无法早于 writable socket。
- capture 仍依赖内存 Set。
- storage failure 后必须伪造 terminal 才能通过。
- cancel 后仍有迟到 delta。
- secret scan命中、新 V0.1/V0.2回归无法归因。

## 11. 验证与回滚

运行 composition/receiver/orchestrator/history专项、完整Swift、Debug/Release、Web、licenses、secret、doctor、diff和Xcode。既有Network/Keychain/socket/Xcode sandbox失败如实分层，不降低测试。

回滚只撤销App→Persistence接线、新App文件、orchestrator接线、02B测试/文档。禁止删除/降级数据库、修改migration001、清理Application Support/Keychain或触碰V0.1 Host。
