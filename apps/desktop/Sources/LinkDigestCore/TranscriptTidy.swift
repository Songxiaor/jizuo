import Foundation

/// Post-edits a finished transcript with the user's configured chat model:
/// punctuation, paragraphing and obvious homophone typos only. The transcript
/// leaves the machine, so every call sits behind an explicit user confirmation.
public protocol TranscriptTidying: Sendable {
  /// `model` overrides the profile's chat model when non-empty; nil falls back
  /// to the configured summary/chat model.
  func tidy(text: String, model: String?) async throws -> TranscriptTidyOutcome
}

/// Tidied text plus the provider-reported token usage summed over chunks.
/// Usage is display-only for now: the evidence tables have fixed columns and
/// persisting tokens there is a schema migration, deliberately out of scope.
public struct TranscriptTidyOutcome: Sendable, Equatable {
  public let text: String
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?

  public init(
    text: String,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil
  ) {
    self.text = text
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}

public enum TranscriptTidyError: Error, Sendable, Equatable {
  case modelNotConfigured
  case emptyTranscript
  case authInvalid
  case responseRejected
  case networkInterrupted
  case cancelled

  public var userMessage: String {
    switch self {
    case .modelNotConfigured: "请先在设置中保存模型服务后再整理文稿。"
    case .emptyTranscript: "没有可整理的转写文字。"
    case .authInvalid: "整理文稿的 API Key 无效或没有权限。"
    case .responseRejected: "模型服务拒绝了整理请求，请检查模型名和账户额度。"
    case .networkInterrupted: "整理文稿连接中断，请稍后重试。原始转写稿未受影响。"
    case .cancelled: "已取消整理文稿。"
    }
  }
}

/// The system prompt is a fixed contract, not a user template: tidying must
/// never become rewriting, so the constraints live in code and in tests.
public enum TranscriptTidyPrompt {
  public static let system = """
    你是转写稿整理器。只做三件事：修正标点符号；按语义重新分段；\
    纠正明显的同音错别字和被误写的品牌、型号、术语名。
    排版规则：一个段落写成连续的一行，段落内部绝不换行；段落之间用一个空行分隔；\
    中文标点后不加空格。
    严格禁止：增加或删除信息、改写语义、概括压缩、翻译、评论，或添加任何前后缀说明。
    输入是同一份转写稿的一个连续片段，可能从句中开始或结束；保持片段边界原样，不要补全句子。
    只输出整理后的正文纯文本。
    """
}

/// Model output arrives in two newline dialects: blank-line paragraphs with
/// hard-wrapped lines inside, or one sentence per line. The reading view is
/// Markdown, where a single newline collapses into a space — mid-CJK that
/// space is the "。  下一句" artifact. Normalizing deterministically here
/// beats hoping the prompt is obeyed.
public enum TranscriptTidyNormalizer {
  public static func normalize(_ text: String) -> String {
    let unified = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !unified.isEmpty else { return unified }

    let lines = unified.components(separatedBy: "\n")
    let hasBlankLineParagraphs = lines.contains {
      $0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    let paragraphs: [[String]] = hasBlankLineParagraphs
      // 空行分段；段内残留的单换行是 hard wrap，需要拼回一行。
      ? lines.split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).map(Array.init)
      // 只有单换行：按“每行一段”处理，宁可段落略碎也不能折叠成空格。
      : lines.map { [$0] }

    let joined = paragraphs.compactMap { paragraphLines -> String? in
      var merged = ""
      for line in paragraphLines {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.isEmpty else { continue }
        if merged.isEmpty {
          merged = trimmedLine
        } else if let last = merged.last, let first = trimmedLine.first,
                  isCJK(last) || isCJK(first) {
          merged += trimmedLine
        } else {
          merged += " " + trimmedLine
        }
      }
      guard !merged.isEmpty else { return nil }
      // 模型偶尔在中文标点后跟半角空格；两个 CJK 字符之间的空格一律多余。
      // 中西文之间的空格（如“三星 Galaxy”）保留。
      return merged.replacingOccurrences(
        of: "(?<=[\\u3000-\\u303F\\u4E00-\\u9FFF\\uFF00-\\uFFEF]) +(?=[\\u3000-\\u303F\\u4E00-\\u9FFF\\uFF00-\\uFFEF])",
        with: "",
        options: .regularExpression
      )
    }
    return joined.joined(separator: "\n\n")
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (0x3000...0x303F).contains(scalar.value)
        || (0x4E00...0x9FFF).contains(scalar.value)
        || (0xFF00...0xFFEF).contains(scalar.value)
    }
  }
}

/// Splits a transcript at paragraph boundaries and packs the pieces greedily.
/// A single over-long paragraph stays whole: sending a mid-sentence cut to the
/// model invites rewriting, which the prompt forbids.
public enum TranscriptTidyChunker {
  public static let defaultChunkCharacterLimit = 6_000

  public static func chunks(
    of text: String,
    limit: Int = TranscriptTidyChunker.defaultChunkCharacterLimit
  ) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard trimmed.count > limit else { return [trimmed] }

    let paragraphs = trimmed
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var result: [String] = []
    var current = ""
    for paragraph in paragraphs {
      if current.isEmpty {
        current = paragraph
      } else if current.count + 2 + paragraph.count <= limit {
        current += "\n\n" + paragraph
      } else {
        result.append(current)
        current = paragraph
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}
