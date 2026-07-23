---
id: stable-native-host-delivery
title: "Stable Native Host 交付与事务边界"
category: decision
status: active
tags: [release, native-host, transactions]
created: "2026-07-16T20:28:16"
updated: "2026-07-17T02:47:11"
---

## compiled_truth

# 当前结论

Loop 4 r1 Stable Host package、r2 clean-room transaction、r3 cache-safe read-only preflight、r4a unsigned release unit 与 r4b local-test ad-hoc DMG 均已完成独立工程审查。

r4b candidate-07 的独立 reviewer 结论为 **PASS，P0/P1/P2 = 0/0/0**。主控随后以 no-clobber staging、candidate digest、`SHA256SUMS`、同目录改名与最终路径复验合同，把不可变 handoff finalize 到 `/Users/song/Documents/Codex/link-summary-app/release/LinkDigest-0.1.0-local-test/`。当前状态为 `READY_FOR_MANUAL_OPEN`，尚未由 Syc 手工启动 App。

# 最终本机测试证据

最终 DMG SHA-256 为 `51f2a6544c40f4d29bc66a062773f23e997f85cc74a49bd693f8c2759b1fe2a7`，candidate digest 为 `513b523c60f92824ad6a31b2c7f704a9375e0c7878c8fb5e40b81583271e19df`。r4b local gate 为 71 assertions + ContractTests 10/10；r3 101 与 r4a focused 74 回归 PASS。最终路径再次完成 `hdiutil verify`、readonly exact mount、mounted App/Host/unit/signature reverify、exact detach 与无 residual mount。

handoff 同目录包含 DMG、冻结 live-worktree source archive、GRDB 7.11.1 source archive、BUILD_MANIFEST、SOURCE_MANIFEST、SHA256SUMS、SOURCE_MAP、限制与恢复说明。源码快照精确对应 candidate-07 构建输入；复审/finalize 后只更新 live workspace 状态文档与 Brain，没有改变产品源码、配置、打包工具或 DMG。

# 产品边界

该 PASS 只表示 local-test ad-hoc build 可交给 Syc 手工打开。App/Host 不是 Developer ID，未 notarize/staple；自动化未启动 App，未安装 Native Host/manifest/receipt，未写真实 HOME/profile/Keychain/socket，未调用真实 Provider。Chrome/Edge 固定 manifests 仍 malformed，manual add/clipboard 仍 disabled。产品和公开发布继续 BLOCKED。关联 [[p0-release-candidate-goal]]。


## timeline

- time: 2026-07-16T20:28:16
  kind: decision
  summary: "Created this page: Stable Native Host 交付与事务边界"
  source: Loop 4 r1 PASS and r2 candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T20:28:51
  kind: decision
  summary: "冻结 r2 clean-room 事务候选合同与证据边界"
  source: Loop 4 r2 implementation and local gates 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T20:29:04
  kind: evidence
  summary: "r2 fast gate 86/86 与 r1 stable gate 56/56 通过；仅为 /private/tmp clean-room 候选证据，真实安装与最终复审未完成。"
  source: transaction and stable host local gates 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T20:59:03
  kind: evidence
  summary: "r2 首次最终独立复审 BLOCK，P0/P1/P2=0/3/0：Edge/install/package 重叠、r1 verifier 全局 SemVer 放宽、malformed journal 落到 exit 70。"
  source: Loop 4 r2 first final independent review 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T20:59:34
  kind: decision
  summary: "记录 r2 首次 BLOCK 后三项修复合同与待唯一 re-review 状态"
  source: Loop 4 r2 P1 remediation candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T20:59:44
  kind: evidence
  summary: "三项 P1 修复候选通过 r2 110/110 与 r1 compatibility 56/56；仅为 /private/tmp 本地证据，等待同一 reviewer 唯一 re-review。"
  source: Loop 4 r2 remediation gates 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T21:08:13
  kind: decision
  summary: "收口 r2 clean-room 最终 re-review PASS 与 r3 前授权边界"
  source: Loop 4 r2 final independent re-review 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T21:08:25
  kind: evidence
  summary: "同一独立 reviewer 唯一 re-review PASS，P0/P1/P2=0/0/0；PASS 仅覆盖 fixed canonical /private/tmp r2 clean-room。"
  source: Loop 4 r2 final independent re-review 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T21:36:43
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 read-only preflight candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T21:43:36
  kind: evidence
  summary: "r3 read-only preflight candidate gate PASS 40 assertions; ordinary report is BLOCKED by unfrozen release IDs/Team ID and absent release evidence. r2 110 and r1 56 clean-room gates completed in /private/tmp; real HOME metadata digest remains 7925d3e9…de1e4. doctor has one environment FAIL: local pnpm store lacks Ajv 8.18.0 index; no dependency install attempted."
  source: Loop 4 r3 local verification 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T21:44:58
  kind: evidence
  summary: "r3 gate expanded to 41 assertions and PASS: production CLI rejects forged test evidence in addition to policy/evidence/path/ownership/zero-write coverage. This is local candidate evidence only, not independent release PASS."
  source: Loop 4 r3 final local gate 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T21:54:50
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 P1 remediation candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T21:55:20
  kind: evidence
  summary: "r3 P1 remediation gate PASS 49 assertions: strict codesign Authority/TeamIdentifier/flags parsing, app/dmg/receipt path hardening, and permanent production release-unit/target-ownership blockers closed the review findings. Candidate remains BLOCKED and is not an independent release PASS."
  source: Loop 4 r3 P1 remediation local verification 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T22:14:37
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 reviewer BLOCK and P1/P2 remediation candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T22:15:13
  kind: evidence
  summary: "正式独立 reviewer BLOCK，P0/P1/P2=0/2/2：spctl 以任意 Notarized 子串判断，Apple subprocess 继承 caller 环境且无 timeout，lexical path 和 policy type fail-closed 不完整。禁止 release-ready 结论，只允许一次 P1/P2 remediation 后由同一 reviewer re-review。"
  source: Loop 4 r3 formal independent review 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T22:15:13
  kind: evidence
  summary: "r3 P1/P2 remediation candidate gate PASS 99 assertions：strict spctl parser、fixed Apple runner boundary、lexical raw path gate 与 policy type fail-closed 已本地验证；当前仍 BLOCKED，等待同一 reviewer唯一 re-review，不是 PASS。"
  source: Loop 4 r3 P1/P2 remediation local verification 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T22:16:57
  kind: evidence
  summary: "r3 P1/P2 remediation gate updated to PASS 100 assertions after additionally enforcing fixed-argv-only Apple runner. This supersedes the prior 99 assertion candidate evidence; status remains BLOCKED pending the same reviewer唯一 re-review."
  source: Loop 4 r3 final local remediation gate 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T22:16:57
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: Loop 4 r3 P1/P2 remediation candidate final local gate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T22:54:37
  kind: decision
  summary: "记录 r3 re-review BLOCK 0/1/0 与 cache-safe 101 项修复候选"
  source: Syc continue authorization and r3 cache remediation 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T22:55:06
  kind: evidence
  summary: "Syc 继续授权后的 cache-safe remediation gate PASS 101 assertions；spctl fixed argv 同时包含 --ignore-cache 与 --no-cache，普通 report 仍 BLOCKED，等待新的独立最终审查。"
  source: scripts/native-host/check-release-preflight.sh 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-16T23:01:38
  kind: decision
  summary: "收口 r3 cache-safe preflight 最终独立 PASS 0/0/0"
  source: r3 cache final independent review 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-16T23:03:56
  kind: evidence
  summary: "r3 cache-safe preflight 新独立最终审查 PASS，P0/P1/P2=0/0/0；主控独占复跑 101 assertions PASS，production report仍 BLOCKED，未执行真实 Apple artifact 查询或安装发布。"
  source: r3 cache final independent review and main rerun 2026-07-16
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-17T00:34:22
  kind: decision
  summary: "记录 r4a unsigned App-DMG release-unit 工程候选与真实 target probe 边界"
  source: Loop 4 r4a implementation candidate 2026-07-16
  affects: [stable-native-host-delivery]

- time: 2026-07-17T00:40:37
  kind: decision
  summary: "收口 r4a final local candidate audit 与门禁证据，仍等待独立 review"
  source: Loop 4 r4a final local candidate 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T01:09:49
  kind: decision
  summary: "记录 r4a 首次 review BLOCK 0/4/2 与集中 remediation candidate"
  source: r4a first independent review and remediation 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T01:09:49
  kind: evidence
  summary: "r4a 首次独立 reviewer BLOCK，P0/P1/P2=0/4/2；remediation dry-run 72 assertions与focused ContractTests 10/10完成，仍等待re-review。"
  source: r4a first review and local remediation dry-run 2026-07-17
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-17T01:17:53
  kind: decision
  summary: "记录 r4a 新 remediation audit 与只读聚焦 gate 候选证据"
  source: r4a remediation candidate verification 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T01:26:39
  kind: decision
  summary: "记录 r4a candidate-02 exact attach binding 与 74 条聚焦门禁"
  source: r4a final remediation candidate verification 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T01:37:17
  kind: decision
  summary: "收口 r4a unsigned release-unit 最终独立 PASS 0/0/0"
  source: r4a final independent re-review 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T01:37:17
  kind: evidence
  summary: "r4a 同一 reviewer 唯一 re-review PASS，P0/P1/P2=0/0/0；74 条聚焦门禁、ContractTests 10/10、真实 DMG exact detach 与无 residual mount 证据成立，产品继续 BLOCKED。"
  source: r4a final independent re-review and main verification 2026-07-17
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-17T02:13:13
  kind: decision
  summary: "记录 r4b local-test ad-hoc DMG implementation candidate 与产品 BLOCKED 边界"
  source: Syc r4b local-test authorization and implementation 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T02:28:39
  kind: evidence
  summary: "r4b candidate-07 已生成 exact local-test handoff；local gate 71 assertions 与 ContractTests 10/10 PASS，r3 101 与 r4a focused 74 回归 PASS；等待主控启动唯一独立 reviewer，产品/公开发布继续 BLOCKED。"
  source: r4b candidate-07 audit and local deterministic gate 2026-07-17
  affects: [stable-native-host-delivery, p0-release-candidate-goal]

- time: 2026-07-17T02:47:10
  kind: decision
  summary: "收口 r4b local-test 独立 PASS 与 READY_FOR_MANUAL_OPEN handoff"
  source: r4b independent review and finalization 2026-07-17
  affects: [stable-native-host-delivery]

- time: 2026-07-17T02:47:11
  kind: evidence
  summary: "r4b candidate-07 独立 reviewer PASS 0/0/0；主控安全 finalize 后从最终路径完成 DMG verify、readonly mount、App/Host/unit/signature reverify、/dev/disk7s1 exact detach 与无 residual mount。"
  source: r4b final handoff verification 2026-07-17
  affects: [stable-native-host-delivery, p0-release-candidate-goal]
