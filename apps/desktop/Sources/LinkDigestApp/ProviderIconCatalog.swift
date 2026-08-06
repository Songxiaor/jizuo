import AppKit
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
    .openCodeGo: "opencode",
    .openCodeZen: "opencode",
    .groq: "groq",
    .siliconFlow: "siliconflow",
    .dashScope: "bailian",
    .zhipu: "zhipu",
    .stepFun: "stepfun",
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
    let value = normalizedProviderName(providerName)
    guard let first = value.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
    return String(first).uppercased()
  }

  /// 自定义服务商没有品牌资产，名字直接取自 Base URL 的 host，而真实世界的
  /// Base URL 绝大多数长成 `https://api.foo.com/v1`。直接取首字母的结果是十个
  /// 互不相干的自定义服务商全都印着一个「A」，跟之前全都印「自」没差多少。
  ///
  /// 所以先按站点规则归一化（`www.`/`m.` 之类由 `HistoryHostNormalizer` 负责），
  /// 再补剥一层 `api.`：`api.deepinfra.com` → D。只剥带点的 `api.`，
  /// 「Apidog」这类真名开头不受影响。
  private static func normalizedProviderName(_ providerName: String) -> String {
    var value = HistoryHostNormalizer.normalized(providerName)
    if value.hasPrefix("api.") { value.removeFirst("api.".count) }
    return value
  }

  /// Keep provider SVGs on the exact same Retina rasterization path as the
  /// history platform icons, while retaining a provider-specific cache above.
  static func crispenedIcon(from url: URL) -> NSImage? {
    PlatformIconCatalog.crispenedIcon(from: url)
  }
}
