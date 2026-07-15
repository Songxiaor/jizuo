---
slug: flow
title: Key flows
role: key flows
updated: "2026-07-15T16:56:54"
---

# Key flows

## 当前页 Capture 持久化流

```mermaid
sequenceDiagram
  participant U as User
  participant P as WXT Popup
  participant B as MV3 Background
  participant H as Native Host
  participant R as CaptureReceiver
  participant G as StorageWriteGate
  participant D as GRDB Repository
  participant UI as SwiftUI

  U->>P: Send current page
  P->>B: CaptureEnvelopeV1
  B->>H: Native Messaging
  H->>R: Unix socket frame
  R->>R: Decode + validate
  R->>G: Request exclusive Capture permit
  G->>D: acceptCapture transaction
  alt commit success
    D-->>G: TaskID + SnapshotID
    G-->>R: committed result
    R->>UI: CurrentCapture update
    R-->>H: taskAccepted
    H-->>P: strict correlated ACK
  else storage failure / gate closed
    G-->>R: stable storage error
    R-->>H: AppError, no UI/ACK success
  end
```

关键语义：并发 Capture 只有一个 permit holder。A 事务失败时 gate 先黏性降级，再拒绝已登记 waiter；后续请求不调用 Repository。duplicate 使用原 TaskID/SnapshotID。

## BYOK Run 持久化流

```mermaid
sequenceDiagram
  participant U as User
  participant A as AppViewModel
  participant O as ModelRunOrchestrator
  participant D as HistoryRepository
  participant K as Keychain
  participant M as Provider

  U->>A: Summarize / Translate
  A->>O: one RunID + idempotency key
  O->>D: queued commit
  O-->>A: starting
  O->>K: resolve API key
  O->>D: running commit
  O->>M: start stream
  M-->>O: deltas
  O->>O: secret holdback/redaction
  O->>D: partial commit
  O-->>A: streaming committed partial
  O->>D: terminal + Artifact commit
  O-->>A: completed/failed/incomplete/stopped
```

Stop 先撤销 authority 并取消 Provider/consumer，再等待 UI callback。每次 await 返回后重验 RunID；旧 Run、迟到 delta 与失败 callback 不能覆盖新 Run。

## Storage 失败与恢复

```mermaid
flowchart TD
  Open[Open Repository] --> Mode{accessMode}
  Mode -- writable --> Recover[recoverInterruptedRuns commit]
  Recover --> Gate[mark write-ready]
  Gate --> Server[start socket server]
  Mode -- read-only/error --> Reject[start rejecting receiver]
  WriteFail[Capture/Run persistence failure] --> Degrade[shared gate unavailable]
  Degrade --> NoWrite[future Capture rejected before Repository]
  NoWrite --> Restart[new bootstrap/recovery required]
```

## 下一允许阶段

02B 已关闭。下一阶段只能是 History Sidebar、详情、单项删除与重启恢复的浏览交互；当前尚未开始。导出、发布工程和其它扩展能力继续等待各自阶段。
