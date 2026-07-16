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
    let suiteName = "com.syc.linkdigest.tests.\(UUID().uuidString)"
    let storageKey = "data-destination-consents"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
    let suiteName = "com.syc.linkdigest.tests.\(UUID().uuidString)"
    let storageKey = "data-destination-consents"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
    let suiteName = "com.syc.linkdigest.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
    let suiteName = "com.syc.linkdigest.tests.\(UUID().uuidString)"
    let storageKey = "provider-profile"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
