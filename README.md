# LinkDigest

> 内部工作名；正式上架名称需在发布前完成商标、域名与应用商店重名检索。

LinkDigest 的产品目标是成为一个 local-first 的链接理解工具：用户可以粘贴网页链接，或从 Chrome、Brave、Edge 的当前页面直接发送内容，在桌面 APP 中完成正文提取、总结、翻译和导出；问答作为 P0 之后的候选能力。History 浏览/详情/单项删除与单条 Markdown/纯文本/JSON 导出已完成。手动公开链接默认使用 `PeerBoundNetworkWebPageFetcher`：`Network.framework` 只连接每跳 DNS/IP policy 已核验的 numeric IP，同时以原 hostname 做 TLS SNI、`SecPolicyCreateSSL` 与 HTTP Host，使用 system trust 并禁用 trust 的网络补取。显式系统 HTTP(S) 代理或 DNS 全部返回 fake-ip 时会进入独立的 `SystemProxyWebPageFetcher` 信任边界：该路径只允许 HTTPS，并保留 hostname 的 CONNECT/TLS 身份校验，但代理或 VPN 会自行重新解析 hostname，故它**不等价于** PeerBound 的“已校验 IP 就是实际 peer”保证，仍有 proxy-resolution SSRF 风险；HTTP 页面应改由浏览器扩展捕获。两条路径均逐跳检查 URL、redirect、凭据和端口，但不能把本机 DNS admission 写成代理实际连接 IP 的证明。`URLSessionWebPageFetcher` 仍只是 test-only legacy。完整用户链路与复审尚未完成，不能宣称产品已验收或发布。

这个仓库以持续交付可运行、可验证、可发布的软件为主。需要解释时结合当前代码和真实问题说明，但不把课程、术语表或学习记录作为开发流程和任务完成门槛。

## 当前阶段

产品路线已收敛为 **macOS 原生优先**：桌面 APP 使用 SwiftUI + 少量 AppKit，Chromium 扩展继续使用 TypeScript/WXT，两端通过 Native Messaging 与版本化 JSON 协议交接。

Loop 8 的浏览器安装事务已独立复审 PASS。当前正在完成 **Loop 9 / 0.2.0 integrated local-test candidate**：同一精确 handoff 将绑定 ad-hoc DMG 内的 App（含 Host、Browser Support UI 和模板）、确定性 Chromium 扩展 zip、完整源码归档、evidence/manifest/SHA256SUMS 及中文总检指南。该候选尚未冻结；只有主控装箱与独立 gate 全绿后才会标为 `READY_FOR_MANUAL_OPEN`。Syc 的真实三浏览器安装、登录页面捕获、BYOK 和价值指标实测属于总检，不由工程自动化冒充完成。Developer ID、公证、商店和公开发布仍未完成，产品与公开发布固定 `BLOCKED`。

日常 dogfood 会直接产生不在 Loop 序列里的改动（脑图、长文翻译分片并发、推理档位控制等）。这类「已实现但未登记」的功能，连同尚未开工的 Chrome Web Store 上架、Intel（x86_64）支持、WebUI 与下载数据看板，统一登记在 [`brain/roadmap.md`](brain/roadmap.md) 的「未规划项」与「已实现但未登记的功能」两节——**需要知道「还剩什么没做」时先看那里**，本节只描述当前 Loop。

- 架构边界见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。
- 当前 P0 产品范围与验收见 [`docs/PRD.md`](docs/PRD.md)。
- 里程碑、未规划项与已实现但未登记的功能见 [`brain/roadmap.md`](brain/roadmap.md)。分发路径的现场核实结论（ad-hoc 签名会弹哪种拦截、macOS 15 起「右键打开」已失效）也记在该文件的「当前状态」一节。
- Loop 9 候选内将随包交付的总检步骤与 PRD §11.1 指标记录模板见 [`docs/ACCEPTANCE_GUIDE.md`](docs/ACCEPTANCE_GUIDE.md)。
- 第一条“测试页面 → 扩展 → Native Messaging → SwiftUI”链路见 [`docs/specs/V0.1_VERTICAL_SLICE.md`](docs/specs/V0.1_VERTICAL_SLICE.md)。
- 10 万/100 万容量口径作为远期参考保留在 [`docs/CAPACITY_MODEL.md`](docs/CAPACITY_MODEL.md)，不驱动 P0 实施。
- Project Brain 只能通过 `./scripts/brain` 读写；一键只读体检使用 `./scripts/doctor`，说明见 [`VERIFY.md`](VERIFY.md)。
- 当前依赖版本、兼容理由和许可证边界见 [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)。
- V0.2 的集中工程证据见 [`docs/specs/V0.2_BYOK_ACCEPTANCE.md`](docs/specs/V0.2_BYOK_ACCEPTANCE.md)。
- P0-RC-02B 的最终实施、验收与证据见 [`docs/specs/P0_RC_02B_APP_WIRING_IMPLEMENTATION.md`](docs/specs/P0_RC_02B_APP_WIRING_IMPLEMENTATION.md)、[`docs/specs/P0_RC_02B_APP_WIRING_ACCEPTANCE.md`](docs/specs/P0_RC_02B_APP_WIRING_ACCEPTANCE.md) 与 [`docs/evidence/P0_RC_02B_APP_WIRING_ACCEPTANCE_2026-07-15.md`](docs/evidence/P0_RC_02B_APP_WIRING_ACCEPTANCE_2026-07-15.md)。
- 手动公开链接输入的边界、角色交接和恢复方式见 [`docs/specs/P0_RC_LOOP_5_DESKTOP_INPUT.md`](docs/specs/P0_RC_LOOP_5_DESKTOP_INPUT.md)。
- V0.1 自动化垂直链路已建立：语言中立 JSON Schema、共同 fixtures、WXT MV3 扩展、SwiftUI APP、Native Host、Unix socket 与结构化错误均可构建和测试；Chrome、Brave 150 的真实触发、离线错误、在线接收与 20 次 Release p95 已通过。Edge 150 的隔离 Profile 也已完成真实 Popup 预览观察，以及修复后 Service Worker → Native Host → Unix socket → 运行中 Swift App 的 20/20 传输证据。
- V0.2 已有完整本地工程证据；Loop 3 的发送前数据去向确认和设置页测试连接已经最终独立复审 PASS。真实 Provider 抽样仍需 Syc 单独授权。
- Stable Host r1 规格、package 格式、clean-room 门禁与候选证据见 [`docs/specs/P0_RC_LOOP_4_STABLE_HOST.md`](docs/specs/P0_RC_LOOP_4_STABLE_HOST.md)。
- Stable Host r2 事务、receipt v2、commit/recover 与证据边界见 [`docs/specs/P0_RC_LOOP_4_R2_TRANSACTIONS.md`](docs/specs/P0_RC_LOOP_4_R2_TRANSACTIONS.md)。
- 当前 App/dev/r3 preflight 的 macOS 浏览器支持中，Chrome 与 Brave 保留两个 UI 入口但共享 `Google/Chrome/NativeMessagingHosts` 的 active manifest 与 `chrome` receipt entry；Edge 保持独立。旧 BraveSoftware leaf/receipt 只用于兼容恢复，不能作为已安装状态。r2 transaction 与 r4 release-unit/local-test target probe 仍保留 legacy Brave 独立角色合同，不能作为 active shared mapping 的发布证据；必须在下一次 candidate freeze 前版本化迁移。
- Stable Host r3 真实安装前只读预检、BLOCKED 语义与授权边界见 [`docs/specs/P0_RC_LOOP_4_R3_PREFLIGHT.md`](docs/specs/P0_RC_LOOP_4_R3_PREFLIGHT.md)。
- r4a unsigned App+DMG release unit、`/private/tmp` audit build、exact mount/detach 与真实目标 probe 见 [`docs/specs/P0_RC_LOOP_4_R4A_RELEASE_UNIT.md`](docs/specs/P0_RC_LOOP_4_R4A_RELEASE_UNIT.md)。
- r4b live-worktree source snapshot、inside-out ad-hoc 签名、local-test DMG/handoff 与独立 gate 见 [`docs/specs/P0_RC_LOOP_4_R4B_LOCAL_TEST_DMG.md`](docs/specs/P0_RC_LOOP_4_R4B_LOCAL_TEST_DMG.md)。
- 旧 Electron/百万容量对齐文档保存在 `docs/archive/`，只用于追溯，不再作为当前实现依据。

V0.1 三浏览器交接矩阵的工程证据已经收口；Edge 的 Popup 观察与 Service Worker 传输压测分别记录，不能合并解读为一次连续的工具栏点击截图验收。Loop 4 r2 PASS 只证明隔离 clean-room 事务合同；checksum 是一致性证据，不是发布真实性或签名证明。r3 cache-safe 101 项已独立 PASS。r4a 进一步绑定 App/Host/DMG，但只使用 engineering-candidate identifier 与 unsigned artifacts，且真实固定 manifest 叶子当前不是 canonical JSON；因此本仓库仍不能写 release ready、安装完成或发布完成。

## Stable Host r2 CLI（仅 clean-room）

快速门禁入口：

```bash
pnpm --config.verifyDepsBeforeRun=false native-host:transaction:check
```

`plan` / `apply` / `recover` 通过 `./scripts/native-host/clean-room-transaction.sh` 调用。每个 session 必须已在 fixed canonical `/private/tmp` 下预置 r1 sentinel 与 mode `0600`、精确固定内容的 `.transaction.lock`；wrapper 不创建或替换它。不要把示例的 `--session-root` / `--home-root` 替换为真实 `$HOME`，也不要把 110 项 clean-room 门禁理解为真实浏览器安装验收。完整参数、退出码和恢复方向见 r2 规格。

## 目录

```text
apps/
  desktop/            macOS SwiftUI 桌面 APP
  browser-extension/  Chrome / Brave / Edge 扩展
contracts/            当前跨语言唯一合同：根 JSON Schema 与共同 fixtures
packages/
  extractor/          后续提取模块预留；当前只有占位 README
  llm/                后续模型模块预留；当前只有占位 README
  shared/             旧 TypeScript 协议原型与兼容参考；不是当前跨语言真相源
server/               远期服务端预留，不进入 P0
docs/                 PRD、架构、验收与发布资料
```

## 第一条产品原则

优先处理用户在浏览器中已经合法打开并看见的内容。默认不读取整个浏览器 Cookie 数据库；只有深度媒体提取确实需要登录态时，才请求当前域名、可撤销、短时有效的授权。

## 安全边界

- API Key、Cookie、Token、浏览器配置和账号数据不得进入 Git。
- P0 不依赖自建服务器，先验证本地核心闭环。
- 任何付费、部署、上架、发布和远程写入都需要 Syc 明确确认。
- 平台适配只服务于用户主动提交的内容，不设计批量采集或绕过访问控制。
