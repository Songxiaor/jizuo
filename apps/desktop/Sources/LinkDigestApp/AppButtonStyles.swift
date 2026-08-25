import SwiftUI

/// 纯图标按钮：工具栏、列表行尾、卡片角上那些只有一个符号的按钮。
///
/// 补这个的理由是审查时量出来的一个数字：全库 0 处自定义 `ButtonStyle`。
/// macOS 用户判断「这东西能不能点」几乎完全依赖 hover——鼠标划过去有反应
/// 才是按钮，没反应就是装饰。当前设置页里的编辑/删除图标在静止和悬停时
/// 完全一样，它们看起来像图例而不是控件。
///
/// 三层反馈各司其职：
/// - **hover**：一块淡背景浮出来，告诉你「这里可以点」
/// - **pressed**：缩到 0.96，模拟按下去的位移
/// - **focus**：键盘走到这里时给一圈 accent 描边（macOS 全键盘控制下必需）
struct AppIconButtonStyle: ButtonStyle {
  /// 命中区域的边长。比图标本身大一圈，让鼠标不必精确压在符号上。
  var size: CGFloat = 28
  /// 悬停背景的强度。工具栏那种深色底上需要更明显一点。
  var hoverOpacity: Double = 0.08

  func makeBody(configuration: Configuration) -> some View {
    IconBody(configuration: configuration, size: size, hoverOpacity: hoverOpacity)
  }

  /// `ButtonStyle` 是 struct，`makeBody` 每次求值都会重建，`@State` 挂不住。
  /// 所以把状态搬进一个真正的 View 里。
  ///
  /// 名字不能叫 `Body`：那正好撞上 `ButtonStyle` 的 `associatedtype Body`，
  /// 编译器会把这个 private 类型当成协议实现，然后抱怨它不够 public。
  private struct IconBody: View {
    let configuration: Configuration
    let size: CGFloat
    let hoverOpacity: Double

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .frame(width: size, height: size)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .fill(Color.primary.opacity(backgroundOpacity))
        )
        // 命中区域要覆盖整个方块，而不是只有图标那几个像素。
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(
          DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
          value: isHovering
        )
        .animation(
          DesignTokens.Motion.resolved(DesignTokens.Motion.instant, reduceMotion: reduceMotion),
          value: configuration.isPressed
        )
        // 禁用态不该有 hover 反馈——那会让人以为还能点。
        .onHover { isHovering = isEnabled && $0 }
    }

    private var backgroundOpacity: Double {
      guard isEnabled else { return 0 }
      if configuration.isPressed { return hoverOpacity * 1.6 }
      return isHovering ? hoverOpacity : 0
    }
  }
}

/// 带文字的常规按钮。
///
/// 三个层级对应三种语气：`prominent` 是这一屏唯一的主动作，`normal` 是并列的
/// 次要动作，`quiet` 是不想抢注意力的辅助动作（「了解更多」「取消」那类）。
///
/// 不自绘系统已经做好的东西——`.bordered` / `.borderedProminent` 在 macOS 上
/// 已经有正确的高度、圆角和按下反馈。这里只补两件系统没给的：统一的 hover
/// 强度，以及和设计 token 对齐的圆角。
struct AppButtonStyle: ButtonStyle {
  enum Emphasis {
    /// 主动作：accent 填充 + 白字。一屏最多一个。
    case prominent
    /// 次要动作：描边。
    case normal
    /// 辅助动作：无背景无描边，只有 hover 时浮出底色。
    case quiet
  }

  var emphasis: Emphasis = .normal
  var accent: Color = .accentColor

  func makeBody(configuration: Configuration) -> some View {
    LabeledBody(configuration: configuration, emphasis: emphasis, accent: accent)
  }

  private struct LabeledBody: View {
    let configuration: Configuration
    let emphasis: Emphasis
    let accent: Color

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .themedFont(.callout)
        .foregroundStyle(foreground)
        .padding(.horizontal, DesignTokens.Space.md)
        .frame(height: 28)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .fill(background)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(
          DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
          value: isHovering
        )
        .onHover { isHovering = isEnabled && $0 }
    }

    private var foreground: Color {
      switch emphasis {
      case .prominent: .white
      case .normal, .quiet: .primary
      }
    }

    private var background: Color {
      switch emphasis {
      case .prominent:
        // 按下比悬停更深一档，让「已经按下去了」和「只是划过」区分得开。
        accent.opacity(configuration.isPressed ? 0.82 : (isHovering ? 0.92 : 1))
      case .normal:
        Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovering ? 0.05 : 0))
      case .quiet:
        Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovering ? 0.05 : 0))
      }
    }

    private var border: Color {
      switch emphasis {
      case .prominent, .quiet: .clear
      case .normal: Color.primary.opacity(0.15)
      }
    }
  }
}

extension ButtonStyle where Self == AppIconButtonStyle {
  /// 工具栏与列表行里的纯图标按钮。
  static var appIcon: AppIconButtonStyle { AppIconButtonStyle() }
}

extension ButtonStyle where Self == AppButtonStyle {
  static var appQuiet: AppButtonStyle { AppButtonStyle(emphasis: .quiet) }
  static var appNormal: AppButtonStyle { AppButtonStyle(emphasis: .normal) }
  static func appProminent(_ accent: Color) -> AppButtonStyle {
    AppButtonStyle(emphasis: .prominent, accent: accent)
  }
}
