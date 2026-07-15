# P0-RC-02B App Capture / Run 持久化接线实施记录

> 状态：**02B 已完成，最终独立 Sol 复审 PASS**。Hana 主线程 post-fix 验证为 Swift 117/117、SwiftPM Debug/Release、Web 与四个 Xcode 目标全部通过；migration 001 保持冻结字节，未创建 migration 002。

## 场景、角色与交接

```text
AppComposition
  → open Application Support/LinkDigest/history.sqlite
  → accessMode
  → recoverInterruptedRuns
  → storage availability
  → start Unix socket server

Capture frame
  → CaptureValidator
  → HistoryApplicationService.acceptCapture commit
  → CurrentCapture(envelope, TaskID, SnapshotID)
  → NativeResponse.taskAccepted

UI Run action
  → one RunID + run:v1:ui:<runID>
  → queued commit → starting
  → credentials → running commit
  → Provider delta → partial commit → streaming UI
  → terminal + Artifact + unknown usage commit
  → terminal UI
```

`AppComposition` 是唯一装配点：生产只创建一个 `GRDBHistoryRepository` 和一个 `HistoryApplicationService`。Application Support root、Repository factory、clock 与 server starter 可注入；02B integration tests 只使用 fake 或临时 root。Gate 0 的 production vertical smoke 在 Debug build 通过 `LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT` 把脚本创建的专属临时 root 显式交给 composition；override 存在时 live-root resolver 会拒绝调用，Release 不包含这个测试入口。

## Capture 接线

`CaptureReceiver` 保持既有 Chromium framing 与 `NativeResponse` 合同。decode 前无法可信取得 request ID 时使用 `app-receiver`；decode 后的 idempotency/storage failure 使用 envelope request ID。成功 ACK 没有新增 TaskID/SnapshotID 字段。

Repository commit 是 UI 与 ACK 的共同闸门。duplicate delivery 使用 Repository 返回的旧 IDs 刷新当前单页并正常 ACK；conflict、read-only 与写入失败都不把正文送入 UI，也不替换或清空此前成功的 CurrentCapture。`AppComposition` 每个生命周期只创建一个 actor-backed `StorageWriteGate`，同一实例交给 socket `CaptureReceiver` 与 `ModelRunOrchestrator`。Capture decode 成功后，通过 gate 的显式 exclusive permit queue 线性化“检查 writable → 授予 permit → 执行短时同步 Repository Capture 事务 → 成功 handoff 或失败先写入 unavailable 再拒绝 waiter”；因此并发 Capture 不能同时越过授权。同步 `throws` operation closure 不包含 UI callback、socket、网络、Provider 或任何 `await`；gate actor 在 A 持有 permit 时仍可登记 B waiter，并在 B 真正入队后提供内部测试 continuation。availability sink、Capture UI 与 ACK 都在 permit 事务外。任一 storage failure 会黏性降级 gate 并同步 UI，后端随后成功或再次调用 bootstrap-success 标记都不能恢复，只能由新的 composition/bootstrap/recovery 生命周期重建。socket/接收服务状态仍与 storage 状态分离。生产链路不再使用 `CaptureInbox` 判断正确性。

## Run 接线

现有 `ModelRunOrchestrator` 被原位扩展，没有新增第二个 coordinator。UI 每次动作生成一个 typed `RunID`，Orchestrator 不再生成另一 UUID；Repository replay 返回的 RunID 成为后续 persistence command 与 UI callback 的唯一身份。active Run 存在时第二次 start 直接忽略，避免遗留 queued/running 记录或产生第二 terminal owner。starting callback 前先完整安装 RunID、handler 与受门控 producer Task，因此 callback 内立即 Stop 也能把 queued Run 提交为 stopped。`createRun` 返回 ID 必须等于 request 与 `run:v1:ui:<id>` 嵌入 ID；不一致映射 `STORAGE_STATE_CONFLICT`，不启动 Provider。credentials、stream iteration、holdback flush 与 state callback 等可重入 await 返回后都重新核对 RunID/Task cancellation。

流式文本区分 candidate 与 committed partial。`StreamingSecretRedactor` 对可能继续组成完整 API Key 的跨-delta 后缀执行 holdback；只有确定安全的前缀或完整替换后的 `[已隐藏]` 才能进入 `savePartialArtifact`。terminal/provider failure 前先安全 flush；holdback flush 写失败仍只保留最后 committed partial。当前 Provider 没有 usage/cost 事件，所有 terminal command 使用 `RunUsageCost.unknown`，数据库字段保持 NULL。

Provider 零输出直接 completed 被保存为 failed `MODEL_STREAM_MALFORMED`，不创建空 complete Artifact。credentials/model/provider failure 先提交 failed，再发布 failed/incomplete UI。

## 取消、stale 与故障

Stop 先清除当前 Run 所有权，并在任何可能缓慢的 UI callback 之前取消 Provider 与 producer Task；随后发布 stopping，最后用最后一次 committed partial 提交 stopped，提交成功后才发布 stopped。旧 Run 的 delta、terminal 与 persistence callback 都必须匹配同一 typed RunID。

partial/terminal/stop 写入失败会取消 Provider/Task，并先降级生命周期共享 `StorageWriteGate`，再发布与 gate 首个稳定错误码一致的 `storageError` UI 状态。此后 socket Capture 在 Repository 前被拒写。该状态只展示最后 committed partial 与稳定 storage code，不伪造 completed/failed/stopped；数据库保留 queued/running，下一次启动由 interrupted recovery 收口。Provider failure 只改变当前 RunState，不污染全局 storage availability。

## 错误与模块边界

`StorageErrorMapper` 纯映射 Repository failure 到冻结 code、retryable 与 action。storage `safeDetail` 默认为 nil，不携带路径、SQL/table、URL/正文、Key/secret reference、Header/token 或 raw Provider body/error。

`LinkDigestApp` 与 App tests 依赖 `LinkDigestPersistence`，但 View/ViewModel 不持有 GRDB、DatabasePool/Queue 或 SQL。GRDB import 仍只存在于 Persistence target。

## 协议专项安全修复

Extension 对 Native Host 返回值先做 wire validation，再决定 UI 结果：成功仅接受 `kind=taskAccepted`、`version=1`、非空且与当前 envelope 相同的 `requestId`、必填整数 `characterCount`；未知 kind、错版本、缺字段或 correlation mismatch 都归一为完整 `AppError`，不得进入“已发送”。未知附加字段继续允许，以保留 wire forward compatibility。Extension 自身 validation/timeout/transport failure 同样构造带可信 request ID、时间、category、code、retryable、action 的完整 AppError，不再伪造残缺 NativeResponse。

Popup 只消费冻结 storage code allowlist 的固定中文文案；raw code、action、safeDetail 以及未知错误内容均不直接展示。Swift `NativeResponse` decoder 对 `taskAccepted`/`error` 使用显式 switch，未知 kind 与非 v1 response decode failure。Canonical ACK schema 将 `characterCount` 列为 required；Swift 与 TypeScript 同时消费 `contracts/native-response-fixtures.json`。Host socket/App timeout 统一映射 category `network`，畸形 App response 使用稳定 `NATIVE_RESPONSE_INVALID`。

Wire schema 明确由 `CaptureWireContractSchema`/`validateWireSchema` 承担并允许未知附加字段；strict persisted schema/invariant 仍只由 frozen migration 与 Repository 检查承担。本次没有修改 framing、ACK 字段形状、migration 或 UI 结构。

## 最终独立复审

独立审查先后发现并关闭两个阻断：运行期 storage 降级必须由 App、Run 与 socket Capture 共用同一动态 gate；并发 Capture 不能同时越过 writable 检查。最终实现使用显式 exclusive permit queue，并以 gate 内 waiter 登记、A failure 先降级再拒绝 B、以及 `.storageError` callback 发生在 `degradeStorage` 返回之后作为确定性 barrier。最终定点复审结论为 PASS，允许关闭 P0-RC-02B。

## 范围边界与回滚

本阶段没有实现历史 Sidebar、详情、删除 UI、导出、Ask、Rerun UI 或视觉重构。回滚只撤销 App→Persistence 依赖、`AppComposition`/`CaptureReceiver`/storage presentation、Orchestrator 持久化扩展、02B tests/docs；不删除数据库、不改 migration 001、不触碰真实 Application Support、Keychain、Provider 或 V0.1 Host。
