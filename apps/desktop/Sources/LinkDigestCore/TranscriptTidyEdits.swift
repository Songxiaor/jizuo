import Foundation

/// 校对改成「只交修改清单」（2026-10-04）。
///
/// 原来让模型把每一段原样重写一遍：Day1 那份 7.6 万字的稿子只改了 570 处，模型却要
/// 一字一字吐出 7.5 万字，44 分钟里绝大部分时间花在「抄」上；76% 的输出 token 还是
/// 模型自己的思考。重写还会挪动段首时间码，被分段核对判成「不是这一段」，四分之一的
/// 请求白跑。
///
/// 现在每段只回几行修改，App 在本机套进原文：
/// - 输出量从「整段」降到「改动」，生成时间跟着降一个数量级；
/// - 时间码、段落顺序由 App 保管，模型改不到，也就不会「对不上」；
/// - 一条修改在原文里找不到就跳过，最坏只是少改一处，原文一个字都不会丢。
public enum TranscriptTidyEdits {
  public enum Edit: Equatable, Sendable {
    /// 把第 n 段里的 `original` 换成 `revised`（revised 为空就是删掉）。
    case replace(paragraph: Int, original: String, revised: String)
    /// 在第 n 段前插一行小标题。
    case heading(paragraph: Int, title: String)
    /// 第 n 段从 `fragment` 开始另起一段。
    case split(paragraph: Int, fragment: String)
  }

  public struct Applied: Equatable, Sendable {
    public let text: String
    public let applied: Int
    public let missed: Int
  }

  /// 发给模型的正文：每段前面标上 [n]。
  public static func numbered(_ chunk: String) -> String {
    paragraphs(of: chunk).enumerated()
      .map { "[\($0.offset + 1)] \($0.element)" }
      .joined(separator: "\n\n")
  }

  public static func paragraphs(of chunk: String) -> [String] {
    chunk.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// 解析模型回的清单。认不出的行直接丢掉：宁可少改，不可乱改。
  ///
  /// 每行一条，竖线分隔：
  /// - `改 3 | 原文片段 | 改后片段`
  /// - `删 3 | 原文片段`
  /// - `题 5 | 小标题`
  /// - `分 7 | 新段开头的片段`
  public static func parse(_ output: String) -> [Edit] {
    var edits: [Edit] = []
    for rawLine in output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      // 模型偶尔加列表符号或包代码块。
      while let first = line.first, "-*•`".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
      guard let kind = line.first, "改删题分".contains(kind) else { continue }
      let parts = line.dropFirst().split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count >= 2,
            let number = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "[]第段 "))),
            number >= 1
      else { continue }
      let a = parts[1]
      switch kind {
      case "改":
        guard parts.count >= 3, !a.isEmpty, a != parts[2] else { continue }
        edits.append(.replace(paragraph: number, original: a, revised: parts[2]))
      case "删":
        guard !a.isEmpty else { continue }
        edits.append(.replace(paragraph: number, original: a, revised: ""))
      case "题":
        let title = a.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard (2...24).contains(title.count) else { continue }
        edits.append(.heading(paragraph: number, title: title))
      case "分":
        guard a.count >= 2 else { continue }
        edits.append(.split(paragraph: number, fragment: a))
      default:
        continue
      }
    }
    return edits
  }

  /// 把清单套进这一段原文，返回校对后的整段文字（段落之间空一行）。
  public static func apply(_ edits: [Edit], to chunk: String) -> Applied {
    var paragraphs = Self.paragraphs(of: chunk)
    var applied = 0
    var missed = 0
    var headings: [Int: String] = [:]
    var splits: [Int: [String]] = [:]

    for edit in edits {
      switch edit {
      case let .replace(number, original, revised):
        guard paragraphs.indices.contains(number - 1) else { missed += 1; continue }
        let (stamp, body) = splitStamp(paragraphs[number - 1])
        // 只在正文里找，时间码碰不到；一次只换第一处，避免把同一个词在整段里误改。
        guard let range = body.range(of: original) else { missed += 1; continue }
        var newBody = body
        newBody.replaceSubrange(range, with: revised)
        paragraphs[number - 1] = stamp + newBody
        applied += 1
      case let .heading(number, title):
        guard paragraphs.indices.contains(number - 1), headings[number] == nil else { missed += 1; continue }
        headings[number] = title
        applied += 1
      case let .split(number, fragment):
        guard paragraphs.indices.contains(number - 1) else { missed += 1; continue }
        splits[number, default: []].append(fragment)
      }
    }

    var output: [String] = []
    for (index, paragraph) in paragraphs.enumerated() {
      let number = index + 1
      if let title = headings[number] { output.append("## " + title) }
      var pieces = [paragraph]
      for fragment in splits[number] ?? [] {
        // 在最后一块里找；不能把时间码切走，也不能切出空段。
        guard let last = pieces.last else { continue }
        let (stamp, body) = splitStamp(last)
        guard let range = body.range(of: fragment), range.lowerBound > body.startIndex else { missed += 1; continue }
        let head = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let tail = String(body[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { missed += 1; continue }
        pieces[pieces.count - 1] = stamp + head
        pieces.append(tail)
        applied += 1
      }
      output.append(contentsOf: pieces)
    }
    return Applied(text: output.joined(separator: "\n\n"), applied: applied, missed: missed)
  }

  /// 段首时间码（`00:36 `、`1:02:03 `）和正文分开。
  static func splitStamp(_ paragraph: String) -> (stamp: String, body: String) {
    guard let match = paragraph.range(of: #"^\d{1,2}:\d{2}(:\d{2})?\s+"#, options: .regularExpression) else {
      return ("", paragraph)
    }
    return (String(paragraph[match]), String(paragraph[match.upperBound...]))
  }
}
