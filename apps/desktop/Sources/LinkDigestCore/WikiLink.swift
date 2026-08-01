import Foundation

/// 笔记之间的双向链接：`[[某条笔记的标题]]`。
///
/// 为什么用标题而不是 ID：写的时候人想得起来的是「那条讲知识库的笔记」，不是
/// 一串 UUID。代价是改标题会断链——但这个代价换来的是「写的时候不必先去查」，
/// 而链接如果写起来费劲，就不会有人写。
///
/// 放在 Core 而不是 App：解析要同时被编辑器着色、跳转和反向链接查询用到，
/// 三处各写一份正则迟早会漂移。
public enum WikiLink {
  /// 一条链接在原文里的位置与它指向谁。
  public struct Reference: Equatable {
    /// 整个 `[[…]]` 在原文中的范围，含方括号。
    public let range: Range<String.Index>
    /// 目标笔记的标题。
    public let target: String
    /// 正文里实际显示的文字。没写 `|` 时与 `target` 相同。
    public let label: String

    public init(range: Range<String.Index>, target: String, label: String) {
      self.range = range
      self.target = target
      self.label = label
    }
  }

  /// 方括号内不允许再出现方括号或换行：链接是一个词组，跨行的多半是没写完的
  /// 半截语法，把它当成链接只会让整段文字被染成蓝色。
  private static let pattern = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)

  /// 找出文本里所有的双链。
  public static func references(in text: String) -> [Reference] {
    guard let pattern else { return [] }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    return pattern.matches(in: text, range: full).compactMap { match in
      guard let whole = Range(match.range, in: text),
            let inner = Range(match.range(at: 1), in: text) else { return nil }
      let raw = String(text[inner])
      // `[[目标|显示成这样]]`：竖线后面是显示文字，不参与匹配目标。
      let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      let target = parts[0].trimmingCharacters(in: .whitespaces)
      guard !target.isEmpty else { return nil }
      let label = parts.count > 1
        ? parts[1].trimmingCharacters(in: .whitespaces)
        : target
      return Reference(
        range: whole,
        target: target,
        label: label.isEmpty ? target : label
      )
    }
  }

  /// 这段文本链向的所有标题，去重后保持出现顺序。
  public static func targets(in text: String) -> [String] {
    var seen = Set<String>()
    return references(in: text).compactMap { reference in
      let key = normalizedTitle(reference.target)
      guard !seen.contains(key) else { return nil }
      seen.insert(key)
      return reference.target
    }
  }

  /// 匹配标题时用的归一化形式。
  ///
  /// 大小写与首尾空白不该影响是否链得上：写 `[[AI 时代]]` 和 `[[ai 时代]]`
  /// 指的显然是同一条,而要求人记住当初标题的大小写等于让链接经常断掉。
  public static func normalizedTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// 把一个标题包成可以直接插进正文的链接。
  public static func markup(for title: String) -> String { "[[\(title)]]" }
}

public extension WikiLink {
  /// 光标前面那个还没闭合的 `[[`，以及已经打进去的字。
  ///
  /// 用来决定「现在该不该弹补全、按什么筛」。判断依据只看光标**之前**的文本：
  /// 后面可能还有别的链接，用整段文本去找会把光标外的语法也算进来。
  struct PendingLink: Equatable {
    /// `[[` 起始位置（含）。补全选中后要从这里开始替换。
    public let openingIndex: String.Index
    /// 已经打进去的部分，用它筛候选。
    public let query: String
  }

  /// 光标处是否正在写一个链接。
  static func pendingLink(in text: String, caret: String.Index) -> PendingLink? {
    let head = text[text.startIndex..<caret]
    guard let opening = head.range(of: "[[", options: .backwards) else { return nil }
    let typed = head[opening.upperBound...]
    // 已经闭合、或者跨了行，就不是「正在写」。
    guard !typed.contains("]"), !typed.contains("\n"), !typed.contains("[") else { return nil }
    return PendingLink(openingIndex: opening.lowerBound, query: String(typed))
  }

  /// 按已打进去的字筛候选标题。
  ///
  /// 前缀命中的排在前面：打了「知」时，`知识库构建` 显然比 `构建知识体系` 更
  /// 可能是想要的那条。空查询给全部，让 `[[` 一敲出来就能挑。
  static func completions(for query: String, among titles: [String], limit: Int = 8) -> [String] {
    let needle = normalizedTitle(query)
    guard !needle.isEmpty else { return Array(titles.prefix(limit)) }
    var prefixed: [String] = []
    var contained: [String] = []
    for title in titles {
      let candidate = normalizedTitle(title)
      if candidate.hasPrefix(needle) {
        prefixed.append(title)
      } else if candidate.contains(needle) {
        contained.append(title)
      }
    }
    return Array((prefixed + contained).prefix(limit))
  }
}

/// 一条指向当前笔记的反向链接。
///
/// 只带标题和 id：反链区要做的事就是「列出来、点进去」，取完整的行投影会顺带
/// 把媒体、运行记录、标签都查一遍，而那些一个都用不上。
public struct NoteBacklink: Sendable, Equatable, Identifiable {
  public let id: TaskID
  public let title: String

  public init(id: TaskID, title: String) {
    self.id = id
    self.title = title
  }
}
