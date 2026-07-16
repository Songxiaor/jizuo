---
id: p0-release-candidate-goal
title: "P0 Release Candidate 最终交付目标"
category: decision
status: active
tags: [p0, release, workflow, quality]
created: "2026-07-15T11:27:22"
updated: "2026-07-16T19:00:04"
---

## compiled_truth

# 当前结论

Loop 1 History UI、Loop 2 单条 Markdown/TXT/JSON 导出、Loop 3 原生数据去向确认/连接测试与 Loop 4 r1 Stable Host package/clean-room 初装已按各自门禁收口。Loop 4 r1 最终独立 re-review PASS，P0/P1/P2 均为 0。

# Loop 4 r1 完成状态

config/native-host.json 是 Host 名称、版本、协议、macOS、架构、entrypoint、resource bundle 与 release extension ID 状态的 canonical config；release IDs 当前为空且明确 not-frozen。Release builder 只接受显式绝对且不存在的 output root，组装 arm64 Host、完整 bundle、package.json 与 SHA256SUMS。verifier 拒绝非普通文件、额外顶层项、权限/checksum/schema/metadata/arch 漂移。manifest renderer 对测试 IDs 排序去重，release IDs 未冻结时 fail closed。

clean-room installer 只允许 fixed canonical /private/tmp 下的 session/home，不读取 TMPDIR/tempfile.gettempdir，并要求精确 sentinel 与逐级无 symlink 路径。Host smoke 禁止 raw executable、skip-build 与 socket path override；packaged smoke 只接受先通过 verifier 的 package root。vertical/Host smoke 在任何 build 或子进程前固定并导出 TMPDIR=/private/tmp。

# 证据、残余与下一步

一次性源码副本删除 .build 后，verified package Host 的 offline/oversize/timeout smoke 与缺 bundle 负例通过。Darwin scope 外伪 clean-room 在 TMPDIR=$PWD/$HOME 时均于写入前拒绝；poisoned vertical smoke 不改变 scope 外 root、真实 LinkDigest HOME 或 Git status。实现与独立 re-review 均完整通过 56 项 deterministic check；Swift focused 54/54、显式跳过 Keychain 的完整 Swift 177/177、SwiftPM/Xcode 四目标、secret/diff/Brain/migration 门禁通过。

r1 只实现 initial install、同内容 noop 与进程正常错误路径的 best-effort 本事务 cleanup，不得称完整 rollback。SIGKILL/crash、同用户并发 TOCTOU、跨进程 lock、dirfd/openat 路径绑定和 transaction recovery 留给 r2。真实 HOME、真实浏览器 profile、升级、卸载、app/DMG、签名、公证和发布未执行，仍需 Syc 明确授权。下一阶段是 r2 Upgrade + uninstall + rollback 的只读规划与 clean-room 工程。


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
