import Foundation

/// 正文章节目录。
///
/// 只在**值得**的时候出现。实测这台机器上 29 条记录里，只有 24% 有 3 个以上标题，
/// 21% 同时满足「≥2000 字且 ≥3 个标题」——但满足的那几条痛得厉害（其中一条 73432
/// 字只有 3 个标题，纯靠滚）。价值是集中的，不是摊开的，所以常驻一栏会让 80% 的
/// 条目白占阅读宽度。
///
/// 另一个用处是**当抽取质量的仪表**：目录一片空白或全是垃圾标题，说明这条抽取有
/// 问题，比翻正文快。
///
/// 这个模型能可靠工作的前提是标题层级已经归一化（抽取侧把最浅标题重基到 h2）。
/// 在那之前，用 h1 分节的页面会产出一份没有层级的平目录。
enum MarkdownOutline {
  struct Entry: Equatable, Identifiable {
    /// 在 `blocks` 数组里的下标。用它定位，而不是用标题文本——同名标题很常见
    /// （「故障排除」下面挂三个同名小节不稀奇），按文本找会跳错地方。
    let blockIndex: Int
    let level: Int
    let text: String

    var id: Int { blockIndex }
  }

  /// 少于这个数就不值得占位置：一两个标题直接滚更快。
  static let minimumEntryCount = 3

  static func entries(from blocks: [MarkdownPresentation.Block]) -> [Entry] {
    blocks.enumerated().compactMap { index, block in
      guard case let .heading(level, text) = block else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return Entry(blockIndex: index, level: level, text: trimmed)
    }
  }

  static func shouldPresent(_ entries: [Entry]) -> Bool {
    entries.count >= minimumEntryCount
  }

  /// 缩进层级：按目录内**最浅**的那一级归零，而不是按绝对 level。
  ///
  /// 抽取侧已经把正文重基到 h2 起，直接用 `level - 1` 会让整份目录白缩进一格；
  /// 而万一某篇正文从 h3 起（页面本身就那么写），按绝对值算会缩进两格。
  /// 按自身最浅级归零，任何来源都从最左侧开始。
  static func indentDepth(of entry: Entry, in entries: [Entry]) -> Int {
    guard let shallowest = entries.map(\.level).min() else { return 0 }
    return max(0, entry.level - shallowest)
  }
}
