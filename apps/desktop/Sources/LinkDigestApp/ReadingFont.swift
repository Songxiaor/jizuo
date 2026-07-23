import AppKit
import SwiftUI

/// 用户可选阅读字体：只作用于阅读区（标题、正文、纯文本、实时转写）。
/// UI 控件保持系统无衬线，代码块保持等宽，这两条边界不随本偏好改变。
enum ReadingFontPreference: String, CaseIterable, Identifiable {
  /// 跟随主题：浅色纸质主题用衬线，系统/深色用无衬线（历史默认行为）。
  case theme
  case serif
  case sansSerif
  case songti
  case kaiti

  static let storageKey = "com.syc.linkdigest.reading-font"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .theme: "跟随主题"
    case .serif: "衬线"
    case .sansSerif: "无衬线"
    case .songti: "宋体"
    case .kaiti: "楷体"
    }
  }

  /// 解析为具体渲染面；跟随主题时由主题的编辑排版标记决定。
  func resolved(usesEditorialReadingTypography: Bool) -> ResolvedReadingFont {
    switch self {
    case .theme: usesEditorialReadingTypography ? .serif : .sans
    case .serif: .serif
    case .sansSerif: .sans
    case .songti: .named("Songti SC")
    case .kaiti: .named("Kaiti SC")
    }
  }
}

/// 阅读字体的渲染描述：系统 design（无衬线/衬线光学设计）或按 family 命名的
/// macOS 内置字体。命名字体不捆绑、不下载；缺失时回退系统字体避免空白渲染。
enum ResolvedReadingFont: Equatable {
  case sans
  case serif
  case named(String)

  func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    switch self {
    case .sans: .system(size: size, weight: weight, design: .default)
    case .serif: .system(size: size, weight: weight, design: .serif)
    case let .named(family): Font.custom(family, size: size).weight(weight)
    }
  }

  /// AttributedString 基底字体路径使用的 NSFont 描述符；与 `font(size:)` 保持同源。
  func nsFontDescriptor(size: CGFloat) -> NSFontDescriptor {
    switch self {
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
