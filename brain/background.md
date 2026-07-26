---
slug: background
title: Project background
role: project background
updated: "2026-07-24T23:15:08"
---

# Project background

## 定位

LinkDigest 是一款 macOS 原生、local-first 的链接理解工具。用户在 Chrome、Brave 或 Edge 中主动发送当前已打开页面，Mac APP 接收并保留可核查原文，后续使用用户自己的 OpenAI-compatible 模型连接完成总结、翻译、保存和导出。

仓库以持续交付可运行、可验证、可发布的软件为主。需要解释时结合当前代码和真实问题说明，但课程、术语表和学习记录不构成任务启动或完成门槛。

## 当前阶段

V0.1 的核心目标是证明“固定文章 → Chromium 扩展 → Native Messaging Host → SwiftUI APP”的跨进程交接链路，而不是一次性完成模型、历史、导出和正式发布包。

截至当前代码与文档：

- macOS 桌面端已采用 Swift Package，包含 `LinkDigestApp`、`LinkDigestNativeHost`、`LinkDigestCore`、`LinkDigestTransport`。
- 浏览器扩展位于 `apps/browser-extension`，使用 TypeScript + WXT + Manifest V3。
- `contracts/capture-envelope-v1.schema.json` 是 Swift 与 TypeScript 的跨语言唯一合同。
- Chrome 150 与 Brave 150 的真实浏览器链路已完成；Microsoft Edge 因本机未安装且需要外部软件授权，仍是 V0.1 浏览器矩阵唯一缺口。
- 当前 Native Host 测试 manifest 指向临时路径；正式 Host 稳定目录、Developer ID 签名、公证和安装包属于后续 release spike。

## 首要用户

第一版优先服务需要频繁阅读、研究和整理网页内容的个人创作者或研究者。他们关心：

- 当前网页正文是否来自自己已经合法打开的页面。
- 摘要或翻译是否能回到原文复核。
- API Key、原文和结果默认不经过 LinkDigest 云端。
- 失败时能知道是页面、扩展、Native Host、APP、模型还是存储层出了问题。

## P0 成功标准

P0 成功不是“云端规模化”，而是本机闭环可靠：

1. 用户能从 Chromium 当前页主动发送 URL、标题、正文、字符数和捕获证据。
2. Mac APP 能展示来源、正文、完整性和失败恢复动作。
3. 用户能配置自己的模型连接并获得总结/翻译结果。
4. 原文、运行记录和结果保存在本机 SQLite，秘密进入 Keychain。
5. 结果至少可导出为 Markdown/纯文本/JSON。
6. Cloud API 不存在或断网时，本地能力仍可使用。

## P0 非目标

- Windows、iOS、iPadOS 与 Safari 扩展。
- 账号、云同步、托管模型、付费和团队协作。
- Cookie 数据库读取、媒体下载、批量采集或绕过平台访问控制。
- YouTube/B 站字幕、小红书、抖音、X 等专用平台适配。
- 用 10 万/100 万容量假设推动当前云端或微服务建设。

## 系统性约束

短期收益是先用 Native Messaging + Unix socket 验证最危险的跨进程边界；长期成本是发布链路必须处理 Host 路径、签名、公证、浏览器 manifest、升级和卸载的一致性。这个成本不能靠扩展或 APP 单侧优化消失，必须在 release spike 中作为完整安装/恢复系统验证。
