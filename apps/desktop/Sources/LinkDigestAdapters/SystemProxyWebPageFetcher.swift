import CFNetwork
import Foundation
import LinkDigestCore
import Security

/// Fetches an original-hostname URL through URLSession's system proxy/VPN
/// machinery. HTTPS proxying uses CONNECT at the Foundation layer; this
/// delegate then independently pins trust evaluation to the original hostname.
public final class SystemProxyWebPageFetcher: WebPageFetcher, SafeResourceFetching, @unchecked Sendable {
  private let policy: PublicWebURLPolicy
  private let limits: URLSessionWebPageFetcher.Limits
  private let proxySettings: @Sendable (URL) -> [AnyHashable: Any]?
  private let trustAnchorsForTesting: [SecCertificate]

  public init(
    policy: PublicWebURLPolicy = .init(resolver: SystemHostResolver().resolve),
    limits: URLSessionWebPageFetcher.Limits = .init()
  ) {
    self.policy = policy
    self.limits = limits
    proxySettings = SystemProxyConfiguration.currentHTTPSettings
    trustAnchorsForTesting = []
  }

  #if DEBUG
  init(
    policy: PublicWebURLPolicy,
    limits: URLSessionWebPageFetcher.Limits = .init(),
    proxySettings: @escaping @Sendable (URL) -> [AnyHashable: Any]?,
    trustAnchorsForTesting: [SecCertificate] = []
  ) {
    self.policy = policy
    self.limits = limits
    self.proxySettings = proxySettings
    self.trustAnchorsForTesting = trustAnchorsForTesting
  }
  #endif

  public func fetch(url: URL) async throws -> WebPageFetchResult {
    let result = try await performFetch(url: url, headers: [:], byteLimit: limits.responseBytes, mode: .html)
    guard case let .html(page) = result else { throw ManualLinkError.network }
    return page
  }

  public func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    guard request.byteLimit > 0 else { throw ManualLinkError.responseTooLarge }
    let result = try await performFetch(url: request.url, headers: request.headers, byteLimit: request.byteLimit, mode: .resource, allowsRedirectTarget: request.allowsRedirectTarget)
    guard case let .resource(response) = result else { throw ManualLinkError.network }
    return response
  }

  private func performFetch(
    url: URL,
    headers: [String: String],
    byteLimit: Int,
    mode: SystemProxyFetchMode,
    allowsRedirectTarget: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) async throws -> SystemProxyFetchOutcome {
    guard url.scheme?.lowercased() == "https" else {
      throw ManualLinkError.proxyHTTPSRequired
    }
    _ = try policy.routingDecision(for: url)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    // Explicit HTTP(S) settings cause Foundation to establish a hostname-based
    // CONNECT tunnel. A nil dictionary intentionally leaves system VPN/network
    // extension routing intact for fake-ip environments that expose no classic
    // proxy dictionary.
    if let settings = proxySettings(url) {
      configuration.connectionProxyDictionary = settings
    }

    let delegate = SystemProxyFetchDelegate(
      policy: policy,
      limits: limits,
      trustAnchorsForTesting: trustAnchorsForTesting,
      mode: mode,
      byteLimit: byteLimit,
      allowsRedirectTarget: allowsRedirectTarget
    )
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.timeoutInterval = limits.timeout
    request.httpShouldHandleCookies = false
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    do {
      return try await delegate.start(session: session, request: request)
    } catch let error as ManualLinkError {
      throw error
    } catch {
      throw ManualLinkError.fakeIPProxyUnavailable
    }
  }
}

private enum SystemProxyFetchMode { case html, resource }
private enum SystemProxyFetchOutcome { case html(WebPageFetchResult), resource(SafeResourceResponse) }

enum SystemProxyConfiguration {
  static func currentHTTPSettings(for url: URL) -> [AnyHashable: Any]? {
    guard let unmanaged = CFNetworkCopySystemProxySettings() else { return nil }
    let settings = unmanaged.takeRetainedValue()
    let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as NSArray
    let hasHTTPProxy = proxies.compactMap { $0 as? [AnyHashable: Any] }.contains { entry in
      guard let type = entry[kCFProxyTypeKey] as? String else { return false }
      return type == (kCFProxyTypeHTTP as String)
        || type == (kCFProxyTypeHTTPS as String)
    }
    return hasHTTPProxy ? settings as NSDictionary as? [AnyHashable: Any] : nil
  }
}

private final class SystemProxyFetchDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
  private let policy: PublicWebURLPolicy
  private let limits: URLSessionWebPageFetcher.Limits
  private let trustAnchorsForTesting: [SecCertificate]
  private let mode: SystemProxyFetchMode
  private let byteLimit: Int
  private let allowsRedirectTarget: @Sendable (URL) -> Bool
  private var data = Data()
  private var redirects = 0
  private var continuation: CheckedContinuation<SystemProxyFetchOutcome, Error>?
  private var activeTask: URLSessionDataTask?
  private var finished = false

  init(
    policy: PublicWebURLPolicy,
    limits: URLSessionWebPageFetcher.Limits,
    trustAnchorsForTesting: [SecCertificate],
    mode: SystemProxyFetchMode,
    byteLimit: Int,
    allowsRedirectTarget: @escaping @Sendable (URL) -> Bool
  ) {
    self.policy = policy
    self.limits = limits
    self.trustAnchorsForTesting = trustAnchorsForTesting
    self.mode = mode
    self.byteLimit = byteLimit
    self.allowsRedirectTarget = allowsRedirectTarget
  }

  func start(session: URLSession, request: URLRequest) async throws -> SystemProxyFetchOutcome {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let task = session.dataTask(with: request)
        activeTask = task
        task.resume()
      }
    } onCancel: { self.activeTask?.cancel() }
  }

  func urlSession(
    _: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    redirects += 1
    guard redirects <= limits.redirects,
          let source = response.url,
          let target = request.url
    else {
      finish(.failure(ManualLinkError.responseStatus))
      completionHandler(nil)
      return
    }
    do {
      try PeerBoundNetworkWebPageFetcher.validateRedirect(from: source, to: target)
      guard allowsRedirectTarget(target) else { throw ManualLinkError.unsafeURL }
      _ = try policy.routingDecision(for: target)
      completionHandler(request)
    } catch {
      finish(.failure(ManualLinkError.unsafeURL))
      completionHandler(nil)
    }
  }

  func urlSession(
    _: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust,
          let expectedHost = task.currentRequest?.url?.host.flatMap(PublicWebURLPolicy.normalizedHost),
          PublicWebURLPolicy.normalizedHost(challenge.protectionSpace.host) == expectedHost
    else {
      // The app neither reads nor supplies proxy credentials. Default handling
      // can wait indefinitely for interactive credential resolution, so fail
      // explicitly and leave authentication to the user's system proxy.
      if challenge.protectionSpace.isProxy() {
        finish(.failure(ManualLinkError.proxyAuthenticationRequired))
        completionHandler(.cancelAuthenticationChallenge, nil)
      } else {
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
      return
    }
    guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString)) == errSecSuccess,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
          (trustAnchorsForTesting.isEmpty || SecTrustSetAnchorCertificates(trust, trustAnchorsForTesting as CFArray) == errSecSuccess),
          (trustAnchorsForTesting.isEmpty || SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess),
          SecTrustEvaluateWithError(trust, nil)
    else {
      finish(.failure(ManualLinkError.proxyTLSValidation))
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _: URLSession,
    dataTask _: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      finish(.failure(ManualLinkError.responseStatus)); completionHandler(.cancel); return
    }
    do {
      switch mode {
      case .html:
        try PublicHTMLResponsePolicy.validate(
          statusCode: http.statusCode,
          contentType: http.value(forHTTPHeaderField: "Content-Type"),
          expectedLength: response.expectedContentLength < 0 ? nil : response.expectedContentLength,
          byteLimit: byteLimit
        )
      case .resource:
        if response.expectedContentLength > Int64(byteLimit) {
          throw ManualLinkError.responseTooLarge
        }
      }
      completionHandler(.allow)
    } catch let error as ManualLinkError {
      finish(.failure(error)); completionHandler(.cancel)
    } catch {
      finish(.failure(ManualLinkError.network)); completionHandler(.cancel)
    }
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive chunk: Data) {
    guard !finished else { return }
    data.append(chunk)
    if data.count > byteLimit {
      activeTask?.cancel()
      finish(.failure(ManualLinkError.responseTooLarge))
    }
  }

  func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard !finished else { return }
    activeTask = nil
    if let error {
      let ns = error as NSError
      if ns.code == NSURLErrorTimedOut { finish(.failure(ManualLinkError.timedOut)) }
      else if ns.code == NSURLErrorCancelled { finish(.failure(ManualLinkError.cancelled)) }
      else { finish(.failure(ManualLinkError.fakeIPProxyUnavailable)) }
      return
    }
    guard let url = task.currentRequest?.url,
          let response = task.response as? HTTPURLResponse,
          let contentType = response.value(forHTTPHeaderField: "Content-Type")
    else { finish(.failure(ManualLinkError.network)); return }
    switch mode {
    case .html:
      let html = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
        ?? ""
      finish(.success(.html(.init(url: url, html: html, contentType: contentType))))
    case .resource:
      finish(.success(.resource(.init(url: url, statusCode: response.statusCode, contentType: contentType, body: data))))
    }
  }

  private func finish(_ result: Result<SystemProxyFetchOutcome, Error>) {
    guard !finished else { return }
    finished = true
    activeTask = nil
    let continuation = continuation
    self.continuation = nil
    switch result {
    case let .success(value): continuation?.resume(returning: value)
    case let .failure(error): continuation?.resume(throwing: error)
    }
  }
}
