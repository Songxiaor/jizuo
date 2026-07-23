# P0-RC Loop 4 r4a：unsigned App + DMG release unit

> 状态：首次独立 review **BLOCK，P0/P1/P2 = 0/4/2**；集中修复后的唯一 re-review **PASS，P0/P1/P2 = 0/0/0**。该 PASS 只证明 `/private/tmp` 隔离构建得到的 unsigned App/Host/DMG 与 release unit 绑定，并对真实固定目标做零写入探测；产品仍 BLOCKED，不代表签名、公证、安装或发布完成。

## 1. 任务卡

- 用户场景：r1–r3 已分别证明 Host package、clean-room transaction 与只读 preflight，但 App、Host、DMG 还没有一份能防止“拿错箱子”的共同装箱单。
- 本次只解决：在 caller 明确给出的新 canonical `/private/tmp/linkdigest-r4a-release.*` audit root 内离线构建 App+Host+DMG；挂载同一 DMG 后复验 exact tree；只读查看五个真实固定对象的 ownership 状态。
- 明确不做：真实 HOME/profile 写入、真实安装/升级/卸载、Keychain、Cookie/History/Login Data、浏览器/App 启动、依赖下载、`codesign -s`（包括 adhoc）、Developer ID、notarytool、公证、stapling、`spctl` artifact query、发布与 Git。
- 当前结论：r4a unsigned release-unit 工程门禁已独立 PASS；`productStatus` 仍固定为 `BLOCKED`，`separateAuthorizationRequired` 仍固定为 `true`。

## 2. 场景 → 角色与交接 → 工作流 → 工具协同

```text
workspace 源码 + 已解析 GRDB checkout（只读）
  ↓ allowlist copy；不复制 .git/.build/node_modules/output/evidence
/private/tmp audit source + audit dependency
  ↓ temp-only sync-contracts + local SwiftPM dependency
Swift Release App + Host + resource bundle
  ↓ r1 verifier 包装 Host；exact plist/tree 包装 App
LinkDigest.app + release-unit.json
  ↓ hdiutil create/verify/readonly attach
mounted exact tree 再验
  ↓ exact dev-entry detach + residual mount check
工程 candidate report（产品继续 BLOCKED）
```

- **Swift 资源定位器**：标准 `.app` 只从 `Bundle.main.resourceURL/LinkDigest_LinkDigestCore.bundle` 找 Schema；SwiftPM/Host executable 只从 executable sibling 找；只有测试显式选择 `testLocator()` 才能使用 `Bundle.module`。App 缺 bundle 时 fail closed，不会偷偷回到编译机 `.build`。
- **release core**：只接收新 `/private/tmp/linkdigest-r4a-release.*` audit root。allowlist source、已有 GRDB checkout、runtime resource、App/Host executable/package 都由 directory-fd/openat nofollow walker复制；symlink、special file、regular `nlink != 1` 或 unsafe parent 在读取内容前拒绝。
- **r1 Host verifier**：把 Release Host 与实际 resource bundle组成 `LinkDigestNativeHost-0.1.0-macos-arm64`，继续使用 r1 frozen config/checksum/packageDigest，不放宽 package 合同。
- **release-unit verifier**：把 App bundle ID/status/version/build/minOS/arch、executable/plist/schema/tree hashes 与 Host embedded path/name/version/minOS/arch/entrypoint/packageDigest 绑定为 canonical JSON。
- **DMG verifier**：attach 无论 success/nonzero 都立即建立 cleanup guard。坏/歧义 plist 或 partial attach 改从 `hdiutil info -plist` 按 exact DMG+mount 寻找唯一 dev-entry；唯一确认后 exact detach，普通失败只有再次 exact reconfirm 才允许一次 force；无法唯一确认固定 exit 8。
- **真实目标 probe**：从 `getpwuid(geteuid())` 取得真实 home，忽略 `HOME/TMPDIR`；从 `/` 起以 directory fd + `openat(O_NOFOLLOW)` 逐组件锚定五个 leaf。同一 leaf fd 负责 fstat、limit+1 bounded read、hash 与前后 snapshot，最后用 anchored parent fd 复核 leaf dev/inode/type；不扫描目录。

## 3. 四个新名词（L3）

| 名词 | 人话定义 | 生活类比 | 项目位置 | 不使用会怎样 |
|---|---|---|---|---|
| release unit | App、Host、装箱单和 DMG 必须能证明属于同一批次 | 箱内商品、序列号与箱外装箱单逐项对上 | `release-unit.json` + DMG staging | 可以把 A 版 App 与 B 版 Host/DMG 错配 |
| audit root | 一次构建唯一允许写入的隔离工作台 | 只在封闭实验台组装，不碰家中抽屉 | `/private/tmp/linkdigest-r4a-release.*` | SwiftPM 可能污染 workspace `.build` 或真实 HOME |
| tree digest | 按 byte-sorted 路径记录 type/mode/size/hash 的整棵树指纹 | 不看箱子生产时间，只核对每件物品与位置 | App tree record | 额外文件、替换文件或权限漂移可能漏过 |
| fail closed | 证据不足、格式不明或挂载身份对不上时停止 | 行李牌看不清就不上飞机 | locator/verifier/probe/exit codes | 系统可能把未知状态误当安全 |

## 4. frozen App config 与四方一致性

`config/app-release.json` 顶层 exact keys，未知字段、bool 冒充 integer、版本/架构漂移均 exit 2：

| 字段 | frozen candidate |
|---|---|
| formatVersion | integer `1` |
| appName / executable | `LinkDigest` / `LinkDigestApp` |
| bundleIdentifier / status | `com.syc.linkdigest` / `engineering-candidate` |
| shortVersion / bundleVersion | `0.1.0` / `1` |
| minimumMacOS / architectures | `15.0` / `[arm64]` |
| category | `public.app-category.productivity` |

四方必须一致：config、`Info.plist`、App/Host Mach-O（`lipo` + `LC_BUILD_VERSION`）、Host `package.json`/r1 config。任何一方变成 14.0、x86_64、0.2.0 或不同 bundle version 都拒绝。

`Info.plist` 只允许 frozen 12 个 keys/types：development region、display/name/executable/identifier、plist version、package type、short/build version、category、minimum system、high-resolution capability。App exact tree 为：

```text
LinkDigest.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/LinkDigestApp
    └── Resources/
        ├── LinkDigest_LinkDigestCore.bundle/...
        └── NativeHost/LinkDigestNativeHost-0.1.0-macos-arm64/...
```

只复制构建中实际存在且运行必需的 Core resource bundle；没有凭计划添加不存在的 GRDB bundle。App 不创建 `_CodeSignature`。允许 Swift linker 自然产生 executable adhoc load state，但脚本不执行任何 `codesign -s`；App 顶层记录仍为 `{mode: unsigned, teamID: null}`，只读 `codesign -dv` 若发现 Developer ID Authority/Team ID 会拒绝。

## 5. release-unit 与 tree 合同

DMG staging 根必须 exact：

```text
LinkDigest.app
release-unit.json
```

外置 manifest 避免把 manifest 自身塞进 App tree/signature 形成自引用。canonical JSON 统一 sorted keys、2-space、末尾换行。`unitID` 固定 `com.syc.linkdigest.release-unit.v1`；blockers 固定包含：

- `official-identifiers-not-frozen`
- `team-id-not-frozen`
- `developer-id-signing-not-performed`
- `notarization-not-performed`
- `stapling-not-performed`
- `real-install-browser-acceptance-not-performed`

tree record 按 UTF-8 filesystem bytes 排序，每条只含 `type/mode/size/hash/path`，不含 uid/gid/mtime。拒绝 symlink、regular hardlink、FIFO、socket、device、unsafe relative path 和额外 top-level item。

## 6. build、DMG 与 cleanup 合同

生产入口：

```bash
./scripts/native-host/package-app-dmg.sh \
  --audit-root /private/tmp/linkdigest-r4a-release.UNIQUE
```

- audit root 必须是 `/private/tmp` direct child、basename 以固定 prefix 开头、canonical、caller 明确且不存在；脚本绝不覆盖。
- GRDB 只从 workspace 现有 `apps/desktop/.build/checkouts/GRDB.swift` 复制；缺失 exit 20，绝不联网。
- `sync-contracts.sh` 只在 audit source 执行；workspace 的内容+metadata inventory（包括已有 `.build`）构建前后必须完全一致。
- DMG 固定 `UDZO + HFS+ + -nospotlight + -srcowners on`，没有 `-ov`。
- attach 固定 readonly/nobrowse/noautoopen/noautofsck/mount required + audit mountpoint + plist；returncode 非零、plist 坏或歧义也不能跳过 cleanup discovery。
- ordinary detach 失败后，只有 `hdiutil verify` 与 `hdiutil info -plist` 重新确认同一 DMG/mount/dev-entry，才允许一次 exact force；仍失败 exit 8，保留现场并 STOP。
- managed sandbox 的 `hdiutil create/attach/detach` 若返回环境权限错误，只能对该条 exact command 单独授权；不能把整个 gate 提升。

所有成功或失败 audit root 都保留，不自动清理。

## 7. 真实目标只读 probe

只触碰以下五个固定对象；绝不 `listdir`/glob/profile scan，也不读 Cookie/History/Login Data：

1. `NativeMessagingHost` root。
2. `receipt-v1.json`。
3. `receipt-v2.json`。
4. Chrome/Brave shared manifest。
5. Edge default manifest。

逐组件 directory-fd/openat nofollow；文件必须 current-user owned、single-link、大小受限、canonical JSON。读取固定最多 `limit + 1`，oversized fail closed且不输出部分 hash。输出只含 token/state/reason/contentHash/mode/nlink/owned，不含用户名、绝对 path、uid/gid、origins 或 raw content。同 fd snapshot 排除 atime；parent symlink、leaf swap/TOCTOU、oversized、FIFO 与 hardlink 均有负例。

当前实机只读事实（本轮阶段证据）：Native Host root、v1/v2 receipt 为 `absent`；Chrome 与 Edge 两个固定 manifest 为 current-user-owned single-link `0600`，但内容不是 r4a canonical JSON，因此状态为 `malformed`。probe 只记录了 content hash，没有显示或改写内容。这一事实让组合状态保持 BLOCKED；它不是授权修复真实 profile。

## 8. 退出码、STOP 与恢复

| code | 含义 |
|---:|---|
| 0 | 工程安全完成；产品仍可/应为 BLOCKED |
| 2 | unsafe path/schema/tree/binding |
| 8 | cleanup required、detach/residual mount 或真实 target 叶子变化 |
| 10 | target unknown/malformed 或组合产品 BLOCKED |
| 20 | 离线依赖/Apple tool/环境阻断 |
| 70 | 未分类内部错误 |

**STOP**：workspace build write、真实 HOME/profile write、网络/依赖/证书/签名/公证需求、无法精确 detach、target 叶子变化、release-unit binding 无法证明时立即停止，保留 audit root。

恢复只允许：读取工程 report/审计根 → 确认同一 DMG 与 residual mount → 对 exact dev-entry detach；不自动删除 audit、不清理真实 manifest、不回写 receipt。若要修真实 target，必须另开具有 ownership、rollback 与浏览器验收合同的授权任务。

## 9. deterministic gate 与证据边界

```bash
./scripts/native-host/check-release-unit.sh \
  --existing-audit /private/tmp/linkdigest-r4a-release.UNIQUE \
  --review-root /private/tmp/linkdigest-r4a-review.UNIQUE
```

candidate audit 必须已存在且全程只读；review root 必须是 caller 指定的新 direct-child。gate 覆盖 strict binding、tamper/extra/symlink/hardlink/FIFO、source/resource/dependency nofollow copy、plist/version/arch/minOS/package drift、release-unit 混搭、完整 fake attach cleanup 序列、target parent symlink/leaf swap/oversized/v1/v2/manifest/hostile env，以及 focused `ContractTests`。成功生成 canonical `gate-result.json`，绑定 DMG/release-unit/App tree/source/tool hashes、commands、assertion/test count 与 exit status。

首次 review 指出 gate 曾在 candidate audit 内写 tamper/Swift scratch，并运行会启动本机 loopback TCP listener 的 full Swift 181/181。该运行作为失败历史透明保留，但**不计入 r4a 授权证据**，remediation gate 已彻底移除 full suite，只允许 ContractTests；本轮不得重跑 full Swift。

2026-07-17 最终 remediation candidate 使用 `/private/tmp/linkdigest-r4a-release.remediation-candidate-02` 与独立 `/private/tmp/linkdigest-r4a-review.remediation-candidate-02`：真实 DMG readonly mount/reverify/exact ordinary detach 完成且无残余 mount；只读 gate 完成 74 assertions、focused ContractTests 10/10、真实 probe expected exit 10。所有 attach 返回都先用 `hdiutil info -plist` 唯一绑定 exact DMG+mount，成功 plist 报告设备与系统状态不一致也进入精确清理。`gate-result.json` 绑定 DMG `e15c9e67…8f78821`、release unit `8237b09a…c692652`、App tree `928bba01…7d83b8`、source inventory `b82fdeb4…745071` 与两份 tool hashes。同一 reviewer 唯一 re-review 确认首次六项 finding 全部关闭，最终结论 PASS 0/0/0；产品继续 BLOCKED。

工程 PASS 只关闭 r4a unsigned release-unit 门禁；正式 identifiers、签名、公证、stapling、真实安装与浏览器验收未完成前，产品仍必须 BLOCKED。

## 10. 可选跟做（5–15 分钟）

只读打开某个保留 audit root 的 `r4a-engineering-report.json` 与 staging `release-unit.json`，对比 App executable/tree digest 和 Host packageDigest 是否同时出现。不要自行 attach、删除 audit root，亦不要把命令中的路径换成 `$HOME`。该观察不是关闭任务的作业或答题门槛。
