---
id: github-repo-source-adapter
title: "GitHub 仓库来源适配器与内容适配器方向"
category: decision
status: active
tags: [github, adapter, loop6.5, product]
created: "2026-07-17T15:31:18"
updated: "2026-07-18T13:48:40"
---

## compiled_truth

# 决定

新增 Loop 6.5(排在 Loop 6 日常可用 DMG 之后、命名检索与 Loop 7 之前):GitHub 仓库链接专属来源适配器。用户把 `github.com/owner/repo` 链接粘贴进 APP 即可总结/翻译,并展示 README 中的仓库内联图片。

# 产品意图(Syc 2026-07-17 原话要点)

APP 的目的是**学习沉淀**:用户刷到对自己有用的内容后丢进来,英文翻译成中文或其它可选语言;总结支持自定义 prompt,也可按默认模板。长期方向是"最好所有内容链接丢进来都可以总结"。

# 分阶段落地

1. **Loop 5 基线(零开发量)**:GitHub 仓库页作为普通公开网页走通用抓取/提取路径,样本集含 1 条 GitHub README 样本验证基线可用性。
2. **Loop 6**:自定义 prompt(默认模板+用户自定义)与翻译目标语言选择进入 BYOK UX 验收;Loop 6 结束的 local-test DMG 是"自用+发安装包给他人"的最低可交付形态。
3. **Loop 6.5**:GitHub 专属适配器——公开仓库 README 原文获取、Markdown 解析、内联图片绝对地址解析与本地缓存展示;同时确立 fetcher/CapturedDocument 协议上的"来源适配器"插件式接缝,作为后续 arXiv/博客等适配器模板。

# 边界

- 只做 README 内联图片的引用/本地缓存,不做通用媒体下载(与 PRD §5.2 一致)。
- 私有仓库需要 token,属于未来单独授权;P0 只做公开仓库。
- 不因未来适配器提前重构 Loop 5;协议接缝已足够。

相关:[[p0-release-candidate-goal]]、[[sam-webpage-summarizer-reference]]


## timeline

- time: 2026-07-17T15:31:18
  kind: decision
  summary: "Created this page: GitHub 仓库来源适配器与内容适配器方向"
  source: Syc conversation 2026-07-17
  affects: [github-repo-source-adapter]

- time: 2026-07-17T15:31:18
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: brain update-truth
  affects: [github-repo-source-adapter]

- time: 2026-07-18T12:58:55
  kind: decision
  summary: "Syc 批准 Loop 6.5 开工。主控设计决定:api.github.com/repos/{owner}/{repo}/readme 无认证获取(走既有安全传输与 SSRF 门禁)、错误走固定文案架构(404 仓库不存在/403+429 限流)、图片只缓存仓库相对路径与 githubusercontent 绝对地址(单图 5MiB/总数 20/image-* 校验/随任务删除)、外部 badges 占位不下载、来源适配器接缝只抽象接管判定+文档产出两件事。Terra 实施中。"
  source: Loop 6.5 kickoff 2026-07-18
  affects: [github-repo-source-adapter]

- time: 2026-07-18T13:48:40
  kind: evidence
  summary: "Loop 6.5 工程侧一轮通过:Terra 单轮实施(含自查关闭图片外域 redirect 与 RIFF/MIME 绕过)+同一 reviewer 复审 PASS 零阻断。261/261、gate 76/10、19 文件绑定、doctor 87/1/0;真实抽样 PowerToys/VS Code 成功、404 正确映射。候选 loop65-candidate-20260718(DMG abe33f3f…89ce1d)READY_FOR_MANUAL_OPEN,待 Syc 人工验收。非阻断遗留:崩溃残留 staging 无启动级清扫(维护项)。"
  source: Loop 6.5 review PASS 2026-07-18
  affects: [github-repo-source-adapter]
