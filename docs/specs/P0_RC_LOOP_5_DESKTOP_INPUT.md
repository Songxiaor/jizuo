# P0-RC Loop 5：桌面手动链接输入

## 任务卡

- 用户场景：Syc 在没有浏览器扩展可用时，仍能主动粘贴一条公开网页链接，保存正文后从现有 History 入口选择总结或翻译。
- 本次只解决：手动 URL/点击读取剪贴板 URL → 受限公开 HTML → 最小正文提取 → 本机 SQLite/History → 当前 Capture 的一条链路。production transport 已固定为 peer-bound `Network.framework` 实现并有自动化证据；full suite 由主控稍后复跑，GUI 截图与真实公开网页确认仍 pending。
- 明确不做：Cookie/Profile 读取、登录绕过、后台剪贴板监听、自动模型调用、Schema/migration 改版、发布或真实网页验收。

## 场景 → 角色与交接 → 工作流 → 工具协同

```text
Syc 点击“添加链接”或“从剪贴板添加链接”
  ↓ URL 文本（剪贴板只在点击时读）
ManualLinkViewModel：输入、取消与人话错误
  ↓ 已主动提交的 URL
PeerBoundNetworkWebPageFetcher：连接已核验 numeric IP，TLS SNI/证书与 Host 仍使用原 hostname；每跳 redirect 重新绑定
  ↓ 有大小/类型上限的 HTML
MinimalHTMLExtractor：article → main → body，去脚本并提取文本
  ↓ CapturedDocument（manual_link，非 browser_capture）
CaptureIngestService + StorageWriteGate：SQLite 提交成功后才发布
  ↓ CurrentCapture + Task/Snapshot ID
HistoryContentView：揭示历史详情，保留现有总结/翻译按钮
```

`CaptureEnvelopeV1` 仍是浏览器 socket 的海关单；它只在 `CaptureReceiver` 校验和映射。`CapturedDocument` 是 APP 内部的货物单：手动链接明确标注为 `manual_link`，不会伪装为浏览器捕获，也不修改 wire Schema、fixtures 或 Migration001。

## 技术选择

| 候选 | 本次选择 | 原因 |
|---|---|---|
| 任意 WebView 直接加载页面 | 否 | 会带入页面执行、Cookie 与更难解释的权限边界。 |
| `Network.framework` peer-bound transport + 最小 HTML extractor | 是 | 每跳先核验 DNS/IP，再只连接 validated numeric IP；原 hostname 仍用于 TLS SNI、`SecPolicyCreateSSL`、system trust 与 HTTP Host，能避免 DNS rebind TOCTOU。 |
| `URLSession` ephemeral + 最小 HTML extractor | 否（历史/test-only） | 首次复审推翻：它不能证明实际 TCP peer 仍是已核验 IP。`URLSessionWebPageFetcher` 仅保留为 test-only legacy，不是 production fallback。 |
| 把手动页面伪造成 `browser_capture` | 否 | 会损坏来源真实性并把内部业务模型绑到跨语言 wire contract。 |

这次选择 peer-bound `Network.framework`，因为当前最重要的是把“允许的解析结果”绑定到实际连接对端；将来若需要登录页，重新评估 Chromium 当前页面扩展，而不是放宽抓取器。

## 安全、失败和恢复

- 仅 `http/https`；拒绝 userinfo、非 80/443 端口、localhost、IP literal 私有/保留/链路本地/组播地址和解析到这些地址的域名；redirect 只允许 policy allowlist 内目标，每跳重新 DNS/IP 检查，拒绝 `https → http` downgrade。
- production 用 `Network.framework` 直接向已核验 numeric IP 建立连接，不创建共享 `URLSession`、不发送 Cookie/cache/credentials；HTTPS 保留原 hostname 的 TLS SNI、`SecPolicyCreateSSL` 与 HTTP Host，使用 system trust，并调用 `SecTrustSetNetworkFetchAllowed(false)` 禁止 AIA/intermediate 经未绑定路径补取。`URLSessionWebPageFetcher` 是首次复审推翻的 test-only legacy，不可与 production 方案并列。
- 只接受 HTML/XHTML，限制 redirect、超时、响应字节和可保存正文；错误不回显 URL 或正文。
- 空正文或登录/动态壳提示改用浏览器扩展；取消只终止本次读取，不写 History。
- StorageWriteGate/Repository 失败时没有 CurrentCapture、没有 History 污染；成功后才关闭 sheet 并 reveal History，不自动发送给模型。

## 检查点与可选共同观察

| 检查点 | 组件职责 | 可观察结果 |
|---|---|---|
| 输入 | `ManualLinkViewModel` 把文本交给 fetch service | 空/错误剪贴板显示固定中文错误，不读取后台剪贴板。 |
| 安全读取 | `PeerBoundNetworkWebPageFetcher` 交出经过 policy 的 HTML | DNS 后只连接已校验的 numeric IP；私网、降级 redirect、非 HTML、超时或超大响应被拒绝。 |
| 入库 | `CaptureIngestService` 先取得 SQLite commit | 成功才出现 History 详情；点击其中既有总结/翻译才会进入 Provider 流程。 |

可选跟做（5–10 分钟）：在 Debug APP 的空 History 点击“添加链接”，先输入非 URL 观察本地错误，再点取消。不要输入登录页、内网地址或真实私密链接；这不是关闭任务的前提。

## 验收与回滚

- 自动测试覆盖 URL policy、extractor、手动 domain capture、共享 ingest 的提交后发布、saving 边界与浏览器回归；PeerBound transport 17/17（含 matching CA chain success、wrong-host/untrusted fail）。full suite 由主控稍后复跑；Debug build 是本轮门禁，Release 与 GUI 截图不在本轮执行范围。Loop 5 整体仍 **UI CONFIRMATION PENDING**，不能伪称 complete。
- 未新增依赖或许可证；未修改 `Migration001`、未新增 Migration002、未改浏览器 wire Schema/fixtures。
- 回滚只移除本次 Core/Adapter/App 输入链路和文档；不动用户数据库、release handoff、真实 Application Support、Cookie 或 Keychain。
