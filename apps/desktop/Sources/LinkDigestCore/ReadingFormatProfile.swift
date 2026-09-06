import Foundation

/// 正文的形态指纹——只看正文本身量得出来的东西。
///
/// 存在的理由：排版决策过去按**平台**硬编码（`!isWeChatCapture` 之类），而平台
/// 是弱信号。同一个公众号既发代码教程也发随笔，同一个站点既有长文也有图集。
/// 按平台分派意味着每加一个来源都要重新判断一遍它「像谁」，判错了不会报错，
/// 只表现为排版怪。形态是量出来的，量错了能被测试抓住。
public struct ContentShape: Sendable, Equatable {
  public let characterCount: Int
  public let headingCount: Int
  public let imageCount: Int
  /// 连续图片段的**段数**。3 张图挤在一起是 1 段，3 张图分别夹在文字之间是 3 段。
  ///
  /// 这一个数把「画廊」和「穿插配图」分开了，而这正是图片能不能重排的分界：
  /// 画廊里图片是并列的，合并成图集更好看；穿插配图的位置是作者安排的语义
  /// （「如下图」），一合并就和上下文脱节。
  public let imageRunCount: Int
  public let hasCode: Bool
  public let hasTable: Bool

  public init(
    characterCount: Int,
    headingCount: Int,
    imageCount: Int,
    imageRunCount: Int,
    hasCode: Bool,
    hasTable: Bool
  ) {
    self.characterCount = characterCount
    self.headingCount = headingCount
    self.imageCount = imageCount
    self.imageRunCount = imageRunCount
    self.hasCode = hasCode
    self.hasTable = hasTable
  }

  /// 图片平均每段多少张。画廊接近图片总数，穿插配图接近 1。
  public var averageImagesPerRun: Double {
    imageRunCount == 0 ? 0 : Double(imageCount) / Double(imageRunCount)
  }

  /// 抽取质量仪表：正文很长却一个标题都没有，多半是抽取把结构丢了，
  /// 而不是作者真的写了两万字不分节。比翻正文快。
  public var looksStructurallyThin: Bool {
    characterCount >= 2_000 && headingCount < 3
  }
}

public extension ContentShape {
  /// 从 Markdown 正文量出形态。
  ///
  /// 围栏代码块整段跳过：里面的 `#` 是注释、`![...]` 可能是示例，当成标题和图片
  /// 会把一篇代码教程量成「多标题图集」。这个坑在标题重基那里已经踩过一次。
  static func measure(markdown: String) -> ContentShape {
    var characterCount = 0
    var headingCount = 0
    var imageCount = 0
    var imageRunCount = 0
    var hasCode = false
    var hasTable = false
    var inFence = false
    var previousLineWasImage = false

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inFence.toggle()
        hasCode = true
        previousLineWasImage = false
        continue
      }
      if inFence { continue }
      if line.isEmpty { continue }

      let images = imageMarkerCount(in: line)
      if images > 0 {
        imageCount += images
        // 空行不打断图集：`![](a)\n\n![](b)` 在 Markdown 里仍是并列的两张图。
        if !previousLineWasImage { imageRunCount += 1 }
        previousLineWasImage = true
        // 一行里若图片之外还有正文，那它就是穿插配图，不能算进画廊。
        if !isImageOnly(line) { previousLineWasImage = false }
        continue
      }

      previousLineWasImage = false
      if line.hasPrefix("#"), line.drop(while: { $0 == "#" }).hasPrefix(" ") {
        headingCount += 1
        continue
      }
      if line.hasPrefix("|"), line.hasSuffix("|") { hasTable = true }
      characterCount += line.count
    }

    return ContentShape(
      characterCount: characterCount,
      headingCount: headingCount,
      imageCount: imageCount,
      imageRunCount: imageRunCount,
      hasCode: hasCode,
      hasTable: hasTable
    )
  }

  private static func imageMarkerCount(in line: String) -> Int {
    var count = 0
    var search = line[...]
    while let marker = search.range(of: "![") {
      guard search[marker.upperBound...].contains("](") else { break }
      count += 1
      search = search[marker.upperBound...]
    }
    return count
  }

  private static func isImageOnly(_ line: String) -> Bool {
    var remainder = line
    while let start = remainder.range(of: "!["),
          let close = remainder[start.upperBound...].range(of: ")") {
      remainder.removeSubrange(start.lowerBound..<close.upperBound)
    }
    return remainder.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

/// 分派排版档案时能用到的全部信息。
public struct ReadingFormatContext: Sendable, Equatable {
  public let shape: ContentShape
  /// 平台仍然保留：它是弱信号，但个别站点的**已知**结构约定值得直接认。
  public let platform: String
  public let isTranscript: Bool

  public init(shape: ContentShape, platform: String, isTranscript: Bool) {
    self.shape = shape
    self.platform = platform
    self.isTranscript = isTranscript
  }
}

/// 一种形态下的确定性排版决策。**不含任何需要模型的东西**。
public struct ReadingFormatDecisions: Sendable, Equatable {
  /// 正文里的图片位置有语义，不许重排：既不合并连续图，也不把未被引用的本地图
  /// 追加到文末。
  public let keepsImagePositions: Bool
  /// 这类内容值不值得有章节目录。
  ///
  /// **当前刻意不接到目录的显示开关上。** 实测 40 条真实记录：落进
  /// `video-transcript` 和 `image-gallery` 的条目标题数全都是 0，而目录本来就
  /// 要求至少 3 条，接上去一条记录的行为都不会变。为一个零收益的改动往
  /// `MarkdownContentView` 加参数、改两处调用，不划算。
  ///
  /// 留着这个字段是因为阶段 4 要用它：判断「这类内容值不值得花 token 让模型
  /// 重排出结构」——转写稿值得，图集不值得。
  public let allowsOutline: Bool

  public init(keepsImagePositions: Bool, allowsOutline: Bool) {
    self.keepsImagePositions = keepsImagePositions
    self.allowsOutline = allowsOutline
  }
}

/// 排版档案：一种内容形态的差异，全部收敛成这一条数据。
///
/// 形状抄 `SiteProfile` / `SiteSessionProfile`——这个项目上已经验证过两次的模式。
/// 那两处的注释把理由写得很清楚：特化散在多个地方时，加一个新类型要在几处分别
/// 下手，漏掉其中一处不会报错，只表现为「这一类抓出来少一块」。
///
/// 目标同样是：**加一种形态等于加一条数据**，核心代码不认识任何具体形态。
public struct ReadingFormatProfile: Sendable {
  public let id: String
  public let matches: @Sendable (ReadingFormatContext) -> Bool
  public let decisions: ReadingFormatDecisions

  public init(
    id: String,
    matches: @escaping @Sendable (ReadingFormatContext) -> Bool,
    decisions: ReadingFormatDecisions
  ) {
    self.id = id
    self.matches = matches
    self.decisions = decisions
  }
}

public enum ReadingFormatRegistry {
  /// 顺序即优先级：第一个 `matches` 命中的档案生效。
  public static let profiles: [ReadingFormatProfile] = [
    // 转写稿没有标题也没有图，目录和图片策略都无从谈起。放在最前面，免得它
    // 因为「字多标题少」落进长文那一档。
    ReadingFormatProfile(
      id: "video-transcript",
      matches: { $0.isTranscript },
      decisions: .init(keepsImagePositions: false, allowsOutline: false)
    ),
    // 画廊：图片成组出现，并列关系，合并成图集比一张张平铺好看。
    // 判据是**图片怎么分布**，不是哪个平台——小红书、抖音图文帖、图多的博客
    // 都会落在这里，而一篇图片穿插的小红书长文不会。
    ReadingFormatProfile(
      id: "image-gallery",
      matches: { $0.shape.imageCount >= 3 && $0.shape.averageImagesPerRun >= 2.5 },
      decisions: .init(keepsImagePositions: false, allowsOutline: false)
    ),
    // 穿插配图：图片一张张夹在文字之间，位置是作者安排的（「如下图」）。
    // 重排就会和上下文脱节。微信图文是最典型的一类，但判据不写平台。
    ReadingFormatProfile(
      id: "inline-illustrated",
      matches: { $0.shape.imageCount >= 2 && $0.shape.averageImagesPerRun < 1.5 },
      decisions: .init(keepsImagePositions: true, allowsOutline: true)
    ),
    ReadingFormatProfile(
      id: "long-form-article",
      matches: { $0.shape.characterCount >= 2_000 },
      decisions: .init(keepsImagePositions: false, allowsOutline: true)
    ),
  ]

  /// 兜底档案：所有内容都必须能落到一个档案上，返回可选值只会把判断推给调用方。
  public static let fallback = ReadingFormatProfile(
    id: "default",
    matches: { _ in true },
    decisions: .init(keepsImagePositions: false, allowsOutline: true)
  )

  public static func profile(for context: ReadingFormatContext) -> ReadingFormatProfile {
    profiles.first { $0.matches(context) } ?? fallback
  }

  public static func decisions(for context: ReadingFormatContext) -> ReadingFormatDecisions {
    profile(for: context).decisions
  }
}
