import AppKit
import SwiftUI
import LinkDigestCore

/// Built-in, local brand marks for high-frequency sources. These files are
/// sealed into the App bundle; `WebsiteFaviconCache` remains the best-effort
/// fallback only for sources without a mapping.
///
/// Icons are loaded from SVG and re-rasterized at a Retina pixel budget so the
/// 16pt list cell does not show soft edges from a 16×16 logical SVG rep.
enum PlatformIconCatalog {
  static let assetDirectory = "PlatformIcons"
  /// Logical point size used in the history list.
  static let displayPointSize: CGFloat = 16
  /// Raster pixel size (2× Retina). Larger than display to keep edges crisp.
  static let rasterPixelSize: CGFloat = 32

  /// Strips the subdomain noise that would otherwise force one table row per
  /// spelling. Adding a platform must stay a one-line change to `assetTable`.
  static func normalizedHost(_ host: String) -> String {
    HistoryHostNormalizer.normalized(host)
  }

  /// Registered domain → bundled asset. Every entry must have a matching file
  /// in `apps/desktop/Assets/PlatformIcons` **and** an entry in the frozen
  /// `PLATFORM_ICON_FILES` tuple of the release/local-test packaging scripts,
  /// or release verification rejects the candidate for icon-set drift.
  private static let assetTable: [String: String] = [
    "x.com": "x.com", "twitter.com": "x.com",
    "weixin.qq.com": "wechat", "mp.weixin.qq.com": "wechat",
    "github.com": "github",
    "zhihu.com": "zhihu", "zhuanlan.zhihu.com": "zhihu",
    "bilibili.com": "bilibili", "b23.tv": "bilibili",
    "youtube.com": "youtube", "youtu.be": "youtube",
    "reddit.com": "reddit",
    "medium.com": "medium",
    // Sources that previously fell through to the network favicon path and
    // therefore never resolved an icon at all.
    "douyin.com": "douyin", "iesdouyin.com": "douyin",
    "xiaohongshu.com": "xiaohongshu", "xhslink.com": "xiaohongshu",
    "weibo.com": "weibo", "weibo.cn": "weibo",
    "toutiao.com": "toutiao",
    "douban.com": "douban",
    "juejin.cn": "juejin",
  ]

  static func assetName(for host: String) -> String? {
    let value = normalizedHost(host)
    if let direct = assetTable[value] { return direct }
    // `zhuanlan.zhihu.com` style subdomains resolve through their parent.
    var remainder = Substring(value)
    while let dot = remainder.firstIndex(of: ".") {
      remainder = remainder[remainder.index(after: dot)...]
      guard remainder.contains(".") else { break }
      if let parent = assetTable[String(remainder)] { return parent }
    }
    return nil
  }

  /// These brand marks are intentionally monochrome. Their bundled SVGs use a
  /// near-black fill, which disappears on the ink theme unless AppKit treats
  /// the rasterized image as a template and supplies the current text color.
  static func usesTemplateRendering(forAssetName name: String) -> Bool {
    name == "x.com" || name == "github"
  }

  /// Rasterizing an SVG is expensive and the history list re-renders every row
  /// on each state change, so the bitmap is produced once per asset.
  /// `NSCache` is thread-safe, which is what `nonisolated(unsafe)` asserts here.
  nonisolated(unsafe) private static let rasterCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    return cache
  }()

  static func image(for host: String) -> NSImage? {
    guard let name = assetName(for: host) else { return nil }
    if let cached = rasterCache.object(forKey: name as NSString) { return cached }
    guard let root = Bundle.main.resourceURL else { return nil }
    let url = root
      .appendingPathComponent(assetDirectory, isDirectory: true)
      .appendingPathComponent(name + ".svg")
    guard let image = crispenedIcon(from: url) else { return nil }
    image.isTemplate = usesTemplateRendering(forAssetName: name)
    rasterCache.setObject(image, forKey: name as NSString)
    return image
  }

  /// Stable, deterministic mark for any source without a bundled asset, so a
  /// row never falls back to an anonymous grey document glyph.
  static func fallbackInitial(for host: String) -> String {
    let value = normalizedHost(host)
    guard let first = value.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
    return String(first).uppercased()
  }

  /// Hue derived from the host so the same source keeps the same colour across
  /// launches without persisting anything.
  static func fallbackColor(for host: String) -> Color {
    let value = normalizedHost(host)
    var hash: UInt64 = 5_381
    for byte in value.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return Color(hue: Double(hash % 360) / 360.0, saturation: 0.45, brightness: 0.72)
  }

  /// Loads the SVG and returns a bitmap-backed `NSImage` sized for Retina list rows.
  static func crispenedIcon(from url: URL) -> NSImage? {
    guard let source = NSImage(contentsOf: url) else { return nil }
    let pixel = rasterPixelSize
    let point = displayPointSize
    let bitmapSize = NSSize(width: pixel, height: pixel)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(pixel),
      pixelsHigh: Int(pixel),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      source.size = NSSize(width: point, height: point)
      return source
    }
    rep.size = bitmapSize
    NSGraphicsContext.saveGraphicsState()
    if let context = NSGraphicsContext(bitmapImageRep: rep) {
      NSGraphicsContext.current = context
      context.imageInterpolation = .high
      context.shouldAntialias = true
      // Draw the vector into the high-res bitmap.
      source.draw(
        in: NSRect(origin: .zero, size: bitmapSize),
        from: NSRect(origin: .zero, size: source.size == .zero ? bitmapSize : source.size),
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: point, height: point))
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
  }
}
