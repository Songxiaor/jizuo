---
slug: flow
kind: root-page
title: Key Flows
updated: "2026-07-14T12:13:32"
---

# Key Flows

## V0.1 已实现：当前页发送到 SwiftUI

```mermaid
sequenceDiagram
  participant U as User
  participant P as WXT Popup
  participant B as MV3 Background
  participant C as Injected Capture Function
  participant V as TS Validator
  participant H as LinkDigestNativeHost
  participant S as Unix Socket
  participant A as LinkDigestApp
  participant UI as SwiftUI

  U->>P: Open popup on current tab
  P->>C: executeScript(extractPageInIsolatedWorld)
  C-->>P: title, url, text, characterCount, method
  P-->>U: Show title and character count
  U->>P: Click send
  P->>B: runtime message send-current-page
  B->>C: executeScript again
  C-->>B: ExtractedPage
  B->>V: Build and validate CaptureEnvelopeV1
  V-->>B: ok or stable error code
  B->>H: browser.runtime.sendNativeMessage
  H->>H: Read Chromium frame, validate schema/invariants
  H->>S: Send validated JSON to /tmp/linkdigest-uid.sock
  S->>A: accepted client frame
  A->>A: CaptureInbox idempotency check
  A->>UI: MainActor state update
  A-->>H: taskAccepted
  H-->>B: NativeResponse frame
  B-->>P: NativeResponse
  P-->>U: Show sent or error/action
```

当前实现重点在交接可靠性：Popup 与 APP 会展示标题、URL、捕获方式、完整性、字符数和正文；还没有创建持久化 Task、模型 Run 或导出 Artifact。

## V0.1 错误与恢复流

```mermaid
flowchart TD
  Start[User clicks send] --> Capture{Can extract text?}
  Capture -- no --> ContentError[CAPTURE_CONTENT_EMPTY / retry]
  Capture -- yes --> Validate{Schema and invariants valid?}
  Validate -- no --> ProtocolError[Stable protocol error]
  Validate -- yes --> Host{Native Host installed?}
  Host -- no --> InstallGuide[NATIVE_HOST_NOT_FOUND / open_install_guide]
  Host -- yes --> App{App socket reachable?}
  App -- no --> OpenApp[APP_UNAVAILABLE / open_app]
  App -- timeout --> Retry[NATIVE_MESSAGE_TIMEOUT / retry]
  App -- yes --> Accepted[taskAccepted]
```

恢复边界：Host 不排队正文、不静默拉起 APP、不写业务数据。这个选择让失败更可解释，但会把“用户是否已打开 APP”变成真实工作流的一部分，后续 UI 需要把它讲清楚。

## 后续 P0 本地理解流

```mermaid
sequenceDiagram
  participant U as User
  participant A as SwiftUI App
  participant O as Task Orchestrator
  participant K as Keychain
  participant M as Provider Adapter
  participant D as SQLite
  participant E as Exporter

  U->>A: Choose summarize / translate
  A->>O: Create Run for current ContentSnapshot
  O->>K: Resolve API key by secret reference
  O->>M: URLSession streaming request
  M-->>O: Stream tokens or provider error
  O->>A: Progress and partial result
  U-->>O: Optional stop / retry
  O->>D: Save Task, Snapshot, Run, Artifact
  U->>E: Export Markdown/TXT/JSON
  E-->>U: User-chosen file
```

## 真实工作流与文档工作流的差异

文档中的 P0 完整循环包括 BYOK、SQLite、Keychain、历史和导出；当前代码中的真实循环停在“当前页正文进入 SwiftUI”。这不是问题，但它影响排期：如果直接开始 UI 打磨，会掩盖更高风险的 Provider streaming、SQLite migration、Keychain failure 和 release install 恢复路径。

## 系统性影响

短期收益是先把最脆弱的跨进程链路变成可测证据。长期成本是用户可见流程跨越浏览器扩展、Host、APP、后续 Provider 和本地存储五个边界；任一边界失败都必须保留稳定错误代码与恢复动作。否则局部优化，例如只让 Popup 显示“失败”，会把系统调试成本转嫁给用户和后续支持。
