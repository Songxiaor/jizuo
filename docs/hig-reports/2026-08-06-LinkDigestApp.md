# HIG Audit Report

**Project:** 汲作 (LinkDigest)
**Date:** 2026-08-06
**Scope:** `apps/desktop/Sources/LinkDigestApp`
**Platform:** macOS（iOS 专用规则已排除，见末尾）
**Tool:** swiftui-hig-audit
**Files audited:** 53（22 view / 13 viewmodel / 1 theme / 1 app）
**Lines:** 26,747

## Summary

| Severity | Count | 状态 |
|----------|-------|------|
| Critical | 0 | — |
| Warning  | 3 | **全部已修（2026-08-06）** |
| Info     | 3 | 2 条已修，1 条判定不改 |
| **Total** | **6** | |

### 修复记录（2026-08-06，审计当天）

| 规则 | 处理 |
|---|---|
| TYP-01 | 23 处文字字号收编为 6 档语义字体 + `BadgeTypography.size`；半点字号清零 |
| MOT-01 | 5 处动画接上 reduceMotion；`CopyFeedback` 顺带消掉了 controller/view 的双重动画 |
| ACC-06 | 状态点改为 label（"总结状态"）+ value（"已总结"/"未总结"）分离 |
| ACC-01 | 补 7 处 accessibilityLabel（4 个列表状态徽标 + 3 个纯图标按钮），19 → 26 |
| BTN-01 | **判定不改**：7 处 onTapGesture 均为 macOS 标准交互，旁边有等价 Button |
| DRK-02 | **判定不改**：纯黑用在播放器/灯箱，属媒体表面标准 |

复核结果：动画点 10 个全部受 reduceMotion 保护；用户可见文件中残留的 `.system(size:)` 仅为 SF Symbol 尺寸、徽标常量与用户可调阅读字号。

**审计中修正的两次误判**（机械套规则会产生的噪音，记录备查）：
1. 123 处硬编码字号里 88 处在工作台，而 `ExperimentalFeatures.isOfferedToUsers = false`，用户不可见——真正要收的只有 35 处，其中 11 处还是 SF Symbol 尺寸而非文字排版。
2. `.help()` 缺 `accessibilityLabel` 初判 21 处，但其中多数挂在 `Label(文字, systemImage:)` 上，文字本身即可访问名称——真正缺失的只有 7 处裸 `Image`。

没有 critical。这个代码库在 HIG 合规上的底子比多数 SwiftUI 项目好：没有 `NavigationView` 遗留、没有硬编码 `Color(red:)`、语义字体是主体（253 处 vs 硬编码 123 处）、`contentShape` 28 处、macOS 该有的 `.help()` tooltip 43 处、空状态覆盖完整。

**下面按「用户现在看得见」和「工作台（当前不可见）」分开统计。** 混在一起会让问题看着比实际大一倍——`ExperimentalFeatures.isOfferedToUsers = false`，工作台那一整套用户点不到。

---

## Warning Findings

### TYP-01: 硬编码字号，字号体系失控

**Severity:** warning
**Detection:** grep + 分布分析

全库 123 处 `.font(.system(size:))`，**18 种不同取值**。按可见性拆开：

| | 处数 | 不同取值 |
|---|---|---|
| **用户可见**（History / Markdown / 设置 / 灯箱） | **35** | **14 种** |
| 工作台（TopicBoard/PieceDesk/MethodLibrary/HitLab/Workbench） | 88 | — |

用户可见部分的取值分布：

```
9(4)  10(1)  10.5(1)  11(8)  12(6)  12.5(2)  13(1)  13.5(1)
14(3) 15(2)  16(1)    30(2)  32(1)  40(1)
```

**问题不在「硬编码」本身**——macOS 不像 iOS 那样强依赖 Dynamic Type，正文之外用固定字号是可以的。问题在**小字区间挤了 8 种值，且出现三对半点差**：

```
10 / 10.5      差 0.5pt，肉眼分不出，却是两个独立的值
12 / 12.5
13 / 13.5
```

这说明字号不是从一套阶梯里选的，而是「感觉小了点就减 0.5」逐处调出来的。直接后果是同类信息在不同位置字号不一致，读者感觉不到具体哪里不对，只会觉得**界面不精细**。

半点字号出现位置：
```
HistoryContentView.swift:1212   10.5   列表行的时间
ArticleImageViewing.swift:418   12.5
ArticleImageViewing.swift:426   12.5
（其余 9 处在工作台）
```

**Fix:** 在 `AppearanceTheme.swift` 旁边立一套字号阶梯（例如 11 / 12 / 13 / 15 / 20 / 28），把用户可见的 35 处映射进去，消掉所有半点值。工作台那 88 处等它重新对外时再收。
**Effort:** moderate（35 处，需逐处判断该落到哪一档）

---

### MOT-01: 5 处动画未响应「减弱动态效果」

**Severity:** warning
**WCAG:** 2.3.3 Animation from Interactions

全库 12 处动画。`HistoryContentView` 的 7 处**全部正确**——都走了 `historyUIAnimation(reduceMotion:)`，这是很好的既有模式。漏网的 5 处：

```
CopyFeedback.swift:20      withAnimation(.spring(duration: 0.25))
CopyFeedback.swift:24      withAnimation(.easeOut(duration: 0.3))
CopyFeedback.swift:48      .animation(.spring(duration: 0.25), value:)
MarkdownPresentation.swift:1068  withAnimation(.easeInOut(duration: 0.25))
HistorySkeletonRow.swift:36      .animation(.easeInOut(duration: 1.1).repeatForever)
```

**最后一条是 2026-08-06 今天新引入的**（骨架屏），且是唯一的 `repeatForever` 无限循环——对前庭敏感用户风险高于一次性过渡动画。

**Fix:** 复用现成的 `historyUIAnimation(reduceMotion:)`，或在各自视图加
`@Environment(\.accessibilityReduceMotion)`，开启时跳过动画（骨架屏则退化为静态灰条）。
**Effort:** quick-fix

---

### ACC-06: 自定义状态控件未暴露 accessibilityValue

**Severity:** warning
**Detection:** grep（全库 0 处 `.accessibilityValue`）

有状态语义的自绘元素没有把「当前值」暴露给 VoiceOver。典型的是历史列表行的状态点：

```swift
// HistoryContentView.swift:1178
Circle().fill(isSummarized ? Color.green : Color.orange)
```

颜色承载了「已总结 / 未总结」，旁边有 `.accessibilityLabel`，但没有 `.accessibilityValue`。同类还有同步进度、运行状态。

**Fix:** 给这类元素加 `.accessibilityValue(isSummarized ? "已总结" : "未总结")`。
**Effort:** quick-fix

---

## Info Findings

### ACC-01: accessibilityLabel 覆盖偏薄（19 处 vs 318 个 identifier）

`accessibilityIdentifier` 有 318 处，但那是**给自动化测试用的，VoiceOver 不读**。真正的 `accessibilityLabel` 只有 19 处。考虑到界面上有 43 处 `.help()` tooltip（说明有大量纯图标控件），VoiceOver 用户拿到的信息比鼠标用户少。

**Fix:** 纯图标按钮补 `.accessibilityLabel`。`.help()` 的文案通常可以直接复用。
**Effort:** moderate

### BTN-01: 7 处 `.onTapGesture`（多数可接受）

```
ArticleImageViewing.swift:143,297   双击缩放
ArticleImageViewing.swift:227       点背景关灯箱
YouTubeEmbedPlayer.swift:100,201    双击进影院 / 点背景退出
MindMapSectionView.swift:196        点开灯箱
WorkbenchView.swift:225             选中卡片（工作台，不可见）
```

双击缩放和点背景关闭是 macOS 标准交互，且相邻位置都有等价的 `Button`。**不建议改**，记录备查。

### DRK-02: `Color.white` / `Color.black` 26 处（基本合理）

排除播放器和灯箱后只剩 4 处，其中 `AppearanceTheme.swift:120,121` 是深色主题里定义 hairline/badge，`HistoryContentView.swift:691` 是选中态白色叠加——都是正确用法。播放器/灯箱用纯黑是媒体表面的行业标准。仅 `WorkbenchView.swift:129` 的 `Color.white` 前景色可疑（工作台，不可见）。

---

## 通过的检查（摘要）

| 检查 | 结果 |
|---|---|
| NAV-01 NavigationView 遗留 | 0 处，用的是 `NavigationSplitView` |
| CLR-04 硬编码 RGB 颜色 | 0 处，全部走 `AppearanceTheme` 令牌 |
| LST-01 列表空状态 | 手写空状态完整（「还没有笔记」「还没有保存页面」「该分类下暂无内容」） |
| LAY-02 点击区域 | `contentShape` 28 处 |
| MOT-01（HistoryContentView 部分） | 7 处动画全部处理 reduceMotion |
| APP-13 Timer 泄漏 | 0 处 |
| FBK 错误呈现 | 有 `StorageErrorPresentation` / `V02ErrorPresentation` 分层体系 |
| macOS tooltip | `.help()` 43 处 |

---

## Recommended Fix Order

**Quick wins（各 5 分钟内）**
1. MOT-01：5 处动画接上 reduceMotion（先修今天新引入的 `HistorySkeletonRow.swift:36`）
2. ACC-06：状态点补 `accessibilityValue`

**Moderate（15–30 分钟）**
3. TYP-01：立字号阶梯，收编用户可见的 35 处（**这条对「精细度」感受影响最大**）
4. ACC-01：纯图标按钮补 accessibilityLabel，复用 `.help()` 文案

**不建议做**
- BTN-01 的 7 处 onTapGesture（macOS 标准交互）
- 播放器/灯箱的纯黑（媒体表面标准）
- 工作台的 88 处字号（当前不对用户提供，等它重新上线再收）

---

## 平台过滤说明

以下 iOS 专用规则类别在本次审计中标记为 N/A，未纳入统计：

- **触摸目标 44×44pt（LAY-01）** — macOS 是鼠标指针，标准不同
- **HAP-01..08 触觉反馈** — macOS 无 Taptic Engine（触控板除外，不适用于本 App）
- **INP-02 keyboardType / INP-09 密码键盘** — iOS 软键盘概念
- **APP-04 statusBar** — iOS 状态栏
- **LAY-07 iPad size classes / NAV-05 TabView ≤5** — iOS 导航范式
- **MOD-07 fullScreenCover / LST-06 refreshable** — iOS 手势与呈现方式
- **TYP-02 @ScaledMetric / Dynamic Type** — macOS 支持有限，仅在正文可缩放处适用（本 App 已通过 `ReadingFontSize` 自建字号偏好覆盖该需求）
