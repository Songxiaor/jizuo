# 交接 · 4567 落地批次 · 2026-09-01 15:50

按建议顺序推进：**Share 深抓 → 桌面 Host 软门控 → Mac 代转写合同 → App 内会话抓取**。

## 已落地

### 1) Share 深抓（5A）
- `SharePreprocess.js`：Safari 分享时抽当前页 title/url/text
- Share Extension 读 property list + HTML；正文标「【来自当前页】」，导入不再盲抓
- 单测：`ShareDeepCapture` / 导入保留正文

### 2) 桌面扩展 Host（6）
- `captureSendBlockReason`：登录墙/SPA/导航误判时，**有选区或正文≥200 字仍可发送**
- 硬失败（安全验证等）仍拦截
- vitest：`capture-send-gate.test.ts` 3 PASS

### 3) Mac 代转写（4A）合同
- `SyncNoteCard.transcriptionRequestedAtMilliseconds` + CloudKit 字段
- iOS 详情「请 Mac 转写」排队
- Mac Companion 同步：导入 History + 写排队状态；History 导出本机转写快照 → `transcript` 回写手机（需 CloudKit 真通）

### 4) App 内 WKWebView 会话抓取（5B）
- `SessionCaptureSheet`：新建链接 →「应用内打开抓取」
- 默认小红书；用户可登录后「抓取本页」；Cookie 仅本 WebView

## 验证

```text
apps/ios NotesViewModelTests PASS（含 Share 深抓）
apps/browser-extension capture-send-gate.test.ts 3 PASS
```

## 你怎么验

1. **Safari** 打开已登录页 → 分享 → 汲作 → 正文应带「【来自当前页】」
2. **桌面扩展**：SPA/易误判页若已有长正文或选区，应能保存到汲作
3. 手机详情点「请 Mac 转写」→（CloudKit 通后）Mac 同步 → 历史里打开「本机转写」→ 再同步回手机
4. 新建链接 → 应用内打开抓取 → 登录后抓本页

## 仍依赖人工

- 付费 Apple Developer（CloudKit 真同步，Mac↔手机转写闭环）
- 真机点一遍 Safari Share / 会话抓取
