import Foundation
import LinkDigestCore

public actor UserDefaultsProviderProfileStore: ProviderProfileStore {
  public static let defaultStorageKey = "com.syc.linkdigest.provider-profile"

  private let defaults: UserDefaults
  private let storageKey: String

  public init(storageKey: String = UserDefaultsProviderProfileStore.defaultStorageKey) {
    self.defaults = .standard
    self.storageKey = storageKey
  }

  public init(
    suiteName: String,
    storageKey: String = UserDefaultsProviderProfileStore.defaultStorageKey
  ) throws {
    guard let suiteDefaults = UserDefaults(suiteName: suiteName) else {
      throw ProviderProfileStoreFailure.readFailed
    }
    self.defaults = suiteDefaults
    self.storageKey = storageKey
  }

  public func load() async throws -> ProviderProfile? {
    guard let data = defaults.data(forKey: storageKey) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(ProviderProfile.self, from: data)
    } catch {
      throw ProviderProfileStoreFailure.readFailed
    }
  }

  public func save(_ profile: ProviderProfile) async throws {
    do {
      defaults.set(try JSONEncoder().encode(profile), forKey: storageKey)
    } catch {
      throw ProviderProfileStoreFailure.writeFailed
    }
  }

  public func delete() async throws {
    defaults.removeObject(forKey: storageKey)
  }
}
