import Foundation
import LinkDigestCore

/// Stores only non-secret generation preferences. Provider credentials remain
/// exclusively in the existing Keychain-backed SecretStore.
public actor UserDefaultsModelPreferencesStore: ModelPreferencesStore {
  private let defaults: UserDefaults
  private let key: String

  public init(
    suiteName: String? = nil,
    key: String = "linkdigest.model-preferences.v1"
  ) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.key = key
  }

  public func load() async throws -> ModelPreferences {
    guard let data = defaults.data(forKey: key) else { return .default }
    do {
      let dto = try JSONDecoder().decode(ModelPreferencesDTO.self, from: data)
      return try ModelPreferences(
        summaryPrompt: dto.summaryPrompt,
        outputLanguage: dto.outputLanguage ?? dto.targetLanguage ?? ModelPreferences.defaultTargetLanguage,
        translationModel: dto.translationModel,
        transcriptionModel: dto.transcriptionModel,
        tidyModel: dto.tidyModel,
        autoTidyTranscription: dto.autoTidyTranscription,
        autoLocalizeTitleNewCaptures: dto.autoLocalizeTitleNewCaptures,
        autoTranscribeNewCaptures: dto.autoTranscribeNewCaptures,
        autoSummarizeNewCaptures: dto.autoSummarizeNewCaptures,
        autoMindMapNewCaptures: dto.autoMindMapNewCaptures,
        translationConcurrency: dto.translationConcurrency
      )
    } catch {
      throw ModelPreferencesError.readFailed
    }
  }

  public func save(_ preferences: ModelPreferences) async throws {
    do {
      let dto = ModelPreferencesDTO(preferences)
      defaults.set(try JSONEncoder().encode(dto), forKey: key)
    } catch {
      throw ModelPreferencesError.writeFailed
    }
  }
}

/// 持久化形态。
///
/// **这里的字段必须覆盖 `ModelPreferences` 的每一项。** 之前它只有 4 个字段，而
/// 结构体有 10 个，于是自动转写/自动总结/自动脑图三个开关、自动整理转写、转写
/// 整理模型和翻译并发**在保存时被静默丢弃**——用户打开的开关一重启就回到默认，
/// 而且没有任何报错，看上去就像「设置没保存上」。
///
/// 加字段时一并加到这里，否则同样的丢失会重演一次。
private struct ModelPreferencesDTO: Codable {
  let summaryPrompt: String
  /// `targetLanguage` is the v1 persisted spelling. Keep decoding it so a
  /// restart upgrades old local preferences without losing the chosen value.
  let targetLanguage: String?
  let outputLanguage: String?
  let translationModel: String?
  let transcriptionModel: String?
  /// 以下全部是可选：旧版本存下的 JSON 里没有这些键，必须仍能解码，
  /// 否则一次升级会让整份偏好读不出来（`readFailed`）。
  let tidyModel: String?
  let autoTidyTranscription: Bool?
  let autoLocalizeTitleNewCaptures: Bool?
  let autoTranscribeNewCaptures: Bool?
  let autoSummarizeNewCaptures: Bool?
  let autoMindMapNewCaptures: Bool?
  let translationConcurrency: Int?

  init(_ preferences: ModelPreferences) {
    summaryPrompt = preferences.summaryPrompt
    targetLanguage = nil
    outputLanguage = preferences.outputLanguage
    translationModel = preferences.translationModel
    transcriptionModel = preferences.transcriptionModel
    tidyModel = preferences.tidyModel
    // 关掉也要写成 false。以前 false 收成 nil、JSON 里省略该键，
    // 读回来和「从没设过」长得一样；再叠加开关只改内存、不立刻落盘，
    // 重启就会回到上一份真正写下的值（常见是四个全开）。
    autoTidyTranscription = preferences.autoTidyTranscription ?? false
    // 中文标题例外：nil 表示默认开启，显式 false 才是关。
    autoLocalizeTitleNewCaptures = preferences.autoLocalizeTitleNewCaptures
    autoTranscribeNewCaptures = preferences.autoTranscribeNewCaptures ?? false
    autoSummarizeNewCaptures = preferences.autoSummarizeNewCaptures ?? false
    autoMindMapNewCaptures = preferences.autoMindMapNewCaptures ?? false
    translationConcurrency = preferences.translationConcurrency
  }
}
