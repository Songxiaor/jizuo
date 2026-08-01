import Foundation

/// 写列表时的按键行为。
///
/// 纯函数，不碰 NSTextView：这类逻辑的坑全在边界上（空列表项、有序编号、
/// 缩进层级），而边界最好在测试里穷举，不该靠在编辑器里手动敲一遍来验证。
enum MarkdownListEditing {
  /// 一行的列表标记。
  struct Marker: Equatable {
    /// 行首缩进（空格或制表符原样保留）。
    let indent: String
    /// 标记本身，含尾随空格，例如 `- `、`3. `、`- [ ] `。
    let bullet: String
    /// 标记之后还有没有实际内容。
    let hasContent: Bool

    /// 标记在行内占的字符数。退出列表时要删掉的就是这一段。
    var prefixLength: Int { indent.count + bullet.count }
  }

  /// 回车之后要做的事。
  struct Continuation: Equatable {
    /// 先从当前行首删掉这么多字符。只有「在空列表项上回车」时才非零。
    let deletingPrefixLength: Int
    /// 再插入这段文本。
    let insert: String
  }

  private static let pattern = try? NSRegularExpression(
    // 缩进 / 项目符号或序号 / 可选的任务框 / 余下内容
    pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]+(\[[ xX]\][ \t]+)?(.*)$"#
  )

  static func marker(ofLine line: String) -> Marker? {
    guard let pattern else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = pattern.firstMatch(in: line, range: range) else { return nil }

    func group(_ index: Int) -> String {
      guard let r = Range(match.range(at: index), in: line) else { return "" }
      return String(line[r])
    }
    let indent = group(1)
    let symbol = group(2)
    let checkbox = group(3)
    let content = group(4)
    // 原样保留符号与空格数会让续行和上一行对不齐，统一成一个空格。
    let bullet = checkbox.isEmpty ? "\(symbol) " : "\(symbol) [ ] "
    return Marker(
      indent: indent,
      bullet: bullet,
      hasContent: !content.trimmingCharacters(in: .whitespaces).isEmpty
    )
  }

  /// 在 `line` 末尾按回车时该发生什么；这一行不是列表则返回 nil（照常换行）。
  static func continuation(forLine line: String) -> Continuation? {
    guard let marker = marker(ofLine: line) else { return nil }
    // 空列表项上回车是「我列完了」，不是「再来一项」。删掉这个标记退出列表，
    // 否则用户得自己退格清掉它——每写完一个列表都要做一次。
    guard marker.hasContent else {
      return Continuation(deletingPrefixLength: marker.prefixLength, insert: "")
    }
    return Continuation(deletingPrefixLength: 0, insert: "\n" + marker.indent + nextBullet(marker.bullet))
  }

  /// 有序列表要递增，无序保持原样；已勾选的任务续成未勾选的新项。
  private static func nextBullet(_ bullet: String) -> String {
    let trimmed = bullet.trimmingCharacters(in: .whitespaces)
    guard let dot = trimmed.firstIndex(of: "."),
          let number = Int(trimmed[trimmed.startIndex..<dot]) else {
      return bullet
    }
    let suffix = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    return suffix.isEmpty ? "\(number + 1). " : "\(number + 1). \(suffix) "
  }

  /// 把一行在「普通行 → 待办 → 已完成 → 普通行」之间轮转。
  ///
  /// 一个键管三种状态，而不是「插入待办」和「勾选」两个命令：写清单时这三步
  /// 本来就是连着发生的，分成两个键要记两个。
  static func toggledTask(_ line: String) -> String {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = String(line.dropFirst(indent.count))

    if let marker = marker(ofLine: line), marker.bullet.contains("[") {
      // 已经是待办：勾上；已经勾上的还原成普通列表项。
      let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      let content = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      let isDone = body.dropFirst(1).first.map { $0 == "x" || $0 == "X" } ?? false
      let symbol = String(rest.prefix(1))
      return isDone ? "\(indent)\(symbol) \(content)" : "\(indent)\(symbol) [x] \(content)"
    }
    if let marker = marker(ofLine: line) {
      // 普通列表项：加上复选框，保留原来的符号。
      let content = String(rest.dropFirst(marker.bullet.count)).trimmingCharacters(in: .whitespaces)
      let symbol = String(rest.prefix(1))
      return "\(indent)\(symbol) [ ] \(content)"
    }
    let content = rest.trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return "\(indent)- [ ] " }
    return "\(indent)- [ ] \(content)"
  }

  /// 用一对记号包住选中的文字，例如加粗。
  ///
  /// 已经被同一对记号包着时反过来去掉——同一个快捷键既开又关，才符合
  /// 「⌘B 是个开关」这个预期。
  static func toggleWrap(_ text: String, selection: Range<String.Index>, marker: String) -> (text: String, selection: Range<String.Index>) {
    let selected = String(text[selection])
    let before = text[text.startIndex..<selection.lowerBound]
    let after = text[selection.upperBound...]

    if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count >= marker.count * 2 {
      let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
      let result = before + inner + after
      let lower = result.index(result.startIndex, offsetBy: before.count)
      let upper = result.index(lower, offsetBy: inner.count)
      return (String(result), lower..<upper)
    }
    // 选区外侧已经有记号：把外面那一对去掉，而不是再套一层。
    if before.hasSuffix(marker), after.hasPrefix(marker) {
      let result = String(before.dropLast(marker.count)) + selected + String(after.dropFirst(marker.count))
      let lower = result.index(result.startIndex, offsetBy: before.count - marker.count)
      let upper = result.index(lower, offsetBy: selected.count)
      return (result, lower..<upper)
    }
    let result = String(before) + marker + selected + marker + String(after)
    let lower = result.index(result.startIndex, offsetBy: before.count + marker.count)
    let upper = result.index(lower, offsetBy: selected.count)
    return (String(result), lower..<upper)
  }
}
