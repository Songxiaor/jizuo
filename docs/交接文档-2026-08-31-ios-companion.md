# 交接文档 · iOS Companion 今晚批次 A–H（2026-09-01）

## 决策（已定，待 Brain CLI 恢复后写入）

本机 `scripts/brain` 找不到 `brain-page` 的 `brain.mjs`，**未能写入 Project Brain**。恢复 CLI 后请补：

1. **reversal**：`hybrid-local-first-cloud-boundary` / 已归档的 `selective-encrypted-sync`——开启 Mac ↔ iOS **CloudKit 私有库**同步；无 LinkDigest 账号；API Key 不同步。
2. **新页面**：`ios-companion-cloudkit-sync`。

## A–H 今晚结果

| 任务 | 结果 | 证据 |
|---|---|---|
| **A** Mac 带 entitlements 部署 | **部分完成** | `build-and-deploy-local.py --replace` 成功 → `/Users/song/Applications/汲作.app`。挂上 iCloud entitlement 后 **launchd 163 起不来**（本机无可用 Mac 开发描述文件 / Personal Team 不支持 Mac iCloud）。已改回 **ad-hoc 无 iCloud** 可启动；脚本也不再在 ad-hoc 上挂受限 entitlement。投影已有 `companion-note-cards-v1.json`（约 326 条 link）。 |
| **B** iOS 真机编签安装 | **安装成功 / 启动待信任** | 带 CloudKit 时 Personal Team：**不支持 iCloud capability**，无法出 profile。现用空 entitlements 编过：`Apple Development: 8617836997232`，`devicectl install` 成功。启动被系统拒：需在 iPhone **设置 → 通用 → VPN 与设备管理**信任该开发者（Apple 安全门，CLI 无法代点）。完整 CloudKit 能力见 `App/LinkDigestIOS.CloudKit.entitlements`。 |
| **C** 双端 CloudKit 实同步 | **阻塞** | 根因同一：Personal Team **不支持 iCloud**；Mac ad-hoc 也不能带 CloudKit 启动。代码路径与 Fake 推拉已测通；**真云同步需付费 Apple Developer Program**。 |
| **D** 链接自动抓取 | **完成** | `LinkHTMLExtractor` + `LinkPageFetcher`；Compose 空正文自动抓。 |
| **E** BYOK 总结 | **完成** | Keychain + OpenAI-compatible；详情「总结」。 |
| **F** 同步状态 UI | **完成** | 列表顶状态 + 立即同步；启动自动 sync。 |
| **G** Mac summary 写回 | **完成** | `applyLinkSummaryIfNeeded`：link + 非空 summary → completed summarize run/artifact；相同正文跳过。 |
| **H** 交接收口 | **本文** | |

## 本批代码要点

### Shared
- `SyncNoteCard` / CloudKit / `SyncNoteCardIdentity` / `LocalJSONNoteCardStore`

### iOS（D/E/F）
- 抓取、BYOK、同步条：见 `apps/ios/Sources/LinkDigestIOS/`
- 真机临时：`LinkDigestIOS.entitlements` 为空；CloudKit 目标：`LinkDigestIOS.CloudKit.entitlements`

### Mac
- 映射 / 桥接 / `CompanionNoteSyncCoordinator` / 设置「手机同步」
- G：`HistoryCompanionNoteBridge.applyLinkSummaryIfNeeded`
- Entitlements 文件保留；**日用 ad-hoc 部署不挂 iCloud**

## 验证（本机已跑）

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
packages/LinkDigestShared SyncNoteCardTests → 15/15
apps/desktop HistorySyncNoteCardMappingTests|HistoryCompanionNoteBridgeTests → 10/10
apps/ios swift test → 12/12
Mac 部署 → deployed App: …/汲作.app（随后去掉 iCloud entitlement 才可启动）
iOS 模拟器 → BUILD SUCCEEDED + launch
iOS 真机 → BUILD SUCCEEDED + install；launch 待「信任开发者」
```

## 明确下一步（需你确认花钱/点一次信任）

1. **付费 Apple Developer Program（$99）** → 才能真开 `iCloud.com.syc.linkdigest`，完成 C。
2. 真机：设置里信任 `Apple Development: 8617836997232` 后，我可再远程 launch 验收 D/E/F UI（无需再编）。
3. Share Extension（原 V1，排在 CloudKit 真通之后更稳）。
4. Brain CLI 恢复后写决策页。

## 已知限制

- Personal Team：无 iCloud；真机每次新证书可能要再信任。
- Mac 日用包：ad-hoc 无 CloudKit entitlement（否则起不来）。
- 链接抓取简易 HTML；登录墙/SPA 弱。
- BYOK 非流式；Key 仅本机 Keychain。
- 全量 CK 拉取，无增量 token。
- 口述 = 系统听写。
