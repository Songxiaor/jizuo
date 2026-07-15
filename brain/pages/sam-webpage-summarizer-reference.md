---
id: sam-webpage-summarizer-reference
title: "Sam Webpage Summarizer 对标参考"
category: reference
status: active
tags: [competitor, ui, local-first, macos]
created: "2026-07-15T12:32:27"
updated: "2026-07-15T12:32:27"
---

## compiled_truth

## 参考定位

Syc 指定 Sam Webpage Summarizer（Dine Creative Design LLC，`sammary.app`，App Store id `6769648029`）为 LinkDigest 的 UI 与产品架构对标。借鉴其信息层级、原生交互、内容排版和 local-first 边界；禁止复制品牌、图标、文案或像素细节，也禁止根据界面臆测未公开内部实现。

## 可验证 UI 特征

- macOS 原生双栏历史/详情结构，左栏搜索与历史列表，系统选中态。
- 历史行以来源、标题、URL、动作和时间形成高密度但克制的信息层级。
- 详情页先展示标题、来源 URL、动作、模型、时间、token/cost，再进入宽松可读的富文本结果。
- 原生 toolbar 承担分享、rerun、删除和显示控制；内容本身占主要视觉面积。
- 整体避免网页 dashboard 感。Ask follow-up 是 Sam 的后续交互参考，但不进入 LinkDigest P0。

## 可验证架构与隐私事实

Sam 公开说明采用 Apple 主 App + share extension，本地 app group 保存配置、模型选项与 archive，OpenRouter key 仅存系统 Keychain；无 Dine 账号、无自建请求后端、无 analytics/ads。用户主动总结或翻译时，readable text、URL、title、action、model/settings 发往 OpenRouter；token/cost 元数据可本地保存。支持单项删除、Markdown export、重复链接打开已有结果和显式 Rerun。

## LinkDigest 的借鉴边界

- 保持已经验证的 Chromium extension → Native Host → Swift App，不因对标改成 Safari/share extension。
- 对齐 local-first、Keychain、无自建后端、用户主动发送、archive、单项删除、rerun 与 usage/cost 元数据。
- delivery 幂等与用户 rerun 分离：传输重试不能重复创建；用户主动再次处理必须有明确的新 Run 语义。是否复用已有 Task 由正式领域模型根据 capture 身份与来源快照决定，不能只按 URL 粗暴全局去重。
- 正式 history/detail projection 应支撑来源、标题、URL、动作、模型、时间、token/cost 和结果状态。
- Q&A、Safari/iOS、云同步和账号不进入 P0。

## 来源

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
