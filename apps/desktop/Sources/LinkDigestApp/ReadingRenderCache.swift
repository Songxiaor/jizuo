import AppKit
import SwiftUI
import LinkDigestCore

/// 阅读区渲染的备忘缓存：Markdown 块解析、富文本组装、纯文本组装。
///
/// 详情视图观察着一个有八十多个发布属性的 ViewModel，任何无关变化（图标
/// 加载完一个、转写进度更新一段）都会让 body 重新求值。以前每次求值都要
/// 「全文解析块 → 逐块过 Apple Markdown 解析器组富文本」，正文越长越卡——
/// 打开一篇长文后，点一下别处的按钮都要重付一遍整篇解析的钱。
///
/// 这里按输入备忘：内容、字体、配色、外观都没变时返回**上一次的同一个
/// 实例**。同一性另有一个用处：NSTextView 侧可以用 `===` 秒判「没变」，
/// 连深比较都省掉（见 SelectableReadingTextView.updateNSView）。
///
/// 只在主线程使用；条目数用小容量 LRU 限住，正文不会被无限持有。
@MainActor
enum ReadingRenderCache {
  /// 同时驻留的缓存条目数。取值考虑的是「一篇图文混排长文会拆成多少段」：
  /// 真实素材里出现过 26 张图的文章，正文会被切成约 27 个 text 段，块解析
  /// 与富文本两路各占一条。24 会被这种文章整体打穿——每次重绘全部 miss，
  /// 缓存等于不存在。96 能容下这种极端条目再留出上一条的余量。
  private static let capacity = 96
  /// 一条社区长帖可能有数百条评论。评论正文通常很短，但每次重绘逐条重新走
  /// Apple Markdown 解析仍会形成明显尖峰；单独给行内正文更大的有界缓存。
  private static let inlineCapacity = 512

  // MARK: - 块解析

  private static var blockEntries: [String: [MarkdownPresentation.Block]] = [:]
  private static var blockOrder: [String] = []

  static func blocks(from source: String) -> [MarkdownPresentation.Block] {
    if let cached = lookup(source, in: blockEntries, order: &blockOrder) { return cached }
    let parsed = MarkdownPresentation.blocks(from: source)
    remember(parsed, forKey: source, in: &blockEntries, order: &blockOrder)
    return parsed
  }

  // MARK: - 评论行内 Markdown

  private static var inlineEntries: [String: AttributedString] = [:]
  private static var inlineOrder: [String] = []

  static func inlineAttributed(from source: String) -> AttributedString {
    if let cached = lookup(source, in: inlineEntries, order: &inlineOrder) { return cached }
    let parsed = MarkdownPresentation.inlineAttributed(source)
    remember(
      parsed,
      forKey: source,
      in: &inlineEntries,
      order: &inlineOrder,
      capacity: inlineCapacity
    )
    return parsed
  }

  // MARK: - 富文本组装（阅读排版）

  private struct AttributedKey: Hashable {
    let blocks: [MarkdownPresentation.Block]
    let font: ResolvedReadingFont
    let paletteKey: [CGFloat]
    /// 语义色（.primary 等）的解析结果随外观翻转，色值指纹抓不到这种
    /// 变化，所以外观名也是键的一部分。
    let appearance: String
  }

  private static var attributedEntries: [AttributedKey: NSAttributedString] = [:]
  private static var attributedOrder: [AttributedKey] = []

  static func attributed(
    blocks: [MarkdownPresentation.Block],
    readingFont: ResolvedReadingFont,
    palette: ReadingTextComposer.Palette
  ) -> NSAttributedString {
    let key = AttributedKey(
      blocks: blocks,
      font: readingFont,
      paletteKey: palette.fingerprint,
      appearance: NSApp.effectiveAppearance.name.rawValue
    )
    if let cached = lookup(key, in: attributedEntries, order: &attributedOrder) { return cached }
    let composed = ReadingTextComposer.attributed(
      blocks: blocks, readingFont: readingFont, palette: palette
    )
    remember(composed, forKey: key, in: &attributedEntries, order: &attributedOrder)
    return composed
  }

  // MARK: - 纯文本组装

  private struct PlainKey: Hashable {
    let source: String
    let font: ResolvedReadingFont
    let colorKey: [CGFloat]
    let appearance: String
  }

  private static var plainEntries: [PlainKey: NSAttributedString] = [:]
  private static var plainOrder: [PlainKey] = []

  /// 「纯文本」开关那条路：plainTextPresentation 本身也是整篇字符串处理，
  /// 一并备忘，开关切换或主题变化才重算。
  static func plainAttributed(
    source: String,
    readingFont: ResolvedReadingFont,
    color: NSColor
  ) -> NSAttributedString {
    let key = PlainKey(
      source: source,
      font: readingFont,
      colorKey: Self.colorFingerprint(color),
      appearance: NSApp.effectiveAppearance.name.rawValue
    )
    if let cached = lookup(key, in: plainEntries, order: &plainOrder) { return cached }
    let composed = ReadingTextComposer.plain(
      MarkdownPresentation.plainTextPresentation(source),
      readingFont: readingFont,
      color: color
    )
    remember(composed, forKey: key, in: &plainEntries, order: &plainOrder)
    return composed
  }

  // MARK: - 详情派生值
  //
  // 下面三组和渲染本身无关，但同属「详情 body 每次求值都要付一遍整篇扫描」
  // 的债：面板正文的 frontmatter 剥离、总结的原文依据匹配、图文混排切段。
  // 详情视图观察的巨型 ViewModel 任何一个属性变化都会重求值 body，这些
  // 派生值只取决于正文内容，备忘住之后重绘只剩一次字典查找。

  private struct PaneBodyKey: Hashable {
    let source: String
    let stripsEchoedMetadata: Bool
  }

  private static var paneBodyEntries: [PaneBodyKey: String] = [:]
  private static var paneBodyOrder: [PaneBodyKey] = []

  /// 阅读面板正文：剥 frontmatter，翻译面板再清一次旧译文回显的元数据块。
  static func paneBody(source: String, strippingEchoedMetadata: Bool) -> String {
    let key = PaneBodyKey(source: source, stripsEchoedMetadata: strippingEchoedMetadata)
    if let cached = lookup(key, in: paneBodyEntries, order: &paneBodyOrder) { return cached }
    var body = MarkdownNoteFrontmatter.parse(source).body
    if strippingEchoedMetadata {
      body = MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: body)
    }
    remember(body, forKey: key, in: &paneBodyEntries, order: &paneBodyOrder)
    return body
  }

  private struct CitationsKey: Hashable {
    let summary: String
    let source: String
  }

  private static var citationsEntries: [CitationsKey: [String]] = [:]
  private static var citationsOrder: [CitationsKey] = []

  /// 总结的「原文依据」：原来每次求值都要把原文整篇重建纯文本再逐条 contains。
  static func summaryCitations(summary: String, source: String) -> [String] {
    let key = CitationsKey(summary: summary, source: source)
    if let cached = lookup(key, in: citationsEntries, order: &citationsOrder) { return cached }
    let quotes = SummaryCitationMatcher.exactQuotes(
      summary: MarkdownNoteFrontmatter.parse(summary).body,
      source: MarkdownNoteFrontmatter.parse(source).body
    )
    remember(quotes, forKey: key, in: &citationsEntries, order: &citationsOrder)
    return quotes
  }

  private struct SegmentsKey: Hashable {
    let markdown: String
    let localImageURLs: [URL]
    let appendsUnusedLocalImages: Bool
    let groupsConsecutiveImages: Bool
  }

  private static var segmentsEntries: [SegmentsKey: [LocalMarkdownImageLayout.Segment]] = [:]
  private static var segmentsOrder: [SegmentsKey] = []

  /// 图文混排切段（含图集合并）：整篇正则扫描，只随正文与本地图片清单变化。
  static func gallerySegments(
    markdown: String,
    localImageURLs: [URL],
    appendsUnusedLocalImages: Bool,
    groupsConsecutiveImages: Bool = true
  ) -> [LocalMarkdownImageLayout.Segment] {
    let key = SegmentsKey(
      markdown: markdown,
      localImageURLs: localImageURLs,
      appendsUnusedLocalImages: appendsUnusedLocalImages,
      groupsConsecutiveImages: groupsConsecutiveImages
    )
    if let cached = lookup(key, in: segmentsEntries, order: &segmentsOrder) { return cached }
    let grouped = LocalMarkdownImageLayout.galleryGrouped(
      LocalMarkdownImageLayout.segments(
        markdown: markdown,
        localImageURLs: localImageURLs,
        appendsUnusedLocalImages: appendsUnusedLocalImages
      ),
      groupsConsecutiveImages: groupsConsecutiveImages
    )
    remember(grouped, forKey: key, in: &segmentsEntries, order: &segmentsOrder)
    return grouped
  }

  // MARK: - 内部

  nonisolated static func colorFingerprint(_ color: NSColor) -> [CGFloat] {
    guard let srgb = color.usingColorSpace(.sRGB) else { return [-1, -1, -1, -1] }
    return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
  }

  /// 命中即续命：把命中的键挪到队尾，淘汰顺序从 FIFO 变成 LRU。
  /// 没有这一步，正在看的这篇长文会被后进的条目顶出去。
  private static func lookup<Key: Hashable, Value>(
    _ key: Key,
    in entries: [Key: Value],
    order: inout [Key]
  ) -> Value? {
    guard let value = entries[key] else { return nil }
    if order.last != key, let index = order.lastIndex(of: key) {
      order.remove(at: index)
      order.append(key)
    }
    return value
  }

  private static func remember<Key: Hashable, Value>(
    _ value: Value,
    forKey key: Key,
    in entries: inout [Key: Value],
    order: inout [Key],
    capacity: Int = capacity
  ) {
    entries[key] = value
    order.append(key)
    if order.count > capacity {
      let evicted = order.removeFirst()
      entries.removeValue(forKey: evicted)
    }
  }
}
