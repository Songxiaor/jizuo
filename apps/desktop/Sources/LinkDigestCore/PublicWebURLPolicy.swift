import Darwin
import Foundation

/// Validates both a URL and the numeric addresses that its resolver or
/// transport observed. DNS answers are only an admission check; transports
/// must call `validatePeerAddress` for the address they actually connected to.
public struct PublicWebURLPolicy: Sendable {
  public typealias Resolver = @Sendable (String) throws -> [String]
  /// 解析一律走异步：同步 `getaddrinfo` 在 async 上下文里会占住协作线程池，
  /// 也不响应取消。用同步闭包构造时会自动搬到普通队列上并加超时。
  private let resolve: AsyncHostResolver
  /// TUN/透明代理把域名解析成 fake-IP（198.18.0.0/15），流量由虚拟网卡接管，
  /// 系统层面并不存在可用的 HTTP 代理设置。只有这类传输才开这道口子：直连
  /// fake-IP 就是交给虚拟网卡。私有、回环、链路本地与文档/测试网段一律照拒。
  private let allowsFakeIPPeers: Bool
  #if DEBUG
  private let allowLoopbackForTesting: Bool
  #endif

  public init(resolver: @escaping Resolver, allowsFakeIPPeers: Bool = false) {
    self.init(asyncResolver: HostResolution.offloaded(resolver), allowsFakeIPPeers: allowsFakeIPPeers)
  }

  public init(asyncResolver: @escaping AsyncHostResolver, allowsFakeIPPeers: Bool = false) {
    resolve = asyncResolver
    self.allowsFakeIPPeers = allowsFakeIPPeers
    #if DEBUG
    allowLoopbackForTesting = false
    #endif
  }

  public enum RoutingDecision: Sendable, Equatable {
    case direct
    case systemProxyForFakeIP
  }

  /// 一次解析的完整结果：规范化后的 host、解析到的地址、以及路由判定。
  ///
  /// 存在的理由只有一个：同一次抓取里，路由判定和"连到哪个对端"必须来自
  /// **同一份**地址答案，调用方也就不必为了拿对端再解析一遍。
  public struct Admission: Sendable {
    public let host: String
    public let addresses: [String]
    public let decision: RoutingDecision
  }

  /// Classifies a syntactically safe public URL without weakening the direct
  /// peer policy. Fake-IP answers are admitted only as a distinct proxy route;
  /// private, loopback, link-local and documentation/test-net answers remain
  /// rejected.
  public func routingDecision(for url: URL) async throws -> RoutingDecision {
    try await admission(for: url).decision
  }

  /// 解析一次并给出判定。判定逻辑与原 `routingDecision` 逐字相同。
  public func admission(for url: URL) async throws -> Admission {
    let host = try validatedHost(for: url)
    let addresses = Self.isNumericAddress(host) ? [host] : try await resolve(host)
    guard !addresses.isEmpty else { throw ManualLinkError.unsafeURL }
    return Admission(host: host, addresses: addresses, decision: try decision(host: host, addresses: addresses))
  }

  private func decision(host: String, addresses: [String]) throws -> RoutingDecision {
    if addresses.allSatisfy({ isGloballyRoutable($0) }) { return .direct }
    #if DEBUG
    if allowLoopbackForTesting, addresses.allSatisfy({ isLoopback($0) }) { return .direct }
    #endif
    if !Self.isNumericAddress(host), addresses.allSatisfy(Self.isFakeIPAddress) {
      return .systemProxyForFakeIP
    }
    throw ManualLinkError.unsafeURL
  }

  #if DEBUG
  public init(
    resolver: @escaping Resolver,
    allowLoopbackForTesting: Bool,
    allowsFakeIPPeers: Bool = false,
    resolverTimeoutSeconds: TimeInterval = HostResolution.defaultTimeoutSeconds
  ) {
    self.init(
      asyncResolver: HostResolution.offloaded(resolver, timeoutSeconds: resolverTimeoutSeconds),
      allowLoopbackForTesting: allowLoopbackForTesting,
      allowsFakeIPPeers: allowsFakeIPPeers
    )
  }

  public init(asyncResolver: @escaping AsyncHostResolver, allowLoopbackForTesting: Bool, allowsFakeIPPeers: Bool = false) {
    resolve = asyncResolver
    self.allowLoopbackForTesting = allowLoopbackForTesting
    self.allowsFakeIPPeers = allowsFakeIPPeers
  }
  #endif

  public func validate(_ url: URL) async throws {
    _ = try await validatedAdmission(for: url)
  }

  /// `validate` 的可取值版本：门禁语义完全一致，只是把那次解析的结果交回去，
  /// 让调用方直接用它绑定对端，而不是再解析一次。
  @discardableResult
  public func validatedAdmission(for url: URL) async throws -> Admission {
    let admission = try await admission(for: url)
    switch admission.decision {
    case .direct:
      return admission
    case .systemProxyForFakeIP:
      guard allowsFakeIPPeers else { throw ManualLinkError.unsafeURL }
      return admission
    }
  }

  /// UI-only link activation performs the same scheme, credential, host and
  /// port admission as a fetch, but intentionally does not resolve or contact
  /// the destination. The default browser owns the later navigation.
  public func validateSyntax(_ url: URL) throws {
    _ = try validatedHost(for: url)
  }

  private func validatedHost(for url: URL) throws -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          components.user == nil, components.password == nil,
          let rawHost = components.host?.lowercased(),
          let host = Self.normalizedHost(rawHost), !host.isEmpty,
          (scheme == "http" && (components.port == nil || components.port == 80)) ||
            (scheme == "https" && (components.port == nil || components.port == 443)),
          host != "localhost", host != "localhost."
    else { throw ManualLinkError.unsafeURL }
    return host
  }

  public func validatePeerAddress(_ raw: String) throws {
    #if DEBUG
    let isAllowed = isGloballyRoutable(raw)
      || (allowLoopbackForTesting && isLoopback(raw))
      || (allowsFakeIPPeers && Self.isFakeIPAddress(raw))
    #else
    let isAllowed = isGloballyRoutable(raw) || (allowsFakeIPPeers && Self.isFakeIPAddress(raw))
    #endif
    guard isAllowed else {
      throw ManualLinkError.unsafeURL
    }
  }

  /// Normalizes Foundation's bracketed IPv6 URL host representation. A bracketed
  /// value is accepted only when its inner value is a valid IPv6 literal; DNS
  /// names and malformed brackets must never reach a resolver.
  public static func normalizedHost(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    guard raw.contains("[") || raw.contains("]") else { return raw }
    guard raw.first == "[", raw.last == "]" else { return nil }
    let literal = String(raw.dropFirst().dropLast())
    guard isIPv6Address(literal) else { return nil }
    return literal
  }

  public static func isFakeIPAddress(_ raw: String) -> Bool {
    var v4 = in_addr()
    guard raw.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 else { return false }
    let bytes = withUnsafeBytes(of: v4) { Array($0) }
    return bytes.count == 4 && bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
  }

  private static func isNumericAddress(_ value: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return value.withCString { inet_pton(AF_INET, $0, &v4) } == 1 ||
      value.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
  }

  private static func isIPv6Address(_ value: String) -> Bool {
    var address = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
  }

  private func isGloballyRoutable(_ raw: String) -> Bool {
    var v4 = in_addr()
    if raw.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
      return isGloballyRoutableIPv4(bytes(of: v4))
    }
    var v6 = in6_addr()
    guard raw.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
    let bytes = bytes(of: v6)
    // IPv4-mapped IPv6 has the same security meaning as its embedded IPv4.
    if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
      return isGloballyRoutableIPv4(Array(bytes.suffix(4)))
    }
    // Only global-unicast 2000::/3. Reject special-purpose ranges within it,
    // then reject unspecified, loopback, ULA, link-local and multicast below.
    guard bytes[0] & 0xe0 == 0x20 else { return false }
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] & 0xfe == 0 { return false } // 2001::/23
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false } // 2001:db8::/32
    if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // 2002::/16
    if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] & 0xf0 == 0 { return false } // 3fff::/20
    return true
  }

  private func isLoopback(_ raw: String) -> Bool {
    var v4 = in_addr()
    if raw.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return bytes(of: v4).first == 127 }
    var v6 = in6_addr()
    guard raw.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
    let bytes = bytes(of: v6)
    if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
    return bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
  }

  private func isGloballyRoutableIPv4(_ b: [UInt8]) -> Bool {
    guard b.count == 4 else { return false }
    let a = b[0], second = b[1], third = b[2]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (64...127).contains(second) { return false }
    if a == 169 && second == 254 { return false }
    if a == 172 && (16...31).contains(second) { return false }
    if a == 192 && (second == 0 || second == 2 || second == 88 && third == 99 || second == 168) { return false }
    if a == 198 && ((18...19).contains(second) || second == 51) { return false }
    if a == 203 && second == 0 && third == 113 { return false }
    return true
  }

  private func bytes<T>(of value: T) -> [UInt8] { withUnsafeBytes(of: value) { Array($0) } }
}
