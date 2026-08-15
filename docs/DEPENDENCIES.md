# LinkDigest 依赖与许可证基线

## 场景

依赖是项目复用的标准零件。商业闭源产品不仅要确认“能运行”，还要确认版本兼容、许可证允许商业使用、构建时与运行时边界清楚，并能通过 lockfile 在另一台机器复现。

## 当前直接依赖

### TypeScript 工具链

| 包 | 版本 | 角色 | 分发边界 | 许可证 |
|---|---:|---|---|---|
| TypeScript | 6.0.3 | 类型检查 | 仅开发 | Apache-2.0 |
| ESLint / `@eslint/js` | 10.7.0 / 10.0.1 | 代码规则检查 | 仅开发 | MIT |
| typescript-eslint | 8.63.0 | 让 ESLint 理解 TypeScript | 仅开发 | MIT |
| Vitest | 4.1.10 | 协议自动测试 | 仅开发 | MIT |
| `@types/node` | 22.20.1 | Node 22 类型 | 仅开发 | MIT |
| Zod | 4.4.3 | 运行时 Schema 校验 | `@linkdigest/shared` 运行时 | MIT |
| Ajv / `ajv-formats` | 8.18.0 / 3.0.1 | 执行 JSON Schema Draft 2020-12 与格式校验 | Ajv 用于 shared 运行时和扩展构建期代码生成；静态格式辅助进入扩展产物；8.18.0 修复 GHSA-2g4f-4pwh-qvx6 | MIT |
| WXT | 0.20.27 | 构建 Chromium MV3 扩展 | 仅开发；输出不包含 WXT Runtime | MIT |

WXT、TypeScript、ESLint 与 Vitest 只服务于构建和测试。扩展使用 Ajv 的 standalone generator 在构建前生成静态校验函数，background 不携带运行时 Schema 编译器，也不调用 Manifest V3 CSP 禁止的动态代码生成；`ajv-formats` 的静态格式辅助会进入产物。Zod 仍服务于旧 shared 模型，不再是 Swift/TypeScript 合同真相源。

### macOS 工具链

| 工具 | 当前状态 | 角色 | 许可证/分发边界 |
|---|---|---|---|
| Xcode | 26.6（Build 17F113） | 构建、测试、签名和公证 macOS APP | Apple 官方工具；不进入产品包 |
| Swift / SwiftUI / AppKit | Swift 6.3.3；V0.1 Swift Package 已建立 | macOS APP、原生 UI 和平台桥接 | 随 Apple SDK/System Framework |
| SQLite / GRDB | 系统 SQLite + GRDB 7.11.1 exact | 正式 `LinkDigestPersistence` migration 001、Repository、WAL 与 Online Backup；不进入 Core/View | SQLite public domain；GRDB MIT，分发时保留 notice |
| Sparkle | 2.9.5 exact | v0.2.9 起提供应用内检查更新、Ed25519 更新包验签与用户确认后的安装 | MIT，`Sparkle.framework` 与 notice 进入 App；发布私钥只在本机 Keychain |

当前第三方 Swift Package 为 GRDB 7.11.1 与 Sparkle 2.9.5，均使用 exact pin；`Package.resolved` 分别锁定 revision `b83108d10f42680d78f23fe4d4d80fc88dab3212` 与 `79bc9e872948e47877e76f194cb0c8e0412b0b90`。本机 resolved graph 没有其它传递 package。`bash scripts/check-swift-licenses` 独立检查两项 pin、revision、零传递 package 与 MIT notice，不能用 pnpm license check 替代。

Sparkle 的 `SUFeedURL`、Ed25519 公钥和是否静默安装由 `config/app-release.json` 冻结；当前 `SUAutomaticallyUpdate=false`，因此后台检查发现新版本后仍由用户确认，不会静默替换 App。私钥不进入源码、产物、日志或许可证目录，只由官方 Sparkle 发布工具从 macOS Keychain 读取并签名 Universal ZIP；App 内仅分发用于验证的公钥。

V0.2 的本地 `LinkDigestAdapters` target 使用 Apple Security framework 访问 Keychain；Foundation/URLSession 实现 streaming adapter，只在测试 target 使用 Apple Network.framework 建立 loopback fake server。V0.3 的 `LinkDigestPersistence` target 单独依赖 GRDB，并通过 `HistoryRepository` Port 依赖 `LinkDigestCore`；Core、SwiftUI、Capture、Provider 与 Native Host 均不依赖 GRDB。正式 benchmark executable 为 `LinkDigestHistoryBenchmark`，旧 spike 源码/API 已移除，历史规格与旧 benchmark JSON 保留。

## SQLite binding 候选记录

| 候选 | 版本 | 许可证 | 包依赖 | 结论 |
|---|---:|---|---|---|
| GRDB | 7.11.1 | MIT | 默认 resolved graph 为 0 transitive | 选择；Swift 6.1+ / Xcode 16.3+，本机 Swift 6.3.3 / Xcode 26.6 Debug/Release 通过 |
| SQLite.swift | 0.16.0 | MIT | tag 清单声明 CSQLite 与 SQLCipher.swift 条件包 | 不加入；能力可用，但供应链与 Online Backup 封装成本高于 GRDB |
| 系统 SQLite3 | 系统 SDK | public domain | 0 | 不加入封装；需要自行承担 migration、连接池、C 生命周期与 Swift 并发边界 |

详细 migration、WAL、并发、备份与只读恢复证据见 `docs/specs/V0.3_SQLITE_SPIKE.md`。

## 兼容选择

建立本依赖基线时曾核对到 TypeScript 7.0.2；这只是当时的版本快照，不代表持续追踪“最新版本”。typescript-eslint 8.63.0 声明支持范围是 `>=4.8.4 <6.1.0`，因此当前锁定 TypeScript 6.0.3。依赖升级优先选择声明兼容且经过验证的组合，不机械追逐版本号。

## 传递依赖

当前许可证集合还包含双许可表达式，例如 `MIT OR GPL-3.0-or-later` 与 `BSD-3-Clause OR GPL-2.0`。SPDX 的 `OR` 表示项目可以选择其中一个许可分支；LinkDigest 对应依赖选择 MIT/BSD 分支，不采用 GPL 分支。

- 没有 GPL、AGPL、仅限非商业、UNLICENSED 或 UNKNOWN 包。
- MPL-2.0 来自 Vitest/Vite 开发链的 `lightningcss`，当前只用于测试工具，不进入产品运行时分发。
- WXT 的开发期传递依赖 `jszip` 与 `node-forge` 分别提供 MIT/BSD 的可选许可路径；`scripts/check-licenses` 只有在所有 `OR` 分支都被禁止时才失败，纯 GPL/AGPL 仍会阻断。
- 当前 TypeScript 运行时依赖为 Zod、Ajv 与 `ajv-formats`，许可证均为 MIT；它们都不进入 Swift macOS APP。

每次新增依赖后运行：

```bash
./scripts/check-licenses
bash ./scripts/check-swift-licenses
pnpm audit --prod
pnpm install --frozen-lockfile
```

`./scripts/check-licenses` 只覆盖 pnpm 依赖；`scripts/check-swift-licenses` 单独覆盖当前 Swift pin。两者不可互相替代。

`check-licenses` 是许可证最低自动门禁，`pnpm audit --prod` 检查生产依赖的已知漏洞。审计结果不是“绝对安全”证明；发布前仍需生成最终产物的第三方清单，并人工核对实际打包内容与许可证文本。

## 更新规则

1. 先核对新版本的 engine、peer dependency 和许可证。
2. 使用精确版本更新 `package.json`，由 pnpm 更新 `pnpm-lock.yaml`。
3. 运行 lint、typecheck、tests、license check 和 doctor。
4. 只有安全修复或明确功能需要才升级；不为“版本号更新”本身扩大任务范围。
