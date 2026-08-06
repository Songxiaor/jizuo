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

  /// 按**端点**判断，不按端点 + 模型。
  ///
  /// 原来是整份身份相等才算已确认，而身份里带模型名。于是同一家服务商换个模型
  /// ——哪怕只差一个 `-free` 后缀——就被当成新目的地重问一次。用户看到的是「每次
  /// 都在问」，而这个框想说的其实是「你的正文要发去 opencode.ai」，这件事在换模型
  /// 时并没有变。换服务商仍然会问，因为那时数据确实去了另一家。
  ///
  /// 记录本身仍存整份身份：留着第一次是用哪个模型授权的，比只存一个域名可查。
  public func isConfirmed(for identity: DataDestinationIdentity) async throws -> Bool {
    try load().contains {
      $0.normalizedBaseURL == identity.normalizedBaseURL && $0.apiMode == identity.apiMode
    }
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

  public func forgetAll() async throws {
    defaults.removeObject(forKey: key)
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
