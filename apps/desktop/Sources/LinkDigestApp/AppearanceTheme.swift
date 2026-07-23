import AppKit
import SwiftUI

/// 用户可选外观：玻璃（系统原生 material）、纸质米黄、墨黑（石墨灰）。
/// 颜色统一收口为令牌，视图不直接写色值。
enum AppearanceTheme: String, CaseIterable, Identifiable {
  case glass
  case paper
  case ink

  static let storageKey = "com.syc.linkdigest.appearance-theme"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .glass: "系统"
    case .paper: "浅色"
    case .ink: "深色"
    }
  }

  var systemImageName: String {
    switch self {
    case .glass: "display"
    case .paper: "sun.max"
    case .ink: "moon"
    }
  }

  /// paper 固定浅色、ink 固定深色、glass 跟随系统。
  var colorScheme: ColorScheme? {
    switch self {
    case .glass: nil
    case .paper: .light
    case .ink: .dark
    }
  }

  /// Claude 风格只属于浅色阅读主题；系统玻璃与深色继续使用 macOS 原生排版。
  var usesEditorialReadingTypography: Bool { self == .paper }

  /// SwiftUI 的 preferredColorScheme(nil) 在 macOS 上不会把已设置的外观
  /// 复位，因此统一用 NSApp.appearance 做全局切换：nil 即回到跟随系统。
  @MainActor static func applyApplicationAppearance(_ rawValue: String) {
    let theme = AppearanceTheme(rawValue: rawValue) ?? .glass
    switch theme {
    case .glass: NSApp.appearance = nil
    case .paper: NSApp.appearance = NSAppearance(named: .aqua)
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
        accent: .accentColor
      )
    case .paper:
      HistoryThemeTokens(
        isNative: false,
        canvas: ClaudePalette.light,          // #FAF9F5
        listPane: ClaudePalette.light,
        card: ClaudePalette.light,
        selectionFill: ClaudePalette.orange,  // #D97757
        selectionText: ClaudePalette.light,
        hairline: ClaudePalette.lightGray,    // #E8E6DC
        badge: ClaudePalette.lightGray,
        primaryText: ClaudePalette.dark,      // #141413
        secondaryText: ClaudePalette.midGray, // #B0AEA5
        accent: ClaudePalette.orange
      )
    case .ink:
      HistoryThemeTokens(
        isNative: false,
        canvas: Color(nsColor: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)),   // #1C1C1E
        listPane: Color(nsColor: NSColor(srgbRed: 0.129, green: 0.129, blue: 0.141, alpha: 1)), // #212124
        card: Color(nsColor: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.165, alpha: 1)),     // #26262A
        selectionFill: .accentColor,
        selectionText: .white,
        hairline: Color.white.opacity(0.10),
        badge: Color.white.opacity(0.10),
        primaryText: .primary,
        secondaryText: .secondary,
        accent: .accentColor
      )
    }
  }
}

/// Anthropic/Claude 公开品牌色。集中定义，避免视图层自行取近似值。
private enum ClaudePalette {
  static let dark = color(0x14, 0x14, 0x13)
  static let light = color(0xFA, 0xF9, 0xF5)
  static let midGray = color(0xB0, 0xAE, 0xA5)
  static let lightGray = color(0xE8, 0xE6, 0xDC)
  static let orange = color(0xD9, 0x77, 0x57)

  private static func color(_ red: Int, _ green: Int, _ blue: Int) -> Color {
    Color(nsColor: NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    ))
  }
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
}
