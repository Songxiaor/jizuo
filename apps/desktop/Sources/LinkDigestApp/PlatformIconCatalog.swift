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

  /// Strips subdomain noise and resolves known aliases to the same stable key.
  static func normalizedHost(_ host: String) -> String {
    HistoryPlatformRegistry.canonicalHost(for: host)
  }

  /// Registered domain → bundled asset. Every entry must have a matching file
  /// in `apps/desktop/Assets/PlatformIcons` **and** an entry in the frozen
  /// `PLATFORM_ICON_FILES` tuple of the release/local-test packaging scripts,
  /// or release verification rejects the candidate for icon-set drift.
  static func assetName(for host: String) -> String? {
    HistoryPlatformRegistry.bundledAssetName(forHost: host)
  }

  /// All bundled platform marks render in monochrome, following the current
  /// text color (AppKit template rendering). Brand-coloured marks turned the
  /// sidebar and the list into a palette — ten hues in one column was the
  /// single largest "not refined" signal. Recognition stays via each mark's
  /// distinct silhouette.
  ///
  /// Coloured originals stay untouched on disk; the dark pixels are lifted
  /// into a single near-black tint at load time (see `monochromed`), which
  /// keeps multi-tone marks (douyin's PNG-in-SVG, bilibili's fills) legible
  /// instead of collapsing them into solid blobs.
  static func usesTemplateRendering(forAssetName name: String) -> Bool {
    true
  }

  /// Luma below this counts as "part of the mark" and is tinted; above it the
  /// pixel fades out proportionally. Chosen so white backgrounds and brand
  /// colours both vanish while dark strokes survive — the palette here spans
  /// #0F1419 (x.com) through mid-saturated brand hues, none of which exceed
  /// this luma except near-white decoration.
  private static let monoLumaCutoff: Double = 0.92

  /// Converts a coloured platform mark into an alpha-only silhouette tinted
  /// near-black, suitable for template rendering. Runs once per asset; the
  /// result is held by `rasterCache`, so the histogram walk never repeats.
  private static func monochromed(_ source: NSImage) -> NSImage {
    let pixel = Int(rasterPixelSize)
    guard
      let srcRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      )
    else { return source }
    NSGraphicsContext.saveGraphicsState()
    if let context = NSGraphicsContext(bitmapImageRep: srcRep) {
      NSGraphicsContext.current = context
      context.imageInterpolation = .high
      context.shouldAntialias = true
      source.draw(
        in: NSRect(origin: .zero, size: NSSize(width: pixel, height: pixel)),
        from: .zero, operation: .sourceOver, fraction: 1.0
      )
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = srcRep.bitmapData else { return source }

    var peak: Double = 0
    for i in stride(from: 0, to: pixel * pixel * 4, by: 4) {
      let a = Double(data[i + 3]) / 255.0
      guard a > 0.05 else { continue }
      let luma = (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255.0
      peak = max(peak, (monoLumaCutoff - luma) * a)
    }
    guard peak > 0 else { return source }

    for i in stride(from: 0, to: pixel * pixel * 4, by: 4) {
      let a = Double(data[i + 3]) / 255.0
      let luma = (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255.0
      let strength = min(1, max(0, (monoLumaCutoff - luma) * a / peak))
      // 固定近黑墨色，与原本单色 SVG 的 #0F1419 一致；真正的主题色由
      // template 渲染在绘制时统一供给，这里只负责留下「形状的深浅」。
      data[i] = 0x1B
      data[i + 1] = 0x1B
      data[i + 2] = 0x1F
      data[i + 3] = UInt8((strength * 255).rounded())
    }

    let image = NSImage(size: NSSize(width: displayPointSize, height: displayPointSize))
    srcRep.size = NSSize(width: displayPointSize, height: displayPointSize)
    image.addRepresentation(srcRep)
    return image
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
    let resolved = monochromed(image)
    resolved.isTemplate = usesTemplateRendering(forAssetName: name)
    rasterCache.setObject(resolved, forKey: name as NSString)
    return resolved
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

  /// 历史侧栏与列表行的未知来源不再发随机彩色块——一列里每个未知来源一个
  /// 随机色，正是「调色盘」观感的一部分。统一成主题无关的中性灰底，靠首字母
  /// 区分来源。站点登录页仍用上面的彩色版（那里一行一个站点，不构成噪声）。
  static func fallbackBadgeBackground(for host: String) -> Color {
    Color.secondary.opacity(0.18)
  }

  static func fallbackBadgeForeground(for host: String) -> Color {
    Color.primary.opacity(0.7)
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
    // isTemplate 由调用方（`image(for:)`）在单色化之后统一设置。
    return image
  }
}
