# 汲作（LinkDigest）项目规则

## 项目目标

- 以交付可用功能、解决实际问题和改善产品体验为首要标准。先完成最小完整链路，再检查、修复和优化；计划、代码写完或测试通过都不能单独代替产品交付。
- 目标可用、必要检查通过、没有已知阻断项时停止，不无限优化。

## 本项目对全局规则的放宽

- 小修复说明后直接做：单个明确的 bug 或界面细节调整，改动集中在少量文件，且不涉及数据结构、合同（contracts）、权限、打包签名和发布线。用一句话说明要改什么，做完报告结果。新功能、跨模块改动和上面这些例外，仍先给方案。
- 未提交改动不阻断工作：以当前工作区为基线，先看相关差异，不清理、回退或覆盖无关改动；冲突无法判断时只暂停冲突部分。
- 本机部署：涉及实际运行的改动，验证后备份、更新并打开 `/Users/song/Applications/汲作.app`，保留资料与设置；同轮集中部署。纯文档和规则修改不部署。
- 以上放宽不包括删除用户数据、凭据与账号、费用、对外发布、Git 提交推送、安装依赖和全局配置。

## 检查命令

按改动影响选，不默认跑全量。`pnpm check`、`check:web`、`check:swift`、完整 `swift test`、同时构建 Debug 和 Release，只在影响广泛、交付门禁或 Syc 要求时使用。

- 桌面端逻辑：`source ./scripts/xcode-env.sh && (cd apps/desktop && swift test --filter <XCTestCase 类名>)`。`--filter` 匹配的是类名不是文件名，跑完核对执行条数确有增加，否则是假绿。
- 浏览器扩展：在 `apps/browser-extension` 下运行 `CI=true pnpm test`、`CI=true pnpm typecheck`、`CI=true pnpm build`，三样缺一不可（前后两个不做类型检查）。
- UI 改动检查相关界面与交互；跨模块功能验证关键接口和用户链路；迁移、权限、合同、Host、打包改动按风险扩大检查。
- 同轮修改集中构建和验证，修复后只复验受影响部分。优先用隔离数据和模拟服务。

## 产品与工程约束

- 保持本地优先、Swift + SwiftUI 桌面端、Chromium 优先、Provider 可配置、失败可解释、数据可导出。不将远期平台或云端设想自动加入当前范围。
- 桌面端与扩展通过版本化 JSON 合同交接。修改合同或平台枚举时遵循：contracts/*.schema.json → pnpm generate:validator → scripts/sync-contracts.sh。
- 修改 extract.ts 的提取逻辑时，只改 `extractCurrentPage`。生产注入走 `entrypoints/extract-page.ts` 的 `files` 打包，不再维护 `extractPageInIsolatedWorld` 拷贝；`extract-copy-drift.test.ts` 禁止把双实现加回来。新增或扩展来源时，按需读取 [内容来源接入标准](docs/SOURCE_ADAPTER_STANDARD.md) 并完成其必要验证。
- UI 沿用用户参考与现有设计令牌，主题色收口在 AppearanceTheme.swift；素材不擅自重绘。
- SwiftPM 构建/测试串行，启动前检查现有进程；不因短暂无输出强杀，不自动清理构建数据库。打包正确携带资源包并完成必要重签。
- 凭据和真实账号数据不得进入仓库、日志、截图或夹具。登录受限内容优先使用当前已渲染页面，不静默读取完整 Cookie 数据库，不绕过访问控制；第三方代码先核对许可证。

## 稳定的坑

- xctrace/Instruments 性能录制每次导出所需数据后立即清理：用 `rm`（不带 -r/-f）删除 `getconf DARWIN_USER_TEMP_DIR` 目录下本次新产生的 `instruments*.ktrace` 和 `xrgpu_*`。单次原始 ktrace 可达 20 GB，录完不会自动删除，2026-09-24 曾因累积写满硬盘导致整机死机。`.trace` 录制包是目录，安全 hook 不允许 Agent 删除，一律放在 `/tmp/` 下，由重启清理。
- TLS 证书夹具默认 `XCTSkip`，全量 `swift test` 可以跑。需要夹具时设 `LINKDIGEST_RUN_TLS_FIXTURES=1`。日常仍可用 `--filter`；filter 匹配的是 XCTestCase 类名不是文件名，跑完核对执行条数确有增加，否则是假绿。
- 汲作数据库不能手工 UPDATE，改了 App 就打不开且报错不指向原因；要动数据走 App 功能，回滚只能整库换 `sqlite3 .backup` 副本。
- `OpenAICompatibleProvider.lowReasoningEffort` 必须是 `"low"`，丢了首字延迟慢一个数量级且界面无报错。
- 扩展部署要 ditto 到浏览器实际加载的目录并在扩展页重载；已存记录不会变，验证必须重新抓一条。
- 部署 App 后核对进程启动时间晚于二进制 mtime；同一时刻只允许一个 App 实例打开 history.sqlite，双开曾损坏 WAL。
- `main` 与 `codex/v0.2.10-stable` 已分叉无法合并，发布线是后者；补功能单点搬运，不提议合并。

## 文档与决策

- 按需读：[PRD](docs/PRD.md) 管产品行为，[ARCHITECTURE](docs/ARCHITECTURE.md) 管组件边界，相关交接文档管未完成状态；只在对应信息实际变化时更新。
- 长期决策需要时读 [BRAIN.md](BRAIN.md)，只通过 CLI 访问。写进 BRAIN.md 的每条决策包含：日期、决定了什么、考虑过哪些方案、为什么选这个、证据或注明「判断，无数据」、什么情况下重新考虑；明确拒绝的方案也写原因。
