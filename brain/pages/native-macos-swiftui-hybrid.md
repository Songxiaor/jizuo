---
id: native-macos-swiftui-hybrid
title: "macOS SwiftUI 与 Chromium 扩展混合架构"
category: decision
status: active
tags: [swiftui, appkit, extension, architecture]
created: "2026-07-13T23:39:38"
updated: "2026-07-15T11:58:08"
---

## compiled_truth

## 当前结论

LinkDigest P0 桌面 APP 使用 Swift + SwiftUI，Chromium 扩展使用 TypeScript + WXT + Manifest V3。V0.1 三浏览器工程门禁已经关闭：用户触发的当前页提取形成 `CaptureEnvelopeV1`，独立 `LinkDigestNativeHost` 处理 Chromium framing 与合同校验，再通过用户私有 Unix domain socket 交给正在运行的 APP。

Chrome 150、Brave 150 与 Edge 150 均有真实隔离浏览器证据。Chrome 与 Brave 的完整链路均为 20/20，p95 分别为 49.2 ms 与 34.9 ms。Edge 真实 Popup 已观察到 `Fixed Test Article / 68 个字符`；隔离 `user-data-dir` manifest 查找根问题修复后，真实 Edge service worker 经 Host 与 Unix socket 连续发送 20 次，`taskAccepted` 20/20、p95 24.5 ms。文档明确保留“修复后没有再次采集单次工具栏到 App 连续截图”这一证据缺口，但它不阻断当前工程关闭。

## 为什么保持独立 Host

浏览器 Native Messaging framing 与 SwiftUI 生命周期是不同职责。独立 Host 只做协议、上限、超时、错误映射和进程交接，APP 的 Application inbox 负责幂等接收和 UI 状态。未来替换安装、签名或公证结构时，不需要把浏览器协议塞入 View，也不需要改写合同。

APP 未运行时 Host 返回 `APP_UNAVAILABLE/open_app`，不保存正文排队，也不静默拉起 APP。扩展把 Host 缺失、Host 启动失败、未知通信失败和超时映射为不同稳定 code，不向 UI 回显底层原始错误。每个 accepted socket 独立处理并有读写超时；一个 stalled 半包不能阻塞后续连接。

## 安装与浏览器边界

- 测试 Host 必须把 executable 与 `LinkDigest_LinkDigestCore.bundle` 作为同一交付单元放在非 `Documents/Desktop/Downloads` 路径；只复制 executable 会缺失合同 Schema。
- `install-dev.sh` 默认 dry-run，要求显式浏览器；只处理 LinkDigest manifest，备份同名旧文件，并以 0600 同目录临时文件执行 rename 设计。
- Edge 自定义 `--user-data-dir` 必须是词法规范、现存、从文件系统根到 Profile 每个组件均非 symlink 的绝对路径；目标严格为直接子目录 `NativeMessagingHosts`。测试覆盖 profile/父级/中间 symlink、dot/dotdot、重复/尾随 slash、缺失 profile、错误浏览器和失败后范围外零写入。
- macOS 词法 `/tmp` 通常经过 symlink；传给安装脚本的隔离 Profile 应使用物理路径（如 `/private/tmp/...` 或 `pwd -P` 结果）。浏览器自身仍可使用 `/tmp/...`。
- 路径预检和多次复验缩小 TOCTOU 窗口，但不声称消除恶意并发换链；正式安装由受控目录权限、签名安装器或目录句柄方案继续收口。
- Brave 1.92.139 当前把用户级 Native Messaging 查找目录映射到 Chrome 目录；未来版本升级需重验。
- 默认 Edge 目标可由只读 `uninstall-plan.sh` 列出；隔离 Profile 按安装输出的精确 `TARGET/BACKUP` 人工回滚。
- 当前真实 manifest 指向测试 `/tmp` Host；正式稳定目录、Developer ID、签名、公证与发布包仍未关闭，不能把测试路径当发布方案。

## 当前边界

- SwiftUI View 不直接访问 socket、文件系统、数据库或模型 Provider。
- AppKit 只在 SwiftUI 实测能力不足时局部桥接。
- 扩展只申请 `activeTab`、`scripting`、`storage`、`nativeMessaging`，不申请 Cookie、history 或 `host_permissions`。
- 进程边界不记录正文、完整私人 URL、Cookie、Token 或 Key。
- V0.1 的合同、framing、超时、stalled client、三浏览器、20/20、Host 安装门禁与状态文档已经通过实施 Sol 和独立 Sol xhigh 审查。

## 关联

跨语言合同见 [[versioned-contracts-forward-migrations]]；本地与云边界见 [[hybrid-local-first-cloud-boundary]]；商业依赖边界见 [[commercial-license-boundary]]；最终交付门禁见 [[p0-release-candidate-goal]]。


## timeline

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "Created this page: macOS SwiftUI 与 Chromium 扩展混合架构"
  source: Syc confirmed Apple-only v0.1 direction 2026-07-13
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-13T23:39:38
  kind: decision
  summary: "确认 Apple-only 第一版采用 SwiftUI 主体与 TypeScript 扩展"
  source: Syc approval 2026-07-13
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-14T00:50:40
  kind: decision
  summary: "记录 V0.1 独立 Host 与 Unix socket 实施边界"
  source: LinkDigest V0.1 implementation and automated vertical smoke 2026-07-14
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-14T02:41:06
  kind: decision
  summary: "补录 Chrome/Brave 真实验收与 Native Host 安装门禁"
  source: LinkDigest V0.1 Chrome/Brave acceptance and Sol-reviewed installer gate 2026-07-14
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-15T11:19:01
  kind: evidence
  summary: "Edge 隔离 user-data-dir 会改变 Native Messaging 的用户级 manifest 查找根；install-dev.sh 已新增仅 Edge 可用的 --user-data-dir 显式目标，并由 native-host check 验证。真实 Edge 复验仍待完成。"
  source: "Microsoft Edge Native Messaging 官方 macOS 文档与 2026-07-15 本机复现"
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-15T11:45:48
  kind: decision
  summary: "校准 Edge 已安装与真实传输证据，并记录 symlink 路径安全复审仍阻断 V0.1 关闭。"
  source: Edge implementation and independent Sol review 2026-07-15
  affects: [native-macos-swiftui-hybrid]

- time: 2026-07-15T11:58:08
  kind: decision
  summary: "独立 Sol 复审通过，关闭 V0.1 三浏览器工程门禁并保留发布风险。"
  source: "Edge implementation + Sol xhigh re-review 2026-07-15"
  affects: [native-macos-swiftui-hybrid]
