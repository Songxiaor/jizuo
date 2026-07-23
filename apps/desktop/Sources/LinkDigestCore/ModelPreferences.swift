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
  public var targetLanguage: String { outputLanguage }

  public init(
    summaryPrompt: String = ModelPreferences.defaultSummaryPrompt,
    targetLanguage: String = ModelPreferences.defaultTargetLanguage,
    translationModel: String? = nil,
    transcriptionModel: String? = nil,
    tidyModel: String? = nil,
    autoTidyTranscription: Bool? = nil
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
  }

  public init(
    summaryPrompt: String = ModelPreferences.defaultSummaryPrompt,
    outputLanguage: String,
    translationModel: String? = nil,
    transcriptionModel: String? = nil,
    tidyModel: String? = nil,
    autoTidyTranscription: Bool? = nil
  ) throws {
    try self.init(
      summaryPrompt: summaryPrompt,
      targetLanguage: outputLanguage,
      translationModel: translationModel,
      transcriptionModel: transcriptionModel,
      tidyModel: tidyModel,
      autoTidyTranscription: autoTidyTranscription
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
    return "\(effectivePrompt)\n\nWrite the final answer in \(effectiveLanguage). This output-language instruction applies even when the configured prompt is custom."
  }
}

public protocol ModelPreferencesStore: Sendable {
  func load() async throws -> ModelPreferences
  func save(_ preferences: ModelPreferences) async throws
}
