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
        transcriptionModel: dto.transcriptionModel
      )
    } catch {
      throw ModelPreferencesError.readFailed
    }
  }

  public func save(_ preferences: ModelPreferences) async throws {
    do {
      let dto = ModelPreferencesDTO(
        summaryPrompt: preferences.summaryPrompt,
        outputLanguage: preferences.outputLanguage,
        translationModel: preferences.translationModel,
        transcriptionModel: preferences.transcriptionModel
      )
      defaults.set(try JSONEncoder().encode(dto), forKey: key)
    } catch {
      throw ModelPreferencesError.writeFailed
    }
  }
}

private struct ModelPreferencesDTO: Codable {
  let summaryPrompt: String
  /// `targetLanguage` is the v1 persisted spelling. Keep decoding it so a
  /// restart upgrades old local preferences without losing the chosen value.
  let targetLanguage: String?
  let outputLanguage: String?
  let translationModel: String?
  let transcriptionModel: String?

  init(summaryPrompt: String, outputLanguage: String, translationModel: String?, transcriptionModel: String?) {
    self.summaryPrompt = summaryPrompt
    targetLanguage = nil
    self.outputLanguage = outputLanguage
    self.translationModel = translationModel
    self.transcriptionModel = transcriptionModel
  }
}
