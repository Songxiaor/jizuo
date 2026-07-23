# P0-RC Loop 4 r4b — Local Test ad-hoc DMG

## 1. 定位与状态

r4b 只交付一个可由 Syc 在本机手工打开的 **local-test ad-hoc build**。它不是 Developer ID 发行版，不做 notarization/stapling，不安装 Browser Native Host/manifest/receipt，自动化不启动 App 或浏览器，也不使用真实 Provider。candidate-07 已独立 reviewer PASS 0/0/0 并 finalize，当前状态为 `READY_FOR_MANUAL_OPEN`；产品与公开发布始终 `BLOCKED`，直到后续正式发布门禁完成。

源码、DMG、构建清单和恢复说明在同一个 handoff tree 中；主控已在独立 reviewer PASS 后，以 no-clobber staging、candidate digest、`SHA256SUMS` 和最终 DMG 复验合同 finalize 到 workspace `release/LinkDigest-0.1.0-local-test/`。

## 2. 场景 → 角色与交接 → 工作流 → 工具协同

- **场景**：dirty worktree 包含已授权 r2/r3/r4a/r4b 修改，不能靠 Git commit 表示“这次到底构建了什么”。
- **角色与交接**：live worktree 是原料；source snapshotter 冻结原料；SwiftPM 只消费解包后的快照；codesign 先处理 Host、r1 packager 再冻结 package，最后 App 外层封口；DMG verifier 挂载复核；handoff manifest 把源码、工具、签名、App、Host、package、DMG 和目标 probe 串成同一批次。
- **工作流**：三次 live inventory 一致 → nofollow source/GRDB snapshot → 确定性双归档与 roundtrip → audit-local Package.swift 单点替换 → isolated Release build → Host ad-hoc sign → r1 package/checksum → App 组装与 ad-hoc sign → r1 reverify → exact DMG → readonly mount/reverify/detach → handoff → 独立 review-root gate。
- **工具协同**：Python 管路径、清单、归档与 fail-closed；SwiftPM 离线构建；`codesign` 只做 ad-hoc；既有 r1 helper 校验 Host package；既有 r4a helper 仅复用已审查的 mount cleanup/target probe，不改变 frozen r4a PASS 语义。

## 3. 四个新名词（L3）

| 名词 | 人话定义 | 生活类比 | 项目位置 | 不使用会怎样 |
|---|---|---|---|---|
| source snapshot | 不经过 Git，把 live dirty worktree 的允许文件逐项安全复制并冻结 | 装箱前给工作台上每件零件拍照、编号、封箱 | `local_test_release.py` + 两份 source tar.gz | 无法证明未提交修改是否进入 DMG，构建还可能读到变化中的文件 |
| inside-out signing | 先签最里面的 Host，再生成 checksum package，最后签外层 App | 先封零件袋、再封内箱、最后封外箱 | Host `codesign` → r1 package → App `codesign` | 外层封口后再改 Host 会破坏 App seal，package checksum 也会错 |
| local-test unit | DMG 内的 canonical JSON，绑定源码、依赖、工具、App、Host、package 与签名事实 | 随箱装箱单，写明本箱每个部件来自哪一批 | `local-test-unit.json` | App、Host、源码和签名可以被不同批次混搭 |
| handoff tree | Syc 实际收到的 exact 交付目录 | 产品、说明书、质检报告和原材料证明放在同一文件夹 | audit 内 `LinkDigest-0.1.0-local-test/` | DMG 与源码/限制/恢复说明分离，无法复现或安全测试 |

## 4. frozen compatibility 与路径合同

`config/local-test-release.json` 冻结 r4a 五个文件的 SHA-256。r4b 每次 build/gate 先校验这些 hash；不得修改 `config/app-release.json`、`release_unit.py`、`release_unit_check.py`、`package-app-dmg.sh`、`check-release-unit.sh` 或重新解释 r4a PASS。

生产 audit 只能是 caller 指定、尚不存在的 `/private/tmp/linkdigest-r4b-local-test.*` direct child。review 只能是新的 `/private/tmp/linkdigest-r4b-review.*`。成功和失败根均保留，不覆盖、不删除。最终 workspace release 只允许在独立 PASS 后由主控从不可变 candidate 安全 finalize，构建脚本本身不创建它。

## 5. live source 与 GRDB snapshot

source 顶层 exact allowlist 在 config 中冻结，覆盖 `.github`、项目入口文档、`apps/`、`packages/`、`contracts/`、`config/`、`scripts/`、`docs/`、`brain/`、lockfiles 与 workspace 配置。`.git`、`.mindmux`、`.build`、`node_modules`、`release`、`artifacts`、cache/output、`.env`、credentials、SQLite、log、downloads/exports 等按 exact basename/suffix 排除。顶层未知 entry 立即 STOP。

snapshot walker 从 directory fd 出发使用 `O_NOFOLLOW`，拒绝 symlink、regular `nlink != 1`、FIFO/socket/device 和复制时变化。文件名与内容执行高置信 secret scan，只报告相对路径，不报告疑似值。snapshot 前、snapshot 后和 final build 前的 live allowlist content+metadata inventory 必须一致。

GRDB 7.11.1 只从既有 `apps/desktop/.build/checkouts/GRDB.swift` 单独 nofollow snapshot；排除 `.git/.build/CustomSQLite/SQLiteCustom`，必须保留 `LICENSE`。构建 input 只由两份 tar.gz 解包产生；`Package.swift` 只允许把唯一 exact remote declaration 替换为本 audit 的 GRDB absolute path，并记录 before/after hash。

## 6. 确定性归档与离线构建

两份 tar.gz 都按 filesystem bytes 排序；tar 统一 `uid/gid=0`、空 `uname/gname`、`mtime=0`，gzip 统一空 filename 与 `mtime=0`。每份各生成两次并要求 byte/hash 一致，再解包到新 review tree，tree digest 必须与 `SOURCE_MANIFEST.json` 一致。

Swift Release build 的 `HOME/TMPDIR/config/cache/scratch/module-cache` 全部位于 audit；环境清除代理、禁止 netrc/prompt，argv 固定 `--disable-netrc --skip-update`。patched Package.swift 不含 remote dependency，缺少 GRDB 时 exit 20，绝不联网 fallback。build 只产出 App、Host 与 Core resource bundle，不运行 App/Host。

## 7. ad-hoc inside-out signing

固定顺序：

1. `/usr/bin/codesign --force --sign - --timestamp=none --identifier com.syc.linkdigest.native-host HOST`
2. Host strict/all-architectures verify。
3. 用 signed Host 创建 r1 package/checksums 并调用 r1 verifier。
4. 组装 App。
5. `/usr/bin/codesign --force --sign - --timestamp=none --identifier com.syc.linkdigest APP`
6. App strict/all-architectures 与 deep verify。
7. 外层 seal 后再次调用 r1 verifier，packageDigest 必须未变。

脚本不使用真实 identity、Keychain、Team ID、Authority、timestamp 或 `--deep` 签名。解析结果必须唯一 `Signature=adhoc`、`TeamIdentifier=not set`、无 `Authority=`、无 `Timestamp=`，并绑定 CDHash。当前不用 `--options runtime`，不宣称正式 hardened runtime。

## 8. local-test unit、DMG 与 handoff

`local-test-unit.json` canonical JSON 绑定 source/dependency archive/tree/manifest、tool facts、Package.swift patch、Swift argv、App/Host hash+Mach-O+CDHash、r1 packageDigest 和签名顺序。DMG staging exact：

```text
LinkDigest.app
local-test-unit.json
```

DMG 固定 UDZO/HFS+；attach 固定 readonly/nobrowse/noautoopen/noautofsck/exact mount。每次 attach 返回都进入 r4a exact cleanup guard，挂载树复验后 ordinary exact detach，确认无 residual mount。

handoff exact tree：

```text
LinkDigest-0.1.0-local-test/
├── LinkDigest-0.1.0-local-test-macos-arm64.dmg
├── README.md
├── BUILD_MANIFEST.json
├── SHA256SUMS
├── KNOWN_LIMITATIONS.md
├── TROUBLESHOOTING.md
├── THIRD_PARTY_NOTICES.md
├── SOURCE_MAP.md
├── source/
│   ├── LinkDigest-0.1.0-live-worktree-source.tar.gz
│   ├── GRDB.swift-7.11.1-source.tar.gz
│   └── SOURCE_MANIFEST.json
└── evidence/
    ├── VERIFICATION_REPORT.json
    ├── APP_TREE.json
    └── TOOL_HASHES.json
```

`SHA256SUMS` 覆盖自身以外全部 regular files。`BUILD_MANIFEST.json` 记录 `distributionClass: local-test-ad-hoc`、`manualTestStatus: READY_FOR_MANUAL_OPEN`、`publicReleaseStatus: BLOCKED`、`gitUsed: false`、live snapshot provenance，并绑定 source/dependency/tool/App/Host/package/signature/CDHash/DMG/mount/target probe。

## 9. 自动化禁区与人工打开

自动化不调用或打开 App/Host，不写真实 Application Support/UserDefaults/Keychain/socket，不安装 Host/manifest/receipt，不启动浏览器，不读取 Cookie/History/Login Data，不调用 Provider 或外网。target probe 只复用 r4a 的五个固定 token、anchored fd、bounded canonical JSON 检查，输出不含 raw path/content。

README 只允许 Finder 双击 DMG、优先右键 App → 打开、或系统设置 Open Anyway；禁止建议清 quarantine/xattr、关闭 Gatekeeper 或 sudo。首次由 Syc 手工启动后，正常 App 行为会写真实 Application Support/UserDefaults/socket；只有主动保存 Key 才写 Keychain。

## 10. 独立 gate、STOP 与状态

```bash
./scripts/native-host/package-local-test-dmg.sh \
  --audit-root /private/tmp/linkdigest-r4b-local-test.UNIQUE

./scripts/native-host/check-local-test-release.sh \
  --existing-audit /private/tmp/linkdigest-r4b-local-test.UNIQUE \
  --review-root /private/tmp/linkdigest-r4b-review.UNIQUE
```

gate 把 candidate audit 全程当只读输入；负例、解包、Swift scratch、mount 与 canonical `gate-result.json` 全写 review root。覆盖 source policy/unknown/symlink/hardlink/special/secret、并发变化、archive determinism+roundtrip、offline input、focused ContractTests 10/10、inside-out facts/tamper、Host checksum、真实 DMG mount、target probe unchanged、final tree/hash/cross-binding 与 no GUI/profile/network/install。不得运行 full Swift/TCP suite。

STOP：live inventory 漂移、unknown top-level、secret、symlink/hardlink/special、归档不确定、remote dependency、签名/Team/Authority/timestamp 漂移、Host/App/package/unit 交叉绑定失败、DMG 无法 exact detach、target leaf 改变或任何真实写入需求。所有 audit 保留。最终证据为 r4b gate 71 assertions、ContractTests 10/10、独立 review PASS 0/0/0；产品/公开发布继续 BLOCKED。

## 13. 最终 handoff 与人工门禁

最终目录：`release/LinkDigest-0.1.0-local-test/`。candidate digest 为 `513b523c60f92824ad6a31b2c7f704a9375e0c7878c8fb5e40b81583271e19df`，DMG SHA-256 为 `51f2a6544c40f4d29bc66a062773f23e997f85cc74a49bd693f8c2759b1fe2a7`。主控从最终路径再次完成 `hdiutil verify`、readonly exact mount、mounted App/Host/unit/signature reverify、`/dev/disk7s1` exact detach 与 no-residual check。

自动化没有启动 App，所以 `manualOpen` 仍未产生。源码归档是 candidate 构建时的冻结 live-worktree snapshot；独立 review 与 finalize 后只更新了工作区的状态文档/Brain，没有改变 DMG、产品源码、配置或打包工具。Syc 手工打开后的 PASS/FAIL 作为下一条人工证据追加，不回写当前不可变 handoff。
