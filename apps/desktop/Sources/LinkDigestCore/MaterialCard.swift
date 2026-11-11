import Foundation

/// 素材卡（2026-11 第二批）：给有转写稿的视频做一张「能不能拿来当素材」的卡。
///
/// 谁在说、核心观点（≤3）、开头怎么抓人、金句（≤3）、是不是真人口播/出镜表达。
/// 模型输出不可信：金句必须是转写稿里真有的句子，对不上的在代码里丢掉。
public struct MaterialCard: Codable, Sendable, Equatable {
  public static let maximumViewpoints = 3
  public static let maximumQuotes = 3

  /// 谁在说（一句话，如「一位独立开发者，出镜讲解」）。
  public var speaker: String
  public var viewpoints: [String]
  /// 开头怎么抓人（一两句话）。
  public var hook: String
  /// 金句：经过代码核对，都是转写稿里的原句。
  public var quotes: [String]
  /// 是否真人出镜/口播表达（有人物在表达观点）。
  public var isLiveSpeaker: Bool
  /// 判断理由（一句话）。
  public var liveSpeakerReason: String

  public init(
    speaker: String, viewpoints: [String], hook: String, quotes: [String],
    isLiveSpeaker: Bool, liveSpeakerReason: String
  ) {
    self.speaker = speaker
    self.viewpoints = viewpoints
    self.hook = hook
    self.quotes = quotes
    self.isLiveSpeaker = isLiveSpeaker
    self.liveSpeakerReason = liveSpeakerReason
  }
}

/// 一条内容一张卡。记录用过的模型和 token，和脑图同一个思路。
public struct TaskMaterialCardRecord: Sendable, Equatable {
  public let taskID: TaskID
  public let card: MaterialCard
  /// 这张卡生成时，「真人口播」标签是不是挂在了这条内容上。
  public let liveSpeakerTagApplied: Bool
  /// 用户手动摘掉过「真人口播」：之后重新生成也不再自动挂回去。
  public let liveSpeakerTagSuppressed: Bool
  public let provider: String?
  public let model: String?
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64

  public init(
    taskID: TaskID, card: MaterialCard,
    liveSpeakerTagApplied: Bool = false, liveSpeakerTagSuppressed: Bool = false,
    provider: String? = nil, model: String? = nil,
    promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
    createdAtMilliseconds: Int64, updatedAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.card = card
    self.liveSpeakerTagApplied = liveSpeakerTagApplied
    self.liveSpeakerTagSuppressed = liveSpeakerTagSuppressed
    self.provider = provider
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

/// 与 `MindMapStoring` 一样单独成协议，不并进 `HistoryRepository`。
public protocol MaterialCardStoring: Sendable {
  func saveMaterialCard(_ record: TaskMaterialCardRecord) throws
  func loadMaterialCard(taskID: TaskID) throws -> TaskMaterialCardRecord?
  func deleteMaterialCard(taskID: TaskID) throws
  /// 已经有素材卡的内容（测试和 UI 用）。
  func materialCardTaskIDs() throws -> Set<TaskID>
  /// 有转写稿、还没有素材卡、没进回收站的内容。批量入口先拿它估算，用户确认后才逐条跑。
  func materialCardCandidates() throws -> [MaterialCardCandidate]
}

/// 批量素材卡的候选：谁，转写稿有多长（字数，用来估算文字量）。
public struct MaterialCardCandidate: Sendable, Equatable {
  public let taskID: TaskID
  public let transcriptCharacters: Int

  public init(taskID: TaskID, transcriptCharacters: Int) {
    self.taskID = taskID
    self.transcriptCharacters = transcriptCharacters
  }
}

extension HistoryApplicationService {
  public var materialCardStore: (any MaterialCardStoring)? { repositoryAsMaterialCardStore }
}

public struct MaterialCardOutcome: Sendable, Equatable {
  public let card: MaterialCard
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  /// 实际调用的服务商标识和模型名（记进素材卡，供按模型核账）。
  public let provider: String?
  public let model: String?

  public init(
    card: MaterialCard, promptTokens: Int?, completionTokens: Int?, totalTokens: Int?,
    provider: String? = nil, model: String? = nil
  ) {
    self.provider = provider
    self.model = model
    self.card = card
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}

public protocol MaterialCardExtracting: Sendable {
  func extractCard(transcript: String, title: String?) async throws -> MaterialCardOutcome
}

public enum MaterialCardError: Error, Sendable, Equatable {
  case emptyTranscript
  case invalidResponse
  case notConfigured
  case readOnly
  case notConfirmed

  public var userMessage: String {
    switch self {
    case .emptyTranscript: "这条还没有转写稿，先转写再做素材卡。"
    case .invalidResponse: "模型这次返回的内容没法读成素材卡，请重试一次。"
    case .notConfigured: "请先在设置的「模型服务」里添加模型。"
    case .readOnly: "这份历史当前只能浏览。"
    case .notConfirmed: "还没有确认把转写稿发给模型服务，已取消。"
    }
  }
}

/// 素材卡提示词：系统提示、输入拼装、解析和金句校验。
public enum MaterialCardPrompt {
  /// 送进模型的转写稿最多这么多字。更长的截断，金句校验仍对**全文**做。
  public static let transcriptCharacterLimit = 12_000
  /// 少于这么多字的转写稿不值得做卡。
  public static let minimumTranscriptCharacters = 80
  /// 金句至少这么长（去掉标点空白后），太短的不算句子。
  public static let minimumQuoteCharacters = 4

  public static let system = """
  你是短视频素材分析助手。下面是一段视频的转写稿，请只依据转写稿内容，输出一张素材卡。
  只输出一个 JSON 对象，不要任何多余文字，字段如下：
  {"speaker":"谁在说，一句话","viewpoints":["核心观点，最多3条"],"hook":"开头怎么抓人，一两句话","quotes":["金句，最多3条"],"live_speaker":true或false,"live_speaker_reason":"一句话说明判断依据"}
  要求：
  1. quotes 必须逐字摘自转写稿，一字不改，不要改写、拼接或概括；找不到合适的句子就给空数组。
  2. viewpoints 写这个人要表达的观点，不要复述情节；没有明确观点就给空数组。
  3. live_speaker 表示是否有真人在出镜或口播，并且在表达观点、讲法（不是纯素材、纯画面、纯配乐）。
  4. 转写稿里没有的信息不要编造；不确定就写「看不出来」。
  """

  public static func userContent(transcript: String, title: String?) -> String {
    let body = String(transcript.trimmingCharacters(in: .whitespacesAndNewlines).prefix(transcriptCharacterLimit))
    let heading = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return heading.isEmpty ? "转写稿：\n\(body)" : "标题：\(heading)\n转写稿：\n\(body)"
  }

  // MARK: 解析

  private struct Raw: Decodable {
    let speaker: String?
    let viewpoints: [String]?
    let hook: String?
    let quotes: [String]?
    let liveSpeaker: Bool?
    let liveSpeakerReason: String?

    enum CodingKeys: String, CodingKey {
      case speaker, viewpoints, hook, quotes
      case liveSpeaker = "live_speaker"
      case liveSpeakerReason = "live_speaker_reason"
    }
  }

  /// 把模型回复解析成素材卡，并用转写稿全文核对金句。
  public static func parse(_ raw: String, transcript: String) throws -> MaterialCard {
    guard let data = jsonObjectData(in: raw),
          let decoded = try? JSONDecoder().decode(Raw.self, from: data),
          let live = decoded.liveSpeaker else { throw MaterialCardError.invalidResponse }
    let speaker = clean(decoded.speaker, limit: 120)
    let viewpoints = Array((decoded.viewpoints ?? []).map { clean($0, limit: 160) }.filter { !$0.isEmpty }
      .prefix(MaterialCard.maximumViewpoints))
    let hook = clean(decoded.hook, limit: 200)
    guard !speaker.isEmpty || !viewpoints.isEmpty || !hook.isEmpty else { throw MaterialCardError.invalidResponse }
    return MaterialCard(
      speaker: speaker, viewpoints: viewpoints, hook: hook,
      quotes: validatedQuotes(decoded.quotes ?? [], transcript: transcript),
      isLiveSpeaker: live, liveSpeakerReason: clean(decoded.liveSpeakerReason, limit: 160)
    )
  }

  /// 金句必须是转写稿里真有的句子：忽略空白、标点和大小写后，要整句包含在全文里。
  /// 对不上的丢弃，重复的去重，最多保留 3 条。
  public static func validatedQuotes(_ quotes: [String], transcript: String) -> [String] {
    let haystack = comparable(transcript)
    var seen = Set<String>()
    var kept: [String] = []
    for quote in quotes {
      let needle = comparable(quote)
      guard needle.count >= minimumQuoteCharacters, haystack.contains(needle), seen.insert(needle).inserted else { continue }
      kept.append(quote.trimmingCharacters(in: .whitespacesAndNewlines))
      if kept.count == MaterialCard.maximumQuotes { break }
    }
    return kept
  }

  static func comparable(_ text: String) -> String {
    let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
    // NFKC：全角字母数字、全角标点和半角视作同一个；繁简不处理。
    let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
    return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !drop.contains($0) }))
  }

  private static func clean(_ text: String?, limit: Int) -> String {
    String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }

  private static func jsonObjectData(in raw: String) -> Data? {
    guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
    return Data(raw[start ... end].utf8)
  }
}

/// 「真人口播」标签的去留，纯函数，单独测。
///
/// - 判真且用户没摘过 → 挂上；判假 → 不挂（已有的也不动）；
/// - 上一次生成时挂上了、现在这条上却没有 → 用户手动摘掉了，之后重新生成不再挂回去（记成 suppressed，一直保留）。
public struct MaterialCardTagDecision: Sendable, Equatable {
  public let attach: Bool
  public let suppressed: Bool
  /// 处理完后，这条内容上是否带着「真人口播」。
  public let applied: Bool

  public static func decide(
    card: MaterialCard, previous: TaskMaterialCardRecord?, tagCurrentlyOnItem: Bool
  ) -> MaterialCardTagDecision {
    let removedByUser = previous?.liveSpeakerTagApplied == true && !tagCurrentlyOnItem
    let suppressed = previous?.liveSpeakerTagSuppressed == true || removedByUser
    let attach = card.isLiveSpeaker && !suppressed && !tagCurrentlyOnItem
    return MaterialCardTagDecision(attach: attach, suppressed: suppressed, applied: tagCurrentlyOnItem || attach)
  }
}
