import Foundation

/// Post-edits a finished transcript with the user's configured chat model.
/// For speech transcripts this is **听写还原**: recover likely spoken words
/// from ASR errors using title/caption context. It is not article rewriting.
/// The transcript leaves the machine, so every call sits behind confirmation.
public protocol TranscriptTidying: Sendable {
  /// `model` overrides the profile's chat model when non-empty; nil falls back
  /// to the configured summary/chat model.
  /// `progress` 报告「已完成分片数 / 总分片数」。
  ///
  /// 长稿要切成十几片、跑上几分钟，没有进度时界面只能干写一句「正在整理…」，
  /// 用户无从判断它是在跑、卡住了、还是快好了——转写那条早就有帧进度，
  /// 这里一直缺。
  func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome
}

public extension TranscriptTidying {
  func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext
  ) async throws -> TranscriptTidyOutcome {
    try await tidy(text: text, model: model, style: style, context: context, progress: nil)
  }

  func tidy(text: String, model: String?, style: TidyStyle) async throws -> TranscriptTidyOutcome {
    try await tidy(text: text, model: model, style: style, context: .empty)
  }

  /// 不指定风格时按转写稿处理——这个功能原本就是为转写稿建的。
  func tidy(text: String, model: String?) async throws -> TranscriptTidyOutcome {
    try await tidy(text: text, model: model, style: .transcript, context: .empty)
  }
}

/// 听写还原用的上下文。标题和配文只帮助猜口误，不写进校对稿。
public struct TranscriptTidyContext: Sendable, Equatable {
  public var title: String?
  public var caption: String?

  public static let empty = TranscriptTidyContext()
  public static let titleCharacterLimit = 200
  public static let captionCharacterLimit = 1_200

  public init(title: String? = nil, caption: String? = nil, transcript: String? = nil) {
    self.title = Self.clipped(title, limit: Self.titleCharacterLimit)
    var captionValue = Self.clipped(caption, limit: Self.captionCharacterLimit)
    if let existingCaption = captionValue, let transcript {
      let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      if existingCaption == trimmedTranscript { captionValue = nil }
    }
    self.caption = captionValue
  }

  public var isEmpty: Bool { title == nil && caption == nil }

  private static func clipped(_ value: String?, limit: Int) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit))
  }
}

/// 整理哪一种文本。两者的毛病不同，提示词也就不能共用。
public enum TidyStyle: String, Sendable, CaseIterable {
  /// 机器听写稿：听写还原 + 标点分段。
  case transcript
  /// 手写笔记：字没错，但结构没成形。
  case note
  /// 画面字幕 OCR 稿：错的是**形近字**，还常粘着画面角标的残片。
  case subtitles

  public var systemPrompt: String {
    switch self {
    case .transcript: TranscriptTidyPrompt.system
    case .note: TranscriptTidyPrompt.note
    case .subtitles: TranscriptTidyPrompt.subtitles
    }
  }

  /// 输出是否要做段落归一化（把段内换行拼回一行）。
  ///
  /// 笔记的产物是 Markdown，换行本身有语义，不能归一；听写稿和字幕稿都是
  /// 连续正文，要归一。
  public var normalizesParagraphs: Bool { self != .note }
}

/// Tidied text plus the provider-reported token usage summed over chunks.
/// Usage is display-only for now: the evidence tables have fixed columns and
/// persisting tokens there is a schema migration, deliberately out of scope.
public struct TranscriptTidyOutcome: Sendable, Equatable {
  public let text: String
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  /// 整理失败、以原文回填的分片数。
  ///
  /// 长稿会切片逐片整理，中间几片撞 429 或超时时，那几片以**原文**回填后函数
  /// 正常返回。原来返回值里没有任何失败信号，调用方于是显示「整理完成 + N tokens」，
  /// 而新建的整理稿里可能有 3/4 内容根本没整理过——典型的「错误被吞掉后继续，
  /// 产出看起来正常的坏结果」。数出来交给调用方如实告知。
  public let failedChunkCount: Int
  /// 总分片数，用来说清「N 段里有 M 段没整理成」。
  public let chunkCount: Int

  public var isPartial: Bool { failedChunkCount > 0 }

  public init(
    text: String,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil,
    failedChunkCount: Int = 0,
    chunkCount: Int = 1
  ) {
    self.text = text
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.failedChunkCount = failedChunkCount
    self.chunkCount = chunkCount
  }
}

public enum TranscriptTidyError: Error, Sendable, Equatable {
  case modelNotConfigured
  /// 模型配好了，但这次**读不出**凭据（钥匙串读失败或超时）。
  ///
  /// 必须和 `modelNotConfigured` 分开：两者的用户动作完全相反——一个要去设置里
  /// 填配置，另一个只需要重试。曾经它俩共用一句「请先在设置中保存文本模型」，
  /// 于是一次钥匙串读超时会让人跑去检查一份根本没问题的配置。
  case credentialsUnavailable
  case emptyTranscript
  case authInvalid
  case responseRejected
  case networkInterrupted
  case cancelled

  public var userMessage: String {
    switch self {
    case .modelNotConfigured: "请先在设置中保存文本模型后再校对转写稿。"
    case .credentialsUnavailable: "这次没能读出模型配置（钥匙串读取失败或超时），请重试。配置本身没有问题。"
    case .emptyTranscript: "没有可整理的转写文字。"
    case .authInvalid: "模型校对使用的 API Key 无效或没有权限。"
    case .responseRejected: "模型服务拒绝了校对请求，请检查模型名和账户额度。"
    case .networkInterrupted: "模型校对连接中断，请稍后重试。原始转写稿未受影响。"
    case .cancelled: "已取消模型校对。"
    }
  }
}

/// The system prompt is a fixed contract, not a user template: restoration
/// must never become writing a new article, so the constraints live in code
/// and in tests.
public enum TranscriptTidyPrompt {
  public static let system = """
    你是听写还原器。把机器听写稿还原成说话人更可能说的那句话，不是润色成一篇新文章。
    可以做：根据标题、配文和前后句，纠正同音、近音、专有名词和术语听写错误；补齐标点；按语义分段。
    必须保留原有时间戳（例如 21:15 或 1:02:03）及其相对位置，不要改时间、不要删除时间戳。
    排版规则：一个段落写成连续的一行，段落内部绝不换行；段落之间用一个空行分隔；\
    中文标点后不加空格。
    严格禁止：编造听写稿里完全看不出的内容；翻译；概括压缩；评论；添加任何前后缀说明。
    某一句已经不像人话、无法从上下文可靠还原时，原样保留该句，不要改写成通顺的新句。
    输入可能附带标题和配文作为上下文；它们只用来帮助还原听写错误，不要写进输出。
    输入是同一份转写稿的一个连续片段，可能从句中开始或结束；保持片段边界原样，不要补全句子。
    只输出还原后的正文纯文本。
    """

  /// 画面字幕的校对契约。
  ///
  /// 和听写稿是**两类错误**，所以不能共用一份提示词：听写错在同音近音
  /// （「衡量」→「横梁」），OCR 错在字形相近（实测「衡量」→「後置」、
  /// 「时间」→「时狗」、「任务」→「低务」）。让模型按同音去猜，只会越改越远。
  ///
  /// 另一个听写稿没有的问题：识别时字幕常和画面角标粘成一行，句尾拖着
  /// `HowN`、`Andrew Ng`、`METR For AI` 这类残片。它们不是说话内容，要删掉。
  public static let subtitles = """
    你是画面字幕校对器。输入是从视频画面里 OCR 出来的字幕，把它还原成画面上原本印着的那句话。
    这些字幕本身是人写的、通常还是人工翻译的，所以句子结构是通顺的，错的只是**个别字**。
    可以做：根据标题、配文和前后句，纠正字形相近的错字（例如「後置」应为「衡量」、「时狗」应为「时间」、「低务」应为「任务」）；补齐标点。
    必须删掉：句首或句尾粘进来的画面角标残片，例如讲者署名、机构名、水印的残缺拼写（`HowN`、`Andrew Ng`、`METR`、`CC-BY` 之类）。它们不是字幕内容。
    必须保留原有时间戳（例如 21:15 或 1:02:03）及其相对位置，不要改时间、不要删除时间戳。
    排版规则：一个段落写成连续的一行，段落内部绝不换行；段落之间用一个空行分隔；\
    中文标点后不加空格。
    严格禁止：改写通顺的句子；翻译；概括压缩；补充画面上没有的内容；添加任何前后缀说明。
    某一句损坏到无法可靠还原时，原样保留，不要编一句通顺的替上去。
    输入可能附带标题和配文作为上下文；它们只用来帮助判断专有名词，不要写进输出。
    输入是同一份字幕稿的一个连续片段，可能从句中开始或结束；保持片段边界原样，不要补全句子。
    只输出校对后的正文纯文本。
    """

  /// 每个分片都带同一份标题/配文，避免长稿切段后模型看不见上下文。
  public static func contextHeader(_ context: TranscriptTidyContext) -> String? {
    guard !context.isEmpty else { return nil }
    var lines: [String] = []
    if let title = context.title { lines.append("标题：\(title)") }
    if let caption = context.caption { lines.append("配文：\(caption)") }
    lines.append("-----")
    lines.append("转写片段：")
    return lines.joined(separator: "\n")
  }

  public static func userMessage(chunk: String, context: TranscriptTidyContext) -> String {
    guard let header = contextHeader(context) else { return chunk }
    return header + "\n" + chunk
  }

  /// 模型偶尔会把标题/配文包装原样抄回。只剥我们发出去的那一层，避免写进校对稿。
  public static func stripEchoedContext(
    _ text: String,
    chunk: String,
    context: TranscriptTidyContext
  ) -> String {
    guard let header = contextHeader(context) else { return text }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == userMessage(chunk: chunk, context: context) { return chunk }
    let headerPrefix = header + "\n"
    if trimmed.hasPrefix(headerPrefix) {
      return String(trimmed.dropFirst(headerPrefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if trimmed.hasPrefix(header) {
      return String(trimmed.dropFirst(header.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }

  /// 笔记的整理排版。
  ///
  /// 和转写稿是两件事：转写稿的问题是「机器听错了字、没有标点」；手写笔记的字
  /// 没听错，问题是想到哪写到哪——标题和正文黏成一段、编号列表挤在一行、层级
  /// 靠缩进看不出来。所以这一版不提错别字，只重排结构，并且明确要求用 Markdown
  /// 记号，因为编辑器本来就按 Markdown 着色。
  public static let note = """
    你是笔记排版整理器。只调整结构与排版，不改内容：
    把标题行写成 Markdown 标题（`#`、`##`），标题与正文之间空一行；\
    把「1. 2. 3.」「- 」这类列举各自独占一行，写成 Markdown 列表；\
    段落之间用一个空行分隔，段落内部不换行；补齐缺失的标点。
    保留原有的 Markdown 记号与已经正确的层级，不要重新编号或调整章节顺序。
    严格禁止：增加或删除信息、改写语义、概括压缩、翻译、评论、润色措辞，\
    或添加任何前后缀说明。
    只输出整理后的正文。
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
