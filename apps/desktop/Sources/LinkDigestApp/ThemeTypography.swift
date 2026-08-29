import AppKit
import SwiftUI

/// 主题的**排版**部分。
///
/// 补这一层的理由：在这之前「主题」只换颜色，字体是全 App 写死的系统字体。
/// 但换主题换的是整套观感，字体和颜色一样是主题的一部分——纸质主题配宋体、
/// 墨黑主题配圆体，和它们各自的配色是同一个决定的两半。
///
/// 系统主题**故意**留在系统字体上。它的定位是「跟随 macOS」，而窗口里还有
/// 一整片我们够不到的系统控件：菜单栏、右键菜单、字体面板、Sparkle 更新弹窗。
/// 给系统主题指定字体，那些控件不会跟着变，反而会露馅。
enum ThemeTextStyle: CaseIterable {
  case largeTitle, title, title2, title3, headline
  case body, callout, subheadline, footnote, caption, caption2

  /// 系统主题走这条：直接用语义字号，交还 macOS。
  var systemFont: Font {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .subheadline: .subheadline
    case .footnote: .footnote
    case .caption: .caption
    case .caption2: .caption2
    }
  }

  /// macOS 上这些语义字号的实际点数（实测 `NSFont.preferredFont(forTextStyle:)`）。
  ///
  /// 具名字体没有「语义字号」的概念，只能给点数。这些值必须和系统的一致，
  /// 否则换主题时整个界面的尺寸会跳一下——那不是换字体，那是换布局。
  var pointSize: CGFloat {
    switch self {
    case .largeTitle: 26
    case .title: 22
    case .title2: 17
    case .title3: 15
    case .headline: 13
    case .body: 13
    case .callout: 12
    case .subheadline: 11
    case .footnote: 10
    case .caption: 10
    case .caption2: 10
    }
  }

  /// `headline` 在系统语义里自带 semibold，其余是 regular。
  ///
  /// 这条必须显式补上：换成具名字体后语义字号的隐含字重就丢了，
  /// 表现是「小标题和正文一样粗」——层级塌掉，而且不会有任何报错。
  var implicitWeight: Font.Weight {
    self == .headline ? .semibold : .regular
  }

  /// 让具名字体仍跟随系统「文字大小」辅助功能设置缩放。
  var scalingAnchor: Font.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .subheadline: .subheadline
    case .footnote: .footnote
    case .caption: .caption
    case .caption2: .caption2
    }
  }
}

/// 一个主题的界面字体。
///
/// `requestedFamily` 保留配置意图；`family` 是当前机器真正能用的家族。
/// `family == nil` 表示「用系统字体」。这不是缺省失败，是系统主题或缺字库时的
/// 正确取值。
struct ThemeTypography: Equatable, Hashable {
  let requestedFamily: String?
  let family: String?

  /// 系统主题专用：不指定家族。
  static let system = ThemeTypography(requestedFamily: nil, family: nil)

  /// 指定家族，但**装不上就退回系统字体**。
  ///
  /// 这些字体除 PingFang 外都不保证存在：思源宋体是用户自己装的开源字体，
  /// Klee 和 Yuanti SC 虽然随 macOS 附带，但可以被用户在「字体册」里停用。
  /// `Font.custom` 遇到不存在的家族不会报错，会静默回退到系统默认——中文标点
  /// 挤压跟着丢，就是当初 New York 那个「每个逗号后裂一道缝」的老问题。
  /// 所以在这里就地判定，宁可退回系统字体，也不要一个半坏的渲染结果。
  static func family(_ name: String) -> ThemeTypography {
    ThemeTypography(
      requestedFamily: name,
      family: NSFont(name: name, size: 13) != nil ? name : nil
    )
  }

  func font(_ style: ThemeTextStyle, weight: Font.Weight? = nil) -> Font {
    let resolved = weight ?? style.implicitWeight
    guard let family else {
      // 系统主题：regular 时原样返回语义字号，让 macOS 自己决定一切。
      return resolved == .regular ? style.systemFont : style.systemFont.weight(resolved)
    }
    return Font
      .custom(family, size: style.pointSize, relativeTo: style.scalingAnchor)
      .weight(resolved)
  }
}

private struct ThemedFontModifier: ViewModifier {
  @Environment(\.appTheme) private var theme
  let style: ThemeTextStyle
  let weight: Font.Weight?
  let monospacedDigit: Bool

  func body(content: Content) -> some View {
    let font = theme.typography.font(style, weight: weight)
    return content.font(monospacedDigit ? font.monospacedDigit() : font)
  }
}

extension View {
  /// 跟随主题的字体。**界面文字**一律走这里，不要直接写 `.font(.caption)`。
  ///
  /// 三类例外，故意不走这里：
  ///
  /// 1. **SF Symbols 图标**——它们也用 `.font()` 定大小，但字形来自系统符号集。
  ///    把图标塞进宋体会掉字形，表现是图标变成方框或干脆消失。
  /// 2. **阅读区正文与标题**——走 `readingFont`，那是用户自己在设置里选的，
  ///    优先级高于主题。
  /// 3. **设置里的字体选择器**——每一行必须用它自己的字渲染，那是预览。
  ///
  /// 从环境读主题，不需要调用方持有 `theme`：主题在窗口根部注入一次，整棵树都读得到。
  func themedFont(
    _ style: ThemeTextStyle,
    weight: Font.Weight? = nil,
    monospacedDigit: Bool = false
  ) -> some View {
    modifier(ThemedFontModifier(style: style, weight: weight, monospacedDigit: monospacedDigit))
  }
}


/// 用户对**界面字体**的选择：要么跟随主题，要么指定一个家族。
///
/// 和 `ReadingFontSelection` 是两个独立的偏好，故意不合并：界面字体和阅读字体
/// 的取舍方向相反——界面最小 10pt、要的是立得住，正文最小 13pt、要的是读着舒服。
/// 同一个字体很少两边都最优，把它们绑在一起等于强迫用户在两者间二选一。
enum UIFontSelection: Equatable {
  case theme
  case family(String)

  static let storageKey = "com.syc.linkdigest.ui-font"
  static let defaultStoredValue = "theme"

  init(storedValue: String) {
    let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    self = (trimmed.isEmpty || trimmed == Self.defaultStoredValue) ? .theme : .family(trimmed)
  }

  var storedValue: String {
    switch self {
    case .theme: Self.defaultStoredValue
    case let .family(name): name
    }
  }

  /// 落到实际排版上。
  ///
  /// 「跟随主题」交还主题自己的 `typography`（系统主题下就是系统字体）；
  /// 指定家族时走 `ThemeTypography.family`，装不上会就地退回系统字体。
  func resolved(themeDefault: ThemeTypography) -> ThemeTypography {
    switch self {
    case .theme: themeDefault
    case let .family(name): .family(name)
    }
  }
}
