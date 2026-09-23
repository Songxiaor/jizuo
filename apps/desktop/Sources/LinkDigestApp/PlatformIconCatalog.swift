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

  /// These brand marks are intentionally monochrome. Their bundled SVGs use a
  /// near-black fill, which disappears on the ink theme unless AppKit treats
  /// the rasterized image as a template and supplies the current text color.
  static func usesTemplateRendering(forAssetName name: String) -> Bool {
    name == "x.com" || name == "github"
  }

  /// 侧栏单色模式下本身就是细线条的 logo：直接取形状、用当前文字色填。
  ///
  /// 和 `usesTemplateRendering` 分开：那条决定的是**所有地方**的位图是否是模板图，
  /// 列表行里 B 站、掘金仍要保留品牌色；这条只管侧栏的单色剪影。
  /// 其余 logo 在侧栏一律走 `sidebarOutlineImage` 的线框画法（2026-09-23）。
  static func usesGlyphSilhouette(forAssetName name: String) -> Bool {
    ["x.com", "bilibili", "juejin"].contains(name)
  }

  /// 深底白标型 logo（YouTube、抖音、知乎…）：线框之外还要保留底色块里的白色标志，
  /// 否则只剩一个空框认不出是谁。GitHub、公众号这类本身是实心外形，只取外轮廓
  /// （连同内部镂空的轮廓）就够。
  static func keepsInnerMarkInOutline(forAssetName name: String) -> Bool {
    !["github", "wechat"].contains(name)
  }

  nonisolated(unsafe) private static let outlineCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  /// 侧栏用的线框版 logo：模板图，颜色由调用方的 foregroundStyle 给。
  ///
  /// 为什么要自动描边：侧栏一列平台图标里原来一半是实心块（公众号、GitHub、YouTube、
  /// Reddit……），实测这一列的墨量是旁边平台名称的 3.5 倍、是「本机」区系统线条图标的
  /// 2.5 倍，一眼看过去先看到一排色块（2026-09-23 Syc：「这一块很重」）。品牌方
  /// 不提供线框版，这里把外形做一次腐蚀，用「外形 − 腐蚀后的外形」得到约 1pt 的轮廓，
  /// 深底白标型再叠回里面的白色标志——外形和标志都还认得出，重量接近系统线条图标。
  static func sidebarOutlineImage(forAssetName name: String) -> NSImage? {
    if let cached = outlineCache.object(forKey: name as NSString) { return cached }
    guard let root = Bundle.main.resourceURL,
          let source = NSImage(contentsOf: root
            .appendingPathComponent(assetDirectory, isDirectory: true)
            .appendingPathComponent(name + ".svg"))
    else { return nil }
    guard let image = outlineImage(from: source, keepsInnerMark: keepsInnerMarkInOutline(forAssetName: name))
    else { return nil }
    outlineCache.setObject(image, forKey: name as NSString)
    return image
  }

  /// 光栅 64px（16pt 的 4 倍），腐蚀半径 5px ≈ 显示时 1pt 线宽。
  static func outlineImage(from source: NSImage, keepsInnerMark: Bool) -> NSImage? {
    let size = 64, radius = 5
    func makeRep() -> NSBitmapImageRep? {
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4, bitsPerPixel: 32
      )
    }
    guard let input = makeRep(), let output = makeRep(),
          let src = input.bitmapData, let dst = output.bitmapData else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: input)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let count = size * size
    var alpha = [Double](repeating: 0, count: count)
    var mark = [Double](repeating: 0, count: count)
    for index in 0..<count {
      let a = Double(src[index * 4 + 3]) / 255
      alpha[index] = a
      guard keepsInnerMark, a > 0 else { continue }
      // 预乘过的颜色先还原再算亮度；亮的部分就是底色块上的白色标志。
      let luminance = (0.299 * Double(src[index * 4]) + 0.587 * Double(src[index * 4 + 1])
        + 0.114 * Double(src[index * 4 + 2])) / 255 / a
      mark[index] = min(1, max(0, (luminance - 0.55) / 0.3)) * a
    }
    var offsets: [(Int, Int)] = []
    for dy in -radius...radius { for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
      offsets.append((dx, dy))
    } }
    for y in 0..<size { for x in 0..<size {
      let index = y * size + x
      var eroded = alpha[index]
      if eroded > 0 {
        for (dx, dy) in offsets {
          let xx = x + dx, yy = y + dy
          let value = (xx < 0 || yy < 0 || xx >= size || yy >= size) ? 0 : alpha[yy * size + xx]
          if value < eroded { eroded = value; if eroded == 0 { break } }
        }
      }
      let coverage = min(1, max(0, alpha[index] - eroded) + mark[index])
      let byte = UInt8((coverage * 255).rounded())
      dst[index * 4] = byte; dst[index * 4 + 1] = byte; dst[index * 4 + 2] = byte
      dst[index * 4 + 3] = byte
    } }
    output.size = NSSize(width: displayPointSize, height: displayPointSize)
    let image = NSImage(size: NSSize(width: displayPointSize, height: displayPointSize))
    image.addRepresentation(output)
    image.isTemplate = true
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

  /// 本机来源没有品牌图标，用系统符号：比首字母徽标（V、L）更能一眼认出是什么。
  static func localSourceSymbolName(for host: String) -> String? {
    switch normalizedHost(host) {
    case LocalImportSource.voiceMemos.rawValue: "waveform"
    case LocalImportSource.files.rawValue: "doc"
    case LocalImportSource.appleNotes.rawValue: "note.text"
    default: nil
    }
  }

  static func image(for host: String) -> NSImage? {
    if let symbol = localSourceSymbolName(for: host) {
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      image?.isTemplate = true
      return image
    }
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
  /// launches without persisting anything. Kept for the site-login settings
  /// list; the history sidebar and rows went neutral (see below).
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
    image.isTemplate = false
    return image
  }
}
