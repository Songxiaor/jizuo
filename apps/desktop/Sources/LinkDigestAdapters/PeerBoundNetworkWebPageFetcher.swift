import Foundation
import Network
import Security
import LinkDigestCore

/// Minimal HTTP/1.1 transport whose TCP endpoint is an already policy-checked
/// numeric address. The original hostname remains TLS SNI/certificate name and
/// HTTP Host, so binding the IP does not weaken HTTPS validation.
public final class PeerBoundNetworkWebPageFetcher: WebPageFetcher, SafeResourceFetching, @unchecked Sendable {
  private let resolvePeer: PublicWebURLPolicy.Resolver
  private let policy: PublicWebURLPolicy
  private let limits: URLSessionWebPageFetcher.Limits
  #if DEBUG
  // This is intentionally internal-only: production always connects on the
  // scheme's standard port, while controlled transport tests use one local
  // ephemeral listener without allowing non-standard public URLs.
  private let portForTesting: UInt16?
  // Production intentionally leaves this nil, which preserves the system
  // trust store. Controlled TLS tests may supply a short-lived local anchor.
  private let trustAnchorsForTesting: [SecCertificate]?
  // Test-only fixed event markers. Production uses the no-op sink below, so
  // transport state never becomes a runtime log or data output.
  private let eventSinkForTesting: @Sendable (String) -> Void
  #endif

  public init(limits: URLSessionWebPageFetcher.Limits = .init()) {
    let resolver = SystemHostResolver()
    resolvePeer = resolver.resolve
    policy = .init(resolver: resolver.resolve)
    self.limits = limits
    #if DEBUG
    portForTesting = nil
    trustAnchorsForTesting = nil
    eventSinkForTesting = { _ in }
    #endif
  }

  #if DEBUG
  init(
    resolver: @escaping PublicWebURLPolicy.Resolver,
    allowLoopbackForTesting: Bool,
    limits: URLSessionWebPageFetcher.Limits,
    portForTesting: UInt16,
    trustAnchorsForTesting: [SecCertificate]? = nil,
    eventSinkForTesting: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    resolvePeer = resolver
    self.policy = .init(resolver: resolver, allowLoopbackForTesting: allowLoopbackForTesting)
    self.limits = limits
    self.portForTesting = portForTesting
    self.trustAnchorsForTesting = trustAnchorsForTesting
    self.eventSinkForTesting = eventSinkForTesting
  }
  #endif

  public func fetch(url: URL) async throws -> WebPageFetchResult {
    var current = url
    for redirect in 0...limits.redirects {
      try policy.validate(current)
      guard let rawHost = current.host,
            let host = PublicWebURLPolicy.normalizedHost(rawHost),
            let scheme = current.scheme?.lowercased()
      else { throw ManualLinkError.unsafeURL }
      let peers = try resolvePeer(host)
      guard let peer = peers.first else { throw ManualLinkError.unsafeURL }
      try policy.validatePeerAddress(peer)
      let result = try await fetchOnce(url: current, host: host, peer: peer, scheme: scheme)
      if Self.isFollowableRedirectStatus(result.status), let target = redirectTarget(result.headers, relativeTo: current) {
        guard redirect < limits.redirects else { throw ManualLinkError.responseStatus }
        try Self.validateRedirect(from: current, to: target)
        current = target; continue
      }
      try PublicHTMLResponsePolicy.validate(statusCode: result.status, contentType: result.headers["content-type"], expectedLength: result.contentLength, byteLimit: limits.responseBytes)
      return .init(url: current, html: String(data: result.body, encoding: .utf8) ?? String(data: result.body, encoding: .isoLatin1) ?? "", contentType: result.headers["content-type"] ?? "")
    }
    throw ManualLinkError.responseStatus
  }

  public func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    guard request.byteLimit > 0 else { throw ManualLinkError.responseTooLarge }
    var current = request.url
    for redirect in 0...limits.redirects {
      try policy.validate(current)
      guard let rawHost = current.host,
            let host = PublicWebURLPolicy.normalizedHost(rawHost),
            let scheme = current.scheme?.lowercased()
      else { throw ManualLinkError.unsafeURL }
      let peers = try resolvePeer(host)
      guard let peer = peers.first else { throw ManualLinkError.unsafeURL }
      try policy.validatePeerAddress(peer)
      let result = try await fetchOnce(
        url: current, host: host, peer: peer, scheme: scheme,
        headers: request.headers, byteLimit: request.byteLimit
      )
      if Self.isFollowableRedirectStatus(result.status), let target = redirectTarget(result.headers, relativeTo: current) {
        guard redirect < limits.redirects else { throw ManualLinkError.responseStatus }
        guard request.allowsRedirectTarget(target) else { throw ManualLinkError.unsafeURL }
        try Self.validateRedirect(from: current, to: target)
        current = target
        continue
      }
      return .init(url: current, statusCode: result.status, contentType: result.headers["content-type"], body: result.body)
    }
    throw ManualLinkError.responseStatus
  }

  private func fetchOnce(
    url: URL,
    host: String,
    peer: String,
    scheme: String,
    headers: [String: String] = [:],
    byteLimit: Int? = nil
  ) async throws -> Response {
    try await withThrowingTaskGroup(of: Response.self) { group in
      group.addTask { try await self.fetchOnceBound(url: url, host: host, peer: peer, scheme: scheme, headers: headers, byteLimit: byteLimit ?? self.limits.responseBytes) }
      group.addTask {
        try await Task.sleep(for: .seconds(self.limits.timeout))
        throw ManualLinkError.timedOut
      }
      guard let value = try await group.next() else { throw ManualLinkError.network }
      group.cancelAll()
      return value
    }
  }

  private func fetchOnceBound(url: URL, host: String, peer: String, scheme: String, headers: [String: String], byteLimit: Int) async throws -> Response {
    #if DEBUG
    let port = portForTesting ?? (scheme == "https" ? 443 : 80)
    #else
    let port: UInt16 = scheme == "https" ? 443 : 80
    #endif
    let parameters: NWParameters
    if scheme == "https" {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
      configureTLSVerification(tls, expectedHost: host)
      parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    } else { parameters = .tcp }
    let connection = NWConnection(host: NWEndpoint.Host(peer), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    let lifecycle = ConnectionLifecycle(cancel: { connection.cancel() })
    defer { lifecycle.cancelOnce() }
    return try await withTaskCancellationHandler {
      try await ready(connection)
    let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
    let request = try Self.requestBytes(path: path, host: host, headers: headers)
      try await send(request, on: connection)
      var all = Data()
      while true {
        let chunk = try await receive(on: connection)
        all.append(chunk.data)
        guard all.count <= byteLimit + 64 * 1024 else { lifecycle.cancelOnce(); throw ManualLinkError.responseTooLarge }
        if chunk.complete { break }
      }
      return try Response(raw: all, bodyLimit: byteLimit)
    } onCancel: { lifecycle.cancelOnce() }
  }

  private static func requestBytes(path: String, host: String, headers: [String: String]) throws -> Data {
    let validName = "^[A-Za-z0-9-]+$"
    var lines = ["GET \(path) HTTP/1.1", "Host: \(host)", "Connection: close", "User-Agent: LinkDigest/0.1"]
    var merged = ["Accept": "text/html,application/xhtml+xml"]
    for (name, value) in headers { merged[name] = value }
    for name in merged.keys.sorted() {
      guard name.range(of: validName, options: .regularExpression) != nil,
            let value = merged[name], !value.contains("\r"), !value.contains("\n")
      else { throw ManualLinkError.network }
      lines.append("\(name): \(value)")
    }
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
  }

  private func configureTLSVerification(_ tls: NWProtocolTLS.Options, expectedHost: String) {
    #if DEBUG
    let anchors = trustAnchorsForTesting
    let eventSink = eventSinkForTesting
    #endif
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
      #if DEBUG
      eventSink("verify-enter")
      #endif
      let systemTrust = sec_trust_copy_ref(trust).takeRetainedValue()
      guard SecTrustSetPolicies(systemTrust, SecPolicyCreateSSL(true, expectedHost as CFString)) == errSecSuccess else {
        #if DEBUG
        eventSink("verify-policy-failed")
        eventSink("verify-false")
        #endif
        complete(false)
        return
      }
      // The TCP peer has already been policy-checked. Do not let trust
      // evaluation fetch AIA/intermediate certificates over an unbound path.
      guard SecTrustSetNetworkFetchAllowed(systemTrust, false) == errSecSuccess else {
        #if DEBUG
        eventSink("verify-network-fetch-policy-failed")
        eventSink("verify-false")
        #endif
        complete(false)
        return
      }
      #if DEBUG
      if let anchors {
        guard SecTrustSetAnchorCertificates(systemTrust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(systemTrust, true) == errSecSuccess else {
          eventSink("verify-anchor-failed")
          eventSink("verify-false")
          complete(false)
          return
        }
      }
      #endif
      let trusted = SecTrustEvaluateWithError(systemTrust, nil)
      #if DEBUG
      eventSink(trusted ? "verify-true" : "verify-false")
      #endif
      complete(trusted)
    }, .global())
  }

  private func ready(_ connection: NWConnection) async throws {
    let gate = ConnectionLifecycle(cancel: { connection.cancel() })
    #if DEBUG
    let eventSink = eventSinkForTesting
    #endif
    try await withCheckedThrowingContinuation { continuation in
      connection.stateUpdateHandler = { state in
        switch state {
        case .preparing:
          #if DEBUG
          eventSink("connection-preparing")
          #endif
        case .ready:
          #if DEBUG
          eventSink("connection-ready")
          #endif
          guard gate.finishOnce() else { return }; continuation.resume()
        case .failed:
          #if DEBUG
          eventSink("connection-failed")
          #endif
          guard gate.finishOnce() else { return }; continuation.resume(throwing: ManualLinkError.network)
        case .waiting:
          #if DEBUG
          eventSink("connection-waiting")
          #endif
          guard gate.finishOnce() else { return }
          gate.cancelOnce()
          continuation.resume(throwing: ManualLinkError.network)
        case .cancelled:
          #if DEBUG
          eventSink("connection-cancelled")
          #endif
          guard gate.finishOnce() else { return }; continuation.resume(throwing: ManualLinkError.cancelled)
        default: break
        }
      }; connection.start(queue: .global())
    }
  }
  private func send(_ data: Data, on connection: NWConnection) async throws {
    #if DEBUG
    let eventSink = eventSinkForTesting
    #endif
    try await withCheckedThrowingContinuation { continuation in connection.send(content: data, completion: .contentProcessed { error in
      if error == nil {
        #if DEBUG
        eventSink("send-complete")
        #endif
        continuation.resume()
      }
      else { continuation.resume(throwing: ManualLinkError.network) }
    }) }
  }
  private func receive(on connection: NWConnection) async throws -> (data: Data, complete: Bool) {
    let gate = ConnectionLifecycle(cancel: { connection.cancel() })
    #if DEBUG
    let eventSink = eventSinkForTesting
    #endif
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, complete: Bool), Error>) in connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
      guard gate.finishOnce() else { return }
      if let error { continuation.resume(throwing: error) }
      else {
        #if DEBUG
        eventSink("receive-complete")
        #endif
        continuation.resume(returning: (data ?? Data(), complete))
      }
      } }
    } onCancel: { connection.cancel() }
  }
  static func validateRedirect(from source: URL, to target: URL) throws {
    guard !(source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http") else {
      throw ManualLinkError.unsafeURL
    }
  }

  private static func isFollowableRedirectStatus(_ status: Int) -> Bool {
    switch status {
    case 301, 302, 303, 307, 308:
      true
    default:
      false
    }
  }

  private func redirectTarget(_ headers: [String: String], relativeTo url: URL) -> URL? {
    guard let value = headers["location"] else { return nil }
    return URL(string: value, relativeTo: url)?.absoluteURL
  }
}

private struct Response {
  let status: Int; let headers: [String: String]; let body: Data; let contentLength: Int64?
  init(raw: Data, bodyLimit: Int) throws {
    let headerLimit = 64 * 1024
    guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else {
      throw raw.count > headerLimit ? ManualLinkError.responseTooLarge : ManualLinkError.network
    }
    guard separator.lowerBound <= headerLimit else { throw ManualLinkError.responseTooLarge }
    guard let head = String(data: raw[..<separator.lowerBound], encoding: .utf8) else { throw ManualLinkError.network }
    let lines = head.components(separatedBy: "\r\n")
    guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw ManualLinkError.network }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard pieces.count == 2 else { throw ManualLinkError.network }
      let name = String(pieces[0]).lowercased()
      guard !name.isEmpty, headers[name] == nil else { throw ManualLinkError.network }
      headers[name] = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let payload = Data(raw[separator.upperBound...])
    let length = try headers["content-length"].map(Self.parseContentLength)
    let transferEncoding = headers["transfer-encoding"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !(length != nil && transferEncoding != nil) else { throw ManualLinkError.network }
    guard transferEncoding == nil || transferEncoding == "chunked" else { throw ManualLinkError.network }
    guard headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else { throw ManualLinkError.unsupportedContentType }
    let body: Data
    if transferEncoding == "chunked" {
      body = try Self.decodeChunked(payload, limit: bodyLimit)
    } else if let length {
      guard length >= 0 else { throw ManualLinkError.network }
      guard length <= bodyLimit else { throw ManualLinkError.responseTooLarge }
      guard payload.count == length else { throw ManualLinkError.network }
      body = payload
    } else {
      guard payload.count <= bodyLimit else { throw ManualLinkError.responseTooLarge }
      body = payload
    }
    self.status = status; self.headers = headers; self.body = body; contentLength = length.map(Int64.init)
  }

  private static func parseContentLength(_ value: String) throws -> Int {
    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let length = Int(value) else {
      throw ManualLinkError.network
    }
    return length
  }

  private static func decodeChunked(_ source: Data, limit: Int) throws -> Data {
    var offset = 0, output = Data()
    while true {
      guard let lineEnd = source.range(of: Data("\r\n".utf8), in: offset..<source.count),
            let rawSize = String(data: source[offset..<lineEnd.lowerBound], encoding: .ascii),
            !rawSize.isEmpty,
            rawSize.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
            let size = Int(rawSize, radix: 16), size >= 0 else { throw ManualLinkError.network }
      offset = lineEnd.upperBound
      if size == 0 {
        guard offset + 2 == source.count, source[offset] == 13, source[offset + 1] == 10 else {
          throw ManualLinkError.network
        }
        return output
      }
      guard size <= limit - output.count else { throw ManualLinkError.responseTooLarge }
      guard offset <= source.count - size - 2 else { throw ManualLinkError.network }
      output.append(source[offset..<(offset + size)])
      offset += size
      guard source[offset] == 13, source[offset + 1] == 10 else { throw ManualLinkError.network }
      offset += 2
    }
  }
}
