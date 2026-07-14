import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

private actor ViewModelProfileStore: ProviderProfileStore {
  private var profile: ProviderProfile?

  func load() async throws -> ProviderProfile? {
    profile
  }

  func save(_ profile: ProviderProfile) async throws {
    self.profile = profile
  }

  func delete() async throws {
    profile = nil
  }
}

private actor ViewModelSecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  private let failSave: Bool

  init(failSave: Bool = false) {
    self.failSave = failSave
  }

  func save(_ secret: String, for reference: SecretReference) async throws {
    if failSave {
      throw SecretStoreFailure(operation: .write, status: -1)
    }
    values[reference] = secret
  }

  func read(_ reference: SecretReference) async throws -> String? {
    values[reference]
  }

  func contains(_ reference: SecretReference) async throws -> Bool {
    values[reference] != nil
  }

  func delete(_ reference: SecretReference) async throws {
    values.removeValue(forKey: reference)
  }
}

@MainActor
final class ProviderSettingsViewModelTests: XCTestCase {
  func testSecretFailureIsRecoverableAndObservableStateDoesNotExposeKey() async {
    let service = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore(failSave: true)
    )
    let model = ProviderSettingsViewModel(configurationService: service)
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    let submittedSecret = UUID().uuidString

    await model.save(apiKey: submittedSecret)

    XCTAssertEqual(
      model.state,
      .failed(code: ProviderConfigurationError.secretStoreWriteFailed.rawValue)
    )
    XCTAssertFalse(model.statusText.contains(submittedSecret))
    XCTAssertFalse(model.baseURL.contains(submittedSecret))
    XCTAssertFalse(model.modelName.contains(submittedSecret))
  }

  func testSuccessfulSaveShowsFixedMaskWithoutExposingKey() async {
    let service = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore()
    )
    let model = ProviderSettingsViewModel(configurationService: service)
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    let submittedSecret = UUID().uuidString

    await model.save(apiKey: submittedSecret)

    XCTAssertEqual(model.state, .configured)
    XCTAssertEqual(model.statusText, "API Key：••••••••（已保存）")
    XCTAssertFalse(model.statusText.contains(submittedSecret))
  }
}
