import Foundation
import LinkDigestCore

/// A local-only consent record. Its encoded values contain only destination
/// URL, host, model and API mode; API keys and Keychain references never enter
/// this adapter.
public actor UserDefaultsDataDestinationConsentStore: DataDestinationConsentStore {
  private let defaults: UserDefaults
  private let key: String

  public init(
    suiteName: String? = nil,
    key: String = "com.syc.linkdigest.dataDestinationConsents.v1"
  ) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.key = key
  }

  public func isConfirmed(for identity: DataDestinationIdentity) async throws -> Bool {
    try load().contains(identity)
  }

  public func rememberConfirmation(for identity: DataDestinationIdentity) async throws {
    var values = try load()
    values.insert(identity)
    do {
      let data = try JSONEncoder().encode(values)
      defaults.set(data, forKey: key)
      guard defaults.data(forKey: key) == data else {
        throw DataDestinationConsentStoreFailure.writeFailed
      }
    } catch {
      throw DataDestinationConsentStoreFailure.writeFailed
    }
  }

  private func load() throws -> Set<DataDestinationIdentity> {
    guard let data = defaults.data(forKey: key) else { return [] }
    do {
      return try JSONDecoder().decode(Set<DataDestinationIdentity>.self, from: data)
    } catch {
      throw DataDestinationConsentStoreFailure.readFailed
    }
  }
}
