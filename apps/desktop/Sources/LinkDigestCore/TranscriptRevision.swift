import Foundation

/// 朱批：机器听写稿与模型校对稿之间「改了哪些字」。
///
/// 只比字，不比标点和空白——校对的主要工作是补标点、分段，把这些都标出来
/// 满屏都是朱色，真正的改字（「前三方」→「前3秒」）反而看不见。
/// 按段首时间戳切块逐块比对：长稿一万多字，整篇做编辑距离既慢又容易把改动
/// 对到别的段落上；时间戳是两份稿子共有的锚点（校对规则要求原样保留）。
public enum TranscriptRevision {
  /// 校对稿里的一处改动。`range` 是校对稿里新文字的范围（按 Character 计的偏移）。
  public struct Change: Equatable, Sendable {
    public let offset: Int
    public let length: Int
    public let original: String
    public let revised: String
    public let timestamp: String?

    public init(offset: Int, length: Int, original: String, revised: String, timestamp: String?) {
      self.offset = offset
      self.length = length
      self.original = original
      self.revised = revised
      self.timestamp = timestamp
    }
  }

  /// 校对稿里被删掉、没有替换文字的原稿片段（比如口头禅「呃」），只进页边清单。
  public struct Deletion: Equatable, Sendable {
    public let offsetBefore: Int
    public let original: String
    public let timestamp: String?
  }

  public struct Result: Equatable, Sendable {
    public let changes: [Change]
    public let deletions: [Deletion]
  }

  /// 单块超过这个字数就不做逐字比对（避免异常长块拖慢界面），该块视为没有可标的改动。
  static let maximumBlockCharacters = 6_000

  public static func compare(original: String, revised: String) -> Result {
    let originalBlocks = blocks(of: original)
    let revisedBlocks = blocks(of: revised)
    let originalByStamp = Dictionary(originalBlocks.compactMap { block in block.stamp.map { ($0, block) } }, uniquingKeysWith: { first, _ in first })
    var changes: [Change] = []
    var deletions: [Deletion] = []
    for (index, block) in revisedBlocks.enumerated() {
      let counterpart: Block?
      if let stamp = block.stamp {
        counterpart = originalByStamp[stamp]
      } else if revisedBlocks.count == 1, originalBlocks.count == 1 {
        counterpart = originalBlocks.first
      } else {
        counterpart = index < originalBlocks.count && originalBlocks[index].stamp == nil ? originalBlocks[index] : nil
      }
      guard let counterpart else { continue }
      let result = compareBlock(original: counterpart.text, revised: block.text, revisedStart: block.offset, stamp: block.stamp)
      changes += result.changes
      deletions += result.deletions
    }
    return Result(changes: changes, deletions: deletions)
  }

  // MARK: - 切块

  struct Block {
    let stamp: String?
    let text: [Character]
    /// 块首在整篇里的 Character 偏移。
    let offset: Int
  }

  /// 以「行首时间戳」为界切块；时间戳之前的开头（若有）单独成块。
  static func blocks(of text: String) -> [Block] {
    let characters = Array(text)
    var starts: [(offset: Int, stamp: String)] = []
    var lineStart = 0
    while lineStart < characters.count {
      if let stamp = stampAt(characters, lineStart) { starts.append((lineStart, stamp)) }
      var cursor = lineStart
      while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
      lineStart = cursor + 1
    }
    guard !starts.isEmpty else { return [Block(stamp: nil, text: characters, offset: 0)] }
    var result: [Block] = []
    if starts[0].offset > 0 {
      result.append(Block(stamp: nil, text: Array(characters[0..<starts[0].offset]), offset: 0))
    }
    for (index, start) in starts.enumerated() {
      let end = index + 1 < starts.count ? starts[index + 1].offset : characters.count
      result.append(Block(stamp: start.stamp, text: Array(characters[start.offset..<end]), offset: start.offset))
    }
    return result
  }

  /// `12:34 ` 或 `1:02:03 `（行首，后跟空白）。
  public static func stampAt(_ characters: [Character], _ start: Int) -> String? {
    var cursor = start
    var stamp = ""
    var groups = 0
    while groups < 3 {
      var digits = ""
      while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber, digits.count < 2 {
        digits.append(characters[cursor]); cursor += 1
      }
      guard !digits.isEmpty else { return nil }
      stamp += digits
      groups += 1
      if cursor < characters.count, characters[cursor] == ":", groups < 3 {
        stamp.append(":"); cursor += 1
      } else {
        break
      }
    }
    guard groups >= 2, cursor < characters.count, characters[cursor].isWhitespace else { return nil }
    return stamp
  }

  // MARK: - 逐块比对

  /// 行首是 `#`（1–6 个）加空白的整行，所有字符的下标。
  static func headingCharacterIndices(_ characters: [Character]) -> Set<Int> {
    var result = Set<Int>()
    var lineStart = 0
    while lineStart < characters.count {
      var end = lineStart
      while end < characters.count, characters[end] != "\n" { end += 1 }
      var hashes = lineStart
      while hashes < end, characters[hashes] == "#" { hashes += 1 }
      if hashes > lineStart, hashes - lineStart <= 6, hashes < end, characters[hashes].isWhitespace {
        result.formUnion(lineStart..<end)
      }
      lineStart = end + 1
    }
    return result
  }

  static func isComparable(_ character: Character) -> Bool {
    if character.isWhitespace { return false }
    if character.isPunctuation || character.isSymbol { return false }
    return true
  }

  static func folded(_ character: Character) -> Character {
    character.isASCII ? Character(character.lowercased()) : character
  }

  static func compareBlock(original: [Character], revised: [Character], revisedStart: Int, stamp: String?) -> Result {
    // 只保留可比字符，并记下它们在块内的位置。块首时间戳本身两边相同，也一起比掉。
    // 校对时加的小标题（`## …`）是分节，不是改字，两边都不参与比对。
    let originalHeadings = headingCharacterIndices(original)
    let revisedHeadings = headingCharacterIndices(revised)
    let originalCore = original.enumerated().filter { isComparable($0.element) && !originalHeadings.contains($0.offset) }
    let revisedCore = revised.enumerated().filter { isComparable($0.element) && !revisedHeadings.contains($0.offset) }
    guard originalCore.count <= maximumBlockCharacters, revisedCore.count <= maximumBlockCharacters else {
      return Result(changes: [], deletions: [])
    }
    let a = originalCore.map { folded($0.element) }
    let b = revisedCore.map { folded($0.element) }
    let difference = b.difference(from: a)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }
    var changes: [Change] = []
    var deletions: [Deletion] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
        i += 1; j += 1
        continue
      }
      var originalRun: [Int] = []
      var revisedRun: [Int] = []
      while i < a.count, removed.contains(i) { originalRun.append(i); i += 1 }
      while j < b.count, inserted.contains(j) { revisedRun.append(j); j += 1 }
      // 删掉与插入可能交替出现（「三方」→「3秒」），一直吃到下一个对上的字。
      while (i < a.count && removed.contains(i)) || (j < b.count && inserted.contains(j)) {
        while i < a.count, removed.contains(i) { originalRun.append(i); i += 1 }
        while j < b.count, inserted.contains(j) { revisedRun.append(j); j += 1 }
      }
      let originalText = String(originalRun.map { originalCore[$0].element })
      if let first = revisedRun.first, let last = revisedRun.last {
        let startInBlock = revisedCore[first].offset
        let endInBlock = revisedCore[last].offset + 1
        changes.append(Change(
          offset: revisedStart + startInBlock,
          length: endInBlock - startInBlock,
          original: originalText,
          revised: String(revised[startInBlock..<endInBlock]),
          timestamp: stamp
        ))
      } else if !originalText.isEmpty {
        let before = j < revisedCore.count ? revisedCore[j].offset : revised.count
        deletions.append(Deletion(offsetBefore: revisedStart + before, original: originalText, timestamp: stamp))
      }
      if originalRun.isEmpty, revisedRun.isEmpty { i += 1; j += 1 }
    }
    return Result(changes: changes, deletions: deletions)
  }
}
