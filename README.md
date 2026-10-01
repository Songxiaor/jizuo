<div align="center">
  <img src="docs/marketing/icon.png" width="112" height="112" alt="汲作">
  <h1>汲作</h1>
  <p><strong>把收藏的文章和视频，变成读得完、找得回的资料。</strong></p>
  <p>汲于外，作于己。macOS 上的个人资料库，资料默认保存在你自己的电脑上。</p>
  <p>
    <a href="https://songxiaor.github.io/jizuo/">官网</a>
    ·
    <a href="https://github.com/Songxiaor/jizuo/releases/latest">下载 macOS 版</a>
    ·
    <a href="https://songxiaor.github.io/jizuo/privacy.html">隐私政策</a>
  </p>
  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2015%2B-black.svg" alt="macOS 15+">
    <img src="https://img.shields.io/badge/local--first-yes-success.svg" alt="local-first">
  </p>
</div>

## 汲作是什么

收藏很容易，读完很难：文章散在各个网站，视频没法很快看文字，过一阵连存在哪都忘了。

汲作把这几件事接成一条线：浏览器里点一下，正文、作者和出处就存下来；视频在本机转写成文字，再用你自己的模型校对、总结、翻译。自己写的笔记、备忘录和本地文件也放在一处。没有账号，没有开发者服务器，开源免费。

界面和操作演示见[官网](https://songxiaor.github.io/jizuo/)。

## 能做什么

| 功能 | 说明 |
|---|---|
| 一键保存 | 浏览器扩展支持 Chrome、Edge、Brave 等 Chromium 内核浏览器。弹窗先显示标题、作者、字数和时长，打开就知道这页存过没有，已存过的可以直接在汲作里打开。也可以把链接直接贴进 App |
| 评论抓取 | B 站、抖音、X、YouTube、知乎、小红书、Reddit 和论坛类网站，保存时可以带上评论（10 到 100 条），先勾选再保存；博主页批量保存时也能一起抓 |
| 博主与批量 | 添加一位博主，列出全部作品，挑几条一起保存 |
| 自有 / 外部 | 自己写下、录下的归「自有」（作），从网上收来的归「外部」（汲），判断错了右键就能改 |
| 本地导入 | 音频、视频只记住原文件位置，不复制第二份，文件挪了也能找回；导入时可以顺手排队转写。把文件夹拖进来会自动建一个同名合集 |
| 五道工序 | 录（转写）、校（校对）、摘（总结）、译（翻译）、图（脑图）。每道工序有一方篆书印，还没做是虚线印位，做完就盖上；哪道自动做在设置里一眼看清 |
| 本机转写 | 视频和音频在这台 Mac 上听写成文字，时间码挂在页边，点一下跳回那一秒。侧栏「待转写」列出还没有转写稿的内容 |
| 朱批 | 校对后的转写稿和原稿逐字比对，改动用朱色标在页边，随时可以切回原稿 |
| 总结、翻译、脑图 | 用你自己配置的模型服务（任一 OpenAI 兼容地址）。翻译逐段对照原文；脑图可以改样式、导出 SVG |
| 按意思搜 | 关键词结果后面附一组「意思相近」。模型在本机运行，第一次打开时下载一次（约 96 MB） |
| 合集 | 把相关内容收成一册，拖动排序 |
| AI 助手接入 | 让 Claude Code、Codex 这类助手读写资料库，权限逐项开关 |
| 导出与备份 | 单条导出 Markdown、纯文本、PDF、Word 或 JSON；整库随时备份、换回；「知识库同步」把资料导出成 Markdown 放进你自己的文件夹 |

## 内容来源

普通网页都能收。下面这些来源另外做了识别或专门抓取：

微信公众号、哔哩哔哩、抖音、小红书、知乎、微博、今日头条、掘金、豆瓣、X、YouTube、Reddit、Medium、Substack、GitHub、论坛类网站。

需要登录才能看的站点，在 App 自带的登录窗口里登录一次即可。网站结构会变，某一家能不能抓稳，以当下打开的页面为准。汲作只保存你主动提交、本来就有权查看的内容，不批量采集他人账号，不绕过登录、付费墙或访问限制。

## 数据和模型

- 原文、转写稿、总结、翻译、脑图、评论、标签、合集和历史都保存在本机资料库里。
- 视频和音频的转写默认在本机完成；图片文字用 Apple Vision 在本机识别。
- 总结、翻译、校对只把需要的文字发给你配置的服务商，第一次发往某个地址前会告诉你去向。
- 模型地址、密钥和模型名由你自己填，不绑死某一家；密钥存在 macOS 钥匙串，不会写进资料库、日志、导出文件或这个仓库。
- 软件不含额度、不抽成，模型费用直接和服务商结算。

完整的联网范围见[隐私政策](https://songxiaor.github.io/jizuo/privacy.html)。

## 安装

1. 在 [GitHub Releases](https://github.com/Songxiaor/jizuo/releases/latest) 下载安装包：Apple 芯片选 `…macOS-Apple-Silicon.dmg`，Intel 芯片选 `…macOS-Intel.dmg`，不确定就选通用的 `…macOS-Universal.zip`。安装包文件名是 `Jizuo`，就是汲作。
2. 当前版本还没有苹果开发者签名和公证，第一次打开会被系统拦一次：双击后弹窗点「完成」，再到「系统设置 → 隐私与安全性」最下面点「仍要打开」。
3. 要用总结、翻译时，在「设置 → 模型服务」填入你自己的服务。
4. 可选：在「设置 → 浏览器支持」打开扩展文件夹，在 Chrome、Edge 或 Brave 的扩展管理页打开开发者模式，加载这个文件夹。

系统要求与说明：

- 需要 macOS 15 及以上；苹果本机视频转写需要 macOS 26 及以上。
- 浏览器扩展和桌面应用在本机交接，不经过任何服务器。
- 从 v0.2.9 起可以在 App 里检查更新，有新版本仍要你确认才会安装；v0.2.8 及更早需要先手动升一次。升级前会自动备份资料库。
- 新电脑怎么装、扩展怎么连上，见 [`docs/新机测试指南.md`](docs/新机测试指南.md)。

对外叫汲作，仓库和代码里还留着早期名字 `LinkDigest`。

**English:** Jizuo (汲作) is a local-first macOS library for the articles, videos and posts you save. It captures pages you can already view from Chromium browsers (Chrome, Edge, Brave), transcribes audio and video on your Mac, and summarizes, translates and proofreads with your own OpenAI-compatible model provider. Everything stays on your Mac; no account, no developer server.

## 技术结构

```text
浏览器当前页面（Chrome / Edge / Brave）
  → TypeScript / WXT 浏览器扩展
  → Native Messaging + 版本化 JSON
  → SwiftUI macOS App
  → SQLite 本地资料库
  → 你自己配置的模型，或苹果本机能力
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

## 暂不提供

- 只有 macOS 版，没有 Windows、iPhone、iPad 版；浏览器扩展暂不支持 Safari 和 Firefox（这两个浏览器里可以把链接贴进 App 保存）。
- 没有账号、云同步、团队协作，也不提供托管的模型。想在手机上看，可以用「知识库同步」导出 Markdown，再用自己的同步方式。
- 不读取整个浏览器的 Cookie，也不会把密钥、Cookie 或 Token 写进这个仓库。

## 许可证

[MIT](LICENSE)
