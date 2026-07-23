import Foundation
import LinkDigestCore

public actor UserDefaultsModelLibraryStore: ModelLibraryStore {
  public static let defaultStorageKey = "com.syc.linkdigest.model-library"

  private let defaults: UserDefaults
  private let storageKey: String

  public init(storageKey: String = UserDefaultsModelLibraryStore.defaultStorageKey) {
    self.defaults = .standard
    self.storageKey = storageKey
  }

  public init(
    suiteName: String,
    storageKey: String = UserDefaultsModelLibraryStore.defaultStorageKey
  ) throws {
    guard let suiteDefaults = UserDefaults(suiteName: suiteName) else {
      throw ProviderProfileStoreFailure.readFailed
    }
    self.defaults = suiteDefaults
    self.storageKey = storageKey
  }

  public func load() async throws -> ModelLibrary? {
    guard let data = defaults.data(forKey: storageKey) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(ModelLibrary.self, from: data)
    } catch {
      throw ProviderProfileStoreFailure.readFailed
    }
  }

  public func save(_ library: ModelLibrary) async throws {
    do {
      defaults.set(try JSONEncoder().encode(library), forKey: storageKey)
    } catch {
      throw ProviderProfileStoreFailure.writeFailed
    }
  }
}
