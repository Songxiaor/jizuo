---
slug: mindmap
kind: root-page
title: Feature Mindmap
updated: "2026-07-14T12:13:32"
---

# Feature Mindmap

```mermaid
mindmap
  root((LinkDigest))
    V0.1 capture bridge
      WXT popup
        current tab preview
        character count
        send action
      DOM extraction
        selection first
        article/main/body fallback
        no cookie database
      Native Messaging
        com.syc.linkdigest.v01
        4-byte little-endian framing
        4 MiB frame limit
        10s timeout
      SwiftUI receiver
        socket server
        idempotent inbox
        current capture display
      Browser acceptance
        Chrome passed
        Brave passed
        Edge pending authorization
    Contracts
      JSON Schema root source
      TypeScript static Ajv validator
      Swift bundled schema validator
      shared fixtures
      semantic invariants
      forward-compatible optional fields
    P0 local core
      BYOK provider
        OpenAI-compatible base URL
        model name
        URLSession streaming
        stop and retry
      Secrets
        Keychain API key
        no plaintext fallback
      Local history
        SQLite tasks
        content snapshots
        runs
        artifacts
        forward migrations
      Export
        Markdown
        plain text
        JSON
    macOS native product
      SwiftUI shell
      native sidebar/detail
      settings
      commands
      AppKit bridges only when proven
    Reliability and recovery
      explainable AppError
      app unavailable recovery
      host install guide
      timeout handling
      partial-result preservation
      read-only database recovery
    Release system
      stable Host location
      resource bundle co-install
      Developer ID signing
      notarization
      browser manifest install/uninstall
      clean upgrade path
    Learning track
      task template
      glossary
      learning log
      scenario-role-handoff explanations
      no exam gate
    Deferred
      Windows
      iOS and iPadOS
      Safari extension
      accounts and sync
      managed AI quota
      media adapters
      batch collection
      cloud capacity
```

## 当前功能重心

当前仓库的实际功能重心是 V0.1 capture bridge：从用户主动点击扩展，到 SwiftUI 显示当前页面正文。P0 的 BYOK、SQLite、Keychain、历史和导出已经在 PRD/Architecture 中定界，但尚未进入当前代码闭环。

## 系统性影响

功能树的上半部分是“交接与恢复系统”，下半部分才是“理解与导出产品”。短期如果跳过 Edge 和安装恢复去做模型功能，用户会更早看到价值；长期代价是每次真实浏览器、Host 路径或签名策略变化都会污染模型/历史调试，导致问题难以定位。因此当前顺序应继续先关闭 capture bridge 的浏览器矩阵，再进入 BYOK。
