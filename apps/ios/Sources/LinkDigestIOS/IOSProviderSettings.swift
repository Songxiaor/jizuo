import Foundation
import Security

/// iOS Companion 的非敏感模型配置。API Key 不进这里。
///
/// 流程对齐 Mac：先拉 `/models` → 勾选 → 加入已添加列表 → 指定当前使用模型。
public struct IOSProviderProfile: Codable, Sendable, Equatable {
  public var baseURL: String
  /// 当前用于总结 / 翻译 / 连接测试的模型。
  public var modelName: String
  /// 用户从目录勾选添加的模型（可多选）。
  public var addedModels: [String]
  /// 总结 / 翻译统一输出语言，默认简体中文。
  public var outputLanguage: String

  public init(
    baseURL: String = "",
    modelName: String = "",
    addedModels: [String] = [],
    outputLanguage: String = OpenAICompatibleSummarizer.defaultOutputLanguage
  ) {
    self.baseURL = baseURL
    self.modelName = modelName
    self.addedModels = Self.normalizedModelList(addedModels)
    self.outputLanguage = outputLanguage
  }

  public var isConfigured: Bool {
    !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  enum CodingKeys: String, CodingKey {
    case baseURL
    case modelName
    case addedModels
    case outputLanguage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
    addedModels = Self.normalizedModelList(
      try container.decodeIfPresent([String].self, forKey: .addedModels) ?? []
    )
    outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
      ?? OpenAICompatibleSummarizer.defaultOutputLanguage
    // 旧配置只有 modelName：自动并入已添加列表。
    if !modelName.isEmpty, !addedModels.contains(modelName) {
      addedModels.insert(modelName, at: 0)
    }
  }

  public static func normalizedModelList(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for item in raw {
      let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      result.append(trimmed)
    }
    return result
  }
}

public protocol IOSProviderProfileStore: Sendable {
  func load() -> IOSProviderProfile
  func save(_ profile: IOSProviderProfile)
}

public struct UserDefaultsIOSProviderProfileStore: IOSProviderProfileStore, @unchecked Sendable {
  public static let defaultsKey = "linkdigest.ios.provider.profile.v1"

  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = UserDefaultsIOSProviderProfileStore.defaultsKey) {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> IOSProviderProfile {
    guard let data = defaults.data(forKey: key),
          let decoded = try? JSONDecoder().decode(IOSProviderProfile.self, from: data)
    else {
      return IOSProviderProfile()
    }
    return decoded
  }

  public func save(_ profile: IOSProviderProfile) {
    let language = OpenAICompatibleSummarizer.normalizedOutputLanguage(profile.outputLanguage)
    var added = IOSProviderProfile.normalizedModelList(profile.addedModels)
    let active = profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !active.isEmpty, !added.contains(active) {
      added.insert(active, at: 0)
    }
    let trimmed = IOSProviderProfile(
      baseURL: profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      modelName: active,
      addedModels: added,
      outputLanguage: language
    )
    guard let data = try? JSONEncoder().encode(trimmed) else { return }
    defaults.set(data, forKey: key)
  }
}

/// API Key 读写端口。测试可注入内存实现，真机用 Keychain。
public protocol IOSAPIKeyStore: Sendable {
  func save(_ apiKey: String) throws
  func read() throws -> String?
  func delete() throws
}

public final class InMemoryIOSAPIKeyStore: IOSAPIKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  public init(seed: String? = nil) {
    self.value = seed
  }

  public func save(_ apiKey: String) throws {
    lock.lock()
    defer { lock.unlock() }
    value = apiKey
  }

  public func read() throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public func delete() throws {
    lock.lock()
    defer { lock.unlock() }
    value = nil
  }
}

/// Keychain 存 API Key；**不得**写入 UserDefaults、文件或日志。
public struct KeychainIOSAPIKeyStore: IOSAPIKeyStore {
  public static let defaultService = "com.syc.linkdigest.ios.provider-secret"
  public static let defaultAccount = "openai-compatible-api-key"

  private let service: String
  private let account: String

  public init(
    service: String = KeychainIOSAPIKeyStore.defaultService,
    account: String = KeychainIOSAPIKeyStore.defaultAccount
  ) {
    self.service = service
    self.account = account
  }

  public func save(_ apiKey: String) throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
      throw IOSProviderSettingsError.keychainWriteFailed
    }
    let query = baseQuery()
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    var status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
    }
    guard status == errSecSuccess else {
      throw IOSProviderSettingsError.keychainWriteFailed
    }
  }

  public func read() throws -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw IOSProviderSettingsError.keychainReadFailed
    }
    return String(data: data, encoding: .utf8)
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw IOSProviderSettingsError.keychainWriteFailed
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public enum IOSProviderSettingsError: Error, LocalizedError, Sendable, Equatable {
  case missingBaseURL
  case missingModel
  case missingAPIKey
  case keychainReadFailed
  case keychainWriteFailed

  public var errorDescription: String? {
    switch self {
    case .missingBaseURL:
      return "请先填写 Base URL。"
    case .missingModel:
      return "请先获取模型并勾选添加，再选择当前使用的模型。"
    case .missingAPIKey:
      return "请先在设置里保存 API Key。"
    case .keychainReadFailed:
      return "无法从钥匙串读取 API Key。"
    case .keychainWriteFailed:
      return "无法把 API Key 写入钥匙串。"
    }
  }
}
