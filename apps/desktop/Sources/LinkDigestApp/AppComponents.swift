import SwiftUI

/// 一块抬起来的表面。
///
/// 现状是各处自己写 `.background(...).clipShape(RoundedRectangle(cornerRadius: N))`，
/// 于是圆角量出来有 1、6、7、8、9、10、12、14、18 九种——6 和 7 在屏幕上根本
/// 分不出来，但它们是两个独立的决定。这个组件的作用是让「卡片」只有一种长相。
///
/// **不是所有东西都该套卡片。** 只有当「抬起」本身传达了层级（这块内容浮在
/// 别的内容之上，或它是一个独立单元）才用；并列的同级内容用分隔线或留白分组，
/// 那样更轻、也更像 macOS。
struct AppCard<Content: View>: View {
  var padding: CGFloat = DesignTokens.Space.lg
  var elevation: DesignTokens.Elevation = .raised
  let theme: HistoryThemeTokens
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(padding)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .fill(theme.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .strokeBorder(theme.hairline, lineWidth: 1)
      )
      // 阴影染主题底色：纯黑阴影压在暖白纸上会发灰发脏。
      .designShadow(elevation, tint: theme.primaryText)
  }
}

/// 计数、状态、分类用的小标签。
///
/// 统一三件事：字号走 `BadgeTypography.size`（语义字体够不到的那一档）、
/// 圆角固定、数字等宽。等宽是因为徽标里的数字会变——9 变 10 时，比例字体
/// 会让整个胶囊宽度跳一下。
struct AppBadge: View {
  let text: String
  var tint: Color?
  var theme: HistoryThemeTokens

  var body: some View {
    Text(text)
      .font(.system(size: BadgeTypography.size, weight: .medium).monospacedDigit())
      .foregroundStyle(tint == nil ? theme.secondaryText : .white)
      .padding(.horizontal, DesignTokens.Space.xs + 2)
      .padding(.vertical, DesignTokens.Space.xxs)
      .background(
        Capsule().fill(tint ?? theme.badge)
      )
      .fixedSize()
  }
}

/// 空 / 错误 / 无结果这类「这里现在没有内容」的统一版式。
///
/// 项目里现有的空状态写得不错（「还没有笔记」「还没有保存页面」都给了下一步
/// 该干什么），问题只是每处各写一遍版式，图标尺寸和间距各不相同。这个组件
/// 把版式固定下来，文案仍由调用方给——文案本来就该各说各的。
///
/// 三段式：图标 → 标题 → 说明 → 动作。说明和动作都可省。
struct AppStateView<Actions: View>: View {
  enum Kind {
    case empty
    case error
    /// 搜索/筛选后没有命中。和 `empty` 分开，因为用户该做的事不同：
    /// 空是「去添加」，无结果是「改条件」。
    case noResults

    var defaultSymbol: String {
      switch self {
      case .empty: "tray"
      case .error: "exclamationmark.triangle"
      case .noResults: "line.3.horizontal.decrease.circle"
      }
    }
  }

  let kind: Kind
  let title: String
  var message: String?
  var symbol: String?
  let theme: HistoryThemeTokens
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(spacing: DesignTokens.Space.md) {
      Image(systemName: symbol ?? kind.defaultSymbol)
        .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
        .foregroundStyle(kind == .error ? theme.danger : theme.secondaryText)
        .accessibilityHidden(true)

      Text(title)
        .themedFont(.title3, weight: .semibold)
        .foregroundStyle(theme.primaryText)

      if let message {
        Text(message)
          .themedFont(.callout)
          .foregroundStyle(theme.secondaryText)
          .multilineTextAlignment(.center)
          // 说明文字不能拉太宽，否则一行扫过去眼睛会丢行。
          .frame(maxWidth: 360)
          .fixedSize(horizontal: false, vertical: true)
      }

      actions()
        .padding(.top, DesignTokens.Space.xs)
    }
    .padding(.horizontal, DesignTokens.Space.xl)
    .padding(.vertical, DesignTokens.Space.huge)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension AppStateView where Actions == EmptyView {
  init(
    kind: Kind,
    title: String,
    message: String? = nil,
    symbol: String? = nil,
    theme: HistoryThemeTokens
  ) {
    self.init(
      kind: kind, title: title, message: message, symbol: symbol,
      theme: theme, actions: { EmptyView() }
    )
  }
}

/// 分区标题。
///
/// 设置页和侧栏都需要「一小行灰字把下面的内容归成一组」，现在各写各的。
struct AppSectionHeader: View {
  let title: String
  var theme: HistoryThemeTokens

  var body: some View {
    Text(title)
      .themedFont(.footnote, weight: .semibold)
      .foregroundStyle(theme.secondaryText)
      .textCase(nil)
      .padding(.bottom, DesignTokens.Space.xxs)
  }
}

/// 栏内的小空状态：一行标题、一句说明、一个文字按钮。
///
/// 2026-10-01 视觉一致性：方法库、选题板的空状态原来只有一行淡灰字，
/// 和同一栏「在做的」那块带图标、带按钮的空态差了一个重量级，用户读不出
/// 「这里空着、下一步点哪」。这两块都嵌在一条长滚动栏里，套大号
/// `HistoryInlineState` 会把整栏撑散，所以单做一个靠左、紧凑的版本。
struct CompactEmptyState: View {
  let title: String
  let message: String
  var actionTitle: String?
  var isActionEnabled = true
  var action: (() -> Void)?
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      Text(title)
        .themedFont(.callout, weight: .medium)
        .foregroundStyle(theme.primaryText)
      Text(message)
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.plain)
          .themedFont(.caption, weight: .semibold)
          .foregroundStyle(isActionEnabled ? theme.accent : theme.secondaryText)
          .disabled(!isActionEnabled)
          .padding(.top, DesignTokens.Space.xxs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 「正在载入…」的统一写法：小号转圈 + 一行说明。
///
/// 2026-10-01 视觉一致性：原来有的写 `ProgressView("正在载入…")`（系统默认大号转圈、
/// 系统字体、文字压在圈下面），有的只转圈不说话，有的自己拼 HStack，字号各不相同。
/// 加载是最常见的过渡态，长相不统一会让每次切换都像换了个 App。
struct InlineLoadingLabel: View {
  let message: String
  @Environment(\.appTheme) private var theme

  init(_ message: String) {
    self.message = message
  }

  var body: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      ProgressView().controlSize(.small)
      Text(message)
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
    }
    .accessibilityElement(children: .combine)
  }
}

/// 独立小窗（快速记录、MCP 博主发现这类自己 new 出来的 NSPanel / NSWindow）的根视图。
///
/// 2026-10-01 视觉一致性：主窗口和设置窗口在 SwiftUI 场景根上注入了主题，而 AppKit
/// 直接建的窗口不经过那条路——里面读到的 `appTheme` 是缺省值，强调色是系统蓝、字体
/// 不跟用户选的界面字体。在这里把同一份偏好读出来再注入一次，窗口里就和主窗口一致。
struct ThemedWindowRoot<Content: View>: View {
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(UIFontSelection.storageKey) private var uiFontRaw = UIFontSelection.defaultStoredValue
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .appThemeEnvironment(appearanceThemeRaw, uiFontRawValue: uiFontRaw)
  }
}
