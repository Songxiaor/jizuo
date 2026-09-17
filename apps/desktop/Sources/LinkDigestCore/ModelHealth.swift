import Foundation

/// 一个模型「现在能不能用」。
///
/// 服务商的模型列表只说明模型存在，不说明这把密钥、这个 App 能不能用：
/// opencode Zen 的免费模型全在列表里，实际多数只能在它自家客户端里调，
/// 下架的模型又会从列表里消失、但用户已保存的配置还指着它。
/// 状态来自三种信号：真实调用的结果、模型列表对照、主动检测。
public enum ModelHealthStatus: String, Codable, Sendable, Equatable {
  case available
  case temporarilyUnavailable
  case removed
  case officialClientOnly
  case billingLimited
  case notEntitled
  case keyInvalid

  /// 由一次失败归类出模型状态。网络中断、输入过长这类与模型本身无关的失败不算。
  public init?(failure code: ModelProviderErrorCode) {
    switch code {
    case .modelNotFound: self = .removed
    case .freeTierRestricted: self = .officialClientOnly
    case .providerUnavailable, .rateLimited: self = .temporarilyUnavailable
    case .providerBillingLimited: self = .billingLimited
    case .authForbidden: self = .notEntitled
    case .authInvalid: self = .keyInvalid
    default: return nil
    }
  }

  /// 确定用不了、换 Key 或重试都没用的状态：在列表里排到后面并变灰。
  public var isDefinitelyUnusable: Bool {
    switch self {
    case .removed, .officialClientOnly: true
    default: false
    }
  }

  /// 用于排序：越小越靠前。
  public var sortRank: Int {
    switch self {
    case .available: 0
    case .temporarilyUnavailable: 2
    case .billingLimited, .notEntitled, .keyInvalid: 3
    case .removed, .officialClientOnly: 4
    }
  }
}

public struct ModelHealthRecord: Codable, Sendable, Equatable {
  public enum Source: String, Codable, Sendable {
    /// 真实翻译、总结等调用的结果。
    case run
    /// 读取模型列表时发现已保存的模型不在列表里。
    case catalog
    /// 用户点「检测可用性」发出的极短请求。
    case probe
  }

  public let status: ModelHealthStatus
  public let checkedAtMilliseconds: Int64
  public let source: Source

  public init(status: ModelHealthStatus, checkedAtMilliseconds: Int64, source: Source) {
    self.status = status
    self.checkedAtMilliseconds = checkedAtMilliseconds
    self.source = source
  }

  /// 服务商随时会变：超过一天的结果只作参考，界面提示需要重新检测。
  public static let freshnessMilliseconds: Int64 = 24 * 60 * 60 * 1_000

  public func isStale(nowMilliseconds: Int64) -> Bool {
    nowMilliseconds - checkedAtMilliseconds > Self.freshnessMilliseconds
  }
}

public enum ModelHealthKey {
  /// 同一个模型名在不同服务地址上是不同的东西（opencode Zen 与 Go 模型名大量重合）。
  public static func make(baseURL: String, model: String) -> String {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while base.hasSuffix("/") { base.removeLast() }
    return base + "|" + model.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func make(baseURL: URL, model: String) -> String {
    make(baseURL: baseURL.absoluteString, model: model)
  }

  /// 模型名里明写了 free 的，按免费模型处理：主动检测不花钱。
  public static func looksFree(_ model: String) -> Bool {
    model.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("free")
  }
}

/// 模型调用结果的旁路通知。适配层每次调用结束后报一次，App 层记下来。
/// 不经过它也不影响调用本身；只传服务地址、模型名和状态，不传密钥和任何回包内容。
public enum ModelHealthObservation {
  public typealias Handler = @Sendable (_ baseURL: URL, _ model: String, _ status: ModelHealthStatus) -> Void

  private static let lock = NSLock()
  nonisolated(unsafe) private static var storedHandler: Handler?

  public static var handler: Handler? {
    get { lock.withLock { storedHandler } }
    set { lock.withLock { storedHandler = newValue } }
  }

  /// 「检测可用性」发出的请求用这个配置 id。它们自己记结论（并且知道用的是不是手填的密钥），
  /// 旁路通知跳过，免得手填错的密钥把已保存的模型记成「密钥无效」。
  public static let probeProfileID = "model-probe"

  public static func reportSuccess(profile: ProviderProfile) {
    guard profile.id != probeProfileID else { return }
    handler?(profile.baseURL, profile.model, .available)
  }

  public static func reportFailure(profile: ProviderProfile, code: ModelProviderErrorCode) {
    guard profile.id != probeProfileID, let status = ModelHealthStatus(failure: code) else { return }
    handler?(profile.baseURL, profile.model, status)
  }
}
