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
    await KeychainReadCache.shared.store(secret, service: service, account: reference.rawValue)
  }

  /// 每条密钥在一次运行里只真正读一次钥匙串。
  ///
  /// 签名不稳定（ad-hoc）或用户还没点「始终允许」时，**每读一次就弹一次**钥匙串授权框。
  /// 打开 App 时总结、转写、模型列表核对会各读一遍同一条密钥，于是连弹四五个。
  /// 这里把读到的值留在内存里（退出即清空、不落盘），同时读同一条的并发请求合并成一次。
  public func read(_ reference: SecretReference) async throws -> String? {
    let service = self.service
    let account = reference.rawValue
    return try await KeychainReadCache.shared.value(service: service, account: account) {
      guard let data = try await self.copyMatching(account: account, returnData: true).data else {
        return nil
      }
      guard let secret = String(data: data, encoding: .utf8) else {
        throw SecretStoreFailure(operation: .read, status: errSecDecode)
      }
      return secret
    }
  }

  public func contains(_ reference: SecretReference) async throws -> Bool {
    try await copyMatching(account: reference.rawValue, returnData: false).found
  }

  public func delete(_ reference: SecretReference) async throws {
    let status = SecItemDelete(baseQuery(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreFailure(operation: .delete, status: status)
    }
    await KeychainReadCache.shared.remove(service: service, account: reference.rawValue)
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

/// 进程内的密钥读取缓存。App 里有不止一个 `KeychainSecretStore` 实例，所以放在共享处。
actor KeychainReadCache {
  static let shared = KeychainReadCache()

  private var values: [String: String] = [:]
  private var inFlight: [String: Task<String?, Error>] = [:]
  /// 每次写入或删除都加一：读到一半被改过，读回来的旧值就不能进缓存。
  private var versions: [String: Int] = [:]

  func value(
    service: String,
    account: String,
    load: @escaping @Sendable () async throws -> String?
  ) async throws -> String? {
    let key = service + "|" + account
    if let cached = values[key] { return cached }
    if let running = inFlight[key] { return try await running.value }
    let versionAtStart = versions[key, default: 0]
    let task = Task { try await load() }
    inFlight[key] = task
    let loaded: String?
    do {
      loaded = try await task.value
    } catch {
      if inFlight[key] == task { inFlight[key] = nil }
      throw error
    }
    if inFlight[key] == task { inFlight[key] = nil }
    // 读的过程中有人写入或删除过这条：以那次改动为准，不拿读回来的旧值覆盖。
    guard versions[key, default: 0] == versionAtStart else { return values[key] ?? loaded }
    // 读不到（nil）不缓存：用户可能随后才保存。
    if let loaded { values[key] = loaded }
    return loaded
  }

  func store(_ secret: String, service: String, account: String) {
    let key = service + "|" + account
    versions[key, default: 0] += 1
    inFlight[key] = nil
    values[key] = secret
  }

  func remove(service: String, account: String) {
    let key = service + "|" + account
    versions[key, default: 0] += 1
    inFlight[key] = nil
    values[key] = nil
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
