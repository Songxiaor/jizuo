# LinkDigest 验证入口

## 一句话

`./scripts/doctor` 是项目体检：它只读取和报告，不自动修复、安装依赖、修改 Git 或发送任何外部数据。

## 场景与角色

```text
架构、规则或 Project Brain 发生变化
              |
              v
        ./scripts/doctor
          |    |    |
          |    |    +-- 检查敏感信息边界
          |    +------- 检查文档和学习规则是否漂移
          +------------ 检查 Brain 路径、根页面和坏链
              |
              v
        PASS / WARN / FAIL
```

- `PASS`：当前检查项满足要求。
- `WARN`：存在需要 Syc 知道、但不应由脚本擅自修复的状态，例如尚无首次 Git commit。
- `FAIL`：项目入口、Brain、关键文档或安全边界已经损坏，不能宣称本阶段完成。

## 一键检查

在项目根目录运行：

```bash
./scripts/doctor
```

预期在首次 commit 之前得到 `doctor: OK WITH WARNINGS`：警告应只说明没有 Git 基线或工作树未提交，不能包含 Brain、文档或敏感边界失败。

## 分项检查

### Project Brain

```bash
./scripts/brain brain-dir
./scripts/brain list-pages
./scripts/brain read-root architecture
./scripts/brain lint-links
./scripts/check-brain-root
```

用于确认：所有 Agent 读取的是项目根下同一个 `brain/`；六个根页面不再是空模板；页面引用没有坏链。

所有 Brain 写入必须通过 `./scripts/brain`，禁止手改 `brain/`。

### 当前架构与远期容量

```bash
rg -n 'SwiftUI|AppKit|Native Messaging|版本化 JSON' docs/ARCHITECTURE.md
rg -n '1,000 RPS|100 jobs/s|100,000,000' docs/CAPACITY_MODEL.md
```

用于确认：当前 SwiftUI APP、TypeScript 扩展和跨语言协议边界仍然存在；10 万/100 万容量数字只作为远期参考保留，没有反向扩大 P0。

### 学习协作

```bash
rg -n '过程中|可选跟做|另开小窗口|不阻塞' AGENTS.md docs/LEARNING_GUIDE.md docs/TASK_TEMPLATE.md
```

用于确认：解释发生在开发过程中，没有退回“课后答题通过才继续”的旧规则。

### 敏感信息

`doctor` 只用高置信模式检查候选路径，并且只打印文件名，不打印疑似秘密值。它是最低安全门槛，不能替代人工审查。

V0.2 还提供一条独立、只读的秘密边界检查：

```bash
pnpm --config.verifyDepsBeforeRun=false secret:check
```

它检查高置信 secret pattern、生产 Swift 日志中 secret/header/body 的可疑形状、`@Published`/`@Observable` 与 RunState 的可疑秘密字段、fixture/snapshot 中的秘密字段或明显 Key、未知 code 的可见 UI sink，以及 UserDefaults adapter 对秘密字段的引用。普通 `sentinel-<UUID>` 与 `not-a-real-key` 测试标记不会被当成真实 Key pattern；若命中，脚本只打印规则名和路径，不打印疑似值。

该检查通过时，doctor 把它计为 `PASS`；命中任一规则时计为 `FAIL` 并阻止宣称 V0.2 工程验收通过。显式关闭 pnpm 的 pre-run 依赖校验，是为了让已有脚本直接运行，避免本地依赖索引缺失时触发联网修补尝试；secret 脚本本身不会产生 `WARN`、读取 Keychain、自动修复文件、安装依赖、修改 Git 或访问网络。

真实 API Key、Cookie、Token、私钥、账号数据和客户内容不得作为测试材料。

### Native Host 安装边界

安装脚本默认只打印计划，且必须显式选择浏览器：

```bash
./scripts/native-host/install-dev.sh --extension-id EXTENSION_ID --host-path /absolute/LinkDigestNativeHost --browser chrome
./scripts/native-host/install-dev.sh --extension-id EXTENSION_ID --host-path /absolute/LinkDigestNativeHost --browser brave
./scripts/native-host/install-dev.sh --extension-id EXTENSION_ID --host-path /absolute/LinkDigestNativeHost --browser edge
```

只有明确加 `--apply` 才会写入一个固定 basename。Brave 150 当前映射到 Chrome 用户级目录；Edge 不会因为 Chrome/Brave 的选择而隐式写入，必须显式授权。脚本会校验 executable、资源 bundle 和合同 Schema，拒绝目标 manifest、备份候选和 HOME 到目标目录路径组件中的 symlink；覆盖前备份并用 `chmod 600` 同目录临时文件执行 rename 设计。失败时临时文件保留并打印路径，不自动删除；自动检查不宣称系统级原子性证明。

卸载先运行只读计划：

```bash
./scripts/native-host/uninstall-plan.sh --browser brave
```

它只报告目标和人工命令，不执行 `rm`。项目级回归使用隔离临时 `HOME`，不会读取或修改真实浏览器配置，并覆盖负向路径和失败临时文件残留：

```bash
pnpm native-host:check
```

Loop 4 r2 的事务入口同样只允许 fixed canonical `/private/tmp` clean-room：

```bash
pnpm --config.verifyDepsBeforeRun=false native-host:transaction:check
./scripts/native-host/clean-room-transaction.sh --help
```

每个 transaction session 必须由 fixture 预置 r1 sentinel 与 mode `0600`、精确固定内容的 `.transaction.lock`；wrapper 不创建、替换或删除锁。`plan`、`apply`、`recover` 的完整参数、退出码与 commit/recovery 方向见 `docs/specs/P0_RC_LOOP_4_R2_TRANSACTIONS.md`。完整 110 项 gate 会创建并保留 `/private/tmp` 审计根并制造 SIGKILL/Unix socket 场景，不属于日常 doctor；不得把 session/home 换成真实 `$HOME`。r2 同一 reviewer 唯一 re-review 已 PASS，P0/P1/P2 = 0/0/0，但该结论只覆盖 fixed canonical `/private/tmp` clean-room，不代表真实 HOME/browser 安装、profile ownership、Developer ID、签名、公证、stapling 或发布。

### r3 真实安装前只读预检

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/native-host/release_preflight.py report
pnpm --config.verifyDepsBeforeRun=false native-host:release:preflight:check
```

第一条命令目前预期 exit `10` 和 `status: "BLOCKED"`：release extension IDs、Team ID、verified package、Developer ID + hardened runtime、notarized/stapled DMG 均尚未冻结或提供；而且 r3 不能离线验证同一 App-DMG release unit，也不读取真实 install namespace 验证 receipt/hash/target leaves。spctl 只有唯一 exact `source=Notarized Developer ID` + `origin=Developer ID Application: ...` 才算 notarization，并固定带 `--ignore-cache --no-cache`，既不读取旧 assessment cache，也不写入新结果；其它 Apple 查询不继承 caller 环境，固定 DEVNULL、5 秒 timeout、`HOME=/var/empty` 和安全 PATH。它只接受 lexical-canonical `.app`、current-user owned single-link `.dmg`/receipt，固定 `release-unit-binding-unverified` 与 `target-ownership-unverified` blockers，且没有 `apply`、`recover` 或删除命令。r3 保留 0/2/2、0/1/0 历史，当前独立最终审查为 **PASS，P0/P1/P2 = 0/0/0**；这只表示只读工程门禁完成，生产状态仍是 BLOCKED。完整合同见 `docs/specs/P0_RC_LOOP_4_R3_PREFLIGHT.md`。

### r4a unsigned App + DMG release unit

```bash
./scripts/native-host/package-app-dmg.sh --audit-root /private/tmp/linkdigest-r4a-release.UNIQUE
./scripts/native-host/check-release-unit.sh \
  --existing-audit /private/tmp/linkdigest-r4a-release.UNIQUE \
  --review-root /private/tmp/linkdigest-r4a-review.UNIQUE
```

第一条在新的 `/private/tmp` audit root 真正离线构建 Swift Release App+Host、创建 DMG、只读挂载后复验。第二条必须把已有 candidate audit 当只读输入，所有 tamper fixture、Swift scratch 与 canonical `gate-result.json` 都写到 caller 明确给出的新 review root；candidate 前后 content/metadata inventory 必须一致。gate 只跑纯 `ContractTests`，不会运行 full Swift suite 或启动 TCP listener。

build 要求 caller 提供 canonical、不存在的 direct-child audit root；review 同样要求不存在的 `/private/tmp/linkdigest-r4a-review.*`。当前 App/DMG unsigned，report 必须为 `engineeringStatus: candidate`、`productStatus: BLOCKED`、`separateAuthorizationRequired: true`。真实 probe 通过 anchored directory fd 只读五个固定对象并隐藏 path/origins/raw；当前 Chrome/Edge manifest 为 noncanonical `malformed`，CLI 预期 exit `10`，不得自动修复。r4a 首次独立 review BLOCK 0/4/2；集中修复后的唯一 re-review PASS 0/0/0，只关闭 unsigned release-unit 工程门禁，产品仍 BLOCKED。

### r4b local-test ad-hoc DMG

```bash
./scripts/native-host/package-local-test-dmg.sh \
  --audit-root /private/tmp/linkdigest-r4b-local-test.UNIQUE
./scripts/native-host/check-local-test-release.sh \
  --existing-audit /private/tmp/linkdigest-r4b-local-test.UNIQUE \
  --review-root /private/tmp/linkdigest-r4b-review.UNIQUE
```

第一条从 live dirty worktree 生成 nofollow source snapshot 和 GRDB 7.11.1 独立 snapshot，两次确定性 tar.gz、roundtrip、isolated offline Swift Release build、Host-first/App-last ad-hoc signing、r1 package reverify、UDZO/HFS+ DMG readonly exact mount/detach，以及包含源码/DMG/清单的 handoff。第二条只读 candidate audit，所有负例、解包、ContractTests 10/10、真实 DMG mount 与 canonical `gate-result.json` 均写入新的 review root；不会运行 full Swift/TCP suite。

两条命令都保留成功/失败根，不覆盖或删除。r4b 自动化不启动 App/Host，不写真实 HOME/profile/Keychain/socket，不安装 Host/manifest/receipt，不调用真实 Provider/网络。candidate-07 的 local gate 为 71 assertions + ContractTests 10/10，独立 reviewer 最终 PASS 0/0/0；主控已按 no-clobber staging → digest/SHA256SUMS 复验 → 同目录改名合同 finalize 到 `release/LinkDigest-0.1.0-local-test/`。最终 DMG SHA-256 为 `51f2a6544c40f4d29bc66a062773f23e997f85cc74a49bd693f8c2759b1fe2a7`，状态为 `READY_FOR_MANUAL_OPEN`，尚未由 Syc 手工启动 App。

## 常见失败与恢复

| 现象 | 原因 | 恢复 |
|---|---|---|
| `brain.mjs` 找不到 | 共享 `brain-page` Skill 不在候选路径 | 检查 Skill 安装状态；未经确认不要自动安装 |
| Brain root 仍有 placeholder | Project Brain 只搭了空壳，尚未播种 | 通过 Brain CLI 更新根页面，不手改 `brain/` |
| stale blocking-learning language | 文档仍要求 Syc 课后验收 | 以 `AGENTS.md` 和 Brain 决策为准修正文案 |
| possible secret patterns | 未忽略文件疑似包含秘密 | 只查看报告路径，先移出或脱敏；不要把值粘贴进聊天 |
| no first commit | 当前仓库没有 Git 基线 | 保留 WARN；只有 Syc 明确确认后才暂存和提交 |

## 可选跟做

想观察项目体检时，只需运行一次 `./scripts/doctor`，查看每一段分别检查了什么。该动作服务于理解，不是后续开发的门槛。
