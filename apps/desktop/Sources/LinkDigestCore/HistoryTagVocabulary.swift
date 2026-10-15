import Foundation

/// 自动打标签时给模型看的「已有标签表」，以及对模型结果的兜底约束。
///
/// 为什么需要它：自动标签原来只看这一篇的总结，每篇各起各的名——同一个主题攒出
/// 「AI 工具」「AI工具」「人工智能工具」好几个近义标签，标签栏越用越乱。把常用的
/// 已有标签递给模型、让它优先从里面挑，新标签每篇最多一个。
public enum HistoryTagVocabulary {
  /// 递给模型的已有标签上限。再多提示词就太长，而且长尾标签本来就少有人复用。
  public static let defaultLimit = 100
  /// 每篇最多新建几个标签。
  public static let maximumNewTagsPerItem = 1

  /// 按使用次数从多到少取前 `limit` 个显示名；系统标记（自有/外部/已使用/已归档）不算主题标签。
  public static func topNames(from tags: [HistoryNavigationTag], limit: Int = defaultLimit) -> [String] {
    let topical = tags.filter {
      $0.count > 0 && !MaterialCatalog.systemTagNormalizedNames.contains($0.tag.normalizedName)
    }
    let ranked = topical.sorted { (lhs: HistoryNavigationTag, rhs: HistoryNavigationTag) -> Bool in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.tag.normalizedName < rhs.tag.normalizedName
    }
    return ranked.prefix(max(0, limit)).map { $0.tag.name }
  }

  /// 模型不一定守规矩：已有的全留，并改用库里的写法；新标签只留前 `maximumNew` 个。
  /// 标签库还是空的时不限制——那时每个标签都是新的。
  public static func limitingNewTags(
    _ tags: [HistoryTag],
    existing: [String],
    maximumNew: Int = maximumNewTagsPerItem
  ) -> [HistoryTag] {
    guard !existing.isEmpty else { return tags }
    var known: [String: HistoryTag] = [:]
    for name in existing {
      if let tag = HistoryTag(rawValue: name), known[tag.normalizedName] == nil {
        known[tag.normalizedName] = tag
      }
    }
    var newCount = 0
    return tags.compactMap { tag in
      if let existingTag = known[tag.normalizedName] { return existingTag }
      guard newCount < maximumNew else { return nil }
      newCount += 1
      return tag
    }
  }

  /// 拼进提示词的那一句。没有已有标签时返回空串，提示词保持原样。
  public static func reuseInstruction(existing: [String]) -> String {
    guard !existing.isEmpty else { return "" }
    return "Prefer tags from this existing list, copied exactly as written: \(existing.joined(separator: ", ")). Add at most \(maximumNewTagsPerItem) new tag, and only when none of the existing tags fits the content."
  }
}
