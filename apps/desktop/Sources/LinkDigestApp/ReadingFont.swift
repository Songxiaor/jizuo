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
  /// 「跟随主题」在纸质主题下给中文衬线（宋体），其余给中文无衬线（PingFang）。
  /// 两者都自带中文字形，所以默认组合不会再出现标点裂缝。
  func resolved(
    usesEditorialReadingTypography: Bool,
    bodySize: CGFloat
  ) -> ResolvedReadingFont {
    switch self {
    case .theme:
      return ResolvedReadingFont(
        face: .named(usesEditorialReadingTypography ? "Songti SC" : "PingFang SC"),
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
struct ResolvedReadingFont: Equatable {
  enum Face: Equatable {
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
