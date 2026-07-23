# P0-RC Loop 4 r2：Stable Host clean-room 事务合同

> 状态：**同一独立 reviewer 唯一 re-review PASS，P0/P1/P2 = 0/0/0**。首次 BLOCK 的三项 P1 已关闭。PASS 只覆盖 fixed canonical `/private/tmp` r2 clean-room；不代表真实 `$HOME`、真实 Chrome/Brave/Edge 安装或 profile ownership、`.app`/DMG、Developer ID、签名、公证、stapling 和发布，也不构成对同 UID 恶意进程或断电的形式化证明。

## 1. 任务卡

- 用户场景：r1 已能在隔离 HOME 初装 Stable Host，但升级或卸载若被并发进程、正常异常或进程崩溃打断，不能靠“尽量删除刚创建的文件”推断系统状态。
- 本次只解决：把 initial install、v1 receipt 迁移、manifest reconcile、严格向前升级、卸载和 recover 收口到同一套可恢复事务合同，并在 `/private/tmp` 证明并发拒绝、commit point 与崩溃恢复。
- 明确不做：真实用户安装/卸载、恶意同 UID 进程的形式化防御证明、断电/文件系统故障的形式化证明、旧版本垃圾回收、签名真实性、发布真实性和任何浏览器/Provider/Keychain/数据库操作。
- 当前状态：首次候选 fast gate 86/86 后，独立 review BLOCK 三项 P1；修复后 r2 fast gate 110/110、r1 compatibility gate 56/56 通过，同一 reviewer 唯一 re-review PASS，P0/P1/P2 = 0/0/0。下一步是 r3/真实安装前决策，任何真实写入仍需 Syc 另行授权。

## 2. 场景 → 角色与交接 → 工作流 → 工具协同

```text
预置 clean-room session
  角色：提供精确 sentinel、永久 .transaction.lock 与隔离 HOME
  交接：可信 session dirfd + lock inode
        ↓
transaction_host.py plan
  角色：只读核对 package、receipt、owned trees 与 manifests
  交接：canonical plan + SHA-256 planDigest + action-bound confirmation
        ↓
transaction_host.py apply
  角色：抢占永久锁、在锁内重算计划、写 durable journal、执行变更
  交接：staged/backups + journal phase + live receipt
        ↓ receipt 是 commit point
transaction_host.py recover
  角色：在同一把锁内判断“提交前回滚”或“提交后收尾”
  交接：rolled-back / finalized / scaffold-cleaned / noop
        ↓
transaction_host_check.py
  用户可观察结果：并发、漂移、SIGKILL、恢复、命名空间重叠与 malformed journal 有 110 项确定性证据
```

工具协同：Python 标准库负责 canonical JSON、SHA-256、`flock`、dirfd/`O_NOFOLLOW`、`fsync`、journal、备份与恢复；Shell 只提供稳定入口。r1 verifier 默认继续验证 canonical `0.1.0` package，transaction 才能显式传入已从 metadata 严格解析的 expected version。没有新增依赖。

## 3. 五个核心名词

| 名词 | 人话定义 | 生活类比 | 项目位置 | 没有它会怎样 | 深度 |
|---|---|---|---|---|---|
| Plan Digest | 对完整只读计划做的确定性 SHA-256 | 给施工清单盖指纹 | `plan` 输出、`apply --plan-digest` | 用户确认后输入变化仍可能照旧施工 | L3 |
| Cross-process Lock | 同一 clean-room 内所有变更共用的进程间互斥锁 | 仓库唯一施工钥匙 | session 根的 `.transaction.lock` | 两个升级/卸载可能交叉改同一批文件 | L3 |
| Transaction Journal | 先落盘、再逐阶段更新的事务流水 | 搬家每一步都签字的操作单 | `NativeMessagingHost/transactions/<txid>/journal.json` | 崩溃后不知道哪些文件该恢复或收尾 | L3 |
| Receipt Ownership | receipt 精确声明 LinkDigest 拥有哪些版本树和 manifests | 有序列号和物品明细的产权清单 | `receipt-v2.json` | 卸载可能删用户文件，或不敢删自有文件 | L3 |
| Commit Point | 决定恢复向前收尾还是向后回滚的唯一分界 | 银行账本正式记账的一刻 | live `receipt-v2.json` 的替换/创建，卸载时为 receipt 删除 | 只看“执行到第几步”会在崩溃窗口猜错方向 | L3 |

## 4. 固定 clean-room 与永久锁合同

事务入口没有 real-HOME 模式。`--session-root`/`--home-root` 继续服从 r1 的 fixed canonical `/private/tmp`、专属 basename、direct-child HOME、精确 sentinel、owner/mode 与无 symlink 边界；所有 mutation 锚定已验证的 session directory descriptor，并在关键操作前复核 session 的 device/inode 身份。

`.transaction.lock` 必须由 clean-room fixture **预先创建**，事务 wrapper 和 `plan`/`apply`/`recover` 均不创建、不替换、不删除它：

- 路径：`<session-root>/.transaction.lock`
- 类型：regular file；拒绝 missing、symlink、hardlink、FIFO、socket
- owner：effective user；link count 精确为 1
- mode：`0600`
- bytes：精确 `LinkDigest transaction lock v1\n`
- `apply` 与 `recover` 使用 `flock(LOCK_EX | LOCK_NB)`；占用时 exit 3，零 mutation
- `plan` 只验证锁叶，不获取排他锁；`apply` 获取锁后必须重新计算计划并比较 digest

这把锁解决协作进程的互斥，不等于对同 UID 恶意进程的安全边界或形式化证明。

## 5. Plan、digest 与确认绑定

`plan` 输出的 canonical JSON 由以下正文计算 SHA-256：

- `formatVersion = 1`
- `action`、解析后的 `operation`
- canonical `sessionRoot`、`homeRoot`
- `packageRoot` 或 `null`
- `before` ownership snapshot 或 `null`
- `afterReceipt` 或 `null`
- `publishVersion` 或 `null`
- `removeVersions`
- canonical/sorted `manifestPayloads`（base64 + absolute target path）

`planDigest = sha256(canonical_bytes(plan body))`；`confirmation = "<action>:<planDigest>"`。`apply` 在永久锁内用相同参数重算计划，digest 或 confirmation 不一致返回 exit 4，不能开始 journal 或 mutation。digest 保护的是“确认的状态/输入与执行时重算结果一致”，不是代码签名、来源认证或发布真实性。

### 5.1 r1 canonical version 与 transaction expected version

首次独立 review 发现：为了让 r2 构造 `0.2.0` upgrade fixture，若直接把 r1 `verify_package` 全局改成接受任意 SemVer，会放宽已经 PASS 的 r1 package 合同。修复后职责分开：

- `stable_host.verify_package(packageRoot)` 没有额外参数时，仍要求 metadata `productVersion` 精确等于 `config/native-host.json` 的 canonical `0.1.0`。
- transaction 先只读 package metadata，要求 `productVersion` 是安全 SemVer，再调用 `verify_package(..., expected_product_version=<该版本>)`。
- 显式 expected version 只改变本次 transaction 对 metadata 的预期；Host name、protocol、architecture、entrypoint、resource bundle、checksum、Schema、owner/mode/link-count 等 r1 verifier 条件不放宽。

因此 r2 的严格向前升级能力不会反向改变 r1 默认 verifier 的冻结语义；本轮 56/56 只作为兼容回归，不是一次新的 r1 最终 review。

## 6. receipt v2 与 ownership 冻结

`receipt-v2.json` 是 canonical JSON、mode `0600`，顶层字段精确为：

```json
{
  "current": { "version": "…", "packageDigest": "…", "path": "…", "directories": [], "files": [] },
  "formatVersion": 2,
  "hostName": "com.syc.linkdigest.v01",
  "lineage": [],
  "ownedManifests": []
}
```

- `current` 与每个 `lineage` record 都冻结 canonical version path、package digest、完整目录 inventory/mode、完整文件 path/hash/mode。
- `ownedManifests` 冻结 canonical absolute path、role、mode `0600` 与 hash，并按路径字节序排序。
- 所有 version record 必须严格 SemVer 递增、路径不重复；读取 receipt 时会重新验证全部 current/lineage tree、package metadata/checksum/schema 和 manifest hash。
- 升级把旧 `current` 追加到 `lineage`，新 package 成为 `current`。**旧版本作为 ownership lineage 保留，不在 r2 自动 GC。**
- r1 `receipt-v1.json` 可在相同 package 的 `install` 或 `upgrade` 中迁移到 v2；迁移先保留原 ownership，commit 后才删除 v1 receipt。
- checksum/package digest 只证明已记录内容的一致性与漂移检测，不证明 package 来自 LinkDigest 官方、未被发布链路外的可信主体替换或具备签名真实性。

## 7. operation 矩阵

| action | 前置状态 | operation | 结果 |
|---|---|---|---|
| `install` | 无 receipt、namespace 无未知 ownership | `initial-install` | 发布 version/manifests 并创建 receipt v2 |
| `install` | 同 package + 同 v2 manifests | `noop` | 零 mutation |
| `install` | 同 package + v1 receipt | `migrate-v1` | 只迁移 ownership receipt/manifest 状态 |
| `install` | 同 package + manifests 变化 | `manifest-reconcile` | 事务化切换 owned manifests |
| `install` | package 不同 | 拒绝 | 必须显式使用 `upgrade` |
| `upgrade` | 无 owned receipt | 拒绝 | 不把未知目录认领为旧安装 |
| `upgrade` | 同 package | `noop` / `migrate-v1` / `manifest-reconcile` | 按 receipt/manifests 状态选择 |
| `upgrade` | 严格更新 SemVer + 新 version path 不存在 | `upgrade` | 新 current；旧 current 进入 lineage |
| `upgrade` | 同版本不同内容、降级或非严格更新 | 拒绝 | 不覆盖、不降级 |
| `uninstall` | 无 receipt 且 namespace 安全 | `noop` | 零 mutation |
| `uninstall` | 有 receipt | `uninstall` | 只移除 receipt 声明的 manifests 与全部 lineage/current version trees |

卸载不会删除 `history.sqlite`、export、install namespace 中未被 receipt 拥有的 sibling 或其它用户数据；发现 owned object 漂移时 fail closed，而不是扩大删除范围。

### 7.1 Edge profile、install namespace 与 package root 隔离

首次独立 review 发现 Edge 隔离 profile 若放入 owned install/version/package tree，manifest target 可能与事务将移动或删除的树互相包含。修复后对 canonical absolute paths 做**双向 overlap** 判断（A 是 B 的祖先或后代都算重叠）：

- Edge profile 与 transaction `install_rel` 不得互为祖先/后代。
- 每个 manifest target 与 `install_rel` 不得互为祖先/后代。
- Edge profile 与 verified `packageRoot` 不得互为祖先/后代。
- 每个 manifest target 与 verified `packageRoot` 不得互为祖先/后代。
- 这些关系既在当前 `plan` 输入计算时检查，也在 recover 读取 journal plan 时重新验证。

Chrome/Brave shared target、Edge default target 与独立且不重叠的 Edge profile 继续允许；current version、install descendant、package root 和 package descendant overlap fixture 均必须在 mutation 前拒绝。

## 8. journal phases、commit point 与恢复方向

每笔非 noop 事务使用随机 32 位小写 hex `txid`，journal 顶层精确为 `formatVersion = 1`、`txid`、`phase`、`plan`。journal 先以 `prepared` 原子落盘；随后按实际工作写入：

- `receipt-backed-up`
- `version-published`（install/upgrade）
- `manifest-backed-up-0000…`
- `manifest-published-0000…`
- `version-backed-up-0000…`（uninstall）
- `receipt-committed`
- terminal：`complete` 或 `rolled-back`

phase 是诊断与进度证据，但**恢复方向不只相信 phase**。唯一 commit point 是 live receipt：

- install/upgrade/migrate/reconcile：live `receipt-v2.json` 精确等于 journal 的 `afterReceipt`，视为已提交；否则必须精确等于 pre-commit receipt 状态。
- uninstall：原 owned receipt 已精确删除，视为已提交；仍存在且 hash 等于 before receipt，视为未提交。

`recover` 在同一永久锁内只允许最多一笔 active journal：commit point 之前恢复 manifests/version/receipt 并标 `rolled-back`；commit point 之后验证新 ownership 并清理 backups/staged，标 `complete`。多个 active transactions、未知 transaction entry、损坏 journal、无法解释的 live receipt 或 user-modified target 返回 exit 8，等待人工审查，不能猜测删除。

journal 不是“能 parse 的 JSON 就可信”。读取时严格验证：顶层与 plan exact keys、format/root/action/operation/phase、before/after receipt、tree/manifest record、lineage 顺序、publish/remove ownership 关系、canonical/sorted manifest payload coverage 与 hash，以及 manifest/Edge profile 对 install/package tree 的 overlap。任何 JSON、字段类型、base64、路径或关系错误都包装为 `RECOVERY_REQUIRED` **exit 8**，并原样保留 journal；已识别的 malformed journal 不得再泄漏成 `INTERNAL_ERROR` exit 70。

若进程只创建了空且结构精确的 `staged`/`backups/manifests`/`backups/versions` scaffold、尚无 journal，`recover` 可以返回 `scaffold-cleaned`；其中出现任何未知或非空内容即拒绝，内容保留。

## 9. 退出码

| code | 常量 | 意义与恢复动作 |
|---:|---|---|
| 0 | `SUCCESS` | `plan`/`noop`/commit/recover 成功 |
| 2 | `INVALID_UNSAFE` | 参数、路径、类型、格式或 package 不安全；修正输入后重跑 plan |
| 3 | `LOCK_BUSY` | 另一进程持锁；等待后重新 plan，不复用旧确认 |
| 4 | `STALE_PLAN` | plan digest/confirmation/package 在窗口内变化；重新 plan 并确认 |
| 5 | `ACTIVE_TRANSACTION` | 有未完成 journal/scaffold；先运行 recover |
| 6 | `OWNERSHIP_DRIFT` | receipt 声明对象被修改/替换/消失；停止自动 mutation，人工核查 |
| 7 | `ROLLED_BACK` | 本次 apply 遇错但已恢复到提交前状态；重新 plan 后再试 |
| 8 | `RECOVERY_REQUIRED` | 状态或 journal schema 无法安全自动解释；保留现场并执行/审查 recover |
| 70 | `INTERNAL_ERROR` | 真正未分类内部错误；malformed journal 已明确不走此码 |

## 10. 确定性 barriers、首次 86 项与当前 110 项覆盖

`--test-barriers` 仅用于 `/private/tmp` 测试，生产调用不得依赖环境注入。当前 barrier：`lock_acquired`、`journal_durable`、`version_published`、`manifest_switched`、`before_receipt_commit`、`after_receipt_commit`、`rollback_started`；测试动作支持 `error`、`sigkill`、`continue`、`wait`。

首次候选 `./scripts/native-host/check-transaction-host.sh` 通过 **86 assertions**，历史证据保留如下：

- r1 fixture 与派生 v2 package verification、package hardlink 拒绝。
- 永久锁 missing/symlink/hardlink/FIFO/socket/mode/content 拒绝且零 mutation；lock busy 与 stale plan 零 mutation。
- session anchor 被换 inode 后停止，原锚点与替换锚点均不被误写。
- initial install、r1 receipt v1 → v2 migration、严格升级、lineage 保留、uninstall 与 post-uninstall recover noop。
- user-modified manifest/receipt、symlink/hardlink/FIFO/socket ownership leaf fail closed。
- 正常异常在 commit 前回滚并保留 receipt uid/gid/mode；`journal_durable`、`version_published`、`before_receipt_commit`、`after_receipt_commit` 四个 SIGKILL 窗口分别恢复到旧版本或新版本。
- safe journal-less scaffold cleanup 与未知 scaffold 保留；poisoned `TMPDIR` 不把写入带到 worktree。
- uninstall 保留未拥有的数据库、export 与 install sibling；worktree 与真实 LinkDigest HOME metadata digest 不变。

首次 86/86 成功审计根为 `/private/tmp/linkdigest-transaction-host-audit.4cuyynw2`。更早的受限 sandbox 尝试因 Unix socket `PermissionError` 失败，现场保留在 `/private/tmp/linkdigest-transaction-host-audit.ul6oa441`；这两份历史不抹除。

首次最终独立 review 随后给出 **BLOCK，P0/P1/P2 = 0/3/0**：Edge profile 与 owned install/version/package tree 重叠、r1 verifier 被全局 SemVer 放宽、malformed journal 落到 exit 70。三项修复后的当前 fast gate 为 **110/110**，在上述 86 项基础上新增覆盖：

- Chrome + Edge default 与独立 Edge profile 正常允许。
- current version、install descendant、package root、package descendant 四类 Edge profile/manifest 双向 overlap 在写入前拒绝。
- r1 default verifier 继续拒绝非 canonical productVersion；transaction 显式 expected version 继续允许严格新版本 fixture。
- journal 顶层、phase、plan exact keys、action/operation、roots、before/after ownership、payload coverage/base64/hash、lineage/publish/remove 关系与 package overlap 的 malformed 变体全部稳定 exit 8，并保留原 journal。

当前 r2 审计根：`/private/tmp/linkdigest-transaction-host-audit.wowu7fax`。配套 r1 compatibility gate 56/56 审计根为 `/private/tmp/linkdigest-stable-package-audit.4wfrzojr` 与 `/private/tmp/linkdigest-host-clean-room.audit.remagrgu`；该 56/56 是修复后的兼容回归，不是新的 r1 最终 review。记录到的真实 HOME metadata digest 前后仍为 `7925d3e9…de1e4`；这只证明该次检查未改变该范围的 metadata snapshot。同一独立 reviewer 唯一 re-review 最终确认三项 P1 关闭，P0/P1/P2 = 0/0/0。

## 11. STOP 条件与证据边界

出现以下任一项立即停止自动 mutation并保留现场：

- 永久锁缺失、内容/owner/mode/link count/type 漂移，或锁正被占用。
- `apply` 重算 plan 与已确认 digest 不同；package 在 staging 前后变化。
- session anchor、receipt、owned manifest/version tree、backup、journal 或 transaction namespace 无法按精确 ownership 解释。
- 同时出现 v1/v2 receipt、多个 active journals、未知 scaffold 内容或 commit state 既不是 before 也不是 after。
- 任何请求指向 `/private/tmp` clean-room 之外、真实 `$HOME` 或真实浏览器 profile。
- 任务试图把 checksum 当签名、把 110/56 或 r2 clean-room PASS 当真实安装验收、把 r1 compatibility rerun 写成新 final review，或把 PASS 扩大到同 UID/断电形式化证明。

当前证据证明的是已覆盖 clean-room 场景下的确定性行为，不宣称对同 UID 恶意进程、内核/磁盘故障、断电或所有崩溃窗口提供形式化证明。

## 12. CLI 入口与真实安装边界

稳定入口：

```bash
pnpm --config.verifyDepsBeforeRun=false native-host:transaction:check
./scripts/native-host/clean-room-transaction.sh plan …
./scripts/native-host/clean-room-transaction.sh apply … --plan-digest <digest> --confirm <action:digest>
./scripts/native-host/clean-room-transaction.sh recover --session-root <session> --home-root <home>
```

调用方必须先在专属 `/private/tmp` session 预置 r1 sentinel 与本规格的 `.transaction.lock`；这些命令不会替调用方创建锁。不得把示例的 session/home 替换成真实 `$HOME`。真实安装需要单独设计 installer authority、真实 profile ownership、签名/公证、升级 UX 与独立验收，不能由 clean-room 参数“放宽”得到。

## 13. 失败、恢复与回滚

- 普通 apply 异常：内部尝试依据 live receipt 自动 rollback/finalize；若已回滚返回 7，若无法解释返回 8。
- SIGKILL/crash：下一次 `plan`/`apply` 返回 active transaction；先运行 `recover`，再重新 `plan`，不得复用旧 digest。
- lock busy/stale plan：零 mutation，等待或重算即可。
- ownership drift/recovery required：保留 journal/backups/audit root，禁止手工批量删除。
- 若未来回滚 r2，只撤销 transaction host/wrapper/check、package script 与 r2 文档/Brain 状态；不触碰 r1 package、Loop 3、migration 001、真实 Application Support、Keychain、Provider 或用户数据库。

## 14. 可选跟做（5–15 分钟）

先只读查看帮助和计划字段：

```bash
./scripts/native-host/clean-room-transaction.sh --help
```

若要共同观察 transaction plan，必须使用已经预置 sentinel 与 `.transaction.lock` 的现有 `/private/tmp` fixture；不要现场把路径替换成 `$HOME`。完整 110 项门禁会制造 SIGKILL、Unix socket 与保留审计根，本任务已经运行，不是关闭任务的作业或前置条件。
