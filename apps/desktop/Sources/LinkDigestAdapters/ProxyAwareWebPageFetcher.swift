import Foundation
import LinkDigestCore

/// Keeps the hardened numeric-peer transport as the default. A DNS answer made
/// entirely of fake-ip addresses is first routed through the system-managed
/// hostname transport, where Network Extensions/TUN can preserve the original
/// URL hostname. Numeric fake-IP direct remains a compatibility fallback.
public final class ProxyAwareWebPageFetcher: WebPageFetcher, SafeResourceFetching, @unchecked Sendable {
  private let policy: PublicWebURLPolicy
  private let direct: any WebPageFetcher
  private let proxy: any WebPageFetcher
  private let directResource: (any SafeResourceFetching)?
  private let proxyResource: (any SafeResourceFetching)?
  /// Compatibility fallback for environments whose TUN accepts an explicitly
  /// bound fake-IP peer. It stays limited to the fake-IP range.
  private let fakeIPDirectResource: (any SafeResourceFetching)?
  private let fakeIPDirect: (any WebPageFetcher)?
  private let shouldUseSystemProxy: @Sendable (URL) -> Bool

  public init(limits: URLSessionWebPageFetcher.Limits = .init()) {
    // 一次抓取里，路由判定、传输层绑定对端、重定向每一跳原本各查一次 DNS。
    // 这里让三条路共用同一个带缓存的异步解析器：同一个 host 只解析一次，
    // 重定向换了 host 才会再解析一次。判定逻辑一个字没改。
    let resolver = HostResolutionCache(base: SystemHostResolver.asyncResolver()).resolver
    policy = .init(asyncResolver: resolver)
    direct = PeerBoundNetworkWebPageFetcher(asyncResolver: resolver, limits: limits)
    proxy = SystemProxyWebPageFetcher(policy: policy, limits: limits)
    let fakeIP = PeerBoundNetworkWebPageFetcher(asyncResolver: resolver, limits: limits, allowsFakeIPPeers: true)
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
    AppLog.info(.capture, "webpage_fetch_started", ["host": AppLog.host(url), "via": "proxy_aware"])
    do {
      let result = try await fetchBody(url: url)
      AppLog.info(.capture, "webpage_fetch_succeeded", ["host": AppLog.host(result.url), "via": "proxy_aware"])
      return result
    } catch {
      AppLog.error(.capture, "webpage_fetch_failed", code: "FETCH_FAILED", ["host": AppLog.host(url), "via": "proxy_aware"])
      throw error
    }
  }

  private func fetchBody(url: URL) async throws -> WebPageFetchResult {
    let decision = try await policy.routingDecision(for: url)
    // 系统代理设置每次抓取只查一次：`CFNetworkCopySystemProxySettings` 会读
    // 系统配置，原来同一条路径上要查两三遍。
    let hasSystemProxy = shouldUseSystemProxy(url)
    let usesProxy = decision == .systemProxyForFakeIP || hasSystemProxy
    guard !usesProxy || url.scheme?.lowercased() == "https" else {
      throw ManualLinkError.proxyHTTPSRequired
    }
    switch decision {
    case .direct:
      if hasSystemProxy {
        return try await proxy.fetch(url: url)
      }
      return try await direct.fetch(url: url)
    case .systemProxyForFakeIP:
      if hasSystemProxy {
        return try await proxy.fetch(url: url)
      }
      // Some TUN products expose no classic HTTP proxy dictionary but still
      // require a hostname-based URLSession request. Try that system-managed
      // route first; only then fall back to an explicitly bound fake-IP peer.
      do {
        return try await proxy.fetch(url: url)
      } catch {
        guard let fakeIPDirect else { throw error }
        return try await fakeIPDirect.fetch(url: url)
      }
    }
  }

  public func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    let decision = try await policy.routingDecision(for: request.url)
    let hasSystemProxy = shouldUseSystemProxy(request.url)
    let usesProxy = decision == .systemProxyForFakeIP || hasSystemProxy
    guard !usesProxy || request.url.scheme?.lowercased() == "https" else {
      throw ManualLinkError.proxyHTTPSRequired
    }
    let resource: (any SafeResourceFetching)?
    switch decision {
    case .direct:
      resource = usesProxy ? proxyResource : directResource
    case .systemProxyForFakeIP:
      if hasSystemProxy {
        resource = proxyResource
      } else if let proxyResource {
        do {
          return try await proxyResource.fetchResource(request)
        } catch {
          guard let fakeIPDirectResource else { throw error }
          return try await fakeIPDirectResource.fetchResource(request)
        }
      } else {
        resource = fakeIPDirectResource
      }
    }
    guard let resource else { throw ManualLinkError.network }
    return try await resource.fetchResource(request)
  }
}
