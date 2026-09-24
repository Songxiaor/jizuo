import Foundation

/// 标签管理里的「可能重复」（2026-09-24）：只按写法找，不猜意思。
///
/// 「AI 编程 / AI编程」「Open-AI / openai」「ＧＰＴ / GPT」这类只差空格、连字符、
/// 全角半角、大小写的，几乎一定是同一个意思，可以放心建议合并。意思相近但写法
/// 不同的（「开源 / 开源工具」）需要人判断，这里不建议——建议错一次，用户就不再
/// 相信这个列表了。合并永远由用户点确认，这里只给候选。
public enum HistoryTagSimilarity {
  /// 比较用的写法：全角转半角、去掉空格和常见连接符、忽略大小写。
  public static func key(_ name: String) -> String {
    let folded = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
    let ignored = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_·・.、/"))
    return String(folded.lowercased().unicodeScalars.filter { !ignored.contains($0) })
  }

  /// 写法相近的标签组：每组至少两个，组内按条数从多到少（第一个就是建议保留的名字），
  /// 组与组之间按总条数从多到少。系统标记不参与。
  public static func groups(_ tags: [HistoryNavigationTag]) -> [[HistoryNavigationTag]] {
    let candidates = tags.filter { !MaterialCatalog.systemTagNormalizedNames.contains($0.tag.normalizedName) }
    let grouped: [String: [HistoryNavigationTag]] = Dictionary(grouping: candidates) { key($0.tag.name) }
    var result: [[HistoryNavigationTag]] = []
    for (groupKey, members) in grouped where members.count > 1 && !groupKey.isEmpty {
      result.append(members.sorted(by: byCountThenName))
    }
    return result.sorted { lhs, rhs in
      let left = total(lhs), right = total(rhs)
      return left == right ? lhs[0].tag.name < rhs[0].tag.name : left > right
    }
  }

  private static func byCountThenName(_ lhs: HistoryNavigationTag, _ rhs: HistoryNavigationTag) -> Bool {
    lhs.count == rhs.count ? lhs.tag.name < rhs.tag.name : lhs.count > rhs.count
  }

  private static func total(_ group: [HistoryNavigationTag]) -> Int {
    group.reduce(0) { $0 + $1.count }
  }
}
