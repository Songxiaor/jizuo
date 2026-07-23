# P0-RC Loop 4 r3：真实安装前只读预检

## 任务卡

- 任务名称：Loop 4 r3 release preflight / planning harness。
- 用户场景：r1/r2 已在 fixed canonical `/private/tmp` clean-room 证明 package 和事务合同；在任何真实用户目录、浏览器 profile、签名或发布动作前，Syc 需要一份可复核的材料清单，而不是一个会悄悄安装的脚本。
- 本次只解决：用 canonical policy、r1 package verifier 与已有离线 Apple 证据，输出稳定、可机读的预检报告；r3 生产 CLI 必定 `BLOCKED`，不能把互不绑定的 App、DMG 或外部 receipt 组合成 `READY`。
- 明确不做：`apply`、`recover`、`delete`、真实 HOME/profile 写入、`sudo`、安装、签名、公证、stapling、网络、凭据、发布，以及把 `install-dev.sh` 升格为生产安装器。
- 当前状态：首次正式 review BLOCK（P0/P1/P2 = 0/2/2），唯一 re-review 又因 `spctl` assessment cache 副作用 BLOCK（0/1/0）；Syc 明确要求继续后，cache-safe candidate 通过新的独立最终审查，**PASS，P0/P1/P2 = 0/0/0**。该 PASS 只代表 r3 只读门禁工程完成；生产 report 仍按设计为 `BLOCKED`，产品并未 release ready。

## 场景 → 角色与交接 → 工作流 → 工具协同

```text
Syc 选择 report / plan（只读）
  ↓ 参数：现有 package、.app、DMG、可选 receipt 路径
release_preflight.py
  ↓ 读取：native-host.json + native-host-release-policy.json
  ↓ 复用：stable_host.verify_package
  ↓ 查询：codesign / spctl / stapler 的既有离线证据
canonical JSON report
  ↓ status + blockers + warnings + targets + reportDigest
Syc 单独决定是否授权下一次真实动作
```

- **入口角色**：`release_preflight.py report|plan` 只读取参数和仓库内两份 canonical JSON；没有 `apply` 或状态恢复子命令。
- **package 交接**：r1 `stable_host.verify_package` 只回答 package 是否符合既有交付合同；缺失或漂移都会成为 blocker，不能由 r3 修复。
- **发布证据交接**：只有 current-user owned、single-link canonical `.dmg` 与 canonical `.app` 才会被本地 `codesign`、`spctl`、`xcrun stapler validate` 查询。Developer ID、Team ID 与 hardened runtime 分别按 `Authority=Developer ID Application:`、exact `TeamIdentifier=` 与 `flags=...(runtime)` 行解析；notarization 还必须恰好出现一行 `source=Notarized Developer ID` 和一行 `origin=Developer ID Application: ...`。文件名、identifier、重复或伪造行中的相同文字都不算证据。
- **Apple 查询边界**：查询固定为 absolute executable 和固定 argv；`spctl` 同时使用 `--ignore-cache` 与 `--no-cache`，既不读取旧 assessment cache，也不写回新结果。所有查询使用 `stdin=DEVNULL`、5 秒 timeout、`HOME=/var/empty`、`TMPDIR=/private/tmp`、受限 PATH 与 `LANG/LC_ALL=C`，不继承调用者 `HOME`、`TMPDIR`、`DEVELOPER_DIR`、`TOOLCHAINS` 或秘密环境。超时或工具缺失只形成 missing evidence，不执行网络、签名或 stapling。
- **人类授权交接**：r3 无法挂载/解包 DMG 来证明 App 同属一个 release unit，也不读取真实 install namespace 来证明 manifest target leaves/receipt 归属。因此生产 report 固定增加 binding/ownership blockers；r4 packaging spike 获得单独授权前不存在生产 `READY`。

## 冻结策略

`config/native-host-release-policy.json` 是 r3 policy 唯一来源，严格拒绝未知字段。它冻结：

| 主题 | 当前候选合同 |
|---|---|
| 用户范围 | `current-user`，禁止 `sudo` |
| 分发候选 | `Developer ID Application` + notarized/stapled DMG |
| Chrome / Brave | 同一个 Chrome user manifest target；生成计划时合并去重 |
| Edge | Microsoft Edge default user target；拒绝任何自定义 profile |
| Team ID | `not-frozen`，因此当前必定 BLOCKED |
| release extension IDs | `config/native-host.json` 仍 `not-frozen`，因此当前必定 BLOCKED |

它不包含 Provider、API Key、Keychain、Cookie 或 profile 内容。Chrome/Brave 的 shared target 是当前 Brave macOS override 的实现事实；这不是把浏览器数据读入预检的许可。参考：[Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[Brave macOS target override](https://github.com/brave/brave-core/blob/master/app/brave_main_delegate.cc)、[Microsoft Edge Native Messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/developer-guide/native-messaging)。

## 输出和失败语义

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/native-host/release_preflight.py report
```

输出为 sorted-key、2-space、末尾换行的 canonical JSON。`reportDigest` 是去除自身字段后的 canonical JSON SHA-256；它只证明报告内容未变，不证明签名或授权。纯 Python policy evaluator 可以在测试中构造 `READY` 组合，但生产 CLI 不接收该合成 evidence，也不据此返回 `READY`。

| 退出码 | 含义 |
|---:|---|
| 0 | 保留给未来具备受权 release-unit/target-leaf 验证的阶段；r3 生产 CLI 不使用 |
| 10 | `BLOCKED`；缺少或不可信材料，当前正常预期 |
| 2 | 不安全输入、symlink、非 canonical 路径或 policy/schema 不合法 |
| 70 | 预检内部错误；不应据此继续动作 |

当前普通 `report` 必定至少包含：`extension-ids-not-frozen`、`team-id-not-frozen`、`package-missing`、`distribution-artifact-missing`、签名/hardened runtime/notarization/stapling 缺证据，以及固定的 `release-unit-binding-unverified`、`target-ownership-unverified`。外部 receipt 即使语法正确也不是可信目标所有权；缺失、未知、畸形或与 frozen manifest target 冲突都会 BLOCKED。

## 预检门禁与回滚不变量

1. 输入先在 `Path(value)` 前做 lexical gate：拒绝空、root、relative、`//`、`/./`、`/../`、末尾 slash/dot、NUL/CR/LF；之后才逐级 lstat/no-symlink/owner/link/type。`.app` 必须是 directory，`.dmg`、receipt 必须由 current user 拥有且为 single-link regular file。
2. package 只复用 r1 verifier；r3 不修改 `stable_host.py`、`transaction_host.py` 或它们的 `/private/tmp` 边界。
3. 任何 Edge 非 `default` profile 都在读文件前拒绝；Chrome/Brave target 在 report 中只出现一次。
4. 检查器只把合成 evidence 交给 Python pure policy evaluator；生产 CLI 没有接收、导入或信任 test evidence 的参数，也不会把 App/DMG/receipt 作为可验证的同一发布单元。
5. 预检和失败都不创建、覆盖、删除或恢复真实文件。回滚不变量是“没有 mutation，所以无需恢复”；下一步若要真正写入，必须另开授权任务并有自己的 rollback 合同。

## 新名词（L3）

| 名词 | 人话解释 | 生活类比 | 项目位置 | 没有它会怎样 |
|---|---|---|---|---|
| 安装画像 | 一份写清“准备给哪个用户范围、哪些浏览器位置安装”的固定清单 | 装修前确认房号、门牌和施工范围 | `native-host-release-policy.json` | 脚本可能把 Chrome、Brave、Edge 或 profile 目标混在一起 |
| 预检门禁 | 先列出缺的材料，再决定能不能进入下一步 | 登机前检查证件；不帮你登机 | `release_preflight.py` | 缺 Team ID、签名或公证时只能靠猜测推进 |
| 故障注入 | 主动制造坏路径、坏 receipt、假签名文字，验证拒绝是否可靠 | 消防演习里故意拉响警报 | `release_preflight_check.py` | 绿灯只证明普通情况，危险输入可能漏网 |
| 回滚不变量 | 无论结果如何都必须保持的安全事实 | 演练不能改变真实房屋 | r3 无 mutation 的 CLI 合同 | 失败预检也可能留下真实安装残留 |

## 自动验收、STOP 与恢复

```bash
pnpm --config.verifyDepsBeforeRun=false native-host:release:preflight:check
```

该 gate 离线运行、保留一个 named `/private/tmp/linkdigest-release-preflight-audit.*` 审计根，并覆盖 strict policy keys/错误类型（含 `teamIDStatus=[]`）、release IDs、package drift、strict Developer ID/ad hoc/Team/runtime 解析（含 `Identifier=com.runtime.fake`）、锚定 spctl notarization 负例、fake Apple runner 的 exact argv/env/stdin/timeout/timeout 分支、`spctl --ignore-cache --no-cache`、release-unit/target-ownership blockers、目标去重、Edge profile、receipt 状态、canonical JSON/exit code/secret hygiene、symlink/hardlink/lexical path controls、poisoned HOME/TMPDIR 和零副作用。

最终工程证据：主控与独立 reviewer 均复跑 **101 assertions PASS**；新独立最终 review 为 PASS，P0/P1/P2 = 0/0/0。最终 reviewer audit root 为 `/private/tmp/linkdigest-release-preflight-audit.rtrupoxs`。这不是对真实 artifact、签名、公证或安装的验收。

**STOP**：若预检不是 `READY`，或政策/路径/evidence 解析为 unsafe/internal，停止，不尝试修复真实机器状态。当前正确结果就是 `BLOCKED`。

**恢复**：r3 不写入，因此不会自动恢复或删除。r4 必须在 Syc 单独授权后，从固定真实 install namespace 与 target leaves 验证 receipt/hash，并建立 App-DMG 同一发布单元绑定；本轮不实现、不读取真实 HOME。
