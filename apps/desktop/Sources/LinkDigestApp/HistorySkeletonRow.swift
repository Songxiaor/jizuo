import SwiftUI

/// 历史列表载入时的占位行。
///
/// 替掉整屏转圈：转圈只说明「在忙」，但它占的空间和真实内容毫无关系，
/// 内容一到位整个列表会突然撑开跳一下。占位行照 `HistoryRowView` 的骨架
/// 画——状态点、标题、摘要、时间各占一块——载入完成时只是灰条变成字，
/// 布局不动。
///
/// 尺寸跟着真实行走：状态点 7×7、标题 13pt、摘要 12pt、时间 10.5pt。
/// 改 `HistoryRowView` 的排版时这里要一起改，否则「不跳」这个前提就没了。
struct HistorySkeletonRow: View {
  let theme: HistoryThemeTokens
  /// 同一屏里让每行宽度不同，避免整齐得像一张表格——真实标题本来就长短不一。
  let widthSeed: Int
  /// 呼吸动画的相位。由父视图统一驱动，避免每行各自起一个计时器。
  let isBreathing: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var titleWidth: CGFloat { [0.82, 0.64, 0.91, 0.73, 0.58][widthSeed % 5] }
  private var previewWidth: CGFloat { [0.55, 0.78, 0.42, 0.66, 0.71][widthSeed % 5] }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // 跟着 `HistoryRowView` 走：左栏是状态点 + 平台标记竖排。
      // 这两个结构必须一致，否则内容到位时布局会跳——那正是骨架屏要防的事。
      VStack(spacing: 6) {
        Circle().fill(placeholder).frame(width: 7, height: 7)
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
          .fill(placeholder)
          .frame(width: 18, height: 18)
      }
      .padding(.top, 4)
      VStack(alignment: .leading, spacing: 4) {
        bar(height: 13, widthFraction: titleWidth)
        bar(height: 12, widthFraction: previewWidth)
        bar(height: 10, widthFraction: 0.28)
      }
    }
    .padding(.vertical, 2)
    // 开了「减弱动态效果」就停在一个固定灰度上。
    //
    // 无限循环的呼吸比一次性过渡更需要这道闸：它永远不停，对前庭敏感的用户
    // 是持续的刺激源。占位行本身靠形状就说明了「在载入」，那口呼吸只是锦上添花。
    .opacity(reduceMotion ? 0.6 : (isBreathing ? 0.45 : 0.85))
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
      value: isBreathing
    )
    .accessibilityHidden(true)
  }

  /// 用主题的次要文字色而不是写死的灰：深色和高对比主题下，固定灰会
  /// 要么糊在背景里、要么亮得像真内容。
  private var placeholder: Color { theme.secondaryText.opacity(0.18) }

  private func bar(height: CGFloat, widthFraction: CGFloat) -> some View {
    GeometryReader { proxy in
      RoundedRectangle(cornerRadius: height / 2.5, style: .continuous)
        .fill(placeholder)
        .frame(width: proxy.size.width * widthFraction, height: height)
    }
    .frame(height: height)
  }
}

/// 一屏占位行。
///
/// 行数取固定值而不是算可用高度：这里唯一的目的是让首屏看起来已经有东西了，
/// 多画几行填不满也不会露馅（列表本来就要滚动），少画几行反而会露出空白。
struct HistorySkeletonList: View {
  let theme: HistoryThemeTokens
  @State private var isBreathing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(0..<8, id: \.self) { index in
        HistorySkeletonRow(theme: theme, widthSeed: index, isBreathing: isBreathing)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.top, 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear { isBreathing = true }
    .accessibilityLabel("正在载入历史记录")
  }
}
