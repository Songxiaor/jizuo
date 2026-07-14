import Foundation
import LinkDigestCore
import Security

public actor KeychainSecretStore: SecretStore {
  public static let defaultService = "com.syc.linkdigest.provider-secret"

  private let service: String

  public init(service: String = KeychainSecretStore.defaultService) {
    self.service = service
  }

  public func save(_ secret: String, for reference: SecretReference) async throws {
    guard
      !reference.rawValue.isEmpty,
      !secret.isEmpty,
      let data = secret.data(using: .utf8)
    else {
      throw SecretStoreFailure(operation: .write, status: errSecParam)
    }

    let query = baseQuery(reference)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    var status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
    }
    guard status == errSecSuccess else {
      throw SecretStoreFailure(operation: .write, status: status)
    }
  }

  public func read(_ reference: SecretReference) async throws -> String? {
    var query = baseQuery(reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard
      status == errSecSuccess,
      let data = result as? Data,
      let secret = String(data: data, encoding: .utf8)
    else {
      throw SecretStoreFailure(operation: .read, status: status)
    }
    return secret
  }

  public func contains(_ reference: SecretReference) async throws -> Bool {
    var query = baseQuery(reference)
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecItemNotFound {
      return false
    }
    guard status == errSecSuccess else {
      throw SecretStoreFailure(operation: .read, status: status)
    }
    return true
  }

  public func delete(_ reference: SecretReference) async throws {
    let status = SecItemDelete(baseQuery(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreFailure(operation: .delete, status: status)
    }
  }

  private func baseQuery(_ reference: SecretReference) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.rawValue
    ]
  }
}
