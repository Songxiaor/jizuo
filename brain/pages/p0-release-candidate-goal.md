---
id: p0-release-candidate-goal
title: "P0 Release Candidate 最终交付目标"
category: decision
status: active
tags: [p0, release, workflow, quality]
created: "2026-07-15T11:27:22"
updated: "2026-07-19T00:14:45"
---

## compiled_truth

# 当前结论

Syc 已完成 r4b local-test DMG 的第一次真实 GUI 打开，并确认该包只能作为工程/UI 基线，不能继续表述为完整可用 APP。截图和源码共同证明：空状态的“添加链接”“从剪贴板添加链接”是永久禁用占位；生产 BYOK 底层已经存在，但入口隐藏且尚无真实 Provider 兼容验收；扩展虽有捕获/Native Messaging 代码，但没有冻结扩展身份、可交付扩展工件和真实用户级 Host 安装入口。

因此，r4b 的准确状态调整为 **GUI_BASELINE_PASS / PRODUCT_INCOMPLETE**。它证明 App/DMG 可打开、历史/导出/设置工程链存在，不证明普通用户能完成添加链接、配置模型、浏览器捕获和生成结果。

# 完整可用 APP 的五个产品 Loop

1. Loop 5 — Desktop Input：实现手动 URL 与按需剪贴板输入、公开网页抓取/正文提取、来源证据、失败恢复，并接入 SQLite/CurrentCapture；动态或登录页面明确引导使用浏览器扩展。
2. Loop 6 — BYOK Product UX：把模型配置做成主流程可发现入口，完成保存、连接测试、目的地确认、流式总结/翻译和真实 OpenAI-compatible Chat Completions SSE 抽样；API Key 只进 Keychain。
3. Loop 7 — Extension Artifact：冻结本地测试扩展 ID，生成确定性 Chromium 扩展工件，补齐安装说明与版本绑定。
4. Loop 8 — Browser Support Installer：将 clean-room 事务语义迁移到生产 Swift 安装服务，在 APP 中提供安装/修复/卸载与冲突确认；只写当前用户 LinkDigest 自有 Host/manifest/receipt。
5. Loop 9 — Integrated Full DMG：将 App、Host、扩展、安装入口、源码、清单和证据绑定为同一 DMG，完成 clean-room 与经单独授权的 Syc Chrome/Brave/Edge 真实端到端验收。

Developer ID、hardened runtime、公证、stapling 和公开下载属于额外 Loop 10，不是 Loop 5–9 本机完整可用版的完成条件。

# 用户确认与验收边界

Syc 已确认 UI 与功能参考 Sam，并要求 UI 编写前使用参考图、完成后提供结果图；功能入口和行为也需在阶段验收点确认。Loop 5 首先执行，成功标准不是按钮变亮，而是“输入 URL/剪贴板 → 获得可核查正文 → 写入 History → 可选择总结/翻译”。真实 Provider、真实 HOME/profile 写入、证书、公证、发布与 Git 仍分别受既有授权门禁约束。


## timeline

- time: 2026-07-15T11:27:22
  kind: decision
  summary: "Created this page: P0 Release Candidate 最终交付目标"
  source: Syc conversation 2026-07-15
  affects: [p0-release-candidate-goal]

- time: 2026-07-15T11:27:22
  kind: decision
  summary: "冻结 LinkDigest P0 RC 最终范围、质量门禁与多 Agent 交付方式。"
  source: Syc conversation 2026-07-15
  affects: [p0-release-candidate-goal]

- time: 2026-07-15T11:34:17
  kind: evidence
  summary: "Sol 完成 P0 RC 顺序化实施计划；主控补齐 Brain/git 基线并将全部 Sub-agent 路由修正为 Sol。"
  source: P0 RC planning subagent 2026-07-15
  affects: [p0-release-candidate-goal, planner-executor-review-loop]

- time: 2026-07-15T11:58:09
  kind: evidence
  summary: "V0.1 三浏览器工程门禁经 Sol xhigh 复审通过，允许进入 SQLite binding spike。"
  source: Sol xhigh re-review 2026-07-15
  affects: [p0-release-candidate-goal, native-macos-swiftui-hybrid]

- time: 2026-07-15T12:24:07
  kind: evidence
  summary: "SQLite binding/recovery spike ACCEPT；独立复审允许冻结 GRDB 7.11.1 并进入正式四模型与 migration 001。"
  source: Sol xhigh SQLite spike review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:32:27
  kind: decision
  summary: "以 Sam Webpage Summarizer 为 UI/产品架构对标：借鉴原生双栏、历史详情、local-first、rerun、usage/cost；不复制品牌，不引入 P0 Q&A/Safari。"
  source: Syc direction 2026-07-15
  affects: [p0-release-candidate-goal, sam-webpage-summarizer-reference, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T12:40:23
  kind: decision
  summary: "正式历史模型已冻结：canonical archive、正文版本 Snapshot、显式 Rerun、delivery ledger、Unicode scalar 与整数微货币 usage/cost。"
  source: P0-RC-02 planning 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, sam-webpage-summarizer-reference]

- time: 2026-07-15T13:44:47
  kind: evidence
  summary: "P0-RC-02A 正式领域、五表 migration 001 与 GRDB Repository 经独立复审通过；允许进入 02B App 接线。"
  source: Sol xhigh 02A re-review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary]

- time: 2026-07-15T16:56:54
  kind: evidence
  summary: "P0-RC-02B App capture/run persistence wiring 经多轮MUST FIX与最终独立Sol复审PASS；共享StorageWriteGate、并发Capture permit queue、Run持久化与协议hardening关闭，主线程Swift 117/117、Web、SwiftPM与Xcode四目标通过。"
  source: P0-RC-02B final review 2026-07-15
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, planner-executor-review-loop]

- time: 2026-07-16T12:41:57
  kind: evidence
  summary: "Loop 2 完成单条 Markdown、TXT、JSON 本地导出工程：只读 future-schema 历史可作为逃生口导出，139/139 Swift tests 通过；未提交、未发布。"
  source: Loop 2 implementation and local Swift test 2026-07-16
  affects: [p0-release-candidate-goal, sqlite-grdb-persistence-boundary, sam-webpage-summarizer-reference]

- time: 2026-07-16T12:42:30
  kind: decision
  summary: "将 Loop 2 导出当前状态、脱敏边界与未发布状态写入 P0 RC 真相。"
  source: Loop 2 implementation and validation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:38:31
  kind: decision
  summary: "更新 Loop 2 独立复审修复状态与 143 项本地门禁，保持待复审口径。"
  source: Loop 2 independent review fixes 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:38:31
  kind: evidence
  summary: "独立复审发现的文件名字节预算、Run 归属、decoder 与 usage 问题已本地修复；focused 22/22、Swift 143/143、SwiftPM/Xcode/migration/diff 门禁通过，等待复审。"
  source: Loop 2 local verification 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:58:56
  kind: decision
  summary: "补齐 launch-pending 删除保护并更新至 Swift 146 项本地门禁，状态保持待最终复审。"
  source: Loop 2 final local fix 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T13:58:56
  kind: evidence
  summary: "launch-pending 在 createRun 前保护真实 Task，starting 接管且失败或无回调会清理；App focused 15/15、Swift 146/146 与完整构建门禁通过，待最终复审。"
  source: Loop 2 final local verification 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T14:05:07
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 2 final independent re-review 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T14:05:07
  kind: evidence
  summary: "Loop 2 最终独立复审 PASS：P0/P1/P2 均为 0；Swift 146/146、SwiftPM 与 Xcode 四目标、diff、migration 001 冻结 hash 和无 Migration002 证据通过。"
  source: Loop 2 final independent re-review 2026-07-16
  affects: [apps/desktop, docs/LEARNING_LOG.md]

- time: 2026-07-16T15:35:22
  kind: decision
  summary: Loop 3 native UX and frozen data-destination authorization implementation
  source: Loop 3 remediation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T15:35:22
  kind: evidence
  summary: "Loop 3 remediation added frozen Core authorization, preparation-token TOCTOU gates, Release-safe visual fixture compilation, and connection-state invalidation; local verification pending final full gate."
  source: Loop 3 remediation 2026-07-16
  affects: [p0-release-candidate-goal, sam-webpage-summarizer-reference]

- time: 2026-07-16T15:48:46
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 3 second independent review BLOCK 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T15:48:46
  kind: evidence
  summary: "Loop 3 第二次独立复审 BLOCK：P0 清零；preparation token 释放、设置 dirty/generation、save/authorize revision 或 permit 三项 P1 未关闭，禁止进入 Loop 4。"
  source: Loop 3 second independent review 2026-07-16
  affects: [p0-release-candidate-goal, roadmap, docs/LEARNING_LOG.md]

- time: 2026-07-16T16:28:40
  kind: decision
  summary: Loop 3 P1 candidate fixes complete and awaiting independent review
  source: Loop 3 P1 remediation and deterministic barrier validation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T16:28:40
  kind: evidence
  summary: "Loop 3 candidate remediation passed 14 deterministic barrier cases, Swift 177/177, SwiftPM Debug/Release, Xcode four targets, secret and migration gates; pnpm license inventory remains environment-blocked by missing Ajv store index."
  source: Loop 3 local verification 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T16:42:26
  kind: evidence
  summary: "ProviderAuthorization now has fixed redacted description and debugDescription; sentinel reflection regression and full Swift 178/178 plus Debug/Release builds passed. Loop 3 remains awaiting independent review."
  source: Loop 3 final security remediation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T16:52:25
  kind: decision
  summary: Loop 3 final independent review PASS and redaction barriers closed
  source: Loop 3 final independent re-review 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T18:06:19
  kind: decision
  summary: Loop 4 r1 stable Host candidate implemented and awaiting independent review
  source: Loop 4 r1 local implementation and deterministic validation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T18:07:12
  kind: evidence
  summary: "Loop 4 r1 local deterministic check passed 47 assertions: clean-source offline Release build, Unicode move, source build deletion, packaged Host smoke, missing-bundle runtime failure, manifest/install/receipt/path gates and tamper rejection; real HOME metadata digest unchanged. Candidate remains awaiting independent review."
  source: scripts/native-host/check-stable-package.sh 2026-07-16
  affects: [p0-release-candidate-goal, roadmap]

- time: 2026-07-16T18:20:02
  kind: decision
  summary: Loop 4 r1 stable Host candidate final local gate is 48 assertions and still awaits review
  source: Loop 4 r1 final local validation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T18:20:02
  kind: evidence
  summary: "Final Loop 4 r1 local gate passed 48 assertions after rejecting installed version trees with unknown empty directories. Swift focused 54/54, Keychain-skipped full 177/177, SwiftPM and Xcode four targets passed; Web Ajv links and pnpm index remain environment-blocked. Candidate awaits independent review."
  source: Loop 4 r1 final local matrix 2026-07-16
  affects: [p0-release-candidate-goal, roadmap]

- time: 2026-07-16T18:48:25
  kind: decision
  summary: Loop 4 r1 fixed TMP root and verified package smoke candidate awaits re-review
  source: Loop 4 r1 reviewer BLOCK remediation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T18:48:25
  kind: evidence
  summary: "Reviewer BLOCK P1 remediation passed 56 assertions: clean-room trusts only fixed /private/tmp; raw Host/skip-build/socket overrides fail closed; packaged smoke requires verified package root; poisoned TMPDIR installer and vertical smoke make no scope-outside, HOME, or worktree changes. Candidate awaits re-review."
  source: Loop 4 r1 BLOCK remediation local gate 2026-07-16
  affects: [p0-release-candidate-goal, roadmap]

- time: 2026-07-16T19:00:04
  kind: decision
  summary: Loop 4 r1 final independent re-review PASS
  source: Loop 4 r1 final independent re-review 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T21:36:43
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 read-only preflight candidate 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T21:43:36
  kind: evidence
  summary: "Loop 4 r3 preflight candidate is locally verified (40 assertions) and deliberately BLOCKED; it has no installation/signing/notarization/release authority. r1/r2 clean-room gates were rerun without changing real HOME metadata; release readiness remains blocked pending Syc-authorized future evidence."
  source: Loop 4 r3 local verification 2026-07-16
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-16T21:45:34
  kind: evidence
  summary: "r3 final local gate PASS 41 assertions; ordinary report remains BLOCKED and separate authorization is mandatory even for a future READY. No real installation, signing, notarization, stapling, release or user-profile action occurred."
  source: Loop 4 r3 final local gate 2026-07-16
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-16T21:54:50
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 P1 remediation candidate 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T21:55:20
  kind: evidence
  summary: "r3 P1 remediation local gate PASS 49 assertions. Production CLI cannot reach READY from separate App/DMG/receipt inputs; r4 must be separately authorized to verify release-unit and real target-leaf ownership. No release action occurred."
  source: Loop 4 r3 P1 remediation local verification 2026-07-16
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-16T22:14:37
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 reviewer BLOCK and P1/P2 remediation candidate 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T22:15:13
  kind: evidence
  summary: "r3 formal review BLOCK P0/P1/P2=0/2/2 已保留；P1/P2 remediation candidate local gate PASS 99 assertions。生产 CLI 仍 BLOCKED，无真实 Apple query/installation/release action，等待同一 reviewer唯一 re-review。"
  source: Loop 4 r3 review and remediation candidate 2026-07-16
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-16T22:16:57
  kind: evidence
  summary: "r3 remediation final local gate PASS 100 assertions, superseding 99 after fixed-argv-only enforcement. Formal review remains BLOCK 0/2/2 until the same reviewer completes the single allowed re-review."
  source: Loop 4 r3 final local remediation gate 2026-07-16
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-16T22:54:54
  kind: decision
  summary: "同步 r3 re-review BLOCK 0/1/0 与 cache-safe 101 项候选状态"
  source: Syc continue authorization and r3 cache remediation 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-16T23:01:59
  kind: decision
  summary: "推进 P0 路线至 r3 final PASS 与 r4 授权门禁"
  source: r3 cache final independent review 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T00:34:22
  kind: decision
  summary: "将 r4a unsigned release-unit 记录为 candidate 并保持产品 BLOCKED"
  source: Loop 4 r4a implementation candidate 2026-07-16
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T00:40:37
  kind: evidence
  summary: "r4a final local candidate：真实DMG/mounted exact reverify/无残余mount、41项负向门禁、Swift 10/10与181/181、r3 101通过；真实Chrome/Edge manifest malformed，产品继续BLOCKED。"
  source: Loop 4 r4a final local gates 2026-07-17
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-17T01:09:49
  kind: decision
  summary: "将 r4a 状态校准为首次 review BLOCK 后的 remediation candidate"
  source: r4a first independent review and remediation 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T01:18:14
  kind: decision
  summary: "同步 r4a 新 remediation candidate 与 72 条只读聚焦门禁"
  source: r4a remediation candidate verification 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T01:26:39
  kind: decision
  summary: "同步 r4a candidate-02 与 74 条只读聚焦门禁"
  source: r4a final remediation candidate verification 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T01:37:17
  kind: decision
  summary: "推进 P0 路线至 r4a engineering PASS 与 r4b 单独授权门禁"
  source: r4a final independent re-review 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T01:37:17
  kind: evidence
  summary: "Loop 4 r4a 最终独立 re-review PASS 0/0/0；只关闭 unsigned App+DMG release-unit 工程门禁，真实 manifests malformed，签名公证安装发布仍需另行授权。"
  source: r4a final independent re-review and main verification 2026-07-17
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-17T02:13:13
  kind: decision
  summary: "把 r4b 从未授权下一步更新为 local-test implementation candidate"
  source: Syc r4b local-test authorization 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T02:28:39
  kind: evidence
  summary: "local-test candidate-07 DMG/source/manifests 已闭环，状态仅 READY_FOR_MANUAL_OPEN-candidate；workspace final release 目录未创建，需独立 reviewer PASS 后由主控 finalize。"
  source: r4b candidate-07 2026-07-17
  affects: [p0-release-candidate-goal, stable-native-host-delivery]

- time: 2026-07-17T02:47:11
  kind: decision
  summary: "推进 P0 至 r4b READY_FOR_MANUAL_OPEN 与 Syc 人工 GUI 门禁"
  source: r4b independent review and finalization 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T02:47:11
  kind: evidence
  summary: "最终 local-test handoff 已放入 release/LinkDigest-0.1.0-local-test；DMG 51f2a654…e2a7、candidate 513b523c…19df，等待 Syc 手工打开，产品/公开发布继续 BLOCKED。"
  source: r4b final handoff verification 2026-07-17
  affects: [p0-release-candidate-goal, stable-native-host-delivery, roadmap]

- time: 2026-07-17T10:31:06
  kind: decision
  summary: "Syc 手工测试确认 r4b 只是可打开工程包，完整可用 APP 需要五个产品 Loop"
  source: Syc GUI feedback and full-product request 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T14:59:38
  kind: decision
  summary: "Syc 授权：四个规划补丁写入 roadmap（PRD §12 样本集入 Loop 5 验收、PRD §11.1 价值指标挂 Loop 9、命名检索前置 Loop 7、Loop 6 结束出日常可用 local-test DMG）；Codex 获授权在当前 dirty worktree 收口 Loop 5（full suite 复跑、20 条样本集、GUI 结果图经 Syc 确认后提交）。真实 Provider 与签名公证发布仍单独授权。"
  source: Syc authorization 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T15:56:40
  kind: evidence
  summary: "Loop 5 第三轮(codex exec)PARTIAL:Swift 218/218、SwiftPM/Xcode/Web/secret/vertical smoke 全绿,20 条样本集含 GitHub 基线建成;但发现 Syc 本机代理为 fake-ip DNS(198.18.0.0/15),production PublicWebURLPolicy 正确拒绝导致 15 条公开样本 environment-blocked,且意味着日常开代理时手动链接功能不可用,需要代理兼容产品决策。GUI 四图与 doctor 的 pnpm store 修复待办。"
  source: "Loop 5 round-3 codex report + unsandboxed DNS verification 2026-07-17"
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T15:59:52
  kind: decision
  summary: "Syc 确认代理环境兼容排进 Loop 6 验收:fake-ip 检测+人话提示,经系统代理按域名连接且保留 TLS/SNI/证书名校验;Loop 6 DMG 必须在开代理的真实环境下完成日常闭环。Loop 5 定格为 CODE-COMPLETE / VERIFICATION-PENDING,公开样本实抓与 GUI 成功链路截图待代理解锁或 Loop 6 兼容后补验。"
  source: Syc decision 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T16:43:14
  kind: evidence
  summary: "Loop 6 第一轮(codex exec)实现候选:BYOK 设置入口/自定义 prompt/多语言、代理兼容(fake-ip 检测+系统代理按域名 CONNECT,TLS/SNI/证书校验保留)落地;fake-ip 环境下 15 条公开样本进入真实网络链路(4 success/8 marker 漂移/8 失败),doctor 87/1/0 全绿,新 local-test DMG 过 71 项本地门禁待独立复审;Swift 222/223(1 项隔离 Keychain 环境失败),GUI 仅 1 张有效图待主控/Syc 补。"
  source: Loop 6 round-1 codex report 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T16:55:28
  kind: evidence
  summary: "Loop 6 独立复审(Sol 只读)BLOCK:P0=0,P1=3(系统代理路径重开 DNS rebinding/proxy-resolution SSRF 窗口、代理 transport 缺执行级 TLS/redirect/代理认证负向测试、重启后保存的 prompt/目标语言不自动进入主流程),P2=2(Codable 绕过偏好校验、PRD/README 与三分流实现口径冲突)。TLS challenge/fake-ip 判定/Keychain 边界/DMG 装箱 gate 经现场抽查确认可信。待 P1 修复后同一 reviewer 复审。"
  source: Loop 6 independent review 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T20:21:55
  kind: evidence
  summary: "Loop 6 P1 修复闭环完成:Terra 三轮修复(HTTPS-only 代理门禁、执行级 CONNECT/TLS/redirect/proxy-auth 负向测试、bootstrap 偏好加载,顺带 P2-1 DTO 校验/P2-2 文档口径);主控修复测试编译错与 8 处转义并独立复跑(定向全过、Swift 233/233、doctor 87/1/0);同一 reviewer 两轮复审后 PASS 零新增 findings。旧候选 SUPERSEDED,新候选 release/loop6-candidate-20260717-r2 过 71 项 gate、13/13 SHA、五文件 archive binding,DMG 4b1e2601…efd8 标 READY_FOR_MANUAL_OPEN;待 Syc 开代理真实环境人工 GUI 闭环验收。"
  source: "Loop 6 P1 fix loop + final review 2026-07-17"
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T20:51:16
  kind: decision
  summary: "Syc 验收 r2 候选期间批准两级排期:1) Loop 6 收尾 UX 批次(侧边栏可收缩[主控已改]、App 图标 Möbius-S squircle 接线含 gate 期望更新、设置页红错改引导/Key 状态化/提示词重置钮),Terra 执行中,产出 r3 候选替代 r2;2) 新增 Loop 6.8 设置页重构与模型体验(两 tab、厂商预设、GET /models 下拉复用现有传输门禁、输出语言统一、翻译可选独立模型、数据去向卡),排在 6.5 之后。明确不做:温度/推理参数、iCloud、多 Profile、可编辑翻译 prompt;ChatGPT 订阅仅观察第三方 GA。"
  source: Syc conversation 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-17T22:28:47
  kind: evidence
  summary: "Loop 6 UX 批次闭环:Terra 两轮(设置页四态+图标接线+gate 扩 76 项;复审 BLOCK 后门禁下沉到 ViewModel 入口+取 Key 前二次复核+负向测试)。同一 reviewer 复审 PASS 零新增:Swift 241/241、gate 76/10、SHA 13/13、11 文件 archive binding MATCH、挂载验证图标生效。最终 dogfood 候选 r3-fix2(DMG 8ca8bd0c…850349,READY_FOR_MANUAL_OPEN);r2/r3/r3-fix1 SUPERSEDED。待 Syc 换用 r3-fix2 完成人工 GUI 闭环后 Loop 6 整体收口。"
  source: UX batch final review 2026-07-17
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T11:24:47
  kind: decision
  summary: "Syc 用 r3-fix2 完成 Loop 6 真实 BYOK 闭环(DeepSeek deepseek-v4-flash 连接成功+真实翻译+历史入库)并批准:错误映射修复并入 r4 最终冻结收口 Loop 6(进行中);验收发现转入新排期——Loop 6.6 历史详情精修(元数据/Token/费用/favicon)、Loop 6.9 标签与看板筛选(自动+手动标签,标签筛选视图);登录页捕获(浏览器 Cookie)维持 Loop 7/8 排期,Syc 知悉扩展 ID 冻结依赖命名检索的约束。"
  source: Syc acceptance session 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T12:54:31
  kind: evidence
  summary: "Loop 6 工程侧收口:r4→r4-fix3 四轮安全收敛(净化绕过×3 后采纳 reviewer 架构建议——取消 Provider 摘要透传,UI 仅固定文案,决策入 ARCHITECTURE.md)。终审 PASS 零 findings:249/249、gate 76/10、SHA 13/13、18 文件绑定、hdiutil VALID。最终 dogfood 候选 r4-fix3(DMG b8fd3cee…30fa7c),历史候选全部 SUPERSEDED。学习:denylist 净化在开放语法空间不可收敛,三轮实证后固定文案是更小可证明边界。"
  source: Loop 6 final review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T13:48:40
  kind: evidence
  summary: "Loop 6.5 GitHub 仓库适配器工程侧一轮通过(见 github-repo-source-adapter),候选 loop65-candidate-20260718 待 Syc 验收;下一站 Loop 6.6 详情精修。"
  source: Loop 6.5 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T14:05:18
  kind: decision
  summary: "Syc 授权:从 Loop 6.6 起连续执行至 Loop 7 结束,期间不逐项请示,Syc 最后总检。底线不变:不 git commit/push、不碰真实凭据、不签名/公证/发布。命名检索做研究与候选论证,最终产品名留 Syc 总检拍板;Loop 7 以技术身份(扩展 key/ID)与显示名解耦方式推进,避免被命名阻塞。X 抓取质量确认为登录墙+客户端渲染边界,完整解决在 Loop 7/8 扩展;favicon 在 6.6、标签在 6.9(已答复 Syc)。"
  source: Syc authorization 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T15:09:42
  kind: decision
  summary: "Syc 扩展授权:连续执行至 Loop 9 完成(原为 Loop 7)再总检。范围:6.6 收尾→6.8→6.9→命名检索研究→Loop 7→Loop 8→Loop 9 工程侧(候选+复审 PASS)。留给 Syc 总检的:产品名拍板、三浏览器端到端人工测试、价值指标确认。底线不变:不 commit/push、不碰真实凭据、不签名/公证/发布(Loop 10 单独授权)。"
  source: Syc authorization 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T15:20:29
  kind: evidence
  summary: "Loop 6.6 收口:详情元数据/Token 落库/favicon/时间格式完成;复审两轮(P1 usage 流级致命→改容错旁路)后 PASS。全量 270/270、gate 76/10、12 文件绑定;候选 loop66-candidate-20260718-fix1(DMG d30ca252…2c1c9f)。装箱职责固化:Terra 环境有静默停点,冻结由主控本机执行。费用估算已裁剪(BYOK 无可靠价格表,PRD 记录理由)。开工 Loop 6.8。"
  source: Loop 6.6 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T16:22:12
  kind: evidence
  summary: "Loop 6.8 收口:设置两 tab、七厂商预设、/models 下拉(1MiB/500条/仅取id)、127.0.0.1 白名单、输出语言统一、翻译独立模型、数据去向卡+四小步全部落地。三轮复审收敛(偏好入口竞态/语言判定两轮),终审 PASS。全量 289/289,候选 loop68-candidate-20260718-fix2(DMG e71b8fce…bd99bd)。开工 Loop 6.9 标签与看板。"
  source: Loop 6.8 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T17:40:52
  kind: evidence
  summary: "Loop 6.9 收口:标签 migration/自动标签(fail-open+同目的地)/手动编辑/SQL 交集筛选/导出含标签。四轮复审收敛(UI 刷新→事件所有权竞态→状态机收尾),终审 PASS 零阻断。全量 306/306,候选 loop69-candidate-20260718-fix3(DMG 77453937…a712df)。非阻断维护项:metadata success 分支显式清零 detailErrorCode(记入后续批次)。开工 Loop 7(扩展身份与显示名解耦)并行命名检索研究。"
  source: Loop 6.9 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T18:37:04
  kind: evidence
  summary: "Loop 7 收口:固定扩展 ID fbpjhlcpfheecigibjghhodhhkgjdgma(reviewer 独立重算一致)、确定性 zip、三浏览器模板字节级一致、显示名 product-display.json 解耦、私钥仓库外 0600、gate 扩至 102 断言。过程两个插曲均转化为收益:FAKE_SECRET 字面量被 snapshot 扫描正确拦截(证明扫描器有效);gate KeyError 修为明确 FAIL。终审 PASS。全量 307/307,候选 loop7-candidate-20260718(DMG f2311936…7067c1,SHA 17/17)。开工 Loop 8 安装器(工程轮全部用隔离 HOME,真实 HOME 安装留 Syc 总检)。"
  source: Loop 7 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T20:45:39
  kind: evidence
  summary: "Loop 8 收口:浏览器支持安装器(状态检测/安装/修复/卸载)三轮复审收敛——receipt 双绑定→durable journal+进程终止恢复+叶节点无窗口替换→journal 不可变+quarantine 绑定+crash barrier 全覆盖。终审 PASS。连续两遍 337/337,gate 107 断言+focused 40/40,候选 loop8-candidate-20260718(DMG 2e3bb05e…0b3f35)。全程隔离 HOME,真实安装留 Syc 总检。开工 Loop 9 Integrated Full DMG(最后一站)。"
  source: Loop 8 review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-18T21:41:27
  kind: evidence
  summary: "Loop 9 收口(两轮复审):0.2.0 集成 DMG——App+安装器+扩展 zip+源码+证据+中文总检指南一体;修复双版本扩展残留与指标定义漂移后终审 PASS。两遍 339/339,gate 133 断言/focused 62/62,329/329 文件绑定,候选 loop9-candidate-20260718(DMG 31d1100f…8b8a6f)。至此 Syc 授权的连续执行(6.6→6.8→6.9→命名检索→7→8→9)全部完成,等待 Syc 按 ACCEPTANCE_GUIDE 总检:真实三浏览器端到端、真实 BYOK、PRD §11.1 指标实测、产品名拍板。Loop 10(签名/公证/发布)单独授权。"
  source: Loop 9 final review PASS 2026-07-18
  affects: [p0-release-candidate-goal]

- time: 2026-07-19T00:14:45
  kind: evidence
  summary: "Syc 总检两轮反馈(14 项)修复批次收口:富文本渲染(引号感知净化扫描器,三轮收敛)、验证页拒绝、X 噪音过滤、run 元数据即时显示、URL 可点击、平台图标包、翻译自动打标、安装后引导、Settings Form 重排、搜索启用、标签 chips、Brave 独立目录全链条拆分(修正共用目录的硬门禁违规)。三轮复审后终审 PASS 零回退。全量 346/346,gate 135/62,候选 loop9(DMG 328d5ae3…391ae9)READY_FOR_MANUAL_OPEN,交 Syc 继续总检。"
  source: Acceptance fix batch final review PASS 2026-07-19
  affects: [p0-release-candidate-goal]
