import CFNetwork
import Darwin
import Foundation
import Security
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// Exercises URLSession's real CONNECT implementation. The proxy listener is
/// deliberately in this XCTest process; only the disposable TLS endpoint is a
/// subprocess, and its self-signed CA is injected into the individual trust.
final class SystemProxyWebPageFetcherTests: XCTestCase {
  func testCONNECTUsesOriginalHostnameAndAcceptsMatchingCertificate() async throws {
    let certificate = try ProxyTLSCertificate(hostname: "fixture.test")
    let server = try ProxyTLSHTTPServer(certificate: certificate, responses: [Self.htmlResponse])
    defer { server.stop() }
    let proxy = try ClassicHTTPConnectProxy(upstreamPort: server.port)
    defer { proxy.stop() }

    let result = try await makeFetcher(proxy: proxy, anchors: [certificate.certificate])
      .fetch(url: Self.fixtureURL(path: "/start"))

    XCTAssertEqual(result.html, Self.htmlBody)
    XCTAssertEqual(proxy.connectTargets, ["fixture.test:443"])
  }

  func testCONNECTRejectsWrongHostnameAndUntrustedCertificate() async throws {
    let wrongHostCertificate = try ProxyTLSCertificate(hostname: "wrong.test")
    let wrongHostServer = try ProxyTLSHTTPServer(certificate: wrongHostCertificate, responses: [Self.htmlResponse])
    defer { wrongHostServer.stop() }
    let wrongHostProxy = try ClassicHTTPConnectProxy(upstreamPort: wrongHostServer.port)
    defer { wrongHostProxy.stop() }
    await assertFetchError(
      .proxyTLSValidation,
      from: makeFetcher(proxy: wrongHostProxy, anchors: [wrongHostCertificate.certificate])
    )

    let untrustedCertificate = try ProxyTLSCertificate(hostname: "fixture.test")
    let untrustedServer = try ProxyTLSHTTPServer(certificate: untrustedCertificate, responses: [Self.htmlResponse])
    defer { untrustedServer.stop() }
    let untrustedProxy = try ClassicHTTPConnectProxy(upstreamPort: untrustedServer.port)
    defer { untrustedProxy.stop() }
    await assertFetchError(.proxyTLSValidation, from: makeFetcher(proxy: untrustedProxy))
  }

  func testRedirectTargetsAreRevalidatedOnEveryProxyHop() async throws {
    let rejectedTargets = [
      "https://private.example/final",
      "https://test-net.example/final",
      "https://user:password@credential.example/final",
      "https://fixture.test:8443/final",
      "http://fixture.test/final"
    ]
    for target in rejectedTargets {
      let certificate = try ProxyTLSCertificate(hostname: "fixture.test")
      let server = try ProxyTLSHTTPServer(
        certificate: certificate,
        responses: [Self.redirectResponse(to: target)]
      )
      defer { server.stop() }
      let proxy = try ClassicHTTPConnectProxy(upstreamPort: server.port)
      defer { proxy.stop() }

      await assertFetchError(
        .unsafeURL,
        from: makeFetcher(proxy: proxy, anchors: [certificate.certificate])
      )
      XCTAssertEqual(proxy.connectTargets, ["fixture.test:443"], "redirect \(target) must be rejected before another CONNECT")
    }

    let certificate = try ProxyTLSCertificate(hostname: "fixture.test")
    let server = try ProxyTLSHTTPServer(
      certificate: certificate,
      responses: [
        Self.redirectResponse(to: "/middle"),
        Self.redirectResponse(to: "https://private.example/final")
      ]
    )
    defer { server.stop() }
    let proxy = try ClassicHTTPConnectProxy(upstreamPort: server.port)
    defer { proxy.stop() }

    await assertFetchError(
      .unsafeURL,
      from: makeFetcher(proxy: proxy, anchors: [certificate.certificate])
    )
    XCTAssertEqual(proxy.connectTargets, ["fixture.test:443", "fixture.test:443"])
  }

  func testAuthenticatedProxyFailsWithoutCredentialStorageAndSendsNoCredential() async throws {
    let certificate = try ProxyTLSCertificate(hostname: "fixture.test")
    let server = try ProxyTLSHTTPServer(certificate: certificate, responses: [Self.htmlResponse])
    defer { server.stop() }
    let proxy = try ClassicHTTPConnectProxy(upstreamPort: server.port, requiresAuthentication: true)
    defer { proxy.stop() }

    await assertFetchError(
      .proxyAuthenticationRequired,
      from: makeFetcher(proxy: proxy, anchors: [certificate.certificate])
    )
    XCTAssertEqual(proxy.connectTargets, ["fixture.test:443"])
    XCTAssertTrue(proxy.proxyAuthorizationHeaders.isEmpty)
  }

  func testProxyTransportRejectsHTTPBeforeAnyCONNECT() async throws {
    let proxy = try ClassicHTTPConnectProxy(upstreamPort: 443)
    defer { proxy.stop() }
    let fetcher = makeFetcher(proxy: proxy)

    await assertFetchError(.proxyHTTPSRequired, from: fetcher, url: URL(string: "http://fixture.test/page")!)
    XCTAssertTrue(proxy.connectTargets.isEmpty)
  }

  private func makeFetcher(
    proxy: ClassicHTTPConnectProxy,
    anchors: [SecCertificate] = []
  ) -> SystemProxyWebPageFetcher {
    let policy = PublicWebURLPolicy(
      resolver: { host in
        switch host {
        case "fixture.test": ["127.0.0.1"]
        case "private.example": ["10.0.0.8"]
        case "test-net.example": ["192.0.2.8"]
        case "credential.example": ["8.8.8.8"]
        default: ["8.8.8.8"]
        }
      },
      allowLoopbackForTesting: true
    )
    return SystemProxyWebPageFetcher(
      policy: policy,
      limits: .init(redirects: 4, responseBytes: 8_192, timeout: 3),
      proxySettings: { _ in
        [
          kCFNetworkProxiesHTTPEnable as String: 1,
          kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
          kCFNetworkProxiesHTTPPort as String: Int(proxy.port),
          kCFNetworkProxiesHTTPSEnable as String: 1,
          kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
          kCFNetworkProxiesHTTPSPort as String: Int(proxy.port)
        ]
      },
      trustAnchorsForTesting: anchors
    )
  }

  private func assertFetchError(
    _ expected: ManualLinkError,
    from fetcher: SystemProxyWebPageFetcher,
    url: URL? = nil
  ) async {
    do {
      _ = try await fetcher.fetch(url: url ?? Self.fixtureURL())
      XCTFail("expected \(expected)")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, expected)
    }
  }

  private static func fixtureURL(path: String = "/") -> URL {
    URL(string: "https://fixture.test\(path)")!
  }

  private static let htmlBody = "<html><body>proxy fixture</body></html>"
  private static let htmlResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 39\r\nConnection: close\r\n\r\n<html><body>proxy fixture</body></html>"

  private static func redirectResponse(to target: String) -> String {
    "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  }
}

private final class ClassicHTTPConnectProxy: @unchecked Sendable {
  private let listener: Int32
  private let upstreamPort: UInt16
  private let requiresAuthentication: Bool
  // `acceptLoop` blocks by design. It must not share a serial executor with
  // per-client CONNECT handling, otherwise every accepted socket times out
  // before its request line can be read.
  private let queue = DispatchQueue(
    label: "com.syc.linkdigest.system-proxy-tests",
    attributes: .concurrent
  )
  private let lock = NSLock()
  private var running = true
  private var targets: [String] = []
  private var authorizations: [String] = []
  let port: UInt16

  init(upstreamPort: UInt16, requiresAuthentication: Bool = false) throws {
    self.upstreamPort = upstreamPort
    self.requiresAuthentication = requiresAuthentication
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FixtureError.startFailed }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    guard withUnsafePointer(to: &address, { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }), listen(fd, 8) == 0 else {
      Darwin.close(fd)
      throw FixtureError.startFailed
    }
    var bound = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &bound, { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) == 0 }
    }) else {
      Darwin.close(fd)
      throw FixtureError.startFailed
    }
    listener = fd
    port = UInt16(bigEndian: bound.sin_port)
    queue.async { [weak self] in self?.acceptLoop() }
  }

  deinit { stop() }

  var connectTargets: [String] { lock.withLock { targets } }
  var proxyAuthorizationHeaders: [String] { lock.withLock { authorizations } }

  func stop() {
    let shouldClose = lock.withLock { () -> Bool in
      guard running else { return false }
      running = false
      return true
    }
    if shouldClose {
      _ = shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
    }
  }

  private func acceptLoop() {
    while lock.withLock({ running }) {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { continue }
      queue.async { [weak self] in self?.handle(client: client) }
    }
  }

  private func handle(client: Int32) {
    defer { Darwin.close(client) }
    guard let header = readHeader(from: client) else { return }
    let lines = header.components(separatedBy: "\r\n")
    guard let request = lines.first?.split(separator: " "), request.count >= 2,
          request[0] == "CONNECT" else { return }
    let target = String(request[1])
    let credentials = lines.compactMap { line -> String? in
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, parts[0].lowercased() == "proxy-authorization" else { return nil }
      return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
    lock.withLock {
      targets.append(target)
      authorizations.append(contentsOf: credentials)
    }
    if requiresAuthentication {
      _ = sendAll("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", to: client)
      return
    }
    guard let upstream = connectToLoopback(port: upstreamPort) else { return }
    defer { Darwin.close(upstream) }
    guard sendAll("HTTP/1.1 200 Connection Established\r\n\r\n", to: client) else { return }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      self.copy(from: client, to: upstream)
      _ = shutdown(upstream, SHUT_WR)
      group.leave()
    }
    copy(from: upstream, to: client)
    _ = shutdown(client, SHUT_WR)
    _ = group.wait(timeout: .now() + 3)
  }

  private func readHeader(from fd: Int32) -> String? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < 65_536 {
      let count = recv(fd, &buffer, buffer.count, 0)
      guard count > 0 else { return nil }
      data.append(buffer, count: Int(count))
      if data.range(of: Data("\r\n\r\n".utf8)) != nil {
        return String(data: data, encoding: .utf8)
      }
    }
    return nil
  }

  private func copy(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = recv(source, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      guard sendAll(Data(buffer.prefix(Int(count))), to: destination) else { return }
    }
  }

  private func connectToLoopback(port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    guard connected else { Darwin.close(fd); return nil }
    return fd
  }

  private func sendAll(_ string: String, to fd: Int32) -> Bool { sendAll(Data(string.utf8), to: fd) }

  private func sendAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return data.isEmpty }
      var sent = 0
      while sent < data.count {
        let written = send(fd, base.advanced(by: sent), data.count - sent, 0)
        guard written > 0 else { return false }
        sent += Int(written)
      }
      return true
    }
  }

  private enum FixtureError: Error { case startFailed }
}

private final class ProxyTLSCertificate {
  let certificate: SecCertificate
  let directory: URL
  let privateKeyURL: URL
  let certificatePEMURL: URL

  init(hostname: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-proxy-tls-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let caKey = directory.appendingPathComponent("ca-key.pem")
    let caCertificate = directory.appendingPathComponent("ca.pem")
    let caDER = directory.appendingPathComponent("ca.der")
    privateKeyURL = directory.appendingPathComponent("server-key.pem")
    let request = directory.appendingPathComponent("server.csr")
    let serverCertificate = directory.appendingPathComponent("server.pem")
    certificatePEMURL = directory.appendingPathComponent("chain.pem")
    let extensions = directory.appendingPathComponent("extensions.cnf")
    do {
      try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", caKey.path, "-out", caCertificate.path, "-subj", "/CN=LinkDigest Proxy Test CA", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
      try Self.openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", privateKeyURL.path, "-out", request.path, "-subj", "/CN=\(hostname)"])
      try "subjectAltName=DNS:\(hostname)\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to: extensions, atomically: true, encoding: .utf8)
      try Self.openssl(["x509", "-req", "-days", "1", "-sha256", "-in", request.path, "-CA", caCertificate.path, "-CAkey", caKey.path, "-CAcreateserial", "-out", serverCertificate.path, "-extfile", extensions.path])
      try Self.openssl(["x509", "-in", caCertificate.path, "-outform", "DER", "-out", caDER.path])
      var chain = try Data(contentsOf: serverCertificate)
      if chain.last != 10 { chain.append(10) }
      chain.append(try Data(contentsOf: caCertificate))
      try chain.write(to: certificatePEMURL, options: .atomic)
      guard let certificate = SecCertificateCreateWithData(nil, try Data(contentsOf: caDER) as CFData) else { throw FixtureError.invalidCertificate }
      self.certificate = certificate
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  private static func openssl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FixtureError.certificateGenerationFailed }
  }

  private enum FixtureError: Error { case certificateGenerationFailed, invalidCertificate }
}

private final class ProxyTLSHTTPServer: @unchecked Sendable {
  private static let script = """
import base64, json, socket, ssl, sys
responses = json.loads(base64.b64decode(sys.argv[4]).decode("utf-8"))
index = 0
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[1])))
listener.listen()
print("READY", flush=True)
while True:
    connection, _ = listener.accept()
    try:
        secure = context.wrap_socket(connection, server_side=True)
        secure.recv(65536)
        response = responses[min(index, len(responses) - 1)].encode("utf-8")
        index += 1
        secure.sendall(response)
        secure.close()
    except Exception:
        try: connection.close()
        except Exception: pass
"""

  private var process: Process?
  private var output: Pipe?
  private let lock = NSLock()
  let port: UInt16

  init(certificate: ProxyTLSCertificate, responses: [String]) throws {
    var selected: UInt16?
    var activeProcess: Process?
    var activeOutput: Pipe?
    for _ in 0..<8 {
      let candidate = UInt16.random(in: 49_152...64_000)
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      let payload = try JSONSerialization.data(withJSONObject: responses)
      process.arguments = ["python3", "-c", Self.script, String(candidate), certificate.certificatePEMURL.path, certificate.privateKeyURL.path, payload.base64EncodedString()]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      if Self.waitForReady(output.fileHandleForReading, timeout: 2) {
        selected = candidate; activeProcess = process; activeOutput = output; break
      }
      if process.isRunning { process.terminate() }
    }
    guard let selected, let activeProcess, let activeOutput else { throw FixtureError.startFailed }
    port = selected
    process = activeProcess
    output = activeOutput
  }

  deinit { stop() }

  func stop() {
    let active = lock.withLock { () -> (Process?, Pipe?) in
      let result = (process, output); process = nil; output = nil; return result
    }
    active.1?.fileHandleForReading.closeFile()
    if let process = active.0, process.isRunning { process.terminate(); process.waitUntilExit() }
  }

  private static func waitForReady(_ handle: FileHandle, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes = Data()
    while Date() < deadline, bytes.count < 64 {
      let next = handle.availableData
      guard !next.isEmpty else { return false }
      bytes.append(next)
      if bytes.range(of: Data("READY\n".utf8)) != nil { return true }
    }
    return false
  }

  private enum FixtureError: Error { case startFailed }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock(); defer { unlock() }; return try body()
  }
}
