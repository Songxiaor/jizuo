import Foundation
import Darwin
import LinkDigestCore

public struct SystemHostResolver: Sendable {
  public init() {}
  public func resolve(_ host: String) throws -> [String] {
    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var pointer: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &pointer) == 0, let first = pointer else { throw ManualLinkError.unsafeURL }
    defer { freeaddrinfo(first) }
    var results: [String] = []
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let entry = current {
      var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
        results.append(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      current = entry.pointee.ai_next
    }
    return results
  }
}

public final class URLSessionWebPageFetcher: NSObject, WebPageFetcher, @unchecked Sendable {
  /// A transport-owned observation of the connected peer. `URLSession` does
  /// not expose this itself, so production must supply a peer-bound transport;
  /// the default deliberately fails closed instead of trusting a prior DNS
  /// lookup and re-resolving during connection.
  public typealias PeerAddressProvider = @Sendable (URL) async throws -> String
  public struct Limits: Sendable { public let redirects: Int; public let responseBytes: Int; public let timeout: TimeInterval; public init(redirects: Int = 4, responseBytes: Int = 2_000_000, timeout: TimeInterval = 20) { self.redirects = redirects; self.responseBytes = responseBytes; self.timeout = timeout } }
  private let policy: PublicWebURLPolicy
  private let limits: Limits
  private let peerAddressProvider: PeerAddressProvider

  public init(
    policy: PublicWebURLPolicy = .init(resolver: SystemHostResolver().resolve),
    limits: Limits = .init(),
    peerAddressProvider: @escaping PeerAddressProvider = { _ in throw ManualLinkError.unsafeURL }
  ) {
    self.policy = policy; self.limits = limits; self.peerAddressProvider = peerAddressProvider
  }

  public func fetch(url: URL) async throws -> WebPageFetchResult {
    try policy.validate(url)
    // Do not start URLSession unless a lower-level transport has supplied the
    // numeric peer it will use. This prevents DNS rebind TOCTOU. Until a
    // peer-bound Network/BSD transport is installed, production fails closed.
    try policy.validatePeerAddress(await peerAddressProvider(url))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml"]
    let delegate = FetchDelegate(policy: policy, limits: limits)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.timeoutInterval = limits.timeout
    request.httpShouldHandleCookies = false
    return try await delegate.start(session: session, request: request)
  }
}

private final class FetchDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
  private let policy: PublicWebURLPolicy
  private let limits: URLSessionWebPageFetcher.Limits
  private var data = Data(), redirects = 0
  private var continuation: CheckedContinuation<WebPageFetchResult, Error>?
  private var finished = false
  init(policy: PublicWebURLPolicy, limits: URLSessionWebPageFetcher.Limits) { self.policy = policy; self.limits = limits }

  func start(session: URLSession, request: URLRequest) async throws -> WebPageFetchResult {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let task = session.dataTask(with: request)
        self.activeTask = task
        task.resume()
      }
    } onCancel: {
      self.activeTask?.cancel()
    }
  }

  private var activeTask: URLSessionDataTask?

  func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    redirects += 1
    guard redirects <= limits.redirects, let url = request.url else { finish(.failure(ManualLinkError.responseStatus)); completionHandler(nil); return }
    do { try policy.validate(url); completionHandler(request) }
    catch { finish(.failure(ManualLinkError.unsafeURL)); completionHandler(nil) }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // This fetcher never consults shared credentials. TLS server trust keeps
    // URLSession's normal hostname/certificate validation; every other
    // challenge fails closed rather than asking the system credential store.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse else { finish(.failure(ManualLinkError.responseStatus)); completionHandler(.cancel); return }
    do {
      try PublicHTMLResponsePolicy.validate(statusCode: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), expectedLength: response.expectedContentLength < 0 ? nil : response.expectedContentLength, byteLimit: limits.responseBytes)
      completionHandler(.allow)
    } catch let error as ManualLinkError {
      finish(.failure(error)); completionHandler(.cancel)
    } catch {
      finish(.failure(ManualLinkError.network)); completionHandler(.cancel)
    }
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
    guard !finished else { return }
    self.data.append(data)
    if self.data.count > limits.responseBytes {
      activeTask?.cancel()
      finish(.failure(ManualLinkError.responseTooLarge))
    }
  }

  func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard !finished else { return }
    activeTask = nil
    if let error {
      let ns = error as NSError
      finish(.failure(ns.code == NSURLErrorTimedOut ? ManualLinkError.timedOut : (ns.code == NSURLErrorCancelled ? ManualLinkError.cancelled : ManualLinkError.network)))
      return
    }
    guard let url = task.currentRequest?.url,
          let response = task.response as? HTTPURLResponse,
          let contentType = response.value(forHTTPHeaderField: "Content-Type")
    else { finish(.failure(ManualLinkError.network)); return }
    let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    finish(.success(.init(url: url, html: html, contentType: contentType)))
  }

  private func finish(_ result: Result<WebPageFetchResult, Error>) {
    guard !finished else { return }; finished = true
    activeTask = nil
    let continuation = continuation; self.continuation = nil
    switch result { case let .success(value): continuation?.resume(returning: value); case let .failure(error): continuation?.resume(throwing: error) }
  }
}
