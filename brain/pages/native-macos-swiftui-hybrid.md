---
id: native-macos-swiftui-hybrid
title: "macOS SwiftUI 与 Chromium 扩展混合架构"
category: decision
status: active
tags: [swiftui, appkit, extension, architecture]
created: "2026-07-13T23:39:38"
updated: "2026-07-14T02:41:06"
---

## compiled_truth

## 当前结论

LinkDigest P0 桌面 APP 使用 Swift + SwiftUI，Chromium 扩展使用 TypeScript + WXT + Manifest V3。V0.1 已实现并验证：用户触发的当前页提取形成 `CaptureEnvelopeV1`，独立 `LinkDigestNativeHost` 处理 Chromium framing 与合同校验，再通过用户私有 `/tmp/linkdigest-<uid>.sock` Unix domain socket 交给正在运行的 APP。

Chrome 150 与 Brave 150 的真实隔离浏览器验收已经完成：固定文章可从 Popup 进入 SwiftUI；APP 未运行时返回 `APP_UNAVAILABLE/open_app`；APP 运行时显示标题、URL、捕获方式、完整性、字符数和正文。两者连续 20 次 Release 发送均为 20/20，无重复或崩溃；Chrome p95 为 49.2 ms，Brave p95 为 34.9 ms。Edge 本机未安装，真实 Edge 验收仍待明确安装授权。

## 为什么保持独立 Host

浏览器 Native Messaging 的 stdin/stdout framing 与 SwiftUI 生命周期是不同职责。独立 Host 只做协议、上限、超时、错误映射和进程交接，APP 的 Application inbox 负责幂等接收和 UI 状态。这样未来替换安装、签名或公证结构时，不需要把浏览器协议塞入 View，也不需要改写合同。

APP 未运行时 Host 返回 `APP_UNAVAILABLE/open_app`，不保存正文排队，也不静默拉起 APP。Host 未安装由扩展映射为 `NATIVE_HOST_NOT_FOUND/open_install_guide`。每个 accepted socket 独立处理并有读写超时；一个 stalled 半包不能阻塞后续连接。

## 安装与浏览器边界

- 测试 Host 必须把 executable 与 `LinkDigest_LinkDigestCore.bundle` 作为同一交付单元放在非 `Documents/Desktop/Downloads` 路径；只复制 executable 会缺失合同 Schema。
- `scripts/native-host/install-dev.sh` 默认 dry-run，并要求显式选择 Chrome、Brave 或 Edge；写入前只处理 `com.syc.linkdigest.v01.json`，拒绝 symlink，备份同名旧文件，再用 0600 同目录临时文件执行 rename 设计。
- Brave 1.92.139 在 macOS 上把用户级 Native Messaging 查找目录映射到 Chrome 目录，因此当前 `--browser brave` 与 Chrome 使用同一实际目标；未来 Brave 升级需要重新验证。
- `uninstall-plan.sh` 永远只读，只列出精确人工删除和恢复命令。
- 当前真实 manifest 指向 `/tmp` 验收 Host；正式稳定目录、Developer ID 签名与公证属于后续发布 spike，不能把临时路径当成发布方案。

## 当前边界

- SwiftUI View 不直接访问 socket、文件系统、数据库或模型 Provider。
- AppKit 只在 SwiftUI 实测能力不足时局部桥接；V0.1 未引入 AppKit bridge。
- 扩展只申请 `activeTab`、`scripting`、`storage`、`nativeMessaging`，不申请 Cookie、history 或 `host_permissions`。
- 进程边界不记录正文、完整私人 URL、Cookie、Token 或 Key。
- 自动化覆盖共享 fixtures、4 MiB framing、超时、stalled client 隔离、20/20 capture、Host 安装/卸载门禁和 Swift/Xcode Debug/Release。
- Edge 未验收前不把 V0.1 浏览器矩阵标记为完整；失败时先记录证据并比较 Helper/安装结构，不静默改回 Electron。

## 关联

跨语言合同见 [[versioned-contracts-forward-migrations]]；本地与云边界见 [[hybrid-local-first-cloud-boundary]]；商业依赖边界见 [[commercial-license-boundary]]。


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
