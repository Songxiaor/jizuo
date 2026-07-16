# P0-RC Loop 4：Stable Native Host package 与 clean-room 初装

> 状态：**Loop 4 r1 最终独立 re-review PASS，P0/P1/P2 均为 0**。本阶段只证明可搬迁 package 与固定 `/private/tmp` clean-room 的首次安装；不表示真实用户安装、升级、卸载、事务化升级回滚、`.app`/DMG、签名、公证或发布完成。

## 1. 任务卡

- 用户场景：开发期 `.build` 与 `/tmp` Host 已能通信，但不能作为可搬迁、可校验、可安装的发布交付物。
- 本次只解决：把 Release Host、完整资源 bundle、metadata 和 checksums 组成一个稳定 package，并只在带 sentinel 的系统临时 clean-room HOME 证明首次安装。
- 明确不做：r2 升级/真实卸载/完整事务 rollback、真实 `$HOME` apply、真实浏览器 profile、`.app`/DMG、Developer ID、notarization、发布与 release extension ID 冻结。
- 当前状态：BLOCK 指出的环境可控 TMP 根与 raw Host/socket override 已修复；deterministic check 56 项和最终独立 re-review 均通过。

## 2. 场景 → 角色与交接 → 工作流 → 工具协同

```text
config/native-host.json
  角色：Host 名称、版本、协议、架构和交付文件名的唯一配置
  交接：canonical metadata
        ↓
scripts/build-release.sh / package-stable.sh
  角色：同步合同、Swift Release build、组装稳定 package
  交接：Host + resource bundle + package.json + SHA256SUMS
        ↓
stable_host.py verify-package
  角色：拒绝漂移、缺件、错误权限、非普通文件和非 arm64 Host
  交接：verified package digest
        ↓
同一个 manifest renderer
  角色：从 config 读取 hostName，生成精确 allowed_origins
  交接：Chrome/Brave/Edge 内容相同的 manifest payload
        ↓
clean-room-install
  角色：只在专属临时 HOME 证明 initial install/noop/failure cleanup
  交接：version directory + manifests + receipt-v1.json
        ↓
check-stable-package.sh + packaged Host smoke
  用户可观察结果：搬迁后仍运行；缺 bundle、篡改或路径越界都会失败
```

工具协同：SwiftPM 只负责编译 `arm64` Release Host；Python 标准库负责确定性 metadata、checksum、manifest、安全路径和事务归属；Shell 只做稳定入口与参数转交；Node smoke 沿用 Chromium framing 测试。没有新增依赖。

## 3. 本次五个核心名词

| 名词 | 人话定义 | 生活类比 | 项目位置 | 没有它会怎样 | 深度 |
|---|---|---|---|---|---|
| Host package | Host 运行需要的完整、可搬迁目录 | 一只列出全部物品的搬家箱 | `LinkDigestNativeHost-0.1.0-macos-arm64/` | 只复制 executable 时资源会丢失 | L3 |
| Resource bundle | SwiftPM 随 Core 交付的 Schema/fixtures 资源目录 | 搬家箱里的说明书包 | `LinkDigest_LinkDigestCore.bundle` | Host 无法加载 canonical Schema，或误回退开发机 `.build` | L3 |
| Package verifier | 安装前逐项验货的只读门禁 | 收货时核对封条、数量和型号 | `stable_host.py verify-package` | 篡改、缺件或错误架构可能进入安装 | L3 |
| Clean-room install | 只在隔离临时 HOME 做的首次安装演练 | 在模型屋先试装，不装修真实房子 | `clean-room-install.sh` | 测试可能误写真实浏览器和 Application Support | L3 |
| Receipt | 记录本次安装拥有哪些目标及其 hash 的非敏感收据 | 未来搬迁/退货需要的物品签收单 | `receipt-v1.json` | r2 无法区分自有文件与未知既有内容 | L2 |

## 4. Canonical config 与 package 格式

`config/native-host.json` 冻结 r1 字段：

- `formatVersion = 1`
- `productVersion = 0.1.0`
- `hostName = com.syc.linkdigest.v01`
- `protocolMajor = 1`
- `minimumMacOS = 15.0`
- `architectures = [arm64]`
- `entrypoint = LinkDigestNativeHost`
- `resourceBundle = LinkDigest_LinkDigestCore.bundle`
- `releaseExtensionIDs = []`，并以 `releaseExtensionIDsStatus = not-frozen` 明确表示尚未冻结。

测试扩展 ID 只通过重复 `--extension-id` 参数注入，绝不写入正式 config。`check-config-sync.sh` 确保 browser background 的 `HOST_NAME` 与 config 一致。

builder 只接受显式、绝对、尚不存在的 `--output-root`，不会写仓库 `dist`，也不会覆盖输出。其唯一 package 子目录为：

```text
LinkDigestNativeHost-0.1.0-macos-arm64/
├── LinkDigestNativeHost                       0755
├── LinkDigest_LinkDigestCore.bundle/          0755 dirs / 0644 files
├── package.json                               0644
└── SHA256SUMS                                 0644
```

`SHA256SUMS` 覆盖 metadata、Host 与 bundle 内全部普通文件，自身除外；UTF-8 路径按字节序稳定排序，拒绝 absolute、`..`、换行和反斜杠路径。

## 5. Verifier 的拒绝边界

verifier fail closed：

- 顶层项不精确，或树内出现 symlink、FIFO、socket、其它非普通文件。
- package 目录不是 `0755`；Host 不是 `0755`；其它普通文件不是 `0644`。
- bundle 或 `capture-envelope-v1.schema.json` 缺失；bundle Schema 与根合同 hash 不同。
- `package.json` 的 version/arch/hostName/protocol/minimum macOS/entrypoint/bundle 与 config 不同。
- `SHA256SUMS` 格式、覆盖范围、排序或内容 hash 漂移。
- Host 不是 Mach-O，或 `/usr/bin/lipo -archs` 不是精确 `arm64`。

## 6. Manifest renderer

单一 renderer 生成以下 payload；Chrome、Brave、Edge 只改变目标目录，不改变内容：

```json
{
  "allowed_origins": ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"],
  "description": "LinkDigest Native Messaging Host",
  "name": "com.syc.linkdigest.v01",
  "path": "/absolute/installed/LinkDigestNativeHost",
  "type": "stdio"
}
```

- 测试 ID 必须精确匹配 `[a-p]{32}`，重复输入排序、去重。
- origin 必须是精确 `chrome-extension://ID/`，不允许 wildcard。
- release 模式只读取 config 中已冻结 release IDs；当前为空，因此明确失败。

## 7. Clean-room initial installer

installer 只有 `clean-room-install`，没有 real-HOME 或 uninstall apply：

1. `--session-root` 与 `--home-root` 必须显式、已存在、canonical、basename 以 `linkdigest-host-clean-room.` 开头；home 必须是 session 的直接子目录。
2. session 必须位于 fixed canonical `/private/tmp`，只信该常量，不读取 `TMPDIR` 或 `tempfile.gettempdir()`；且已有内容精确的 `.linkdigest-clean-room-root` sentinel。
3. 从 `/` 到 session/home，以及 version/manifest/receipt 的每个现存祖先都用 `lstat` 拒绝 symlink；真实 `$HOME`、root、scope 外 Edge profile、非 direct-child manifest 都拒绝。
4. 先 verify package，再安装到 `Library/Application Support/LinkDigest/NativeMessagingHost/versions/0.1.0-macos-arm64/`。
5. 目录为 `0700`，Host 为 `0755`，其它安装文件、manifest 与 receipt 为 `0600`。
6. Chrome/Brave 共享 Google Chrome 用户级 manifest；Edge 使用 clean HOME 默认目录，或显式隔离 profile 的 direct child。
7. 同版本、同 package digest、同 manifest 与同 receipt 的第二次 apply 返回 `noop`，不改 mtime。
8. 任一目标未知或不同即拒绝；r1 不覆盖、不备份、不升级。
9. failure injection 只删除本事务创建的 staging/version/manifest/receipt 与可安全 `rmdir` 的新目录；既有内容不删除。
10. dry-run 做完整只读预检并输出计划，零写入。

`receipt-v1.json` 只记录 format、host、版本、package digest、version directory、owned manifest path/hash；不含 API Key、Cookie、Token、extension ID 或正文。

## 8. 自包含证据与 `.build` 回退

SwiftPM 的生成代码会把开发机 `.build/.../LinkDigest_LinkDigestCore.bundle` 作为 `Bundle.module` 的第二回退路径编进 binary。因此普通“复制 Host 后运行”是假阳性风险。

`check-stable-package.sh` 使用以下证据链：

1. 在 `/private/tmp` 创建一次性源码副本，排除 `.git`、`.build`、`node_modules`、浏览器 `output` 与用户 evidence。
2. 把已锁定 GRDB 7.11.1 工作树复制为 audit-local path dependency，排除 Git metadata/submodule；不联网、不安装。
3. 在副本中 Release build/package，再把 package 移到含空格与 Unicode 的路径。
4. 删除副本 `apps/desktop/.build`。
5. 用 package Host 跑 offline、oversize、timeout smoke。
6. 另复制 executable 到缺 bundle 目录，要求无法返回有效 frame。

这证明成功来自 package 内同级 bundle，而不是原仓库或一次性源码副本的 `.build`。

## 9. 当前自动证据

`./scripts/native-host/check-stable-package.sh` 最新通过 **56 assertions**，覆盖：

- build/verify、Unicode/空格移动、packaged Host 三类 smoke、缺 bundle runtime 负例。
- manifest 排序去重、非法 ID、release IDs 未冻结 fail closed。
- dry-run 零写、Chrome/Brave 去重、Edge 默认/隔离 profile、apply/noop mtime。
- 未知目标拒绝、receipt 边界、failure injection cleanup、真实 HOME 前后 metadata digest 相同且不打印文件名。
- checksum、bundle、schema、permission、symlink、FIFO、socket、额外顶层项和 metadata 篡改拒绝。
- clean HOME 内 `Library` symlink 指向 scope 外时拒绝，外部 marker 不变。
- 已安装版本目录多出未知空目录时也视为不同目标并拒绝，不能伪装成 noop。
- Darwin 用户 temp 中具备正确 prefix/sentinel/direct child 的假 clean-room，在 `TMPDIR=$PWD` 与 `TMPDIR=$HOME` 下均于写入前拒绝且 metadata 不变。
- packaged Host smoke 只接受 verified package root；raw executable/skip-build 与 scope 外 socket override 均 fail closed。
- Host/vertical smoke 在任何 build/子进程前固定并导出 `TMPDIR=/private/tmp`；两次 poisoned vertical smoke 不改变 poison root、真实 LinkDigest HOME 或 Git worktree status。

本次保留两个审计 TMP 目录供独立复审，未清理：

- `/private/tmp/linkdigest-stable-package-audit.8k01spvl`
- `/private/tmp/linkdigest-host-clean-room.audit.sa71xl6t`

## 10. 失败、恢复与回滚

- 首次源码复制碰到浏览器 profile dangling symlink：把 root `output/` 明确归入用户/运行证据排除，不跟随或复制。
- 本地 GRDB Git mirror 尝试补测试 submodule：改为 audit-local 普通 path dependency，排除 `.git/.gitmodules/SQLiteCustom`，不联网安装。
- Codex sandbox 禁止测试 Unix socket：在保持 installer 路径门禁和真实 HOME digest 的前提下，仅对全检查使用允许 Unix socket 的执行权限。
- Darwin `sun_path` 过长：审计根固定到 canonical `/private/tmp`；socket tamper inode 在短路径创建后移动进深层 package。
- 独立 reviewer BLOCK 证明 `tempfile.gettempdir()` 会信任攻击者可控 `TMPDIR`，且 raw Host/socket override 与 vertical 子进程继承可把写入带到 worktree/HOME；修复后所有 smoke 子进程都先固定 `/private/tmp`，package override 必须先 verify。
- 修复首跑只固定 vertical 自己的 `TMP_BASE`，SwiftPM 仍继承 poisoned `TMPDIR` 并在 worktree 产生临时锁；该批本事务临时项已精确清理，随后改为 build 前 `export TMPDIR=/private/tmp`，worktree status gate 通过。

若要回滚 r1，只撤销 config、新 release/verify/render/clean-room scripts、Host smoke override 和本任务文档；不触碰 Loop 3、migration 001、真实 Application Support、浏览器 profile 或 Keychain。

## 11. 可选跟做（5–15 分钟）

运行：

```bash
pnpm --config.verifyDepsBeforeRun=false native-host:config:check
```

它只核对 canonical config 与 browser background Host name，不构建、不安装。完整 `native-host:stable:check` 会在 `/private/tmp` 创建并保留两个审计目录，适合需要共同观察 package 树、receipt 和 tamper cases 时再运行；它仍不触碰真实 HOME。

## 12. 残余限制与 r2/r3 交接

- release extension ID 未冻结，release manifest 继续 fail closed。
- 只支持 `arm64` 与 macOS 15.0；未做 universal binary。
- r1 只有初装、同内容 noop 与进程正常退出路径的 best-effort 本事务 cleanup；不得称完整 rollback。
- SIGKILL/crash、同用户并发替换产生的 TOCTOU、跨进程 lock、dirfd/openat 路径绑定和 transaction recovery 均未实现，归 r2。
- 未在真实 Chrome/Brave/Edge profile apply，也未做真实用户安装。
- `.app`/DMG、签名、公证、stapling、商店与发布仍需 Syc 单独授权。
- r1 已标记最终 PASS；r2/r3、真实安装、签名、公证与发布仍保持未授权、未完成。
