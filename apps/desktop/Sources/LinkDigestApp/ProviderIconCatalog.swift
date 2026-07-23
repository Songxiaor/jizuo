import AppKit
import SwiftUI
import LinkDigestCore

/// Offline provider marks used by the settings list. The release pipelines
/// freeze this directory so a packaged settings screen never needs the network
/// merely to identify a provider.
enum ProviderIconCatalog {
  static let assetDirectory = "ProviderIcons"
  static let displayPointSize: CGFloat = 16

  private static let assetTable: [ProviderPreset: String] = [
    .openAI: "openai",
    .deepSeek: "deepseek",
    .deepInfra: "deepinfra",
    .openRouter: "openrouter",
    .groq: "groq",
    .siliconFlow: "siliconflow",
    .dashScope: "bailian",
    .zhipu: "zhipu",
    .ollama: "ollama",
  ]

  /// This cache is intentionally separate from website/platform icons: provider
  /// rows have a different identity space and may be shown on every settings refresh.
  nonisolated(unsafe) private static let rasterCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 16
    return cache
  }()

  static func assetName(for preset: ProviderPreset) -> String? {
    assetTable[preset]
  }

  static func image(for preset: ProviderPreset) -> NSImage? {
    guard let name = assetName(for: preset) else { return nil }
    if let cached = rasterCache.object(forKey: name as NSString) { return cached }
    guard let root = Bundle.main.resourceURL else { return nil }
    let url = root
      .appendingPathComponent(assetDirectory, isDirectory: true)
      .appendingPathComponent(name + ".svg")
    guard let image = crispenedIcon(from: url) else { return nil }
    rasterCache.setObject(image, forKey: name as NSString)
    return image
  }

  /// Any future or custom endpoint must remain visually identifiable even when
  /// it has no curated brand asset.
  static func fallbackInitial(for providerName: String) -> String {
    guard let first = providerName.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
    return String(first).uppercased()
  }

  static func fallbackInitial(for preset: ProviderPreset) -> String {
    fallbackInitial(for: preset.displayName)
  }

  static func fallbackColor(for providerName: String) -> Color {
    var hash: UInt64 = 5_381
    for byte in providerName.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return Color(hue: Double(hash % 360) / 360.0, saturation: 0.45, brightness: 0.72)
  }

  static func fallbackColor(for preset: ProviderPreset) -> Color {
    fallbackColor(for: preset.rawValue)
  }

  /// Keep provider SVGs on the exact same Retina rasterization path as the
  /// history platform icons, while retaining a provider-specific cache above.
  static func crispenedIcon(from url: URL) -> NSImage? {
    PlatformIconCatalog.crispenedIcon(from: url)
  }
}
