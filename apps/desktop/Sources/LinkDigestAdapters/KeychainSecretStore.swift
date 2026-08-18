import Foundation
import LinkDigestCore
import Security

public actor KeychainSecretStore: SecretStore {
  public static let defaultService = "com.syc.linkdigest.provider-secret"
  public static let defaultReadTimeoutNanoseconds: UInt64 = 15_000_000_000

  private let service: String
  private let readTimeoutNanoseconds: UInt64

  public init(
    service: String = KeychainSecretStore.defaultService,
    readTimeoutNanoseconds: UInt64 = KeychainSecretStore.defaultReadTimeoutNanoseconds
  ) {
    self.service = service
    self.readTimeoutNanoseconds = readTimeoutNanoseconds
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
    guard let data = try await copyMatching(account: reference.rawValue, returnData: true).data else {
      return nil
    }
    guard let secret = String(data: data, encoding: .utf8) else {
      throw SecretStoreFailure(operation: .read, status: errSecDecode)
    }
    return secret
  }

  public func contains(_ reference: SecretReference) async throws -> Bool {
    try await copyMatching(account: reference.rawValue, returnData: false).found
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

  private func copyMatching(account: String, returnData: Bool) async throws -> KeychainCopyMatch {
    let service = self.service
    let timeout = readTimeoutNanoseconds
    return try await SecretStoreTimeout.run(nanoseconds: timeout) {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitOne
      ]
      if returnData {
        query[kSecReturnData as String] = true
      }
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound {
        return KeychainCopyMatch(data: nil, found: false)
      }
      guard status == errSecSuccess else {
        throw SecretStoreFailure(operation: .read, status: status)
      }
      return KeychainCopyMatch(data: result as? Data, found: true)
    }
  }
}

struct KeychainCopyMatch: Sendable {
  var data: Data?
  var found: Bool
}

enum SecretStoreTimeout {
  static func run<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let state = TimeoutState<T>()
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          state.finish(result: .success(try operation()), continuation: continuation)
        } catch {
          state.finish(result: .failure(error), continuation: continuation)
        }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + .nanoseconds(Int(nanoseconds))
      ) {
        state.finish(
          result: .failure(SecretStoreFailure(operation: .read, status: SecretStoreFailure.timeoutStatus)),
          continuation: continuation
        )
      }
    }
  }
}

private final class TimeoutState<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false

  func finish(
    result: Result<T, Error>,
    continuation: CheckedContinuation<T, Error>
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    continuation.resume(with: result)
  }
}
