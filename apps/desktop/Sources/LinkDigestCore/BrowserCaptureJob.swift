import Foundation

/// 浏览器代抓：汲作自己打不开、或打不开完整内容时，改用用户浏览器里已登录的
/// 汲作扩展把这一页抓回来。
///
/// 这条通道需要一个 App 与扩展之间的约定：
/// 1. App 打开标签前先登记一个一次性任务（job），把目标链接和排队项绑在一起；
/// 2. 扩展在标签加载完成时问 Host/App「这个地址有没有待抓任务」，命中才动手；
/// 3. 扩展抓完把内容连同 job id 送回 App，App 用它认回排队项。
///
/// 请求/回包都是独立消息类型，不塞进 capture envelope 的必填字段：旧版 App 收到
/// 不认识的消息如实回错，旧版扩展根本不会发，双方都能单独升级。

/// 扩展问：「这些地址里有待代抓的吗？」
public struct BrowserCaptureJobRequest: Sendable, Equatable {
  public static let kind = "browserCaptureJob"
  public static let maximumURLLength = 4_096
  /// 一次带上当前地址和这一页导航过程中见过的地址（短链会跳转，见 relay.ts）。
  public static let maximumURLCount = 4

  public let requestId: String
  /// 发问的标签。job 被某个标签认领后，别的标签再问不再返回它，
  /// 避免两个标签（用户自己的 + 代抓开的）重复抓同一条内容。
  public let tabID: Int
  /// 这个标签带代抓标记：短链重定向后地址可能完全变样，导航历史也未必还在
  /// （MV3 后台被回收过）。为真时，App 可以在「地址对不上、但只有一单在等」
  /// 的情况下把这一单交给它——标记本身就是 App 开的证据。
  public let allowsRelayTabFallback: Bool
  public let urls: [String]

  public init(requestId: String, tabID: Int, allowsRelayTabFallback: Bool = false, urls: [String]) {
    self.requestId = requestId
    self.tabID = tabID
    self.allowsRelayTabFallback = allowsRelayTabFallback
    self.urls = urls
  }

  /// 返回 nil 表示「不是这类消息」；抛错表示是但不合法。
  public static func decode(_ data: Data) throws -> BrowserCaptureJobRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String,
      kind == Self.kind
    else { return nil }
    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    guard let tabID = (object["tabID"] as? NSNumber)?.intValue,
          (1...Int(Int32.max)).contains(tabID)
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    let allowsRelayTabFallback = (object["relayTab"] as? NSNumber).map {
      CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
    } ?? false
    guard let rawURLs = object["urls"] as? [String],
          (1...maximumURLCount).contains(rawURLs.count)
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    for raw in rawURLs {
      guard raw.count <= maximumURLLength,
            let parsed = URL(string: raw),
            ["http", "https"].contains(parsed.scheme?.lowercased())
      else { throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED }
    }
    return BrowserCaptureJobRequest(
      requestId: requestId,
      tabID: tabID,
      allowsRelayTabFallback: allowsRelayTabFallback,
      urls: rawURLs
    )
  }
}

/// 哪些抓取失败值得交给浏览器再试一次。
///
/// 只挑「浏览器里有登录/有渲染、换个环境就可能成功」的那几种。链接本身不合法、
/// 被安全策略挡住、或明确要求换链接的失败不代抓——那不是环境问题，多开一个标签
/// 只会得到同样的结论，还白白等 90 秒。
public enum BrowserCaptureRelayPolicy {
  public static func shouldRelay(_ error: ManualLinkError) -> Bool {
    switch error {
    case .extensionCaptureRequired, .timedOut, .verificationRequired, .emptyContent, .invalidPageResult,
         .loginRequired, .shareLinkMissingToken:
      return true
    case .invalidURL, .unsafeURL, .webHostNotAllowed, .proxyHTTPSRequired, .proxyAuthenticationRequired,
         .fakeIPProxyUnavailable, .proxyTLSValidation, .responseStatus, .unsupportedContentType,
         .responseTooLarge, .shareLinkExpired, .githubRepositoryUnavailable, .githubFileUnavailable,
         .githubRateLimited, .xStatusIdentityMismatch, .cancelled, .network:
      return false
    }
  }
}

/// 代抓失败的真实原因。以前这些问题都塌缩成「请在浏览器里打开它，再用浏览器扩展保存」，
/// 自动化在清晨无人值守时只会一次次撞同一堵墙；现在每种失败都有自己能看懂的说明。
public enum BrowserCaptureRelayFailure: Error, Sendable, Equatable {
  /// 本机既没有 ego 也没有 Chrome，或它们的扩展通道没装好。
  case browserUnavailable
  /// 打开了标签，但 90 秒内没有任何扩展来认领。
  case extensionNotConnected
  /// 扩展认领了，但页面在时限内没加载完/没送出内容。
  case timedOut
  /// 浏览器扩展没有这个站点的访问权限，注入不了提取脚本。
  case permissionMissing(host: String)
  /// 页面在浏览器里落地成了平台自己的错误页/登录页（小红书 404、验证页…），
  /// 带着对应的抓取错误码立即失败，不再干等超时。
  case blocked(ManualLinkError, landing: String)
  /// 扩展确实来问过任务，但落地地址对不上任何排队项：说明页面被平台或网络换掉了。
  case targetNotMatched(landing: String)
  case cancelled

  public var code: String {
    switch self {
    case .browserUnavailable: "browser_capture_unavailable"
    case .extensionNotConnected: "browser_extension_unreachable"
    case .timedOut: "browser_capture_timeout"
    case .permissionMissing: "browser_capture_permission_missing"
    case let .blocked(error, _): String(describing: error)
    case .targetNotMatched: "browser_capture_target_unmatched"
    case .cancelled: "browser_capture_cancelled"
    }
  }

  public var userMessage: String {
    switch self {
    case .browserUnavailable:
      "没找到可用的浏览器：需要本机装有 ego 或 Google Chrome，并在汲作「设置 → 浏览器扩展」里装好扩展。"
    case .extensionNotConnected:
      "浏览器扩展没有连上汲作：浏览器没打开，或扩展没启用。确认浏览器和扩展都开着后重试。"
    case .timedOut:
      "浏览器里这条链接 90 秒内没有抓取完成（页面太慢、需要人工验证，或扩展被收回了站点权限），这次没有保存。"
    case let .permissionMissing(host):
      "浏览器扩展没有 \(host.isEmpty ? "这个网站" : host) 的访问权限，需要在扩展设置里允许访问该网站后才能代抓。"
    case let .blocked(error, landing):
      Self.blockedMessage(for: error, landing: landing)
    case let .targetNotMatched(landing):
      "浏览器打开这条链接后落地到 \(landing)，没有找到对应的抓取任务，这次没有保存。"
    case .cancelled:
      "已取消浏览器抓取。"
    }
  }

  /// 「页面打不开」和「链接本身有问题」是两件事：这里按平台真正给出的原因说清楚。
  private static func blockedMessage(for error: ManualLinkError, landing: String) -> String {
    switch error {
    case .shareLinkMissingToken:
      "小红书不让打开这条笔记（浏览器里落地到 \(landing)），这条链接多半缺了访问码。请回小红书 App 重新复制完整分享链接再试，或改用博主主页批量保存。"
    case .shareLinkExpired:
      "这条笔记在浏览器里也打不开（落地到 \(landing)），可能已删除或链接过期。请换一条链接。"
    case .loginRequired:
      "这条内容需要登录，浏览器里当前账号也看不到（落地到 \(landing)）。请先在该网站登录后再试。"
    case .verificationRequired:
      "页面要求人机验证，浏览器里也没有自动通过（落地到 \(landing)）。请在浏览器里通过验证后重试。"
    default:
      "浏览器打开这条链接后落地到 \(landing)，页面不是能保存的内容，这次没有保存。"
    }
  }

  /// 给 MCP / 诊断用的真实原因：页面打不开就沿用抓取错误码（如 shareLinkMissingToken），
  /// 调用方据此判断要不要换链接。
  public var underlyingCaptureError: ManualLinkError? {
    if case let .blocked(error, _) = self { return error }
    return nil
  }
}

/// 把「App 打开的那个地址」和「浏览器实际加载到的地址」认成同一条。
///
/// 短链会跳转（v.douyin.com、xhslink.com、b23.tv），抖音还会把地址换成带参数的详情页；
/// 扩展问过来的是标签地址，App 登记的是排队时的原始链接。只按字符串比会全部认不出。
public enum BrowserCaptureJobMatching {
  public static func matches(candidate: String, jobURL: String) -> Bool {
    guard let candidateURL = URL(string: candidate), let job = URL(string: jobURL) else { return false }
    if normalized(candidateURL) == normalized(job) { return true }
    if let left = try? CanonicalURL(candidate), let right = try? CanonicalURL(jobURL), left == right {
      return true
    }
    if let left = workKey(candidateURL), let right = workKey(job), left == right { return true }
    return false
  }

  /// scheme 小写、主机小写、去掉片段和结尾斜杠；查询参数保留（小红书访问码就在查询里）。
  static func normalized(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    var value = components.string ?? url.absoluteString
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  /// 平台作品标识。只用于同一篇内容的不同地址之间对号，不做抓取判断。
  static func workKey(_ url: URL) -> String? {
    let host = (url.host ?? "").lowercased()
    let parts = url.pathComponents.filter { $0 != "/" }
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
    func digits(_ value: String) -> Bool {
      !value.isEmpty && value.allSatisfy(\.isNumber)
    }
    if on("douyin.com") || on("iesdouyin.com") {
      if parts.count >= 2, ["video", "note"].contains(parts[0].lowercased()), digits(parts[1]) {
        return "douyin:\(parts[1])"
      }
      return nil
    }
    if on("xiaohongshu.com") {
      if parts.count >= 2, ["explore", "item", "discovery"].contains(parts[0].lowercased()) {
        let id = parts[0].lowercased() == "discovery" && parts.count >= 3 ? parts[2] : parts[1]
        return id.isEmpty ? nil : "xiaohongshu:\(id)"
      }
      return nil
    }
    if on("x.com") || on("twitter.com") {
      if parts.count == 3, parts[1].lowercased() == "status", digits(parts[2]) {
        return "x:\(parts[2])"
      }
      return nil
    }
    if on("bilibili.com") {
      if parts.count >= 2, parts[0].lowercased() == "video", parts[1].lowercased().hasPrefix("bv") {
        return "bilibili:\(parts[1].uppercased())"
      }
      return nil
    }
    return nil
  }
}

/// 扩展把内容送回来时，用顶层 `captureJobID` 说明「这是哪次代抓」。
///
/// 放在 envelope 顶层而不是 capture 里：v1/v2 的 `properties` 都允许未知字段，
/// 旧 App 会把它当普通抓取照常入库，新 App 则能认回排队项。
extension CaptureWireEnvelope {
  public static func captureJobID(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let jobID = object["captureJobID"] as? String,
          !jobID.isEmpty, jobID.count <= 64
    else { return nil }
    return jobID
  }
}

/// App 在代抓标签地址上加的固定片段。
///
/// 扩展靠它做两件事：只在带标记的标签上发 native message（用户正常浏览时零打扰），
/// 以及确认「这个标签是代抓开的」——失败/过期时可以安全关闭，绝不碰用户自己的标签。
/// 短链跳转不会丢掉片段（HTTP 重定向会继承原片段），所以跳转后的页面照样认得出。
public enum BrowserCaptureMarker {
  public static let fragmentToken = "jizuo-relay"

  public static func markedURL(_ url: String) -> String {
    guard let hashIndex = url.firstIndex(of: "#") else { return url + "#" + fragmentToken }
    if contains(url) { return url }
    return String(url[..<hashIndex]) + "#" + String(url[url.index(after: hashIndex)...]) + "&" + fragmentToken
  }

  public static func contains(_ url: String) -> Bool {
    guard let hashIndex = url.firstIndex(of: "#") else { return false }
    let parts = url[url.index(after: hashIndex)...].split(separator: "&")
    return parts.contains { $0 == fragmentToken }
  }

  /// 去掉标记；页面自己的锚点原样保留，没有片段了就连 `#` 一起去掉。
  public static func stripping(_ url: String) -> String {
    guard let hashIndex = url.firstIndex(of: "#") else { return url }
    let base = String(url[..<hashIndex])
    let parts = url[url.index(after: hashIndex)...].split(separator: "&").filter { $0 != fragmentToken }
    return parts.isEmpty ? base : base + "#" + parts.joined(separator: "&")
  }
}

/// 扩展在代抓标签上发现「平台自己说这页打不开」时，带着 job 回报一次。
///
/// 这条消息只为让 App 立刻以真实原因失败：小红书 404 / 登录页、抖音验证页之类，
/// 等到 90 秒超时再报「扩展没连上」既不准确，也让调用方错判成环境问题。
public struct BrowserCaptureJobOutcomeRequest: Sendable, Equatable {
  public enum Reason: String, Sendable, Codable, CaseIterable {
    case noteUnavailable = "note_unavailable"
    case loginRequired = "login_required"
    case verificationRequired = "verification_required"
    case notFound = "not_found"
    case unknown
  }

  public static let kind = "browserCaptureJobOutcome"
  public static let maximumURLLength = 4_096

  public let requestId: String
  public let jobID: String
  /// 页面最终落地的地址（含参数，只在 App 内分类用，日志只记 host+path）。
  public let finalURL: String
  public let reason: Reason

  public init(requestId: String, jobID: String, finalURL: String, reason: Reason) {
    self.requestId = requestId
    self.jobID = jobID
    self.finalURL = finalURL
    self.reason = reason
  }

  /// 返回 nil 表示「不是这类消息」；抛错表示是但不合法。
  public static func decode(_ data: Data) throws -> BrowserCaptureJobOutcomeRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String,
      kind == Self.kind
    else { return nil }
    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String, !requestId.isEmpty, requestId.count <= 128,
          let jobID = object["jobID"] as? String, !jobID.isEmpty, jobID.count <= 64,
          let finalURL = object["finalURL"] as? String,
          finalURL.count <= maximumURLLength,
          let parsed = URL(string: finalURL),
          ["http", "https"].contains(parsed.scheme?.lowercased()),
          let reason = Reason(rawValue: object["reason"] as? String ?? "")
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    return BrowserCaptureJobOutcomeRequest(
      requestId: requestId, jobID: jobID, finalURL: finalURL, reason: reason
    )
  }
}

/// 日志里只放 host+path：参数里可能是访问码、token 或搜索词。
public enum BrowserCaptureLanding {
  public static func describe(_ raw: String) -> String {
    guard let url = URL(string: raw), let host = url.host, !host.isEmpty else { return "unknown" }
    let path = url.path.isEmpty ? "/" : url.path
    return host.lowercased() + path
  }
}
