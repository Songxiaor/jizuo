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
  private let shouldUseSystemProxy: @Sendable (URL) -> Bool

  public init(limits: URLSessionWebPageFetcher.Limits = .init()) {
    let resolver = SystemHostResolver()
    policy = .init(resolver: resolver.resolve)
    direct = PeerBoundNetworkWebPageFetcher(limits: limits)
    proxy = SystemProxyWebPageFetcher(policy: policy, limits: limits)
    directResource = direct as? any SafeResourceFetching
    proxyResource = proxy as? any SafeResourceFetching
    shouldUseSystemProxy = { SystemProxyConfiguration.currentHTTPSettings(for: $0) != nil }
  }

  #if DEBUG
  init(
    policy: PublicWebURLPolicy,
    direct: any WebPageFetcher,
    proxy: any WebPageFetcher,
    shouldUseSystemProxy: @escaping @Sendable (URL) -> Bool = { _ in false }
  ) {
    self.policy = policy
    self.direct = direct
    self.proxy = proxy
    directResource = direct as? any SafeResourceFetching
    proxyResource = proxy as? any SafeResourceFetching
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
      return try await proxy.fetch(url: url)
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
      resource = proxyResource
    }
    guard let resource else { throw ManualLinkError.network }
    return try await resource.fetchResource(request)
  }
}
