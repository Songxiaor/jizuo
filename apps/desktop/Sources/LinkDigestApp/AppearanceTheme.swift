import AppKit
import SwiftUI

/// 用户可选外观：跟随系统、浅色、深色。
///
/// 2026-09-10 从六套收成三套。石楠、珊瑚、高对比各自另起一套底色和强调色，
/// 和浅色不是一家（Syc 的原话是「土」）；深色原来用橙色强调，也和浅色的墨绿
/// 不是一家。现在只有一套设计：浅色是它的白天，深色是从同一组色相推出来的夜晚，
/// 「跟随系统」只是在两者之间自动切换，不再是另一套原生外观。
///
/// 颜色统一收口为令牌，视图不直接写色值。
enum AppearanceTheme: String, CaseIterable, Identifiable {
  case glass
  case paper
  case ink

  static let storageKey = "com.syc.linkdigest.appearance-theme"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .glass: "跟随系统"
    case .paper: "浅色"
    case .ink: "深色"
    }
  }

  var systemImageName: String {
    switch self {
    case .glass: "circle.lefthalf.filled"
    case .paper: "sun.max"
    case .ink: "moon"
    }
  }

  /// glass 跟随系统，其余都把外观钉死——主题的意义就是不随系统翻转。
  var colorScheme: ColorScheme? {
    switch self {
    case .glass: nil
    case .paper: .light
    case .ink: .dark
    }
  }

  /// 阅读区默认字体是否走宋体。三套主题都不走：长文默认无衬线，宋体在外观页
  /// 作为一键选项提供，由用户自己选。
  var usesEditorialReadingTypography: Bool { false }

  /// 色卡预览的底色。
  var swatchBase: Color { tokens.canvas }

  /// 色卡上那一小条强调色。
  var swatchAccent: Color { tokens.accent }

  /// 系统当前是不是深色外观。跟随系统时靠它决定用哪套令牌。
  ///
  /// 测试和无 UI 的进程里 `NSApp` 可能为 nil，那就当浅色。
  @MainActor static var systemPrefersDark: Bool {
    NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  /// 脑图这类独立生成产物（有自己整块底色的 SVG/位图）默认走深色还是浅色。
  ///
  /// 只决定「用户没显式选过风格时的默认值」，不覆盖任何已保存的选择。
  @MainActor static func currentPrefersDarkGeneratedArtwork(
    defaults: UserDefaults = .standard
  ) -> Bool {
    let theme = AppearanceTheme(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .glass
    switch theme {
    case .ink: return true
    case .paper: return false
    case .glass: return systemPrefersDark
    }
  }

  /// 这套主题该在哪种 macOS 外观下渲染。
  ///
  /// 抽出来是因为**动态语义色只有在对应外观里才是对的**：深色主题的
  /// `primaryText` 是 `.primary`，在浅色外观下解析出来接近纯黑，压在深画布上
  /// 算出来只有 1.2:1。任何离屏取色（测试、导出、缩略图）都得先切到这里给出的外观。
  ///
  /// `nil` = 跟随系统。
  var renderingAppearance: NSAppearance? {
    switch self {
    case .glass: nil
    case .paper: NSAppearance(named: .aqua)
    case .ink: NSAppearance(named: .darkAqua)
    }
  }

  /// SwiftUI 的 preferredColorScheme(nil) 在 macOS 上不会把已设置的外观
  /// 复位，因此统一用 NSApp.appearance 做全局切换：nil 即回到跟随系统。
  @MainActor static func applyApplicationAppearance(_ rawValue: String) {
    NSApp.appearance = (AppearanceTheme(rawValue: rawValue) ?? .glass).renderingAppearance
  }

  /// 令牌表按主题**算一次就存下来**。
  ///
  /// 原来 `tokens` 是计算属性，每次读都重新构造 17 个 Color 再做一次字体查找。
  /// 而各视图里 `theme` 又是 `{ appearanceTheme.tokens }` 这样的计算属性——光
  /// `HistoryContentView` 一个 body 里就读 87 次。切主题时整棵视图图重算，这份
  /// 构造开销跟着乘以每个节点。
  private static let cache: [AppearanceTheme: HistoryThemeTokens] = Dictionary(
    uniqueKeysWithValues: [AppearanceTheme.paper, .ink].map { ($0, $0.makeTokens()) }
  )

  /// 跟随系统解析出来的令牌另给身份串：它和 paper / ink 内容相同，但
  /// `testTokenIdentityDistinguishesEveryTheme` 要求三套主题身份各异，
  /// 而且用户切到「跟随系统」时环境值必须变，否则视图不刷新。
  private static let glassLight: HistoryThemeTokens = AppearanceTheme.paper.makeTokens().renamed("glass/light")
  private static let glassDark: HistoryThemeTokens = AppearanceTheme.ink.makeTokens().renamed("glass/dark")

  /// 当前令牌。跟随系统时按 `NSApp.effectiveAppearance` 挑浅色或深色。
  ///
  /// 视图里读这个不会在系统翻转时自动刷新；需要跟着翻转的视图改读
  /// `tokens(systemColorScheme:)` 并传入 `@Environment(\.colorScheme)`。
  var tokens: HistoryThemeTokens {
    switch self {
    case .glass:
      return MainActor.assumeIsolated { Self.systemPrefersDark } ? Self.glassDark : Self.glassLight
    case .paper, .ink:
      return Self.cache[self] ?? makeTokens()
    }
  }

  /// 跟随系统时按 SwiftUI 环境给的明暗解析；其余主题忽略这个参数。
  func tokens(systemColorScheme: ColorScheme?) -> HistoryThemeTokens {
    guard self == .glass, let systemColorScheme else { return tokens }
    return systemColorScheme == .dark ? Self.glassDark : Self.glassLight
  }

  private func makeTokens() -> HistoryThemeTokens {
    switch self {
    case .glass:
      // 不会走到：glass 在 `tokens` 里解析成 paper / ink。留一份浅色兜底。
      return AppearanceTheme.paper.makeTokens()
    case .paper:
      return HistoryThemeTokens(
        identity: "paper",
        isNative: false,
        // 界面字体交给系统：英文数字走 SF Pro、中文自动回退 PingFang，
        // 和 macOS 自家应用同一套。这是「Mac 味」最直接的来源。
        // 用户在设置里指定的界面字体优先于这里。
        typography: .system,
        // 三档底色：侧栏最沉、列表居中、正文纸面最亮，视线自然从左往右走。
        canvas: ReadingPalette.sidebar,     // #E4E5E2  侧栏
        listPane: ReadingPalette.listPane,  // #EFF0ED  列表列
        card: ReadingPalette.paper,         // #FAFAF7  阅读区 / 设置卡
        selectionFill: ReadingPalette.green,
        selectionText: ReadingPalette.paper,
        hairline: ReadingPalette.rule,
        badge: ReadingPalette.badge,
        primaryText: ReadingPalette.ink,
        secondaryText: ReadingPalette.secondary,
        accent: ReadingPalette.green,
        // 纸底上的状态色统一降饱和，并按 AA 压深到 4.5:1 以上（两个面都验过）。
        success: themeColor(0x48, 0x6E, 0x4A),
        warning: themeColor(0x83, 0x5E, 0x2A),
        danger: themeColor(0xA1, 0x4B, 0x42),
        info: themeColor(0x41, 0x6B, 0x7B),
        encodesStatusByShape: false
      )
    case .ink:
      // 从浅色派生：同一组带绿的中性色相，只把明度翻过来。
      // 强调色是浅色墨绿提亮后的版本，明暗切换时像同一个产品的白天和夜晚。
      return HistoryThemeTokens(
        identity: "ink",
        isNative: false,
        typography: .system,
        canvas: InkPalette.sidebar,     // #1F2321  侧栏
        listPane: InkPalette.listPane,  // #252927  列表列
        card: InkPalette.paper,         // #2A2E2B  阅读区 / 设置卡
        selectionFill: InkPalette.green,
        selectionText: InkPalette.onGreen,
        hairline: Color.white.opacity(0.08),
        badge: Color.white.opacity(0.10),
        primaryText: InkPalette.ink,
        secondaryText: InkPalette.secondary,
        accent: InkPalette.green,
        // 深底要把状态色提亮，否则暗绿暗红在深灰上糊成一团；
        // 四支对画布和正文卡都在 4.5:1 以上。
        success: themeColor(0x86, 0xB9, 0x8F),
        warning: themeColor(0xD9, 0xB3, 0x6A),
        danger: themeColor(0xD9, 0x80, 0x70),
        info: themeColor(0x7F, 0xA9, 0xBF),
        encodesStatusByShape: false
      )
    }
  }
}

/// 各调色板共用的 sRGB 构造器。放在类型外面，免得每加一套主题就复制一份。
private func themeColor(_ red: Int, _ green: Int, _ blue: Int) -> Color {
  Color(nsColor: NSColor(
    srgbRed: CGFloat(red) / 255,
    green: CGFloat(green) / 255,
    blue: CGFloat(blue) / 255,
    alpha: 1
  ))
}

/// 汲作阅读主题（浅色）：中性纸面、清晰墨色、少量绿色强调。
private enum ReadingPalette {
  static let sidebar = themeColor(0xE4, 0xE5, 0xE2)
  /// 列表列：比侧栏亮、比纸面暗的中间档。对侧栏 L* 差约 4，对纸面约 4。
  static let listPane = themeColor(0xEF, 0xF0, 0xED)
  static let paper = themeColor(0xFA, 0xFA, 0xF7)
  static let ink = themeColor(0x27, 0x2D, 0x28)
  static let secondary = themeColor(0x60, 0x67, 0x60)
  static let green = themeColor(0x35, 0x60, 0x46)
  static let rule = themeColor(0xD6, 0xDA, 0xD2)
  static let badge = themeColor(0xDD, 0xE3, 0xD9)
}

/// 深色主题：浅色同一组色相的夜晚版。
private enum InkPalette {
  static let sidebar = themeColor(0x1F, 0x23, 0x21)
  static let listPane = themeColor(0x25, 0x29, 0x27)
  static let paper = themeColor(0x2A, 0x2E, 0x2B)
  /// 暖白正文，对画布约 12:1。
  static let ink = themeColor(0xE8, 0xEA, 0xE6)
  /// 次要文字，对画布约 6:1、对正文卡约 5:1。
  static let secondary = themeColor(0x9A, 0xA0, 0x9B)
  /// 浅色墨绿 #35 60 46 提亮后的版本，对画布约 6.5:1。
  static let green = themeColor(0x7F, 0xB0, 0x8A)
  /// 压在强调色块上的文字：深绿黑，对 green 约 7:1。
  static let onGreen = themeColor(0x14, 0x1E, 0x18)
}

// Equatable：列表行按值输入决定是否重算（HistoryRowView ==），主题令牌是输入之一。
struct HistoryThemeTokens: Equatable {
  /// 身份串：主题 + 界面字体。
  ///
  /// SwiftUI 用环境值的相等性判断要不要让下游失效，而这个结构体有 17 个 Color。
  /// 逐个比 Color 在切主题时会被整棵树乘一遍。令牌是按主题预先算好的常量，
  /// 只要身份相同内容必然相同，所以相等性可以退化成比一个字符串。
  private(set) var identity: String

  static func == (lhs: HistoryThemeTokens, rhs: HistoryThemeTokens) -> Bool {
    lhs.identity == rhs.identity
  }

  /// 原生模式：不绘制自定义画布/面板背景，交还系统 material。
  let isNative: Bool
  /// 这套令牌是不是深色底。工具栏的 Liquid Glass 胶囊要按它选明暗，否则深底上
  /// 会画出浅色胶囊、白色图标——图标就看不见了。
  var isDark: Bool { identity.hasSuffix("ink") || identity.hasSuffix("dark") }
  /// 只替换界面字体，其余令牌原样保留。
  ///
  /// 用户在设置里指定界面字体后，走的就是这条：主题的颜色照旧，只有排版被覆盖。
  /// 内容不变、只换身份串。跟随系统解析出的令牌用它和 paper / ink 区分开。
  func renamed(_ identity: String) -> HistoryThemeTokens {
    var copy = self
    copy.identity = identity
    return copy
  }

  func withTypography(_ typography: ThemeTypography) -> HistoryThemeTokens {
    var copy = self
    copy.typography = typography
    // 身份必须跟着换。忘了这一步的表现是：用户在设置里换界面字体，环境值
    // 「看起来没变」（相等性只比身份），下游一个视图都不刷新。
    copy.identity = "\(identity)/\(typography.family ?? "system")"
    return copy
  }

  /// 这套主题的界面字体。见 `ThemeTypography`。
  ///
  /// 放进令牌而不是单独一个环境键：主题换的是颜色**和**字体，两者永远同时生效。
  /// 拆成两个键，迟早会有一处只更新了颜色。
  private(set) var typography: ThemeTypography
  let canvas: Color
  let listPane: Color
  let card: Color
  let selectionFill: Color
  let selectionText: Color
  let hairline: Color
  let badge: Color
  let primaryText: Color
  let secondaryText: Color
  let accent: Color
  /// 状态语义色。
  ///
  /// 补这一层的理由：这些颜色原本以 `.green` / `.orange` / `.red` 的形式直接写在
  /// 视图里（列表状态点、待转写标记等），于是换主题时它们不跟着走——暖褐主题
  /// 那种低对比纸底上压一个 SwiftUI 默认的高饱和绿，是全屏最刺眼的一块。
  ///
  /// 各主题自己定值而不是共用一套：同一个绿在纸底、深色底和纯白底上，
  /// 需要的明度和饱和度完全不同。
  let success: Color
  let warning: Color
  let danger: Color
  let info: Color
  /// 列表状态点是否改用形状（实心/空心）而不是颜色（绿/橙）传达「已总结」。
  ///
  /// 唯一不是颜色的令牌，放在这里是因为它和颜色是同一个决定的两面：一套主题
  /// 要么用色相编码状态，要么用形状。高对比主题的前提就是不靠辨色读信息，
  /// 顺带对色觉障碍用户友好；其余主题的绿/橙在各自底色上都够分。
  let encodesStatusByShape: Bool
}

/// 语义字体够不到的那一档字号。
///
/// 界面上绝大多数文字用 `.footnote` / `.subheadline` / `.callout` / `.body` /
/// `.title3` 这套语义字体——它们跟随系统辅助功能设置缩放，也和系统 App 一致。
/// 但 macOS 的语义字体最小只到 10pt，而 favicon 圆里那个兜底字母、列表行的
/// 状态徽标确实需要更小才装得下。
///
/// 收成一个命名常量而不是让 `9` 散落在各视图里：散落的字号正是「界面看着
/// 粗糙」的来源——同类元素在不同位置用了 9、9.5、10 三种值，读者说不出
/// 哪里不对，只觉得不齐整。
enum BadgeTypography {
  /// 徽标与角标里的文字。只用于 16×16 一类的极小容器。
  static let size: CGFloat = 9
}

/// 让任意层级的视图拿到当前主题，不必各自重复
/// `@AppStorage` + 两个计算属性那三行样板。
///
/// 起因是状态色 token 落地时发现的：设置页那几个子视图（视频存储、浏览器支持、
/// 知识库同步）压根没有 `theme` 变量，于是错误文字只能写死 `.red`——在暖褐这种
/// 低对比主题上，系统红是全屏最跳的一块，而在高对比主题上它又不够黑。
///
/// 默认值给 `glass`，所以忘了注入时退化成系统外观，不会崩也不会花。
private struct AppThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppearanceTheme.glass.tokens
}

extension EnvironmentValues {
  var appTheme: HistoryThemeTokens {
    get { self[AppThemeEnvironmentKey.self] }
    set { self[AppThemeEnvironmentKey.self] = newValue }
  }
}

extension View {
  /// 在窗口根部注入一次，整棵树都能读到。
  ///
  /// `uiFontRawValue` 是用户在设置里选的界面字体。它在这里就地覆盖掉主题自带的
  /// `typography`，所以**下游只需要读 `theme.typography` 一处**，不必各自再去
  /// 判断「用户是不是选过」——那种判断只要漏一处，就会有一小块界面不跟着走。
  func appThemeEnvironment(
    _ rawValue: String,
    uiFontRawValue: String = UIFontSelection.defaultStoredValue
  ) -> some View {
    modifier(AppThemeInjector(rawValue: rawValue, uiFontRawValue: uiFontRawValue))
      // 连**默认字体**一起换掉，不只是显式写了 `.themedFont` 的地方。
      //
      // 这一条是补出来的，而且不补就一定会漏：大量 `Text` 和 `Label` 从来没写过
      // 字体，靠的是环境里的默认值——侧栏顶上那组「全部/最近/未总结/收藏」就是
      // `Label(title, systemImage:)`，一个 `.font()` 都没有。把它们逐个补上
      // `.themedFont` 是做不完的，因为 grep `.font(` **根本找不到它们**：
      // 那里没有字体调用可供搜索，只有缺席。
      //
      // 系统主题不设这个值，交还 macOS 自己的默认字体。
      // 这里**不再**注入 `.environment(\.font,)`。
      //
      // 曾经注入过，想一次覆盖所有「没写字体」的 Text/Label。两个问题：
      //
      // 1. 它到不了 `List` 行内（macOS 的 List 是 NSTableView 支撑的，会用自己的
      //    字体盖过环境），也就是最需要它的地方它没用；
      // 2. 采样实测它让每次切主题多花 ~104ms（总开销的 31%）——因为它让整棵树
      //    里连不关心主题的节点也一起失效。
      //
      // 现在改成所有界面文字显式走 `.themedFont`。漏没漏不是靠 grep（裸文本没有
      // 字体调用可搜），而是靠**哨兵字体**：把这里临时换成行楷之类的异形字体，
      // 部署后逐屏截图，凡是显示成行楷的就是漏掉的站点。
  }
}

/// 在窗口根部把主题令牌注入环境。
///
/// 做成 ViewModifier 而不是直接 `environment(...)`：「跟随系统」要在系统明暗翻转时
/// 换令牌，而翻转唯一可靠的信号是 `@Environment(\.colorScheme)`——只有 View /
/// ViewModifier 能读它。
private struct AppThemeInjector: ViewModifier {
  let rawValue: String
  let uiFontRawValue: String
  @Environment(\.colorScheme) private var systemColorScheme

  func body(content: Content) -> some View {
    let tokens = (AppearanceTheme(rawValue: rawValue) ?? .glass)
      .tokens(systemColorScheme: systemColorScheme)
    let typography = UIFontSelection(storedValue: uiFontRawValue)
      .resolved(themeDefault: tokens.typography)
    return content.environment(\.appTheme, tokens.withTypography(typography))
  }
}
