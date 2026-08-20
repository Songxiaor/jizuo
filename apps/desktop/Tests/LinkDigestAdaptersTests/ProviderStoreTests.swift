import Foundation
import Security
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

private actor ConsentStartBarrier {
  private let target: Int
  private var arrivals = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(target: Int) { self.target = target }

  func arriveAndWait() async {
    arrivals += 1
    if arrivals == target {
      let waiting = continuations
      continuations.removeAll()
      waiting.forEach { $0.resume() }
      return
    }
    await withCheckedContinuation { continuations.append($0) }
  }
}

final class ProviderStoreTests: XCTestCase {
  func testDataDestinationConsentRoundTripContainsOnlyNonSensitiveIdentity() async throws {
    let (suiteName, defaults) = try ephemeralDefaults("com.syc.linkdigest.tests.")
    let storageKey = "data-destination-consents"
    let profile = try ProviderProfile(
      baseURL: "https://EXAMPLE.test/v1///",
      model: "fixture-model",
      secretReference: .init(rawValue: "opaque-reference")
    )
    let identity = DataDestinationIdentity(profile: profile)
    let store = UserDefaultsDataDestinationConsentStore(suiteName: suiteName, key: storageKey)

    let initiallyConfirmed = try await store.isConfirmed(for: identity)
    XCTAssertFalse(initiallyConfirmed)
    try await store.rememberConfirmation(for: identity)

    let confirmed = try await store.isConfirmed(for: identity)
    XCTAssertTrue(confirmed)
    let raw = try XCTUnwrap(defaults.data(forKey: storageKey))
    let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
    XCTAssertTrue(text.contains("fixture-model"))
    XCTAssertTrue(text.contains("example.test"))
    XCTAssertFalse(text.contains("opaque-reference"))
  }

  func testDataDestinationConsentCorruptionFailsClosed() async throws {
    let (suiteName, defaults) = try ephemeralDefaults("com.syc.linkdigest.tests.")
    let storageKey = "data-destination-consents"
    defaults.set(Data("not-json".utf8), forKey: storageKey)
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: .init(rawValue: "opaque-reference")
    )
    let store = UserDefaultsDataDestinationConsentStore(suiteName: suiteName, key: storageKey)

    await XCTAssertThrowsErrorAsync(try await store.isConfirmed(for: DataDestinationIdentity(profile: profile))) { error in
      XCTAssertEqual(error as? DataDestinationConsentStoreFailure, .readFailed)
    }
  }

  func testConcurrentConsentWritesOnOneProductionStorePreserveEveryIdentity() async throws {
    let (suiteName, defaults) = try ephemeralDefaults("com.syc.linkdigest.tests.")
    let store = UserDefaultsDataDestinationConsentStore(
      suiteName: suiteName,
      key: "concurrent-data-destination-consents"
    )
    let identities = try (0..<8).map { index in
      try DataDestinationIdentity(
        baseURL: "https://provider-\(index).example.test/v1",
        model: "model-\(index)"
      )
    }
    let startBarrier = ConsentStartBarrier(target: identities.count)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for identity in identities {
        group.addTask {
          await startBarrier.arriveAndWait()
          try await store.rememberConfirmation(for: identity)
        }
      }
      try await group.waitForAll()
    }

    for identity in identities {
      let confirmed = try await store.isConfirmed(for: identity)
      XCTAssertTrue(confirmed)
    }
  }

  func testUserDefaultsRoundTripContainsOnlyProviderProfile() async throws {
    let (suiteName, defaults) = try ephemeralDefaults("com.syc.linkdigest.tests.")
    let storageKey = "provider-profile"

    let store = try UserDefaultsProviderProfileStore(
      suiteName: suiteName,
      storageKey: storageKey
    )
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: UUID().uuidString)
    )
    let submittedSecret = UUID().uuidString

    try await store.save(profile)
    let loaded = try await store.load()
    let rawData = try XCTUnwrap(defaults.data(forKey: storageKey))
    let rawText = try XCTUnwrap(String(data: rawData, encoding: .utf8))

    XCTAssertEqual(loaded, profile)
    XCTAssertFalse(rawText.contains(submittedSecret))
    XCTAssertTrue(rawText.contains(profile.secretReference.rawValue))
  }

  func testSecretStoreTimeoutCancelsHungRead() async throws {
    let started = Date()
    do {
      _ = try await SecretStoreTimeout.run(nanoseconds: 40_000_000) {
        Thread.sleep(forTimeInterval: 1)
        return "should-not-return"
      }
      XCTFail("Expected timeout")
    } catch let failure as SecretStoreFailure {
      XCTAssertTrue(failure.isTimeout)
      XCTAssertEqual(failure.operation, .read)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
  }

  func testKeychainWriteReadReplaceAndDeleteUsesIsolatedService() async throws {
    let serviceName = "com.syc.linkdigest.tests.\(UUID().uuidString)"
    let reference = SecretReference(rawValue: UUID().uuidString)
    let store = KeychainSecretStore(service: serviceName)

    do {
      let firstSecret = UUID().uuidString
      try await store.save(firstSecret, for: reference)
      let containsFirstSecret = try await store.contains(reference)
      let storedFirstSecret = try await store.read(reference)
      XCTAssertTrue(containsFirstSecret)
      XCTAssertEqual(storedFirstSecret, firstSecret)

      let replacementSecret = UUID().uuidString
      try await store.save(replacementSecret, for: reference)
      let storedReplacementSecret = try await store.read(reference)
      XCTAssertEqual(storedReplacementSecret, replacementSecret)

      try await store.delete(reference)
      let containsDeletedSecret = try await store.contains(reference)
      let deletedSecret = try await store.read(reference)
      XCTAssertFalse(containsDeletedSecret)
      XCTAssertNil(deletedSecret)
    } catch let failure as SecretStoreFailure {
      try? await store.delete(reference)
      if [
        errSecNotAvailable,
        errSecInteractionNotAllowed,
        errSecAuthFailed
      ].contains(OSStatus(failure.status)) {
        throw XCTSkip("Keychain is unavailable in this test environment")
      }
      throw failure
    } catch {
      try? await store.delete(reference)
      throw error
    }
  }

  func testModelPreferencesRoundTripUsesOnlyNonSecretUserDefaultsData() async throws {
    let suite = ephemeralDefaultsSuiteName("com.syc.linkdigest.preferences-tests.")
    let store = UserDefaultsModelPreferencesStore(suiteName: suite)
    let preferences = try ModelPreferences(
      summaryPrompt: "只列出核心结论与证据。",
      targetLanguage: "日本語",
      transcriptionModel: "whisper-large-v3-turbo"
    )

    try await store.save(preferences)

    let loaded = try await store.load()
    XCTAssertEqual(loaded, preferences)
    let domain = UserDefaults.standard.persistentDomain(forName: suite)?.description ?? ""
    XCTAssertFalse(domain.lowercased().contains("api_key"))
    XCTAssertFalse(domain.lowercased().contains("authorization"))
  }

  func testModelPreferencesMigratesLegacyTargetLanguageAndPersistsTranslationModel() async throws {
    let (suite, defaults) = try ephemeralDefaults("com.syc.linkdigest.preferences-migration-tests.")
    let key = "linkdigest.model-preferences.v1"
    defaults.set(
      try JSONSerialization.data(withJSONObject: [
        "summaryPrompt": "legacy custom prompt",
        "targetLanguage": "Deutsch"
      ]),
      forKey: key
    )
    let store = UserDefaultsModelPreferencesStore(suiteName: suite, key: key)

    let migrated = try await store.load()
    XCTAssertEqual(migrated.outputLanguage, "Deutsch")
    XCTAssertNil(migrated.translationModel)
    XCTAssertNil(migrated.transcriptionModel)

    let updated = try ModelPreferences(
      summaryPrompt: migrated.summaryPrompt,
      outputLanguage: migrated.outputLanguage,
      translationModel: "translation-model",
      transcriptionModel: "transcription-model"
    )
    try await store.save(updated)
    let restarted = try await store.load()
    XCTAssertEqual(restarted, updated)
  }

  func testProviderProfileAllowsOnlyExactLoopbackHTTPWhenExplicitlyEnabled() throws {
    let reference = SecretReference(rawValue: "fixture-reference")
    let loopback = try ProviderProfile(
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3",
      secretReference: reference,
      allowLoopbackHTTP: true
    )
    XCTAssertEqual(loopback.baseURL.host, "127.0.0.1")

    XCTAssertThrowsError(try ProviderProfile(
      baseURL: "http://localhost:11434/v1",
      model: "llama3",
      secretReference: reference,
      allowLoopbackHTTP: true
    )) { error in
      XCTAssertEqual(error as? ProviderConfigurationError, .baseURLInvalid)
    }
    XCTAssertThrowsError(try ProviderProfile(
      baseURL: "http://192.168.1.10:11434/v1",
      model: "llama3",
      secretReference: reference,
      allowLoopbackHTTP: true
    ))
  }

  func testModelPreferencesLoadRejectsInvalidDTOValuesAndCorruption() async throws {
    let (suite, defaults) = try ephemeralDefaults("com.syc.linkdigest.preferences-invalid-tests.")
    let key = "linkdigest.model-preferences.v1"
    let store = UserDefaultsModelPreferencesStore(suiteName: suite, key: key)

    let invalidPayloads: [Data] = [
      try JSONSerialization.data(withJSONObject: ["summaryPrompt": "valid", "targetLanguage": "   "]),
      try JSONSerialization.data(withJSONObject: ["summaryPrompt": String(repeating: "p", count: 4_001), "targetLanguage": "中文"]),
      Data("{not-json".utf8)
    ]
    for payload in invalidPayloads {
      defaults.set(payload, forKey: key)
      do {
        _ = try await store.load()
        XCTFail("invalid persisted preferences must not enter the provider path")
      } catch let error as ModelPreferencesError {
        XCTAssertEqual(error, .readFailed)
      }
    }
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure @escaping () async throws -> T,
  _ handler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("expected error")
  } catch {
    handler(error)
  }
}

/// 生成偏好的持久化必须**逐字段完整**。
///
/// 这里断言的是整个结构体相等，不是挑几个字段看。原来的 DTO 只有 4 个字段而
/// `ModelPreferences` 有 10 个，自动转写/自动总结/自动脑图三个开关、自动整理、
/// 转写整理模型和翻译并发在保存时被静默丢弃——用户打开的开关一重启就回到默认。
/// 挑字段断言正是它当年溜过去的原因，所以这条只比较整体：以后谁加了字段却忘了
/// 加进 DTO，这里立刻变红。
final class ModelPreferencesFullRoundTripTests: XCTestCase {
  func testEveryFieldSurvivesSaveAndLoad() async throws {
    let suite = ephemeralDefaultsSuiteName("com.syc.linkdigest.preferences-full.")
    let store = UserDefaultsModelPreferencesStore(suiteName: suite)

    // 每一项都取**非默认值**，否则「没存下来」和「存了默认值」看起来一样。
    let saved = try ModelPreferences(
      summaryPrompt: "只列出核心结论与证据。",
      outputLanguage: "日本語",
      translationModel: "translate-model",
      transcriptionModel: "whisper-large-v3-turbo",
      tidyModel: "tidy-model",
      autoTidyTranscription: true,
      autoTranscribeNewCaptures: true,
      autoSummarizeNewCaptures: true,
      autoMindMapNewCaptures: true,
      translationConcurrency: ModelPreferences.defaultTranslationConcurrency + 2
    )
    try await store.save(saved)

    let loaded = try await UserDefaultsModelPreferencesStore(suiteName: suite).load()
    XCTAssertEqual(loaded, saved, "有字段没能穿过保存/读取——多半是 DTO 漏了它")
  }

  /// 旧版本存的 JSON 里没有新字段，升级后必须仍能读出来，不能整份偏好读失败。
  func testOlderPayloadWithoutNewFieldsStillLoads() async throws {
    let (suite, defaults) = try ephemeralDefaults("com.syc.linkdigest.preferences-legacy.")
    let key = "linkdigest.model-preferences.v1"
    defaults.set(
      try JSONEncoder().encode(["summaryPrompt": "老提示词", "outputLanguage": "Deutsch"]),
      forKey: key
    )

    let loaded = try await UserDefaultsModelPreferencesStore(suiteName: suite, key: key).load()
    XCTAssertEqual(loaded.summaryPrompt, "老提示词")
    XCTAssertEqual(loaded.outputLanguage, "Deutsch")
    // 缺失的新字段回落到默认，而不是让整次读取失败。
    XCTAssertNil(loaded.autoSummarizeNewCaptures)
    XCTAssertEqual(loaded.effectiveTranslationConcurrency, ModelPreferences.defaultTranslationConcurrency)
  }

  func testTurningOffPipelineFlagsSurvivesRestartAsExplicitFalse() async throws {
    let suite = ephemeralDefaultsSuiteName("com.syc.linkdigest.preferences-pipeline-off.")
    let store = UserDefaultsModelPreferencesStore(suiteName: suite)
    let saved = try ModelPreferences(
      autoTidyTranscription: false,
      autoTranscribeNewCaptures: true,
      autoSummarizeNewCaptures: false,
      autoMindMapNewCaptures: false
    )
    try await store.save(saved)

    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let data = try XCTUnwrap(defaults.data(forKey: "linkdigest.model-preferences.v1"))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["autoTranscribeNewCaptures"] as? Bool, true)
    XCTAssertEqual(json["autoTidyTranscription"] as? Bool, false)
    XCTAssertEqual(json["autoSummarizeNewCaptures"] as? Bool, false)
    XCTAssertEqual(json["autoMindMapNewCaptures"] as? Bool, false)

    let loaded = try await UserDefaultsModelPreferencesStore(suiteName: suite).load()
    XCTAssertEqual(loaded.autoTranscribeNewCaptures, true)
    XCTAssertNil(loaded.autoTidyTranscription)
    XCTAssertNil(loaded.autoSummarizeNewCaptures)
    XCTAssertNil(loaded.autoMindMapNewCaptures)
  }
}
