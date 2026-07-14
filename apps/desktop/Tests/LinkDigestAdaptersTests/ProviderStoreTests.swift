import Foundation
import Security
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class ProviderStoreTests: XCTestCase {
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
