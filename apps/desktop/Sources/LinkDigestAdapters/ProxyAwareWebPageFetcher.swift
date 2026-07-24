import Foundation
import LinkDigestCore

/// Keeps the hardened numeric-peer transport as the default. Only a DNS answer
/// made entirely of fake-ip addresses is routed through the system-managed
/// HTTP(S) proxy/VPN path, where the original URL hostname remains intact.
public final class ProxyAwareWebPageFetcher: WebPageFetcher, SafeResourceFetching, @unchecked Sendable {
  private let policy: PublicWebURLPolicy
  private let direct: any WebPageFetcher
  private let proxy: any WebPageFetcher
  private let directResource: (any SafeResourceFetching)?
  private let proxyResource: (any SafeResourceFetching)?
  /// TUN/透明代理模式下没有系统 HTTP 代理可用，fake-IP 只能直连交给虚拟网卡。
  /// 这条传输独立于默认直连器，且只对 fake-IP 段开口。
  private let fakeIPDirectResource: (any SafeResourceFetching)?
  private let fakeIPDirect: (any WebPageFetcher)?
  private let shouldUseSystemProxy: @Sendable (URL) -> Bool

  public init(limits: URLSessionWebPageFetcher.Limits = .init()) {
    let resolver = SystemHostResolver()
    policy = .init(resolver: resolver.resolve)
    direct = PeerBoundNetworkWebPageFetcher(limits: limits)
    proxy = SystemProxyWebPageFetcher(policy: policy, limits: limits)
    let fakeIP = PeerBoundNetworkWebPageFetcher(limits: limits, allowsFakeIPPeers: true)
    fakeIPDirect = fakeIP
    fakeIPDirectResource = fakeIP
    directResource = direct as? any SafeResourceFetching
    proxyResource = proxy as? any SafeResourceFetching
    shouldUseSystemProxy = { SystemProxyConfiguration.currentHTTPSettings(for: $0) != nil }
  }

  #if DEBUG
  init(
    policy: PublicWebURLPolicy,
    direct: any WebPageFetcher,
    proxy: any WebPageFetcher,
    fakeIPDirect: (any WebPageFetcher)? = nil,
    shouldUseSystemProxy: @escaping @Sendable (URL) -> Bool = { _ in false }
  ) {
    self.policy = policy
    self.direct = direct
    self.proxy = proxy
    directResource = direct as? any SafeResourceFetching
    proxyResource = proxy as? any SafeResourceFetching
    self.fakeIPDirect = fakeIPDirect
    fakeIPDirectResource = fakeIPDirect as? any SafeResourceFetching
    self.shouldUseSystemProxy = shouldUseSystemProxy
  }
  #endif

  public func fetch(url: URL) async throws -> WebPageFetchResult {
    let decision = try policy.routingDecision(for: url)
    let usesProxy = decision == .systemProxyForFakeIP || shouldUseSystemProxy(url)
    guard !usesProxy || url.scheme?.lowercased() == "https" else {
      throw ManualLinkError.proxyHTTPSRequired
    }
    switch decision {
    case .direct:
      if shouldUseSystemProxy(url) {
        return try await proxy.fetch(url: url)
      }
      return try await direct.fetch(url: url)
    case .systemProxyForFakeIP:
      // 有系统代理就照旧走它；没有则说明是 TUN/透明代理模式——那里系统层根本
      // 不存在 HTTP 代理设置，硬等它只会静默失败，直连 fake-IP 交给虚拟网卡。
      if shouldUseSystemProxy(url) {
        return try await proxy.fetch(url: url)
      }
      guard let fakeIPDirect else { throw ManualLinkError.network }
      return try await fakeIPDirect.fetch(url: url)
    }
  }

  public func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    let decision = try policy.routingDecision(for: request.url)
    let usesProxy = decision == .systemProxyForFakeIP || shouldUseSystemProxy(request.url)
    guard !usesProxy || request.url.scheme?.lowercased() == "https" else {
      throw ManualLinkError.proxyHTTPSRequired
    }
    let resource: (any SafeResourceFetching)?
    switch decision {
    case .direct:
      resource = usesProxy ? proxyResource : directResource
    case .systemProxyForFakeIP:
      // 同 fetch(url:)：TUN 模式没有系统代理，fake-IP 直连才走得通。X 的图片
      // CDN 正是这种情况，此前一直静默下载失败、正文里的图全都不显示。
      resource = shouldUseSystemProxy(request.url) ? proxyResource : fakeIPDirectResource
    }
    guard let resource else { throw ManualLinkError.network }
    return try await resource.fetchResource(request)
  }
}
