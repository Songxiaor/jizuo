import Foundation

/// 校对时模型「拿不准」的一处：正文里保持听写原样，由用户决定采纳建议还是保留原文。
public struct TranscriptDoubt: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case pending
    case adopted
    case kept
  }

  public var id: String
  /// 稿子里逐字出现的原文片段。
  public var original: String
  public var suggestion: String
  public var reason: String
  public var status: Status

  public init(
    id: String = UUID().uuidString,
    original: String,
    suggestion: String,
    reason: String,
    status: Status = .pending
  ) {
    self.id = id
    self.original = original
    self.suggestion = suggestion
    self.reason = reason
    self.status = status
  }
}

/// 存疑清单的解析与核对。模型在同一次校对调用里，于正文之后另起一行写 `marker`，
/// 后面跟 JSON 数组；本机把它从正文里切开，并逐条核对原文片段真的在稿子里。
public enum TranscriptDoubtParser {
  public static let marker = "<<<存疑>>>"
  /// 单段（一次模型调用）最多收几条，防止模型把整篇都标成存疑。
  public static let perChunkLimit = 6
  /// 一份稿子最多留几条。
  public static let perTranscriptLimit = 30
  public static let fragmentMinimumCharacters = 2
  public static let fragmentMaximumCharacters = 40

  private struct Raw: Decodable {
    let original: String?
    let suggestion: String?
    let reason: String?
  }

  /// 把模型输出切成「正文」和「还没核对的存疑项」。没有标记就原样返回正文。
  /// 标记之后无论 JSON 能不能读懂，都不会进正文。
  public static func split(_ output: String) -> (text: String, doubts: [TranscriptDoubt]) {
    guard let range = output.range(of: marker, options: .backwards) else { return (output, []) }
    let text = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = String(output[range.upperBound...])
    return (text, parseJSON(tail))
  }

  static func parseJSON(_ tail: String) -> [TranscriptDoubt] {
    var json = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```") {
      json = json.drop { $0 != "\n" }.dropFirst().description
      if let fence = json.range(of: "```", options: .backwards) { json = String(json[..<fence.lowerBound]) }
    }
    if let open = json.firstIndex(of: "["), let close = json.lastIndex(of: "]"), open < close {
      json = String(json[open...close])
    }
    guard let data = json.data(using: .utf8),
          let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
    var result: [TranscriptDoubt] = []
    for raw in raws {
      guard let original = raw.original?.trimmingCharacters(in: .whitespacesAndNewlines),
            let suggestion = raw.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
            !original.isEmpty, !suggestion.isEmpty, original != suggestion else { continue }
      result.append(.init(
        original: original,
        suggestion: suggestion,
        reason: (raw.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      ))
      if result.count >= perChunkLimit { break }
    }
    return result
  }

  /// 只留原文片段在稿子里找得到的；去重；超长或过短的丢掉。
  public static func verified(_ doubts: [TranscriptDoubt], in text: String) -> [TranscriptDoubt] {
    var seen = Set<String>()
    var kept: [TranscriptDoubt] = []
    for doubt in doubts {
      let count = doubt.original.count
      guard count >= fragmentMinimumCharacters, count <= fragmentMaximumCharacters,
            doubt.suggestion.count <= fragmentMaximumCharacters * 2,
            seen.insert(key(of: doubt.original)).inserted,
            // 片段在稿子里出现不止一处（又没带出唯一的上下文）时无法确定改的是哪一处：丢弃，不猜。
            matchRanges(of: doubt.original, in: text, limit: 2).count == 1 else { continue }
      kept.append(doubt)
      if kept.count >= perTranscriptLimit { break }
    }
    return kept
  }

  /// NFKC 之后去掉空白和标点，只比较有意义的字。
  public static func key(of value: String) -> String {
    String(value.precomposedStringWithCompatibilityMapping.unicodeScalars.filter(isSignificant).map(Character.init))
  }

  private static func isSignificant(_ scalar: Unicode.Scalar) -> Bool {
    !CharacterSet.whitespacesAndNewlines.contains(scalar)
      && !CharacterSet.punctuationCharacters.contains(scalar)
      && !CharacterSet.symbols.contains(scalar)
      && !CharacterSet.controlCharacters.contains(scalar)
  }

  /// 稿子里「有意义的字」的展开：NFKC 之后去掉空白标点，并记下每个字在原文里的范围。
  private static func significantStream(of text: String) -> (chars: [Character], starts: [String.Index], ends: [String.Index]) {
    var haystack: [Character] = []
    var starts: [String.Index] = []
    var ends: [String.Index] = []
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      for scalar in String(text[index..<next]).precomposedStringWithCompatibilityMapping.unicodeScalars
      where isSignificant(scalar) {
        haystack.append(Character(scalar))
        starts.append(index)
        ends.append(next)
      }
      index = next
    }
    return (haystack, starts, ends)
  }

  /// 片段在稿子里的全部命中（按「NFKC + 忽略空白标点」比，允许重叠），最多收 `limit` 处。
  /// 范围覆盖稿子里从第一个到最后一个匹配字的原文（含中间的标点空白）。
  public static func matchRanges(of fragment: String, in text: String, limit: Int = Int.max) -> [Range<String.Index>] {
    let needle = Array(key(of: fragment))
    guard !needle.isEmpty else { return [] }
    let stream = significantStream(of: text)
    guard stream.chars.count >= needle.count else { return [] }
    var result: [Range<String.Index>] = []
    var offset = 0
    while offset + needle.count <= stream.chars.count, result.count < limit {
      if stream.chars[offset] == needle[0], Array(stream.chars[offset..<(offset + needle.count)]) == needle {
        result.append(stream.starts[offset]..<stream.ends[offset + needle.count - 1])
      }
      offset += 1
    }
    return result
  }

  /// 在稿子里找片段（第一处命中）。没有返回 nil。
  public static func range(of fragment: String, in text: String) -> Range<String.Index>? {
    if let exact = text.range(of: fragment) { return exact }
    return matchRanges(of: fragment, in: text, limit: 1).first
  }

  /// 采纳：把稿子里的原文片段换成建议。找不到、或现在出现了不止一处（分不清改哪一处）
  /// 都返回 nil，由调用方提示，不乱改。
  public static func applying(_ doubt: TranscriptDoubt, to text: String) -> String? {
    let matches = matchRanges(of: doubt.original, in: text, limit: 2)
    guard matches.count == 1, let range = matches.first else { return nil }
    return text.replacingCharacters(in: range, with: doubt.suggestion)
  }

  /// 一次校对改了几处：把前后两份稿子按有意义的字做差，数连续改动的段数。
  /// 太长的稿子不算（返回 nil），免得拖慢；调用方只用来显示「改了 N 处」。
  public static func changeCount(original: String, revised: String, characterLimit: Int = 20_000) -> Int? {
    let a = Array(key(of: original))
    let b = Array(key(of: revised))
    guard a.count <= characterLimit, b.count <= characterLimit else { return nil }
    var removed: [Int] = []
    var inserted: [Int] = []
    for change in b.difference(from: a) {
      switch change {
      case let .remove(offset, _, _): removed.append(offset)
      case let .insert(offset, _, _): inserted.append(offset)
      }
    }
    // 相邻（间隔不到 4 个字）的改动算同一处；一处替换同时有删和增，取两边较大的数。
    func clusters(_ offsets: [Int]) -> Int {
      var count = 0
      var last = Int.min / 2
      for offset in offsets.sorted() {
        if offset - last > 3 { count += 1 }
        last = offset
      }
      return count
    }
    return max(clusters(removed), clusters(inserted))
  }
}

/// 卡片顶上那一行：改了几处字、几处拿不准。
public enum ProofreadDoubtSummary {
  public static func line(changeCount: Int?, pending: Int, hasDoubts: Bool) -> String {
    let changed: String
    switch changeCount {
    case .none: changed = "AI 校对过"
    case .some(0): changed = "AI 只补了标点"
    case let .some(count): changed = "AI 改了 \(count) 处字"
    }
    if pending > 0 { return changed + "，有 \(pending) 处拿不准，请看高亮" }
    return hasDoubts ? changed + "，拿不准的地方都已处理" : changed
  }

  /// 全部处理完后收成的一行。
  public static func collapsedLine(handled: Int) -> String { "已处理 \(handled) 处" }
}
