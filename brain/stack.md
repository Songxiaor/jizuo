---
slug: stack
title: Tech stack
role: tech-stack choices
updated: "2026-07-15T12:24:47"
---

# Tech stack

## 当前已落地栈

| domain | current choice | evidence | system consequence |
|---|---|---|---|
| Workspace | pnpm 11 workspace | root package | TypeScript 统一门禁，Swift 由脚本桥接 |
| Node runtime | Node >= 22.13 | root engines | 扩展构建依赖现代 Node |
| Browser extension | TypeScript 6.0.3 + WXT 0.20.27 + MV3 | browser package | Chromium 最小权限与 service worker |
| TS schema runtime | Ajv 8.17.1 + ajv-formats 3.0.1 | extension dependencies | 构建期静态 validator，避免 MV3 CSP 冲突 |
| macOS app | Swift 6 package, macOS 15 target | desktop package | 原生 App 与 Host；发布仍需稳定路径和 signing spike |
| UI | SwiftUI | `LinkDigestApp.swift` | 当前捕获与 BYOK 已落地；历史与导出待实现 |
| Transport | Native Messaging + Unix domain socket | Host/Transport | Chrome、Brave、Edge V0.1 工程门禁已关闭 |
| Contract | JSON Schema Draft 2020-12 + fixtures | `contracts/` | Swift/TypeScript 共享语言中立合同 |
| BYOK | URLSession + Swift Concurrency + Keychain | V0.2 acceptance | 单 OpenAI-compatible streaming、取消、错误与 secret hygiene |
| Storage binding | GRDB 7.11.1 exact | SQLite spike + Sol xhigh review | 只进入 Persistence Adapter；migration/备份/只读恢复门禁冻结 |
| SQLite engine mode | WAL + Online Backup API | persistence spike | 单写受控并发读；活跃库禁止直接 cp |

## 当前验证入口

- `pnpm check:web`：lint、typecheck、test、browser build、doctor。
- `pnpm check:swift`：contract sync、Swift tests/build、native-host 与进程 smoke。
- `pnpm sqlite:spike`：GRDB、migration、事务、WAL、备份、恢复与并发专项。
- `pnpm sqlite:benchmark:release`：隔离 10k Release 查询 benchmark。
- `bash ./scripts/check-swift-licenses`：GRDB exact pin、revision、resolved graph 与 MIT notice。
- `pnpm xcode:build`：当前在 Hana 外层 nested sandbox 下阻断，clean-room RC 前需补证。

## 许可与安全边界

- 商业闭源准备下，GPL/AGPL/非商业/UNKNOWN 不得合入。
- GRDB 只属于 Persistence target；Core、Application 和 UI 不暴露 binding 类型。
- API Key、Cookie、Token、正文和私人 URL 不进入普通日志、测试夹具或 Git。
- 扩展不申请 Cookie/history/host permissions，只处理主动触发当前页。

## 当前实施顺序

1. 冻结 `Task → ContentSnapshot → Run → Artifact`、UUID/UTC、幂等键、删除关系、终态状态与 Export projection。
2. 实现正式 migration 001、Repository Port/GRDB Adapter 和 Application service。
3. 重启恢复、历史列表、详情与删除。
4. Markdown/TXT/JSON 导出与原生 UX。
5. 稳定 Host、升级/卸载与 clean-room RC。

## 未关闭证据

- 正式四表 10k benchmark、确定性并发 overlap、真实存储失败注入和 checkpoint 推进证明。
- Host 稳定安装目录、资源共置、Developer ID、签名、公证与发布包。
- Xcode clean-room Debug/Release 与完整 Swift suite。
