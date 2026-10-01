import SwiftUI

/// 列表、图库、博主目录共用的搜索框：放大镜 + 输入框，浅灰凹槽外观。
///
/// 2026-10-01 视觉一致性：原来三处搜索框各写一遍——中栏和博主目录是
/// `primaryText.opacity(0.045)` 的凹槽，图库却是 `card` 白底；左右边距一处 10、
/// 一处 12。同一个控件三种长相，切分类时搜索框会「跳」一下。外观收在这里，
/// 调用方只决定输入框本身（防抖的 `DebouncedSearchField` 或普通 `TextField`）
/// 和外侧留白。
///
/// 只画框，不加外边距：外边距跟着所在列走（列内统一用 `Layout.columnInset`）。
struct ThemedSearchField<Field: View>: View {
  @Environment(\.appTheme) private var theme
  @ViewBuilder var field: () -> Field

  var body: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(theme.secondaryText)
        .accessibilityHidden(true)
      field()
        .textFieldStyle(.plain)
        .themedFont(.body)
    }
    .padding(.horizontal, DesignTokens.Space.sm)
    .frame(maxWidth: .infinity)
    .frame(height: 30)
    // 列表列已经是纸面色，搜索框是浅一档的凹槽，不是白框套白底。
    .background(
      theme.primaryText.opacity(0.045),
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .stroke(theme.hairline, lineWidth: 1)
    )
  }
}

extension ThemedSearchField where Field == TextField<Text> {
  /// 不需要防抖的场合（博主目录这类内存过滤）直接给占位文字和绑定。
  init(_ placeholder: String, text: Binding<String>) {
    self.init { TextField(placeholder, text: text) }
  }
}
