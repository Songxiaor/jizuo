import AppKit
import SwiftUI

/// 用户可选外观：玻璃（系统原生 material）、纸质米黄、墨黑（石墨灰）、
/// 暖褐（低对比护眼）、高对比（黑白）。
/// 颜色统一收口为令牌，视图不直接写色值。
enum AppearanceTheme: String, CaseIterable, Identifiable {
  case glass
  case paper
  case ink
  case sepia
  case mono

  static let storageKey = "com.syc.linkdigest.appearance-theme"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .glass: "系统"
    case .paper: "浅色"
    case .ink: "深色"
    case .sepia: "暖褐"
    case .mono: "高对比"
    }
  }

  var systemImageName: String {
    switch self {
    case .glass: "display"
    case .paper: "sun.max"
    case .ink: "moon"
    case .sepia: "sun.haze"
    case .mono: "circle.lefthalf.filled"
    }
  }

  /// glass 跟随系统，其余都把外观钉死——主题的意义就是不随系统翻转。
  var colorScheme: ColorScheme? {
    switch self {
    case .glass: nil
    case .paper, .sepia, .mono: .light
    case .ink: .dark
    }
  }

  /// 宋体 + Claude 风格排版属于「读长文」的浅色主题；系统玻璃、深色和
  /// 高对比都用 macOS 原生排版（高对比要的是笔画清晰，不是书卷气）。
  ///
  /// 写成 switch 而不是 `self == .paper`：加主题时编译器会在这里报错，
  /// 逼着人回答「这套主题读长文用不用宋体」，而不是默默继承一个 false。
  var usesEditorialReadingTypography: Bool {
    switch self {
    case .paper, .sepia: true
    case .glass, .ink, .mono: false
    }
  }

  /// 色卡预览的底色。glass 的 canvas 是 `.clear`（要交还系统 material），
  /// 直接拿去填色卡会是透明的一块，所以单独取系统窗口色。
  var swatchBase: Color {
    tokens.isNative ? Color(nsColor: .windowBackgroundColor) : tokens.canvas
  }

  /// 色卡上那一小条强调色。只看画布色分不出「浅色」和「高对比」——
  /// 两者都是近白底；强调色（品牌橙 / 赭石 / 纯黑）才是一眼的区别。
  var swatchAccent: Color { tokens.accent }

  /// SwiftUI 的 preferredColorScheme(nil) 在 macOS 上不会把已设置的外观
  /// 复位，因此统一用 NSApp.appearance 做全局切换：nil 即回到跟随系统。
  @MainActor static func applyApplicationAppearance(_ rawValue: String) {
    let theme = AppearanceTheme(rawValue: rawValue) ?? .glass
    switch theme {
    case .glass: NSApp.appearance = nil
    case .paper, .sepia, .mono: NSApp.appearance = NSAppearance(named: .aqua)
    case .ink: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  var tokens: HistoryThemeTokens {
    switch self {
    case .glass:
      HistoryThemeTokens(
        isNative: true,
        canvas: .clear,
        listPane: .clear,
        card: Color(nsColor: .textBackgroundColor),
        selectionFill: .accentColor,
        selectionText: .white,
        hairline: Color.primary.opacity(0.08),
        badge: Color.primary.opacity(0.07),
        primaryText: .primary,
        secondaryText: .secondary,
        accent: .accentColor,
        // 跟随系统的主题用系统语义色，它们自己会随明暗翻转。
        success: .green, warning: .orange, danger: .red, info: .blue,
        encodesStatusByShape: false
      )
    case .paper:
      HistoryThemeTokens(
        isNative: false,
        // 两档，不是三档：辅助区 #EFEDE5（导航列 + 列表列）→ 正文区 #FDFCF9。
        //
        // 原来是三档递进，导航列 #EFEDE5、列表列 #FAF9F5、详情卡片 #FDFCF9。
        // 量出来的问题是分级方向反了：唯一看得见的那一档（差 11/255）落在导航列
        // 和列表列之间——两个都是辅助列，本来最不需要分界；而真正该分开的
        // 「辅助 vs 正文」两侧只差 3/255，等于没分。列表列跟着画布走之后，
        // 整扇窗只剩一条明度边界，正好落在辅助区和正文区中间。
        canvas: ClaudePalette.sunken,         // #EFEDE5  导航列 / 列表列
        listPane: ClaudePalette.sunken,       // 同上：列表列不再自成一档
        card: ClaudePalette.raised,           // #FDFCF9  正文区
        selectionFill: ClaudePalette.orange,  // #D97757
        selectionText: ClaudePalette.light,
        hairline: ClaudePalette.lightGray,    // #E8E6DC
        badge: ClaudePalette.lightGray,
        primaryText: ClaudePalette.dark,      // #141413
        secondaryText: ClaudePalette.midGray, // #B0AEA5
        accent: ClaudePalette.orange,
        // 纸底上的状态色统一降饱和：默认的 .green/.red 在暖白纸上过跳。
        success: themeColor(0x5A, 0x8A, 0x5C),
        warning: themeColor(0xC0, 0x8A, 0x3E),
        danger: themeColor(0xB5, 0x54, 0x4A),
        info: themeColor(0x4A, 0x7A, 0x8C),
        encodesStatusByShape: false
      )
    case .ink:
      HistoryThemeTokens(
        isNative: false,
        // 和 paper 一样收成两档：辅助区 #1C1C1E → 正文区 #26262A。
        canvas: Color(nsColor: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)),   // #1C1C1E
        listPane: Color(nsColor: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)), // 同 canvas
        card: Color(nsColor: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.165, alpha: 1)),     // #26262A
        // 深色以前用 `.accentColor`（系统蓝），于是切到深色时品牌就没了——
        // 同一个 App 在两种模式下两种强调色，看起来像没人管过配色。
        // 见 `InkPalette` 注释：填充和前景必须分开取值。
        selectionFill: InkPalette.selection,
        selectionText: .white,
        hairline: Color.white.opacity(0.10),
        badge: Color.white.opacity(0.10),
        primaryText: .primary,
        secondaryText: .secondary,
        accent: InkPalette.accent,
        // 深底要把状态色提亮，否则暗绿暗红在 #1C1C1E 上糊成一团。
        success: themeColor(0x7F, 0xB0, 0x81),
        warning: themeColor(0xD9, 0xA8, 0x5E),
        danger: themeColor(0xD4, 0x75, 0x6B),
        info: themeColor(0x6F, 0xA3, 0xB5),
        encodesStatusByShape: false
      )
    case .sepia:
      // 和 paper 是同一家族的不同温度：都是纸，这张更黄、对比更低。
      //
      // 正文用 #3B3229 而不是纯黑：护眼主题的要点就是把「纸」和「墨」的
      // 亮度差收窄，纯黑配暖底反而比 paper 更刺眼。
      HistoryThemeTokens(
        isNative: false,
        // 同 paper 收成两档：辅助区 #EFE4D0 → 正文区 #FBF5E9。
        canvas: SepiaPalette.sunkenPaper,     // #EFE4D0  导航列 / 列表列
        listPane: SepiaPalette.sunkenPaper,   // 同上：列表列不再自成一档
        // 唯一和 paper 结构不同的一处：卡片比画布亮一档。
        // 低对比主题里 hairline 也淡，卡片再同色就真的分不出边界了。
        card: SepiaPalette.raisedPaper,       // #FBF5E9
        selectionFill: SepiaPalette.ochre,    // #A9713F
        selectionText: SepiaPalette.raisedPaper,
        hairline: SepiaPalette.rule,          // #E2D5BC
        badge: SepiaPalette.badge,            // #EADDC4
        primaryText: SepiaPalette.ink,        // #3B3229
        secondaryText: SepiaPalette.fadedInk, // #8B7B65
        accent: SepiaPalette.ochre,
        // 跟着这套主题往黄里偏。warning 特意避开 ochre(#A9713F)——
        // 强调色和警告色撞色时，用户分不出「这是重点」还是「这是问题」。
        success: themeColor(0x5F, 0x7F, 0x52),
        warning: themeColor(0xB8, 0x86, 0x3B),
        danger: themeColor(0xA5, 0x54, 0x44),
        info: themeColor(0x4F, 0x73, 0x83),
        encodesStatusByShape: false
      )
    case .mono:
      // 可读性优先：纯白底、纯黑字，强调色也是黑。
      //
      // 次要文字用 #4A4A4A（对白底约 9:1）而不是 paper 那种 #B0AEA5——
      // 那个在这套主题里只有 2 出头，正好违背「高对比」这三个字。
      // 分隔线同理用 #767676，淡到看不见的线在这里是缺陷不是克制。
      HistoryThemeTokens(
        isNative: false,
        canvas: MonoPalette.white,
        listPane: MonoPalette.white,
        card: MonoPalette.white,
        selectionFill: MonoPalette.black,
        selectionText: MonoPalette.white,
        hairline: MonoPalette.rule,           // #767676
        badge: MonoPalette.badge,             // #E8E8E8
        primaryText: MonoPalette.black,
        secondaryText: MonoPalette.secondary, // #4A4A4A
        accent: MonoPalette.black,
        // 这套主题不靠色相传信息（状态点走形状），但状态色仍要有——
        // 错误文字、警告横幅这些地方总得有个颜色。取值一律压到对纯白底
        // 7:1 以上，让它们在不辨色的前提下也能靠明度差读出来。
        success: themeColor(0x1B, 0x5E, 0x20),
        warning: themeColor(0x7A, 0x4E, 0x00),
        danger: themeColor(0x8B, 0x1A, 0x10),
        info: themeColor(0x01, 0x57, 0x9B),
        // 这套主题里状态点是唯一的彩色，绿/橙在纯黑白上格外扎眼，
        // 而且它本来就不该靠色相传信息。
        encodesStatusByShape: true
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

/// Anthropic/Claude 公开品牌色。集中定义，避免视图层自行取近似值。
private enum ClaudePalette {
  static let dark = themeColor(0x14, 0x14, 0x13)
  static let light = themeColor(0xFA, 0xF9, 0xF5)
  /// 侧栏与详情区外层的底色，比 `light` 沉一档。
  ///
  /// 三栏原本共用同一个 `light`，只靠 1px 分隔线区分，扫一眼分不出主次。
  /// macOS 的惯例是侧栏最沉、内容区最亮，视线自然往右走。每档差约 2–3%
  /// 明度：再小看不出来，再大就开始像三个不同的 App 拼在一起。
  static let sunken = themeColor(0xEF, 0xED, 0xE5)
  /// 详情区那张卡片，最亮的一档。
  static let raised = themeColor(0xFD, 0xFC, 0xF9)
  static let midGray = themeColor(0xB0, 0xAE, 0xA5)
  static let lightGray = themeColor(0xE8, 0xE6, 0xDC)
  static let orange = themeColor(0xD9, 0x77, 0x57)
}

/// 深色主题的品牌色。
///
/// 一个色号不够用，因为它要同时干两件对比方向相反的事：
///
/// - `selection` 是**背景**，上面压白字。橙色越亮，白字越糊——`#C2703F`
///   对白字约 4.2:1，选中态是半粗体，够读。
/// - `accent` 是**前景**（图标、强调文字），衬在 `#1C1C1E` 的画布上。这里要够亮
///   才看得清——`#E8956B` 对画布约 6.7:1。
///
/// 用同一个值去干这两件事，必然有一边不达标。浅色主题不需要拆是因为
/// 纸底本身够亮，橙色在它上面既能当背景也能当前景。
private enum InkPalette {
  static let selection = themeColor(0xC2, 0x70, 0x3F)
  static let accent = themeColor(0xE8, 0x95, 0x6B)
}

/// 暖褐主题。整体比 `ClaudePalette` 往黄里偏，纸墨亮度差收窄。
private enum SepiaPalette {
  static let paper = themeColor(0xF4, 0xEB, 0xDA)
  /// 侧栏底色。和 paper 主题同一个思路，但幅度更小——这套主题的整个卖点
  /// 就是低对比，分栏差太大会把「久读不累」这个前提破坏掉。
  static let sunkenPaper = themeColor(0xEA, 0xDF, 0xC8)
  static let raisedPaper = themeColor(0xFB, 0xF5, 0xE9)
  static let rule = themeColor(0xE2, 0xD5, 0xBC)
  static let badge = themeColor(0xEA, 0xDD, 0xC4)
  static let ink = themeColor(0x3B, 0x32, 0x29)
  static let fadedInk = themeColor(0x8B, 0x7B, 0x65)
  static let ochre = themeColor(0xA9, 0x71, 0x3F)
}

/// 高对比主题。只有黑、白和两级中性灰，没有色相。
private enum MonoPalette {
  static let white = themeColor(0xFF, 0xFF, 0xFF)
  static let black = themeColor(0x00, 0x00, 0x00)
  static let rule = themeColor(0x76, 0x76, 0x76)
  static let badge = themeColor(0xE8, 0xE8, 0xE8)
  static let secondary = themeColor(0x4A, 0x4A, 0x4A)
}

struct HistoryThemeTokens {
  /// 原生模式：不绘制自定义画布/面板背景，交还系统 material。
  let isNative: Bool
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
  func appThemeEnvironment(_ rawValue: String) -> some View {
    environment(\.appTheme, (AppearanceTheme(rawValue: rawValue) ?? .glass).tokens)
  }
}
