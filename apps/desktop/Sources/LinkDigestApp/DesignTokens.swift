import SwiftUI

/// 间距、圆角、投影、动效的取值来源。
///
/// 立这套东西的理由，是审查时量出来的一组数字：界面里 padding 用了 21 种取值、
/// spacing 12 种、圆角 10 种，其中一半以上不是 4 的倍数，而且 6 和 7、9 和 10
/// 这样的相邻值同时存在。差 1pt 的间距不会被看成「精心安排」，只会累积成
/// 「没对齐」的模糊感——用户说不出哪里不对，只能得出「粗糙」这个判断。
///
/// 所以这里不是审美偏好，是**把「每处单独决定」换成「从一张表里取」**。
///
/// **本文件只定义，不替换任何现有取值。** 迁移在后续阶段逐屏进行，一次换一屏、
/// 换完看一眼，避免一次性全局替换把视觉打乱却没人发现。
enum DesignTokens {}

// MARK: - 间距

extension DesignTokens {
  /// 4pt 基数网格。
  ///
  /// 只有这 8 档。需要 6pt 或 10pt 时，答案是选 4 或 8、12，而不是加一档——
  /// 中间值正是当前这套界面失准的来源。
  enum Space {
    /// 2 — 图标与紧邻文字之间。唯一小于 4 的档，因为图标本身自带视觉边距。
    static let xxs: CGFloat = 2
    /// 4 — 行内元素之间。
    static let xs: CGFloat = 4
    /// 8 — 组件内部的常规间隔。
    static let sm: CGFloat = 8
    /// 12 — 相关元素之间。
    static let md: CGFloat = 12
    /// 16 — 卡片内边距、列表行内边距。
    static let lg: CGFloat = 16
    /// 24 — 区块之间。
    static let xl: CGFloat = 24
    /// 32 — 页面级留白。
    static let xxl: CGFloat = 32
    /// 48 — 空状态上下留白。
    static let huge: CGFloat = 48
  }
}

// MARK: - 圆角

extension DesignTokens {
  /// 四档 + 胶囊。
  ///
  /// 圆角是最容易失控的一项：当前有 1、6、7、9、10、14、18 这些值并存，
  /// 而 6 和 7 在屏幕上根本分不出来。
  enum Radius {
    /// 4 — 徽标、小标签。
    static let sm: CGFloat = 4
    /// 8 — 按钮、输入框。
    static let md: CGFloat = 8
    /// 12 — 卡片、弹层。
    static let lg: CGFloat = 12
    /// 16 — 大容器、Sheet。
    static let xl: CGFloat = 16
  }
}

// MARK: - 投影

extension DesignTokens {
  /// 投影只有四级，且**阴影颜色必须带底色色相**。
  ///
  /// 纯黑阴影压在暖色纸底上会发灰发脏；暖底要用暖阴影。所以这里不给死值，
  /// 而是给一个按主题底色调出来的构造器。
  struct Elevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    /// 0 — 不投影，靠 hairline 分隔。列表行、分区标题用这一档。
    static let flat = Elevation(radius: 0, y: 0, opacity: 0)
    /// 1 — 卡片。几乎察觉不到，只用来把卡片从画布上「托」起来一点。
    static let raised = Elevation(radius: 2, y: 1, opacity: 0.04)
    /// 2 — 弹层、菜单。
    static let floating = Elevation(radius: 12, y: 4, opacity: 0.08)
    /// 3 — 模态。
    static let modal = Elevation(radius: 32, y: 12, opacity: 0.12)
  }
}

extension View {
  /// 按主题底色染过的投影。
  ///
  /// `tint` 传当前主题的画布色：暖底得暖阴影，深色主题下则几乎只是加深。
  func designShadow(_ elevation: DesignTokens.Elevation, tint: Color) -> some View {
    shadow(
      color: tint.opacity(elevation.opacity),
      radius: elevation.radius,
      x: 0,
      y: elevation.y
    )
  }
}

// MARK: - 动效

extension DesignTokens {
  /// 四档时长。
  ///
  /// 全部要经 `reduceMotion` 判据——项目里已有 `historyUIAnimation(reduceMotion:)`
  /// 这个现成模式，新代码沿用它，不要各写各的曲线。
  ///
  /// **不设常驻循环动画。** 唯一的例外是骨架屏的呼吸，它已经单独接了
  /// reduce-motion 保护。
  enum Motion {
    /// 100ms — 选中、开关这类「立即」的状态变化。
    static let instant = Animation.linear(duration: 0.1)
    /// 180ms — hover、按下。
    static let quick = Animation.easeOut(duration: 0.18)
    /// 240ms — 展开、切换。界面默认档。
    ///
    /// 用 `snappy` 而不是 `easeOut`：它带一点回弹，在 macOS 上手感更接近
    /// 系统控件。项目原本的 `historyUIAnimation` 就是 snappy，token 跟着
    /// 现状走，而不是反过来逼一屏屏已经调好的动效迁就一条新规则。
    static let standard = Animation.snappy(duration: 0.24)
    /// 320ms — 模态出现/消失。
    static let slow = Animation.easeInOut(duration: 0.32)

    /// 开启「减弱动态效果」时的统一替身：保留状态变化，去掉过程。
    static let reduced = Animation.easeInOut(duration: 0.1)

    /// 按无障碍设置挑一条曲线。
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
      reduceMotion ? reduced : animation
    }
  }
}

// MARK: - 图标

extension DesignTokens {
  /// SF Symbol 的三档尺寸。权重统一 `.medium`。
  ///
  /// 和字号分开定义：图标尺寸和文字字号是两件事，之前混在一起用
  /// `.font(.system(size:))` 表达，导致审查时要逐处判断某个数字到底是
  /// 在调字还是在调图标。
  enum IconSize {
    /// 11 — 行内、列表行内的状态图标。
    static let inline: CGFloat = 11
    /// 14 — 工具栏、按钮。
    static let control: CGFloat = 14
    /// 17 — 区块标题旁。
    static let section: CGFloat = 17
    /// 32 — 空状态主图。
    static let empty: CGFloat = 32
  }
}

// MARK: - 窗口

extension DesignTokens {
  /// 窗口与分栏的尺寸下限。
  ///
  /// 记在这里而不是散在各 `frame(minWidth:)` 里：三栏的最小宽度互相牵制，
  /// 单独改一栏会让另一栏在窄窗口下被挤到不可用。
  enum Layout {
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 620

    static let sidebarMin: CGFloat = 180
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMax: CGFloat = 300

    static let listMin: CGFloat = 280
    static let listIdeal: CGFloat = 340

    static let detailMin: CGFloat = 420
    /// 阅读列「偏好」宽度：默认正文字号（16.5pt）下约 45 个汉字。首帧宽度未知时
    /// 回退到这里；默认 1200 窗口里详情列可用宽度通常更窄，真正画出来仍是可用宽度。
    ///
    /// 曾经是 680（约 41 字）。汉字是全宽字，一行字数就是「列宽 ÷ 字号」，41 正好
    /// 踩在中文长行的下限上——再短，一句话被切成三行，读起来发碎。45 是排版惯例
    /// 里中文正文的舒适区中段。注意上一版注释写的「约 65 个汉字」是错的，680 ÷ 16.5
    /// 只有 41。
    ///
    /// 正式列宽走 `readingColumnMaxWidth(availableWidth:bodySize:)`，不要只拿这个常数
    /// 当死上限——窗口拉宽后正文应跟着变宽。
    static let readingMaxWidth: CGFloat = 748

    /// 可读性绝对上限（默认字号）：再宽长行伤阅读。约 58 个汉字一行。
    /// 4K 全屏也停在这里，两侧继续留白。
    static let readingAbsoluteMaxWidth: CGFloat = 960

    /// 详情列正文左右内边距。列宽计算要扣掉两侧，和 `.padding(.horizontal, …)` 同源。
    static let readingHorizontalInset: CGFloat = 40

    /// 偏好行宽按正文字号等比缩放，保持「一行多少个字」不随字号变化。
    ///
    /// 比例与 `ResolvedReadingFont.scaledSize` 同源（`size / ReadingFontSize.default`）。
    static func readingMaxWidth(bodySize: CGFloat) -> CGFloat {
      readingMaxWidth * ReadingFontSize.clamped(bodySize) / ReadingFontSize.default
    }

    /// 绝对上限按正文字号等比缩放：字号大时允许更宽，每行字数仍受控。
    static func readingAbsoluteMaxWidth(bodySize: CGFloat) -> CGFloat {
      readingAbsoluteMaxWidth * ReadingFontSize.clamped(bodySize) / ReadingFontSize.default
    }

    /// 正文列宽：随详情列可用宽度增长，封顶在字号联动的可读上限。
    ///
    /// - `availableWidth` 是详情列全宽（含左右 inset）；这里扣除 `readingHorizontalInset * 2`。
    /// - 宽度未知（首帧 0）时回退到偏好宽度，与旧默认窗口观感接近。
    static func readingColumnMaxWidth(availableWidth: CGFloat, bodySize: CGFloat) -> CGFloat {
      let ceiling = readingAbsoluteMaxWidth(bodySize: bodySize)
      let preferred = readingMaxWidth(bodySize: bodySize)
      guard availableWidth > 0 else { return preferred }
      let usable = max(0, availableWidth - readingHorizontalInset * 2)
      return min(usable, ceiling)
    }

    /// 20 — 设置侧栏分类图标 chip 的边长。比页头同款 chip（`IconSize.empty`）小一档，
    /// 侧栏一行只有一个行高的空间，放不下页头那种大方块。
    static let settingsSidebarChip: CGFloat = 20
  }
}
