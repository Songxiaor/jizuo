# P0-RC-02B App Capture / Run 持久化接线证据

日期：2026-07-15
状态：最终独立 Sol 复审 PASS；P0-RC-02B 已关闭；最终主线程 Swift/Web/Xcode 门禁通过

## 专项结果

```text
AppCompositionTests                  4/4 PASS
CaptureReceiverTests                 9/9 PASS
GRDBOrchestratorIntegrationTests      8/8 PASS
PersistentModelRunOrchestratorTests 14/14 PASS
ModelRunOrchestratorTests           13/13 PASS
HistoryDomainTests                    4/4 PASS
AppViewModelTests                   11/11 PASS
High-risk + design + security total  63/63 PASS
Contract                                 6/6 PASS
Combined targeted                       69/69 PASS
```

临时 GRDB restart 用例只在 `FileManager.default.temporaryDirectory` 下创建隔离 Application Support root；没有启动生产 App，也没有访问真实 Application Support、浏览器资料、Keychain 或 Provider。

## 时序证据

```text
recover → server
capture commit → MainActor UI → taskAccepted
queued commit → starting UI → running commit → Provider
partial commit → streaming UI
terminal commit → terminal UI
```

Ordered fake 用 semaphore 分开 method entry 与 commit success：Capture 的 ACK/UI、Run 的 starting/streaming/terminal，以及 normal server start 在 blocker 释放前均为 0 或保持上一 committed 状态。共享 `StorageWriteGate` 补证证明：Composition 并发 bootstrap 返回同一 gate；首次 Capture write failure 后即使 fake Repository 恢复成功并再次尝试标记 writable，第二次 Capture 仍在 Repository 前被拒绝，调用次数保持 1、无 UI/ACK、已有成功 Capture 保留；read-only/open/recovery 重复 Capture 始终拒写。新增 A/B 确定性 barrier：A 已获 exclusive permit、进入同步 Repository Capture 事务并阻塞；测试随后等待 gate 内部 `waitForQueuedCaptureAttempt()` continuation，只在 B 已真正登记进 permit waiter queue 后返回，此时 Repository 调用仍为 1。释放 A 使其失败，gate 在 permit handoff 前写入 unavailable 并拒绝 B；B 不调用 Repository且无 UI/ACK。Run partial/terminal failure 等待对应 `.storageError` state callback；该 callback 只能发生在 `degradeStorage` 返回后，测试收到明确事件后才发送 Capture，Repository 调用保持 0；GRDB terminal/stop failure 均观测到 gate 降级。测试不以概率 sleep 建立这些线性化顺序，也不声称 failure 能撤销此前已经线性化的 Capture 授权。故障用例还证明：第二次 partial 写失败只保留第一次 committed partial；terminal/stop 注入失败不发布伪 terminal。恶意 Provider 故意忽略取消并迟到发送旧 delta，550ms 后仍被 RunID/stale gate 拒绝。真实 temp GRDB 中 partial/terminal/stop 失败均保持 running，close/reopen 后由 recovery 转 interrupted；Provider explicit cancel、stream termination 与 producer finish 均有证据。

## 安全证据

- storage category 使用冻结 code，`safeDetail == nil`。
- 每个 sentinel 用例动态生成唯一绝对路径，扫描 response JSON、UI 文案与 snapshot；均无命中。映射输出也不含 database 名、SQL、私人 URL、API Key、Authorization/Header 或 raw Provider body。
- 成功 Run 经 temp GRDB detail、close 与 reopen 后验证 input/output/total token、cost micros、currency 五列均为 NULL。
- App/Core grep 不含 `import GRDB`、`DatabasePool`、`DatabaseQueue` 或 SQL。
- migration 001 未修改；最终 hash 在完整门禁后复核。

## 协议专项补证

```text
contract sync                         PASS
TypeScript NativeResponse fixtures    PASS
Swift NativeResponse fixtures         PASS
Extension typecheck/tests            PASS (10/10)
Framing tests                          PASS (5/5)
Host timeout category source/fixture  PASS; dedicated temp-socket smoke在严格子会话中受EPERM阻断
```

共用 fixture 证明：ACK 缺 `characterCount`、错版本与未知 kind 均为 wire invalid；ACK request ID mismatch 为 correlation error；未知附加字段保持可接受。Popup allowlist 测试把 `sentinel-secret-path` 放入 storage `safeDetail`，最终文案不含 sentinel、raw code 或 raw action。Host smoke 的 source assertion 已收紧为 `network/NATIVE_MESSAGE_TIMEOUT`，但本轮执行在 `/tmp` 临时 Unix socket `listen` 被外层 sandbox 以 EPERM 阻断，因此该项保留环境层 BLOCKED，不宣称运行通过。

## 完整门禁结果

```text
High-risk + design + security        63/63 PASS
Contract                                6/6 PASS
Combined targeted                      69/69 PASS
Full Swift                          117/117 PASS
Known product failures                 0/117
SwiftPM Debug                         PASS
SwiftPM Release                       PASS
pnpm check:web                        PASS
Shared tests                         10/10 PASS
Browser extension tests              10/10 PASS
WXT production build                  PASS
JS licenses                           PASS
Swift licenses                        PASS
secret hygiene                        PASS
native-host check                     PASS
doctor                                PASS=52 WARN=1 FAIL=0
git diff --check                      PASS
App/Core binding + CaptureInbox scan  PASS
Migration001 SHA-256                  2402fd0dcb8293010f3c080af583a98c50af661a200915c321e0faaccfb93b57
Migration001 diff                     empty
Migration002                          absent
Xcode LinkDigestApp Debug/Release      PASS
Xcode LinkDigestNativeHost Debug/Release PASS
Vertical smoke                        SKIP: no proven temp Application Support injection
```

并发线性化补证使用确定性 semaphore/continuation barrier，不用概率 sleep 触发关键交错：starting/stopping/streaming callback suspension、producer 注册/取消、Stop 与 completed 双线性化、terminal failure 后新 Run、partial failure 后 hostile late event、MainActor 旧 Run 全状态矩阵均通过。`createRun` 返回 RunID 与 request/key ID 不一致时稳定返回 `STORAGE_STATE_CONFLICT`，不启动 Provider、不切换 authority。500ms 分别覆盖 Provider cancel、consumer termination 与 stop return；550ms 同时核对 UI states、Repository write/terminal count 与 Provider active count不再变化。

安全候选补证：temp GRDB 中 `.starting` callback 内立即 Stop 在 500ms 内完成 queued→stopped，Provider cancel 在 UI await 前发生；active Run 第二次 start 被忽略，DB 最终只有一个 stopped Run；多种 2+ delta secret 分片与 holdback flush 写失败均未把 secret/未完成前缀送入 UI、RunState 或 Artifact；24 路并发 Capture 的 envelope/TaskID/SnapshotID 保持成组一致。storage socket retry/action/safeDetail 已统一由 `StorageErrorMapper.presentation(for:)` 生成。

设计状态矩阵覆盖 cold start、writable/no capture、capture success/failure、starting/streaming/completed/stop、partial/terminal failure、read-only 与 Provider error。Provider failure 保持 storage writable；storage failure 只使用本地历史/本地存储语义并禁用新 Run。控件级源码扫描未发现 Sidebar、NavigationSplitView、history UI、Rerun/Share/Export/Delete/Ask、token-cost、Banner/Toast/dashboard；首轮宽泛正则仅误命中 `Task/taskID/SECRET_STORE_DELETE_FAILED`，收窄为控件级模式后零命中。

实施子会话曾出现 8 个 Network.framework fake server `startFailed`、1 个隔离 Keychain status 100001、1 个 Unix socket address-in-use，以及 Xcode nested sandbox exit 74；这些都在最终 Hana 主线程 clean post-fix 复验中消失：完整 Swift 117/117 与 Xcode 四目标全部通过。因此最终分类为子会话执行环境差异，不是产品代码失败。高风险专项和所有 GRDB integration 只使用 fake 或 `FileManager.default.temporaryDirectory`；没有运行可能解析真实 Application Support 的 production vertical smoke，也没有修改全局 defaults、降低测试、启动生产 App，或访问真实 Application Support、浏览器资料、真实 Keychain/Provider。
