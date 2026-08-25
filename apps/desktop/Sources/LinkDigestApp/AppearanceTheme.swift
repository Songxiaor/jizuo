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
    case .sepia: "石楠"
    case .mono: "高对比"
    }
  }

  var systemImageName: String {
    switch self {
    case .glass: "display"
    case .paper: "sun.max"
    case .ink: "moon"
    case .sepia: "leaf"
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

  /// 脑图这类独立生成产物（有自己整块底色的 SVG/位图）默认走深色还是浅色。
  ///
  /// 只决定「用户没显式选过风格时的默认值」，不覆盖任何已保存的选择。
  /// 深色主题默认深色，三套浅色主题默认浅色；玻璃主题跟随系统当前明暗。
  @MainActor static func currentPrefersDarkGeneratedArtwork(
    defaults: UserDefaults = .standard
  ) -> Bool {
    let theme = AppearanceTheme(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .glass
    switch theme {
    case .ink: return true
    case .paper, .sepia, .mono: return false
    case .glass:
      return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
  }

  /// 这套主题该在哪种 macOS 外观下渲染。
  ///
  /// 抽出来是因为**动态语义色只有在对应外观里才是对的**：深色主题的
  /// `primaryText` 是 `.primary`，在浅色外观下解析出来接近纯黑，压在 #1C1C1E
  /// 的画布上算出来只有 1.2:1。那不是主题坏了，是解析时的外观不对。任何
  /// 离屏取色（测试、导出、缩略图）都得先切到这里给出的外观。
  ///
  /// `nil` = 跟随系统。
  var renderingAppearance: NSAppearance? {
    switch self {
    case .glass: nil
    case .paper, .sepia, .mono: NSAppearance(named: .aqua)
    case .ink: NSAppearance(named: .darkAqua)
    }
  }

  /// SwiftUI 的 preferredColorScheme(nil) 在 macOS 上不会把已设置的外观
  /// 复位，因此统一用 NSApp.appearance 做全局切换：nil 即回到跟随系统。
  @MainActor static func applyApplicationAppearance(_ rawValue: String) {
    // 和 `renderingAppearance` 同源，避免两处 switch 各说各话。
    NSApp.appearance = (AppearanceTheme(rawValue: rawValue) ?? .glass).renderingAppearance
  }

  /// 令牌表按主题**算一次就存下来**。
  ///
  /// 原来 `tokens` 是计算属性，每次读都重新构造 17 个 Color 再做一次字体查找。
  /// 而各视图里 `theme` 又是 `{ appearanceTheme.tokens }` 这样的计算属性——光
  /// `HistoryContentView` 一个 body 里就读 87 次。切主题时整棵视图图重算，这份
  /// 构造开销跟着乘以每个节点。
  ///
  /// 采样实测：切一次主题有 ~290ms 花在 SwiftUI 视图图重算上。图重算本身躲不掉
  /// （根部环境值一变，树上每个节点都失效），但每个节点里的这份重复构造可以省。
  private static let cache: [AppearanceTheme: HistoryThemeTokens] = Dictionary(
    uniqueKeysWithValues: AppearanceTheme.allCases.map { ($0, $0.makeTokens()) }
  )

  var tokens: HistoryThemeTokens {
    // allCases 覆盖了全部取值，取不到只可能是加了新 case 没重建缓存。
    Self.cache[self] ?? Self.glassFallbackTokens
  }

  /// `cache` 自己构造 `.glass` 时不能再回头读 `cache`（会死锁在静态初始化上），
  /// 所以兜底走一次现算。
  private static var glassFallbackTokens: HistoryThemeTokens { AppearanceTheme.glass.makeTokens() }

  private func makeTokens() -> HistoryThemeTokens {
    switch self {
    case .glass:
      HistoryThemeTokens(
        identity: "glass",
        isNative: true,
        // 系统主题故意留在系统字体：它的定位就是跟随 macOS，而窗口里那些
        // 我们够不到的系统控件（菜单栏、右键菜单、Sparkle 弹窗）只会用系统字体。
        typography: .system,
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
        identity: "paper",
        isNative: false,
        // 思源宋体：纸质主题的落点是「印刷品」，衬线是这套主题的一半。
        // 7 个真字重，是这台机器上唯一撑得住完整界面层级的中文衬线。
        typography: .family("思源宋体 VF"),
        // 两档，不是三档：辅助区 #E6E3D8（导航列 + 列表列）→ 正文区 #FDFCF9。
        //
        // 原来是三档递进，导航列 #EFEDE5、列表列 #FAF9F5、详情卡片 #FDFCF9。
        // 量出来的问题是分级方向反了：唯一看得见的那一档（差 11/255）落在导航列
        // 和列表列之间——两个都是辅助列，本来最不需要分界；而真正该分开的
        // 「辅助 vs 正文」两侧只差 3/255，等于没分。列表列跟着画布走之后，
        // 整扇窗只剩一条明度边界，正好落在辅助区和正文区中间。
        canvas: ClaudePalette.sunken,         // #E6E3D8  导航列 / 列表列
        listPane: ClaudePalette.sunken,       // 同上：列表列不再自成一档
        card: ClaudePalette.raised,           // #FDFCF9  正文区
        selectionFill: ClaudePalette.orange,  // #D97757
        selectionText: ClaudePalette.light,
        hairline: ClaudePalette.lightGray,    // #DFDCD1
        badge: ClaudePalette.lightGray,
        primaryText: ClaudePalette.dark,      // #141413
        secondaryText: ClaudePalette.midGray, // #6E6C63
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
        identity: "ink",
        isNative: false,
        // 圆体而不是宋体：深色底上是浅字压暗底，衬线那些细笔画会被背景「吃」掉
        // 一部分（同样的笔画在浅色底上是暗字压亮底，不会）。圆体笔画均匀且偏粗，
        // 是这几个候选里深色底上最实的一个。
        //
        // 代价是只有 3 个字重，靠字重拉开层级的地方会比纸质主题平一些。
        typography: .family("Yuanti SC"),
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
      // 和 paper 不是同一张纸的不同温度，是**另一个色相**。见 `SepiaPalette`
      // 顶上那段——旧的「更黄一档」方案对浅色只有 ΔE 7，两套主题看着像同一套。
      HistoryThemeTokens(
        identity: "sepia",
        isNative: false,
        // 楷体：这套主题偏安静，字形本身也该往「久读不累」走。
        //
        // 原本选的是 Klee（日文教科書体），观感更贴，但它**缺简化字**：实测
        // 「这条记录来自哔哩哔哩」24 个字里有 7 个（这/记/录/哔/为/进）画不出来，
        // 逐字回退到 Songti SC，一句话里两种字形混排。Kaiti SC 是这个意图在
        // 简体中文里的对应物，3 个字重，简体覆盖满分。
        //
        // 代价是楷体笔画细，10pt 的计数和时间戳会偏虚。觉得不行就在设置里
        // 单独指定界面字体——主题只给默认值。
        typography: .family("Kaiti SC"),
        // 同 paper 收成两档：辅助区 #AEC2B1 → 正文区 #C0D6C3。
        canvas: SepiaPalette.sunkenPaper,     // #CBCADB  导航列 / 列表列
        listPane: SepiaPalette.sunkenPaper,   // 同上：列表列不再自成一档
        // 唯一和 paper 结构不同的一处：卡片比画布亮一档。
        // 低对比主题里 hairline 也淡，卡片再同色就真的分不出边界了。
        card: SepiaPalette.raisedPaper,       // #F0EEE6
        selectionFill: SepiaPalette.ochre,    // #788C5D
        selectionText: SepiaPalette.onAccent,
        hairline: SepiaPalette.rule,          // #E3DACC
        badge: SepiaPalette.badge,            // #E8E6DC
        primaryText: SepiaPalette.ink,        // #141413
        secondaryText: SepiaPalette.fadedInk, // #3D3D3A
        accent: SepiaPalette.ochre,
        // 状态色取官方色相**按比例压深**，直到在画布和正文卡两面都过 AA（4.5:1）。
        // 官方色板里这几支只有浅色版本（olive/sky/accent/kraft 是给大色块用的），
        // 直接当文字色在这套底上只有 2.0–3.3:1。压深只动明度，保住色相认知
        // （绿=成功、蓝=信息、红褐=危险）。
        //
        // 注：其余几套主题的状态色都还没过这条线（浅色的 warning 只有 2.58:1），
        // 那是一批更早的取值，本轮没动。
        success: themeColor(0x4E, 0x5B, 0x3C), // olive #788C5D 压到 65%，4.51:1
        warning: themeColor(0x6A, 0x51, 0x40), // kraft #D4A27F 压到 50%，4.54:1
        danger: themeColor(0x87, 0x42, 0x2B),  // accent #C6613F 压到 68%，4.57:1
        info: themeColor(0x3C, 0x58, 0x74),    // sky #6A9BCC 压到 56%，4.58:1
        encodesStatusByShape: false
      )
    case .mono:
      // 可读性优先：纯白底、纯黑字，强调色也是黑。
      //
      // 次要文字用 #4A4A4A（对白底约 9:1）而不是 paper 那种 #6E6C63——
      // paper 那档过了 AA 但够不上「高对比」这三个字。
      // 分隔线同理用 #767676，淡到看不见的线在这里是缺陷不是克制。
      HistoryThemeTokens(
        identity: "mono",
        isNative: false,
        // 这套主题的目的是**看得清**，不是有性格。所以取四套里字面最开、
        // 小字号最稳的 PingFang SC，而不是任何一种有风格的字体。
        //
        // 它不等于系统字体：系统字体是 SF Pro（中文才回退到 PingFang），
        // 指定 PingFang SC 之后拉丁字母和数字也一并交给它。
        typography: .family("PingFang SC"),
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
  /// macOS 的惯例是侧栏最沉、内容区最亮，视线自然往右走。
  ///
  /// 曾经是 #EFEDE5，对正文卡只差 5.3 个 L* 单位——「太融为一体」说的就是这一档。
  /// 现在拉到 8.8 个 L* 单位。上限不是审美问题而是对比度：画布每沉一档，压在
  /// 它上面的次要文字和分隔线就少一分，`midGray` / `lightGray` 必须跟着往下走。
  static let sunken = themeColor(0xE6, 0xE3, 0xD8)
  /// 详情区那张卡片，最亮的一档。
  static let raised = themeColor(0xFD, 0xFC, 0xF9)
  // 次要文字必须在两种底上都过 WCAG AA（4.5:1）：正文卡 #FDFCF9 上 5.9:1，
  // 辅助列画布 #E6E3D8 上 4.7:1。
  //
  // 这个值跟着 `sunken` 走：上一档 #6E6C63 配旧画布 #EFEDE5 是 4.49:1，画布沉到
  // #E6E3D8 后只剩 4.10:1——跌破 AA，而且是静默的，没有任何测试会红。
  static let midGray = themeColor(0x65, 0x63, 0x56)
  /// 分隔线与徽章底。同样跟着 `sunken` 走。
  ///
  /// 上一档 #E8E6DC 在新画布上只有 1.027:1，等于看不见（旧画布上是 1.067:1）。
  /// 这一档对新画布 1.069:1，把原来的可见度还了回来。
  static let lightGray = themeColor(0xDF, 0xDC, 0xD1)
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
/// 苔绿主题。原来这套叫「暖褐」，是一张更黄的纸。
///
/// 换掉的理由是量出来的：旧暖褐画布 #EADFC8 对浅色画布 #E6E3D8 的色差只有
/// **ΔE 7.0**（「接近，易混」），正文卡之间更是只有 5.4。两套主题真正不同的
/// 只有强调色和文字色，而底色占屏幕 95%——所以它不是「另一种纸」，只是同一
/// 张纸黄了一档，看上去像浅色主题脏了。
///
/// 新配色换的是**维度**而不是黄度：明度压到 L*≈76（浅色是 90，深色更暗），
/// 色相走低饱和的灰绿。对浅色画布 ΔE 16.5，一眼是两套东西。
///
/// 这些值不是挑出来的，是在「分栏差 7–12 L\* / 对浅色 ΔE ≥ 16 / 彩度 10–24 /
/// 正文 ≥7:1 / 次要 ≥4.5:1 / 分隔线 ≥1.05:1」这组约束下搜出来的最亮解——
/// 再亮就够不到 ΔE 门槛，再暗长文读着累。
/// 石楠主题。原来这套叫「暖褐」，是一张更黄的纸。
///
/// 换掉的理由是量出来的：旧暖褐画布 #EADFC8 对浅色画布 #E6E3D8 的色差只有
/// **ΔE 7.0**（「接近，易混」），正文卡之间 5.4。两套主题真正不同的只有强调色
/// 和文字色，而底色占屏幕 95%——它不是「另一种纸」，只是同一张纸黄了一档。
/// 旧的次要文字 #8B7B65 在自家画布上更是只有 2.6:1，远低于 AA，一直没人测到。
///
/// **这里每一个色值都出自 Anthropic 官方色板**（anthropic.com 的
/// `ant-brand.shared.css`，变量名写在各行后面），不是调出来的。曾经试过用约束
/// 求解生成配色，指标全过但很难看——指标能证伪，不能生成。
///
/// 选 heather 而不是别的：它对浅色画布 ΔE 16.9，是官方色板里能拉开最远的一支；
/// 冷灰紫对暖米黄，一眼是两套东西，而浅色主题本身完全不用动。
private enum SepiaPalette {
  /// `--swatch--heather`。侧栏与列表列。
  static let sunkenPaper = themeColor(0xCB, 0xCA, 0xDB)
  /// `--swatch--ivory-medium`。正文卡，比画布亮 12.2 个 L* 单位。
  static let raisedPaper = themeColor(0xF0, 0xEE, 0xE6)
  /// `--swatch--oat`。分隔线。
  ///
  /// 选它而不是 ivory-dark：ivory-dark 对正文卡只有 1.077:1，卡片内部的分隔线
  /// 会看不见。oat 两面分别是 1.166 / 1.192，和浅色主题的手感（1.171 / 1.338）
  /// 接近。分隔线必须**两个面都验**——只验画布是上一版栽过的坑。
  static let rule = themeColor(0xE3, 0xDA, 0xCC)
  /// `--swatch--ivory-dark`。徽章底：对画布 1.290，托 slate-medium 文字 8.71:1。
  static let badge = themeColor(0xE8, 0xE6, 0xDC)
  /// `--swatch--slate-dark`。正文：对画布 11.4:1、对卡 15.9:1。
  static let ink = themeColor(0x14, 0x14, 0x13)
  /// `--swatch--slate-medium`。次要文字：对画布 6.75:1、对卡 9.38:1，两边远超 AA。
  static let fadedInk = themeColor(0x3D, 0x3D, 0x3A)
  /// `--swatch--olive`。强调色。
  ///
  /// 配白字 3.68:1——按 WCAG 大字/粗体的 3:1 门槛是过的，而且比现状浅色的
  /// clay（3.12:1）还好一档。这是全 App 一致的既有取舍，不是这套主题的新问题。
  static let ochre = themeColor(0x78, 0x8C, 0x5D)
  /// `--swatch--ivory-light`。压在强调色上的文字。
  static let onAccent = themeColor(0xFA, 0xF9, 0xF5)
}

/// 高对比主题。只有黑、白和两级中性灰，没有色相。
private enum MonoPalette {
  static let white = themeColor(0xFF, 0xFF, 0xFF)
  static let black = themeColor(0x00, 0x00, 0x00)
  static let rule = themeColor(0x76, 0x76, 0x76)
  static let badge = themeColor(0xE8, 0xE8, 0xE8)
  static let secondary = themeColor(0x4A, 0x4A, 0x4A)
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
  /// 只替换界面字体，其余令牌原样保留。
  ///
  /// 用户在设置里指定界面字体后，走的就是这条：主题的颜色照旧，只有排版被覆盖。
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
    let tokens = (AppearanceTheme(rawValue: rawValue) ?? .glass).tokens
    let typography = UIFontSelection(storedValue: uiFontRawValue)
      .resolved(themeDefault: tokens.typography)
    return
      environment(\.appTheme, tokens.withTypography(typography))
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
