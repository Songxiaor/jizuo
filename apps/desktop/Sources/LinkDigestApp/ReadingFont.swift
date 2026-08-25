import AppKit
import SwiftUI

/// 阅读区可选字体的目录。
///
/// 只收录**自带中文字形**的字体家族。这条限制不是洁癖：纸质主题原来把「衬线」
/// 解析成 `system(design: .serif)`（New York），而 New York 没有中文字形，中文
/// 只能逐字回退，回退路径不做标点挤压——表现就是每个「，」「。」后面裂开一道
/// 大缝。实测这台机器 246 个家族里只有 73 个自带中文，其余全会重现这个问题。
///
/// 判据是「用这个家族画『中』字时，CoreText 是否仍然落在这个家族上」。回退到
/// 别家就说明它自己没有这个字形。
enum ReadingFontCatalog {
  /// 枚举一次要遍历几百个家族并各做一次 CoreText 查询，够慢到不能放进 body。
  nonisolated(unsafe) private static var cachedFamilies: [String]?

  /// 保底项：即使目录枚举失败也必须有得选。
  static let fallbackFamily = "PingFang SC"

  /// 纸质主题下「跟随主题」解析到的中文衬线。
  ///
  /// 首选思源宋体：Songti SC 是屏幕渲染年代之前的字形，笔画末端的衬线在 16.5pt
  /// 上偏细，整段看下去发虚；思源宋体是为屏幕重画的，同字号下字面更实。
  ///
  /// 但它是开源字体，**不随 macOS 附带**——这台机器上装了，换台机器不一定有。
  /// `NSFont(name:)` 找不到时返回 nil，渲染层会掉回系统默认（无衬线），中文标点
  /// 挤压也跟着丢，就是当初 New York 那个「每个逗号后裂一道缝」的老问题。所以
  /// 这里不能硬编码：装了才用，没装退回系统自带的 Songti SC。
  ///
  /// 家族名必须写中文那个串。这台机器上 `NSFont(name: "Source Han Serif SC")`
  /// 返回 nil，只有 `"思源宋体 VF"` 能实例化——而它对外报的 `familyName` 却是
  /// `"Source Han Serif SC VF"`，两个名字对不上，所以别拿 familyName 去反查。
  static let editorialSerifFamily: String = {
    let preferred = "思源宋体 VF"
    return NSFont(name: preferred, size: 16) != nil ? preferred : "Songti SC"
  }()

  static func cjkCapableFamilies() -> [String] {
    if let cachedFamilies { return cachedFamilies }
    var families = NSFontManager.shared.availableFontFamilies.filter(supportsCJK)
    if families.isEmpty { families = [fallbackFamily] }
    families.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    cachedFamilies = families
    return families
  }

  static func supportsCJK(_ family: String) -> Bool {
    guard let font = NSFont(name: family, size: 16) else { return false }
    let resolved = CTFontCreateForString(font, "中" as CFString, CFRange(location: 0, length: 1))
    return (resolved as NSFont).familyName == font.familyName
  }

  /// 简化字探针。
  ///
  /// 这十个字在日文和韩文字体里通常只有对应的繁体或异体，简体字形是缺的。
  /// 「中」这类中日韩共有的字探不出区别——`supportsCJK` 单测「中」，于是
  /// Klee、Hiragino Mincho、YuMincho 这些日文字体全都能通过，但拿它们排简体
  /// 中文时会**逐字回退**：实测「这条记录来自哔哩哔哩」24 个字里有 7 个掉到
  /// 别的字体上，一句话里两种字形混排。
  static let simplifiedProbe = "龙买习鲁边这国见东车"

  /// 这个家族能不能自己画完整的简体中文。
  ///
  /// 判据和 `supportsCJK` 一样是「用它画这个字时 CoreText 是否仍落在它自己
  /// 身上」，只是把探针从一个中日韩共有字换成一组简化字。
  static func supportsSimplifiedChinese(_ family: String) -> Bool {
    guard let font = NSFont(name: family, size: 16) else { return false }
    return simplifiedProbe.allSatisfy { ch in
      let s = String(ch)
      let resolved = CTFontCreateForString(font, s as CFString, CFRange(location: 0, length: s.utf16.count))
      return (resolved as NSFont).familyName == font.familyName
    }
  }
}

/// 推荐字体名单。
///
/// 全部 74 个自带中文字形的家族里，绝大多数不适合这个 App：日文/韩文字体缺
/// 简化字，书法体和装饰体（行楷、隶书、魏碑、翩翩体、娃娃体…）在正文和界面
/// 上都读不了，点阵字体没有中文标点。名单不是口味，是下面这几条硬门槛筛出来的：
///
/// - 简体覆盖必须满分（`supportsSimplifiedChinese`）
/// - 至少两个字重，否则界面层级或正文的粗体标题会塌
/// - 不是书法体/装饰体
///
/// 完整列表仍然留着（选择器里的「其它」一档），这里只决定**推荐**哪些。
enum RecommendedFonts {
  /// 明显不适合正文与界面的书法体、装饰体与工具性字体。
  ///
  /// 这些都能通过上面的硬门槛（简体覆盖满分、标点齐全），只能靠名单排除：
  /// 程序判不出「这个字形适不适合读一千字」。
  private static let decorative: Set<String> = [
    "Baoli SC", "Baoli TC", "Libian SC", "Libian TC", "Weibei SC", "Weibei TC",
    "Xingkai SC", "Xingkai TC", "HanziPen SC", "HanziPen TC",
    "Hannotate SC", "Hannotate TC", "Wawati SC", "Wawati TC",
    "Yuppy SC", "Yuppy TC", "LingWai SC", "LingWai TC",
    "Kai", "Hei", "GB18030 Bitmap", "Arial Unicode MS",
    "BiauKaiHK", "BiauKaiTC",
  ]

  /// 界面字体：控件、列表、侧栏。
  ///
  /// 比阅读字体多一条要求——**10pt 上要立得住**。界面里最小的字（计数、时间戳）
  /// 是 10pt，笔画细的字体在这个尺寸上会发虚。
  static let uiPreference = [
    "PingFang SC",           // 无衬线，6 字重，macOS 中文标准字，最稳
    "思源宋体 VF",            // 衬线，7 字重，唯一撑得住完整界面层级的中文衬线
    "Yuanti SC",             // 圆体，3 字重，笔画均匀偏粗，深色底上最实
    "Lantinghei SC",         // 无衬线，3 字重，比 PingFang 更方
    "Songti SC",             // 衬线，4 字重，10pt 上偏虚，放在后面
    "Heiti SC",              // 无衬线，2 字重，老一代黑体
    "Hiragino Sans GB",      // 无衬线，2 字重，冬青黑体简体中文
    "STHeiti",               // 无衬线，2 字重
  ]

  /// 阅读字体：文章正文。
  ///
  /// 不要求 10pt 可读（正文最小 13pt），所以楷体这类界面上不行、长文里很好的
  /// 字体可以进来。
  static let readingPreference = [
    "思源宋体 VF",            // 为屏幕重画的宋体，长文首选
    "Songti SC",             // 系统自带宋体
    "Kaiti SC",              // 楷体，3 字重，教科书观感
    "PingFang SC",           // 无衬线，不喜欢衬线时的默认
    "Yuanti SC",             // 圆体
    "Lantinghei SC",         // 无衬线
    "SimSong",               // 衬线，2 字重
    "Hiragino Sans GB",      // 无衬线
  ]

  /// 名单 ∩ 这台机器上真的装了、且真的能画简体中文的。
  ///
  /// 名单是写死的，机器是活的：思源宋体是用户自己装的，系统字体也可能在
  /// 「字体册」里被停用。任何时候都以实测为准。
  static func available(_ preference: [String]) -> [String] {
    preference.filter { family in
      !decorative.contains(family)
        && ReadingFontCatalog.supportsSimplifiedChinese(family)
    }
  }

  static func ui() -> [String] { available(uiPreference) }
  static func reading() -> [String] { available(readingPreference) }

  /// 推荐名单之外、但仍自带中文字形的家族。选择器里的「其它」一档。
  static func others(excluding recommended: [String]) -> [String] {
    let shown = Set(recommended)
    return ReadingFontCatalog.cjkCapableFamilies().filter { !shown.contains($0) }
  }
}

/// 用户选的阅读字体：要么跟随主题，要么指定一个字体家族。
///
/// 存储值沿用旧 key。旧值（serif / sansSerif / songti / kaiti）迁移成具体家族名，
/// 其中 `serif` 特意迁到「宋体」而不是 New York——用户当初选的是「衬线」这个
/// 意图，New York 只是当时错误的实现。
enum ReadingFontSelection: Equatable {
  case theme
  case family(String)

  static let storageKey = "com.syc.linkdigest.reading-font"
  static let defaultStoredValue = "theme"

  private static let legacyMapping: [String: String] = [
    "serif": "Songti SC",
    "sansSerif": "PingFang SC",
    "songti": "Songti SC",
    "kaiti": "Kaiti SC",
  ]

  init(storedValue: String) {
    let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "theme" {
      self = .theme
      return
    }
    if let migrated = Self.legacyMapping[trimmed] {
      self = .family(migrated)
      return
    }
    self = .family(trimmed)
  }

  var storedValue: String {
    switch self {
    case .theme: "theme"
    case let .family(name): name
    }
  }

  var displayName: String {
    switch self {
    case .theme: "跟随主题"
    case let .family(name): name
    }
  }

  /// 解析为具体渲染面。
  ///
  /// 「跟随主题」在纸质主题下给中文衬线，其余给中文无衬线（PingFang）。
  /// 两者都自带中文字形，所以默认组合不会再出现标点裂缝。
  /// 衬线具体落到哪个家族见 `ReadingFontCatalog.editorialSerifFamily`——它会
  /// 在思源宋体缺席的机器上自己退回 Songti SC。
  func resolved(
    usesEditorialReadingTypography: Bool,
    bodySize: CGFloat
  ) -> ResolvedReadingFont {
    switch self {
    case .theme:
      return ResolvedReadingFont(
        face: .named(
          usesEditorialReadingTypography
            ? ReadingFontCatalog.editorialSerifFamily
            : "PingFang SC"
        ),
        bodySize: bodySize
      )
    case let .family(name):
      return ResolvedReadingFont(face: .named(name), bodySize: bodySize)
    }
  }
}

/// 阅读区正文字号偏好。
enum ReadingFontSize {
  static let storageKey = "com.syc.linkdigest.reading-font-size"
  static let `default`: CGFloat = 16.5
  static let minimum: CGFloat = 13
  static let maximum: CGFloat = 24
  static let step: CGFloat = 0.5

  /// 存量偏好和手工改过的 plist 都可能越界；渲染层不接受越界字号。
  static func clamped(_ value: CGFloat) -> CGFloat {
    guard value.isFinite, value > 0 else { return `default` }
    return min(max(value, minimum), maximum)
  }
}

/// 阅读字体的渲染描述：字形面 + 正文字号。
///
/// 字号放进来而不是单独传：`readingFont` 已经贯穿三十多个调用点，正文和标题
/// 必须同源缩放，拆成两个参数迟早会有一处忘记跟着变。
// Hashable：阅读渲染缓存（ReadingRenderCache）把字体作为缓存键的一部分。
struct ResolvedReadingFont: Equatable, Hashable {
  enum Face: Equatable, Hashable {
    case sans
    case serif
    case named(String)
  }

  let face: Face
  let bodySize: CGFloat

  init(face: Face, bodySize: CGFloat = ReadingFontSize.default) {
    self.face = face
    self.bodySize = ReadingFontSize.clamped(bodySize)
  }

  // 旧调用点用 `.sans` / `.serif` / `.named(x)` 当 ResolvedReadingFont 值；
  // 保留同名入口，避免为了加字号去动几十处签名。
  static let sans = ResolvedReadingFont(face: .sans)
  static let serif = ResolvedReadingFont(face: .serif)
  static func named(_ family: String) -> ResolvedReadingFont {
    ResolvedReadingFont(face: .named(family))
  }

  func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    switch face {
    case .sans: .system(size: size, weight: weight, design: .default)
    case .serif: .system(size: size, weight: weight, design: .serif)
    case let .named(family): Font.custom(family, size: size).weight(weight)
    }
  }

  /// 正文字号本身。
  func body(weight: Font.Weight = .regular) -> Font {
    font(size: bodySize, weight: weight)
  }

  /// 按「设计稿字号 ÷ 默认正文字号」的比例跟随用户字号缩放。
  /// 标题、引用等都走这里，用户调大正文时整套层级一起放大，不会挤成一团。
  func scaled(designSize: CGFloat, weight: Font.Weight = .regular) -> Font {
    font(size: scaledSize(designSize), weight: weight)
  }

  func scaledSize(_ designSize: CGFloat) -> CGFloat {
    designSize * bodySize / ReadingFontSize.default
  }

  /// 编辑器用的正文 NSFont。与阅读区同源，保证「写」和「读」是同一套排版。
  func nsFont() -> NSFont {
    NSFont(descriptor: nsFontDescriptor(size: bodySize), size: bodySize)
      ?? NSFont.systemFont(ofSize: bodySize)
  }

  /// AttributedString 基底字体路径使用的 NSFont 描述符；与 `font(size:)` 保持同源。
  func nsFontDescriptor(size: CGFloat) -> NSFontDescriptor {
    switch face {
    case .sans:
      return NSFont.systemFont(ofSize: size).fontDescriptor
    case .serif:
      let base = NSFont.systemFont(ofSize: size).fontDescriptor
      return base.withDesign(.serif) ?? base
    case let .named(family):
      let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
      guard NSFont(descriptor: descriptor, size: size) != nil else {
        return NSFont.systemFont(ofSize: size).fontDescriptor
      }
      return descriptor
    }
  }
}
