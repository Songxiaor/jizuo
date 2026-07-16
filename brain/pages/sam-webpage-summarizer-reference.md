---
id: sam-webpage-summarizer-reference
title: "Sam Webpage Summarizer 对标参考"
category: reference
status: active
tags: [competitor, ui, local-first, macos]
created: "2026-07-15T12:32:27"
updated: "2026-07-16T12:41:57"
---

## compiled_truth

## 参考定位

Syc 指定 Sam Webpage Summarizer（Dine Creative Design LLC，`sammary.app`，App Store id `6769648029`）为 LinkDigest 的 UI 与功能对标。2026-07-16 的最终确认反转了旧的“禁止复制像素细节”边界：用户提供的 1100×760 空/有内容截图现在是 History 壳层、分栏、间距、字体层级、列表密度、toolbar 和内容排版的像素级视觉真相源。

像素级参考不等于复制品牌。LinkDigest 必须保留自己的名称、产品文案、数据流和功能范围；不得复制 Sam 名称、Logo、专有图标、美术、内容资产或未公开内部实现。通用 macOS 布局、系统控件与 SF Symbols 可以按参考位置和节奏实现。

## 可验证 UI 特征与 02C 结果

- macOS 原生双栏历史/详情结构，1100×760 窗口，约 340pt Sidebar，顶部 320×28 搜索框与系统选中态。
- 历史行以来源图标、标题、URL、动作和时间形成高密度但克制的信息层级；正式分页使用 keyset cursor。
- 详情页先展示约 30pt 标题、来源 URL、两行紧凑的动作/模型/时间/token/cost/status 元数据，再进入宽松可读的结果正文。
- 原生 toolbar 承担分享、rerun、删除和格式位置；02C 只有删除接业务，其他控制按已确认范围显示为禁用。
- 空状态、删除确认、loading、阻断错误与 future-schema 只读状态均使用 macOS 原生控件；只读态说明原因、数据未修改、禁用范围与升级恢复动作。
- 02C 已在主仓库保留既有总结、翻译、停止、流式结果和 Provider 设置；current Capture 与 History 共享同一 Task/Run 数据，不形成互不相认的第二套界面。
- Design QA 使用同尺寸、同状态的同屏比较，最终没有剩余 P0/P1/P2 视觉问题；证据位于 `docs/evidence/SYC_64_STAGE_2/` 与根 `design-qa.md`。

## 可验证架构与隐私事实

Sam 公开说明采用 Apple 主 App + share extension，本地 app group 保存配置、模型选项与 archive，OpenRouter key 仅存系统 Keychain；无 Dine 账号、无自建请求后端、无 analytics/ads。用户主动总结或翻译时，readable text、URL、title、action、model/settings 发往 OpenRouter；token/cost 元数据可本地保存。支持单项删除、Markdown export、重复链接打开已有结果和显式 Rerun。

## LinkDigest 的借鉴边界

- 保持已经验证的 Chromium extension → Native Host → Swift App，不因对标改成 Safari/share extension。
- 对齐 local-first、Keychain、无自建后端、用户主动发送、archive、单项删除、rerun 与 usage/cost 元数据。
- delivery 幂等与用户 rerun 分离：传输重试不能重复创建；用户主动再次处理必须有明确的新 Run 语义。是否复用已有 Task 由正式领域模型根据 capture 身份与来源快照决定，不能只按 URL 粗暴全局去重。
- `HistoryViewModel` 只接收 projection，不持有 GRDB/SQL；异步请求用 generation/request identity 拒绝旧回写。删除确认冻结请求时 Task ID，生成中 Task 的保护 ID 由真实 RunID→TaskID 绑定，不能跟随之后到来的 current Capture 漂移。
- future-schema Repository 只交给 History 浏览；Capture、Run 与 Delete 继续拒写。migration 001 已冻结，02C 不修改 schema。
- Add/Paste/Search/Share/Rerun/Format、Markdown/TXT/JSON Export、Q&A、Safari/iOS、云同步和账号不因像素参考自动进入 02C；功能必须由后续明确范围与验收门禁开启。

## 来源

- Syc 提供的 Sam 空/有内容截图与像素级确认，2026-07-16
- https://sammary.app/
- https://sammary.app/privacy
- https://dinehq.com/news/sam/
- Apple App Store 公开页面与版本说明

## 关联

产品目标见 [[p0-release-candidate-goal]]；local-first 边界见 [[hybrid-local-first-cloud-boundary]]；持久化边界见 [[sqlite-grdb-persistence-boundary]]。


## timeline

- time: 2026-07-15T12:32:27
  kind: decision
  summary: "Created this page: Sam Webpage Summarizer 对标参考"
  source: Syc benchmark designation and public Sam materials 2026-07-15
  affects: [sam-webpage-summarizer-reference]

- time: 2026-07-15T12:32:27
  kind: decision
  summary: "记录 Syc 指定的 Sam UI/架构对标边界与公开事实。"
  source: "Syc + Sam public website/privacy/App Store 2026-07-15"
  affects: [sam-webpage-summarizer-reference]

- time: 2026-07-16T12:01:04
  kind: decision
  summary: "反转旧的非像素边界：按 Syc 最终确认，将 Sam 空/有内容截图作为 LinkDigest 原生 History UI 的像素级布局参考，同时继续禁止复制品牌、Logo、专有美术和内容资产。"
  source: "Syc explicit pixel-level confirmation + SYC-64 implementation and visual evidence 2026-07-16"
  affects: [sam-webpage-summarizer-reference]

- time: 2026-07-16T12:41:57
  kind: evidence
  summary: "按既有 toolbar 顺序在详情分享位置接入三格式导出菜单，保持 Sam 1100x760 History 壳层与原生外观，不扩大其他功能范围。"
  source: Loop 2 implementation 2026-07-16
  affects: [sam-webpage-summarizer-reference, p0-release-candidate-goal]
