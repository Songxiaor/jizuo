# P0-RC-02B App Capture / Run 持久化接线验收

> 当前结论：**最终独立 Sol 复审 PASS，P0-RC-02B 关闭**。Hana 主线程 post-fix 验证为 Swift 117/117、SwiftPM Debug/Release、Web 与四个 Xcode 目标全部通过；历史 Sidebar/详情/删除 UI 与导出不属于本阶段，也尚未开始。

## 已通过专项

- Composition 6 项：bootstrap 一次性；recovery method entry 后仍保持 normal server start=0，commit success 后才启动；read-only/open/recovery failure 只启动结构化拒绝端；临时 GRDB restart 把 running Run 恢复为 interrupted；Debug production smoke 显式注入临时 Application Support root 时绝不解析 live root，未注入时才委托 live root。
- CaptureReceiver 9 项：ordered fake 区分 method entry/commit success，UI/ACK 只在 commit 后；success/duplicate 返回正确 IDs；首次 write failure 黏性关闭共享 gate，fake Repository 随后恢复成功也不再被调用；并发 A 在同步 Repository barrier 内失败时，已发起的 B 不能再次调用 Repository，释放 A 后两者均为稳定 storage error、无 UI/ACK；validation 与 storage request ID 分层；每次生成动态 sentinel 绝对路径并扫描 response/UI/snapshot。
- GRDB Orchestrator integration 8 项：partial/terminal/stop 写失败后 Provider+producer 收口、无伪 terminal、DB 保持 running 并在 temp reopen 后恢复 interrupted；成功 Run 经 detail/reopen 验证 usage/cost 五列实际 NULL。
- Persistent Orchestrator 14 项：queued/running/partial/terminal 的 method entry 与 commit success 分离；credentials failure；空 completed；partial/terminal rollback；queued/running stop；同一 RunID/key replay 与新点击新 key；storage hygiene。
- Orchestrator 并发/回归 13 项：流式顺序、secret redaction、provider failure、stop <500ms、550ms 无迟到 delta、新旧 Run 隔离，以及恶意 Provider 忽略取消后仍无法发布迟到旧 delta。
- AppViewModel 11 项：冷启动/writable无Capture/read-only 明确禁用；总结/翻译与 stopped；Provider failure 不污染 storage；partial/terminal storage failure 无 candidate/伪 terminal，并通过同一 gate 阻止后续 Capture；storage 文案不含 Provider/API Key/Base URL/网络建议。
- 02A History 24 项、Contract 5 项、History Core 4 项继续通过。

## 关键断言

1. writable 之前不会启动 server；失败窗口仍可打开，但 socket 只返回 category `storage` 的稳定错误。
2. Capture commit 前没有 `CurrentCapture`，也没有 success ACK；duplicate 正常打开旧 TaskID/SnapshotID。
3. Run 每个 persistence/UI callback 使用同一 typed RunID；同一次动作 key 为 `run:v1:ui:<runID>`。
4. partial commit 失败后 UI 只保留最后 committed partial；terminal rollback 不发布 completed/failed/stopped。
5. 当前 Provider 没有 usage，terminal 的 token/cost 全部为 NULL；空 completed 不写空 complete Artifact。
6. View/ViewModel 没有 GRDB/DatabasePool/SQL；所有真实数据库 integration 只使用临时 root。
7. 冷启动、writable无Capture、Capture成功/失败、starting/streaming/completed/stop、partial/terminal写失败、read-only 与 Provider error 均通过 ViewModel 可观察状态核对。
8. 控件级扫描确认没有 Sidebar、NavigationSplitView、history UI、Rerun/Share/Export/Delete/Ask、token-cost、Banner/Toast/dashboard；现有单页内容与 Provider 设置结构保持。
9. temp GRDB 证明 starting callback 内立即 Stop 可在 500ms 内提交 queued→stopped；active Run 第二次 start 被忽略且 DB 只有一个 terminal Run。
10. 多边界 split secret、holdback 阶段 partial failure、UI/Artifact/RunState 扫描均无完整 secret 或未提交 secret 前缀；并发 24 Capture 的 envelope/TaskID/SnapshotID 成组一致。
11. `StorageErrorMapper.presentation(for:)` 是 socket storage retry/action/safeDetail 的单一权威。
12. 确定性 barrier 覆盖 starting/stopping/streaming callback suspension、producer 注册/取消、Stop 与 completed 双线性化、terminal failure 后新 Run、hostile late events，以及 MainActor 对旧 Run 的全部状态拒绝；关键交错不依赖概率 sleep。
13. `createRun` 返回 RunID 与 request/key 嵌入 ID 不一致时映射 `STORAGE_STATE_CONFLICT`，Provider 不启动，authority 不切换。
14. App 生命周期只有一个共享 `StorageWriteGate`；Capture 授权、短时同步 Repository Capture 事务与失败降级由同一 exclusive permit queue 线性化，operation closure 内没有 `await` 或 UI/socket/network/Provider callback。并发 A 在 Repository barrier 内持有 permit 时，测试等待 gate 内部 queued-attempt continuation，确定 B 已登记为 waiter，Repository 调用数仍保持 1；A failure 在释放 permit 前降级，B 随后在 Repository 前拒写。Run partial/terminal/stop、read-only/open/recovery failure 也黏性降级同一实例；测试等待只能在 `degradeStorage` 返回后发生的 `.storageError` state callback，证明 Run degrade 完成在先时 Capture 绝不调用 Repository，不对 Capture 授权在先的合法顺序作追溯撤销。既有成功 Capture 保留，错误 code/action 固定且 `safeDetail == nil`。

## 协议专项复核

- Canonical ACK schema 已冻结 `characterCount` 为 required；Swift/TS 共用 NativeResponse fixture 覆盖匹配与不匹配 request ID、缺字段、错版本、未知 kind、storage errors、敏感 sentinel 与未知附加字段。
- Extension 仅对严格 v1 且 request ID 匹配的 ACK 显示成功；本地 validation/transport failure 返回完整 AppError 并保留可信 envelope request ID。
- Popup storage 文案来自冻结 allowlist，未知 code 使用通用降级；测试证明 raw code/action/safeDetail 与 sentinel 不进入展示文案。
- Swift decoder 未知 kind/non-v1 decode failure；Host socket/App timeout category 固定为 `network`。
- Wire validator 允许未知附加字段；strict persisted invariant 仍归 migration/Repository，未修改 migration 001、ACK 字节字段或 Chromium framing。

## 完整门禁

- 高风险 02B/设计/安全/并发专项加 Contract 69/69 PASS；Hana 主线程最终完整 Swift **117/117 PASS**。实施子会话曾受 Network fake server、隔离 Keychain 与 Unix socket sandbox 限制，但这些签名没有在最终主线程复验中复现，不能写成最终产品失败。
- SwiftPM Debug/Release PASS；原样 `pnpm check:web` PASS，shared 10/10、browser extension 10/10、WXT production build均通过。
- JS licenses、Swift GRDB exact/MIT license、secret hygiene、`pnpm native-host:check` 与 `git diff --check` PASS。
- doctor `PASS=52 WARN=1 FAIL=0`；唯一 WARN 为工作树未提交。
- App/Core binding scan PASS；没有 `import GRDB`、DatabasePool/Queue 或 SQL，也没有生产 `CaptureInbox` 引用。Composition root 仅通过 Persistence Adapter 类型完成装配。
- `pnpm xcode:build` PASS：LinkDigestApp Debug/Release 与 LinkDigestNativeHost Debug/Release 四个目标均通过。
- migration hash 保持冻结值，migration diff 为空，未创建 Migration002。
- Gate 0 已实际运行 production vertical smoke：脚本以 `mktemp` 创建专属临时 Application Support root，并通过 `LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT` 显式注入真实 App composition；Debug 下该环境变量存在时 `liveApplicationSupportRoot()` 会拒绝，因而成功的 20/20 运行证明没有回退解析真实 `~/Library/Application Support/LinkDigest`。运行中自动断言 `history.sqlite` 只位于该临时 root，清理后自动断言整个临时 root 已移除。该 override 不编译进 Release。

## migration 与回滚

`Migration001.swift` 必须保持 SHA-256 `2402fd0dcb8293010f3c080af583a98c50af661a200915c321e0faaccfb93b57`。回滚只移除 02B 接线、新 App 文件、Orchestrator 扩展、tests/docs；不删库、不降级、不清理真实 Application Support/Keychain，也不触碰 V0.1 Host。
