<div align="center">
  <img src="site/assets/icon.png" width="112" height="112" alt="汲作 App 图标">
  <h1>汲作</h1>
  <p><strong>把网页和视频里的优质内容，变成能回看、能整理、能继续使用的个人资料。</strong></p>
  <p>macOS 原生应用 · 浏览器采集 · 视频转写 · AI 分析 · 本地资料库</p>
  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2015%2B-black.svg" alt="macOS 15+">
    <img src="https://img.shields.io/badge/local--first-yes-success.svg" alt="local-first">
  </p>
</div>

> 代码中的 `LinkDigest` 是早期工程名，当前产品名称为“汲作”。
>
> **English:** LinkDigest (product name 汲作) is a local-first macOS app + Chromium extension that captures the page you can already view, stores source text in on-device SQLite, and runs summarize/translate/export with your own OpenAI-compatible models (BYOK).

## 汲作是什么

汲作是一款面向内容创作者和深度学习者的 macOS 内容采集与学习工具。

它可以从用户正在浏览的网页和在线视频中取得正文、字幕或音频转写，再继续完成总结、翻译、转写稿整理和脑图生成。原文与处理结果会保存在同一条本地记录中，用户可以随时搜索、标注、复习或导出。

收藏链接很容易，重新找到并真正读完却很难。文章散在不同网站，视频无法快速浏览，临时复制到聊天工具里的原文和生成结果也常常分散在多个窗口。汲作把采集、理解、整理和复用放进一份可以长期保留的个人资料里。

## 一次完整使用

1. **收进汲作**。在 Chrome 当前页面点击扩展，或在 App 中粘贴公开链接。汲作会保存来源、标题、正文和可用的媒体信息。

2. **取得可阅读的原文**。普通网页提取正文。在线视频优先读取平台已有字幕，没有字幕时可使用 Apple 本机语音识别，或由用户确认后调用自己配置的在线转写服务。

3. **理解内容**。使用自己的 OpenAI-compatible 模型生成总结、翻译和脑图。转写稿可以先整理标点、分段和明显错字，再进入后续处理。

4. **留在自己的资料库**。原文、总结、翻译、脑图、笔记、摘录和标签保存在本机。用户可以按平台、时间、收藏或标签筛选，也可以搜索标题、正文和生成结果。

5. **继续使用**。单条内容可导出为 Markdown、TXT、PDF、DOCX 或 JSON。脑图支持 SVG 导出，也可以与原文一起导出为自包含 HTML。

## 现在能做什么

| 场景 | 当前能力 |
|---|---|
| 网页采集 | 从 Chrome 当前页面保存标题、正文、选区和来源，也可在 App 中添加公开链接 |
| 视频转写 | 优先使用已有字幕，并为无字幕视频提供本机或在线转写路径 |
| 内容理解 | 总结、翻译、转写稿整理、结构化分析和脑图生成 |
| 阅读与复核 | 原文、总结和翻译分开查看，保留来源，支持转写稿人工校对 |
| 个人资料管理 | 本地历史、全文搜索、平台筛选、标签、收藏、笔记和摘录 |
| 图片文字识别 | 使用 Apple Vision 在本机识别图片文字，图片不会交给在线模型 |
| 导出 | Markdown、TXT、PDF、DOCX、JSON，以及脑图 SVG 和自包含 HTML |

## 内容来源

汲作可以处理普通网页，并为下面这些内容来源提供识别或专用采集逻辑。

- YouTube
- Bilibili
- 抖音
- 小红书
- X
- 微信公众号
- GitHub
- 知乎
- 今日头条
- Medium
- Substack

浏览器接入目前以 **Google Chrome** 为已验证入口。平台网页会持续变化，专用采集逻辑的可用性以当前页面和最新测试结果为准。汲作只处理用户主动提交、已经有权查看的内容，不做批量账号采集，也不绕过登录、付费墙或访问限制。

## 数据与模型

汲作采用 local-first 设计。

- 原文、历史、标签、笔记和生成结果默认保存在本机 SQLite 数据库中。
- API Key 保存在 macOS Keychain，不写入数据库、日志、导出文件或 Git。
- 用户可以配置自己的 OpenAI-compatible Base URL、API Key 和模型。
- 首次向某个模型地址发送文字前，App 会显示数据去向并等待确认。
- Apple Vision 图片识别在本机完成。macOS 26 或更高版本可使用 Apple 本机视频转写。
- 使用在线总结、翻译或转写时，只把完成该操作所需的数据发送给用户选择的服务商。

项目不依赖汲作账号或自建云端才能打开本地资料。

## 当前状态

汲作是一个正在真实使用和持续迭代的个人产品。当前 GitHub Release 提供分开的 Apple Silicon 与 Intel 测试安装包。

- 桌面端最低支持 macOS 15。
- Apple 本机视频转写需要 macOS 26 或更高版本。
- Chrome 扩展通过 Native Messaging 与 macOS App 交接内容。
- 当前安装包使用 ad-hoc 签名，Developer ID 签名与公证尚未完成；首次打开需按 DMG 内说明在“系统设置 → 隐私与安全性”确认。
- v0.2.9 起支持应用内“检查更新”和周期检查；更新包使用 Ed25519 验签，安装仍需用户确认。v0.2.8 及更早版本需要先手动升级一次。
- 最新下载入口：[GitHub Releases](https://github.com/Songxiaor/jizuo/releases/latest)。新机安装与扩展连接见 [`docs/新机测试指南.md`](docs/新机测试指南.md)。

## 技术结构

```text
Chrome 当前页面
  → TypeScript / WXT 浏览器扩展
  → Native Messaging + 版本化 JSON
  → SwiftUI macOS App
  → SQLite 本地资料库
  → 用户配置的 AI 服务或 Apple 本机能力
```

| 目录 | 内容 |
|---|---|
| `apps/desktop/` | SwiftUI + 少量 AppKit 的 macOS App、核心业务、数据持久化和 Native Host |
| `apps/browser-extension/` | TypeScript、WXT、Manifest V3 浏览器扩展 |
| `contracts/` | Swift 与 TypeScript 共用的 JSON Schema 和测试夹具 |
| `docs/` | 产品范围、架构、验收和发布资料 |
| `site/` | 产品介绍页面 |

更多工程资料见 [`docs/PRD.md`](docs/PRD.md)、[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和 [`VERIFY.md`](VERIFY.md)。

## 本地开发

需要 Node.js 22.13 或更高版本、pnpm 11、Swift 6 和 Xcode 16 或更高版本。

```bash
pnpm install

# 构建浏览器扩展
pnpm browser:build

# 构建并测试 macOS 代码
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer pnpm swift:test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer pnpm swift:build:debug

# 运行仓库检查
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer pnpm check
```

更细的构建、Native Host 安装和验证步骤见 [`VERIFY.md`](VERIFY.md)。

## 项目边界

- 当前只面向 macOS，不包含 Windows、iPhone、iPad 或 Safari 版本。
- 不提供账号系统、云同步、团队协作或托管模型。
- 不读取整个浏览器 Cookie 数据库，不保存 API Key、Cookie 或 Token 到仓库。
