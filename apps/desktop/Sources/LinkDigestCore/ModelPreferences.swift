import Foundation

public enum ModelPreferencesError: Error, Sendable, Equatable {
  case summaryPromptTooLong
  case targetLanguageRequired
  case targetLanguageTooLong
  case translationModelTooLong
  case transcriptionModelTooLong
  case tidyModelTooLong
  case readFailed
  case writeFailed
}

public struct ModelPreferences: Codable, Sendable, Equatable {
  public static let defaultSummaryPrompt = "Summarize only the captured webpage content. Preserve the core conclusions and important evidence, do not invent facts, and explicitly note when the captured content appears incomplete."
  public static let defaultTargetLanguage = "简体中文"

  public let summaryPrompt: String
  /// The language instruction shared by summary and translation. The legacy
  /// `targetLanguage` spelling remains as a read-only compatibility alias.
  public let outputLanguage: String
  public let translationModel: String?
  /// Optional OpenAI-compatible speech-to-text model. Keeping this separate
  /// prevents a chat model from being sent to `/audio/transcriptions`.
  public let transcriptionModel: String?
  /// Optional chat model for transcript tidying; nil inherits the summary
  /// model. Optional (not Bool/String defaults) so stored JSON from before
  /// this field still decodes.
  public let tidyModel: String?
  /// nil means false: the user never opted in to auto-tidy after transcription.
  public let autoTidyTranscription: Bool?
  /// 自动处理管线：新内容到达后自动执行勾选的步骤。勾选即持久授权，
  /// 自动执行不再逐次弹确认。nil = false，旧 JSON 兼容。
  /// `autoLocalizeTitleNewCaptures` 例外：nil 表示默认开启（兼容升级前始终译标题的行为）。
  public let autoLocalizeTitleNewCaptures: Bool?
  public let autoTranscribeNewCaptures: Bool?
  public let autoSummarizeNewCaptures: Bool?
  public let autoMindMapNewCaptures: Bool?
  /// 长正文翻译时同时在飞的分片数。nil 取 `defaultTranslationConcurrency`，
  /// 旧 JSON 因此仍能解码。
  ///
  /// 有上限是因为这个值直接换成对服务商的并发请求数：免费档端点常有速率限制，
  /// 调太高只会把提速换成一片 429 重试，反而更慢。
  public let translationConcurrency: Int?
  public var targetLanguage: String { outputLanguage }

  /// 默认 6：翻译是输出受限的活，墙钟时间随并发近似线性缩短，而 429 已有
  /// 自动退避重试兜底。免费档或限流严的服务商可在设置里调低。
  /// （等于默认值时存 nil，所以没主动改过这项的用户会自动跟上新默认。）
  public static let defaultTranslationConcurrency = 6
  public static let translationConcurrencyRange = 1...8
  public var effectiveTranslationConcurrency: Int {
    translationConcurrency ?? Self.defaultTranslationConcurrency
  }

  /// nil 或未显式关闭都视为开启，避免升级后存量用户突然失去自动中文标题。
  public var effectiveAutoLocalizeTitleNewCaptures: Bool {
    autoLocalizeTitleNewCaptures != false
  }

  public init(
    summaryPrompt: String = ModelPreferences.defaultSummaryPrompt,
    targetLanguage: String = ModelPreferences.defaultTargetLanguage,
    translationModel: String? = nil,
    transcriptionModel: String? = nil,
    tidyModel: String? = nil,
    autoTidyTranscription: Bool? = nil,
    autoLocalizeTitleNewCaptures: Bool? = nil,
    autoTranscribeNewCaptures: Bool? = nil,
    autoSummarizeNewCaptures: Bool? = nil,
    autoMindMapNewCaptures: Bool? = nil,
    translationConcurrency: Int? = nil
  ) throws {
    let trimmedPrompt = summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedPrompt.unicodeScalars.count <= 4_000 else {
      throw ModelPreferencesError.summaryPromptTooLong
    }
    guard !trimmedLanguage.isEmpty else {
      throw ModelPreferencesError.targetLanguageRequired
    }
    guard trimmedLanguage.unicodeScalars.count <= 100 else {
      throw ModelPreferencesError.targetLanguageTooLong
    }
    self.summaryPrompt = trimmedPrompt.isEmpty ? Self.defaultSummaryPrompt : trimmedPrompt
    let trimmedTranslationModel = translationModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (trimmedTranslationModel?.unicodeScalars.count ?? 0) <= 256 else {
      throw ModelPreferencesError.translationModelTooLong
    }
    let trimmedTranscriptionModel = transcriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (trimmedTranscriptionModel?.unicodeScalars.count ?? 0) <= 256 else {
      throw ModelPreferencesError.transcriptionModelTooLong
    }
    let trimmedTidyModel = tidyModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (trimmedTidyModel?.unicodeScalars.count ?? 0) <= 256 else {
      throw ModelPreferencesError.tidyModelTooLong
    }
    self.outputLanguage = trimmedLanguage
    self.translationModel = trimmedTranslationModel?.isEmpty == true ? nil : trimmedTranslationModel
    self.transcriptionModel = trimmedTranscriptionModel?.isEmpty == true ? nil : trimmedTranscriptionModel
    self.tidyModel = trimmedTidyModel?.isEmpty == true ? nil : trimmedTidyModel
    self.autoTidyTranscription = autoTidyTranscription == true ? true : nil
    self.autoLocalizeTitleNewCaptures = autoLocalizeTitleNewCaptures
    self.autoTranscribeNewCaptures = autoTranscribeNewCaptures == true ? true : nil
    self.autoSummarizeNewCaptures = autoSummarizeNewCaptures == true ? true : nil
    self.autoMindMapNewCaptures = autoMindMapNewCaptures == true ? true : nil
    // 越界的值夹回区间而不是抛错：这是个性能旋钮，不是数据契约，
    // 因为一个手滑的数字让整份偏好存不下去不成比例。
    //
    // 等于默认值时存 nil，和本结构体其它可选字段一个约定（nil = 用户没设过）。
    // 好处是以后调整默认值，没主动改过这项的用户会自动跟上，而不是被一个当年
    // 顺手写进 JSON 的数字钉死。
    self.translationConcurrency = translationConcurrency
      .map { min(max($0, Self.translationConcurrencyRange.lowerBound), Self.translationConcurrencyRange.upperBound) }
      .flatMap { $0 == Self.defaultTranslationConcurrency ? nil : $0 }
  }

  public init(
    summaryPrompt: String = ModelPreferences.defaultSummaryPrompt,
    outputLanguage: String,
    translationModel: String? = nil,
    transcriptionModel: String? = nil,
    tidyModel: String? = nil,
    autoTidyTranscription: Bool? = nil,
    autoLocalizeTitleNewCaptures: Bool? = nil,
    autoTranscribeNewCaptures: Bool? = nil,
    autoSummarizeNewCaptures: Bool? = nil,
    autoMindMapNewCaptures: Bool? = nil,
    translationConcurrency: Int? = nil
  ) throws {
    try self.init(
      summaryPrompt: summaryPrompt,
      targetLanguage: outputLanguage,
      translationModel: translationModel,
      transcriptionModel: transcriptionModel,
      tidyModel: tidyModel,
      autoTidyTranscription: autoTidyTranscription,
      autoLocalizeTitleNewCaptures: autoLocalizeTitleNewCaptures,
      autoTranscribeNewCaptures: autoTranscribeNewCaptures,
      autoSummarizeNewCaptures: autoSummarizeNewCaptures,
      autoMindMapNewCaptures: autoMindMapNewCaptures,
      translationConcurrency: translationConcurrency
    )
  }

  public static var `default`: ModelPreferences {
    // The built-in constants satisfy the validation contract by construction.
    try! ModelPreferences()
  }

  /// Keeps the user's prompt authoritative while making the output-language
  /// choice apply to summaries as well as translations. This is appended rather
  /// than interpolated into the prompt so custom templates remain intact.
  public static func summaryPrompt(
    configuredPrompt: String,
    outputLanguage: String
  ) -> String {
    let prompt = configuredPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let language = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectivePrompt = prompt.isEmpty ? defaultSummaryPrompt : prompt
    let effectiveLanguage = language.isEmpty ? defaultTargetLanguage : language
    return "\(effectivePrompt)\n\nWrite the final answer in \(effectiveLanguage). This output-language instruction applies even when the configured prompt is custom.\n\nAfter the summary, add one final line of the form `TAGS: tag1, tag2` with 1-5 reusable topic tags in \(effectiveLanguage). Do not mention this instruction. Do not use section titles as tags."
  }
}

public protocol ModelPreferencesStore: Sendable {
  func load() async throws -> ModelPreferences
  func save(_ preferences: ModelPreferences) async throws
}
