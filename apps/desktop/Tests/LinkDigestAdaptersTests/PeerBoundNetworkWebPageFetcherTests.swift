import Foundation
import Network
import Security
import Darwin
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class PeerBoundNetworkWebPageFetcherTests: XCTestCase {
  func testContentLengthHTMLSuccess() async throws {
    let server = try ControlledHTTPServer(scripts: [.response(Self.contentLength("<html>length</html>"))])
    defer { server.stop() }

    let result = try await makeFetcher(server).fetch(url: fixtureURL(path: "/length"))

    XCTAssertEqual(result.html, "<html>length</html>")
    XCTAssertEqual(server.requestPaths, ["/length"])
  }

  func testChunkedHTMLSuccess() async throws {
    let server = try ControlledHTTPServer(scripts: [.response(Self.chunked(["<html>", "chunked</html>"]))])
    defer { server.stop() }

    let result = try await makeFetcher(server).fetch(url: fixtureURL(path: "/chunked"))

    XCTAssertEqual(result.html, "<html>chunked</html>")
    for payload in ["0\r\n", "0\r\njunk"] {
      let server = try ControlledHTTPServer(scripts: [.response(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(payload)"
      )])
      defer { server.stop() }

      await assertFetchError(.network, from: makeFetcher(server))
    }
  }

  func testConnectionCloseHTMLSuccess() async throws {
    let server = try ControlledHTTPServer(scripts: [.response(Self.connectionClose("<html>close</html>"))])
    defer { server.stop() }

    let result = try await makeFetcher(server).fetch(url: fixtureURL(path: "/close"))

    XCTAssertEqual(result.html, "<html>close</html>")
  }

  func testContentLengthAndTransferEncodingFramingConflictsAreRejected() async throws {
    let responses = [
      "Content-Length: 5\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n",
      "Content-Length: 5\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
      "Transfer-Encoding: gzip\r\nConnection: close\r\n\r\n0\r\n\r\n",
      "Transfer-Encoding: chunked, gzip\r\nConnection: close\r\n\r\n0\r\n\r\n",
      "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n"
    ]
    for headersAndBody in responses {
      let server = try ControlledHTTPServer(scripts: [.response(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\(headersAndBody)"
      )])
      defer { server.stop() }

      await assertFetchError(.network, from: makeFetcher(server))
    }
  }

  func testRelativeRedirectReresolvesEachHop() async throws {
    let server = try ControlledHTTPServer(scripts: [
      .response("HTTP/1.1 302 Found\r\nLocation: /final\r\nConnection: close\r\n\r\n"),
      .response(Self.contentLength("<html>redirected</html>"))
    ])
    defer { server.stop() }
    let recorder = HostRecorder()
    let fetcher = makeFetcher(server, resolver: { host in
      recorder.record(host)
      return ["127.0.0.1"]
    })

    let result = try await fetcher.fetch(url: fixtureURL(host: "origin.test", path: "/start"))

    XCTAssertEqual(result.url, fixtureURL(host: "origin.test", path: "/final"))
    XCTAssertEqual(server.requestPaths, ["/start", "/final"])
    XCTAssertEqual(recorder.hosts, ["origin.test", "origin.test", "origin.test", "origin.test"])
  }

  func testLocationOnNonRedirectResponseIsNotFollowed() async throws {
    let server = try ControlledHTTPServer(scripts: [.response(
      "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 17\r\nLocation: /ignored\r\nConnection: close\r\n\r\n<html>stay</html>"
    )])
    defer { server.stop() }

    let original = fixtureURL(path: "/original")
    let result = try await makeFetcher(server).fetch(url: original)

    XCTAssertEqual(result.url, original)
    XCTAssertEqual(server.requestPaths, ["/original"])
  }

  func testOnlyStandardRedirectStatusesFollowLocation() async throws {
    for status in [301, 302, 303, 307, 308] {
      let server = try ControlledHTTPServer(scripts: [
        .response("HTTP/1.1 \(status) Redirect\r\nLocation: /final\r\nConnection: close\r\n\r\n"),
        .response(Self.contentLength("<html>redirected</html>"))
      ])
      defer { server.stop() }

      let result = try await makeFetcher(server).fetch(url: fixtureURL(path: "/start"))

      XCTAssertEqual(result.url, fixtureURL(path: "/final"), "status \(status)")
      XCTAssertEqual(server.requestPaths, ["/start", "/final"], "status \(status)")
    }
  }

  func testLocationOnReservedThreeXXStatusesIsNotFollowed() async throws {
    for status in [304, 305, 306] {
      let server = try ControlledHTTPServer(scripts: [
        .response("HTTP/1.1 \(status) Reserved\r\nLocation: /ignored\r\nConnection: close\r\n\r\n")
      ])
      defer { server.stop() }

      await assertFetchError(.responseStatus, from: makeFetcher(server), url: fixtureURL(path: "/original"))

      XCTAssertEqual(server.requestPaths, ["/original"], "status \(status) must not follow Location")
    }
  }

  func testRedirectLimitIsRejected() async throws {
    let server = try ControlledHTTPServer(scripts: [
      .response("HTTP/1.1 302 Found\r\nLocation: /again\r\nConnection: close\r\n\r\n"),
      .response("HTTP/1.1 302 Found\r\nLocation: /again\r\nConnection: close\r\n\r\n")
    ])
    defer { server.stop() }

    await assertFetchError(.responseStatus, from: makeFetcher(server, limits: .init(redirects: 1, responseBytes: 1_024, timeout: 0.5)))
    XCTAssertEqual(server.requestPaths, ["/", "/again"])
  }

  func testHTTPSDowngradeRedirectPolicyIsRejected() throws {
    XCTAssertThrowsError(
      try PeerBoundNetworkWebPageFetcher.validateRedirect(
        from: URL(string: "https://safe.example/path")!,
        to: URL(string: "http://safe.example/path")!
      )
    ) { XCTAssertEqual($0 as? ManualLinkError, .unsafeURL) }
  }

  func testOversizedContentLengthIsRejected() async throws {
    let server = try ControlledHTTPServer(scripts: [.response(Self.contentLength("0123456789abcdef"))])
    defer { server.stop() }

    await assertFetchError(.responseTooLarge, from: makeFetcher(server, limits: .init(redirects: 1, responseBytes: 8, timeout: 0.5)))
  }

  func testOversizedHeaderIsRejected() async throws {
    let oversized = String(repeating: "x", count: 65_537)
    let server = try ControlledHTTPServer(scripts: [.response(
      "HTTP/1.1 200 OK\r\nX-Large: \(oversized)\r\n\r\n"
    )])
    defer { server.stop() }

    await assertFetchError(.responseTooLarge, from: makeFetcher(server, limits: .init(redirects: 1, responseBytes: 1_024, timeout: 0.5)))
  }

  func testTimeoutCancelsTheOpenPeerConnection() async throws {
    let server = try ControlledHTTPServer(scripts: [.holdOpen])
    defer { server.stop() }
    let fetcher = makeFetcher(server, limits: .init(redirects: 1, responseBytes: 1_024, timeout: 0.08))

    await assertFetchError(.timedOut, from: fetcher)
    XCTAssertTrue(server.waitForPeerClose(timeout: 1), "timeout must close the local peer connection")
  }

  func testTaskCancellationCancelsTheOpenPeerConnection() async throws {
    let server = try ControlledHTTPServer(scripts: [.holdOpen])
    defer { server.stop() }
    let fetcher = makeFetcher(server, limits: .init(redirects: 1, responseBytes: 1_024, timeout: 1))
    let url = fixtureURL()
    let task = Task { try await fetcher.fetch(url: url) }
    XCTAssertTrue(server.waitForRequest(timeout: 1), "fixture must receive the request before cancellation")

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancelled fetch unexpectedly succeeded")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? ManualLinkError) != nil)
    }
    XCTAssertTrue(server.waitForPeerClose(timeout: 1), "task cancellation must close the local peer connection")
  }

  func testTLSAcceptsMatchingHostnameWithInjectedLocalAnchor() async throws {
    let certificate = try TemporaryTLSFixture(hostname: "fixture.test")
    let server = try OpenSSLTLSHTTPServer(certificate: certificate)
    defer { server.stop() }
    let recorder = EventRecorder()

    let fetcher = makeFetcher(
      server,
      limits: .init(redirects: 4, responseBytes: 1_024, timeout: 5.0),
      trustAnchorsForTesting: [certificate.certificate],
      eventSinkForTesting: { recorder.record($0) }
    )
    let result: WebPageFetchResult
    do {
      result = try await fetcher.fetch(url: fixtureURL(scheme: "https", path: OpenSSLTLSHTTPServer.responsePath))
    } catch {
      XCTFail("matching TLS fetch failed; events: \(recorder.events)")
      return
    }

    let events = recorder.events
    XCTAssertEqual(result.html, OpenSSLTLSHTTPServer.responseBody, "TLS events: \(events)")
    XCTAssertTrue(events.contains("verify-enter"), "TLS events: \(events)")
    XCTAssertTrue(events.contains("verify-true"), "TLS events: \(events)")
    XCTAssertTrue(events.contains("connection-ready"), "TLS events: \(events)")
  }

  func testTLSRejectsCertificateForDifferentHostname() async throws {
    let certificate = try TemporaryTLSFixture(hostname: "different.test")
    let server = try OpenSSLTLSHTTPServer(certificate: certificate)
    defer { server.stop() }
    let recorder = EventRecorder()

    await assertFetchError(
      .network,
      from: makeFetcher(
        server,
        limits: .init(redirects: 4, responseBytes: 1_024, timeout: 5.0),
        trustAnchorsForTesting: [certificate.certificate],
        eventSinkForTesting: { recorder.record($0) }
      ),
      url: fixtureURL(scheme: "https", path: OpenSSLTLSHTTPServer.responsePath)
    )

    let events = recorder.events
    XCTAssertTrue(events.contains("verify-enter"), "TLS events: \(events)")
    XCTAssertTrue(events.contains("verify-false"), "TLS events: \(events)")
  }

  func testTLSRejectsUntrustedSelfSignedCertificateWithoutTestAnchor() async throws {
    let certificate = try TemporaryTLSFixture(hostname: "fixture.test")
    let server = try OpenSSLTLSHTTPServer(certificate: certificate)
    defer { server.stop() }
    let recorder = EventRecorder()

    await assertFetchError(
      .network,
      from: makeFetcher(
        server,
        limits: .init(redirects: 4, responseBytes: 1_024, timeout: 5.0),
        eventSinkForTesting: { recorder.record($0) }
      ),
      url: fixtureURL(scheme: "https", path: OpenSSLTLSHTTPServer.responsePath)
    )

    let events = recorder.events
    XCTAssertTrue(events.contains("verify-enter"), "TLS events: \(events)")
    XCTAssertTrue(events.contains("verify-false"), "TLS events: \(events)")
  }

  private func makeFetcher(
    _ server: some LocalTestServer,
    resolver: @escaping PublicWebURLPolicy.Resolver = { _ in ["127.0.0.1"] },
    limits: URLSessionWebPageFetcher.Limits = .init(redirects: 4, responseBytes: 1_024, timeout: 0.5),
    trustAnchorsForTesting: [SecCertificate]? = nil,
    eventSinkForTesting: @escaping @Sendable (String) -> Void = { _ in }
  ) -> PeerBoundNetworkWebPageFetcher {
    PeerBoundNetworkWebPageFetcher(
      resolver: resolver,
      allowLoopbackForTesting: true,
      limits: limits,
      portForTesting: server.port,
      trustAnchorsForTesting: trustAnchorsForTesting,
      eventSinkForTesting: eventSinkForTesting
    )
  }

  private func assertFetchError(
    _ expected: ManualLinkError,
    from fetcher: PeerBoundNetworkWebPageFetcher,
    url: URL? = nil
  ) async {
    do {
      _ = try await fetcher.fetch(url: url ?? fixtureURL())
      XCTFail("expected \(expected)")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, expected)
    }
  }

  private func fixtureURL(scheme: String = "http", host: String = "fixture.test", path: String = "/") -> URL {
    URL(string: "\(scheme)://\(host)\(path)")!
  }

  private static func contentLength(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
  }

  private static func chunked(_ chunks: [String]) -> String {
    let body = chunks.map { "\(String(Data($0.utf8).count, radix: 16))\r\n\($0)\r\n" }.joined()
    return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(body)0\r\n\r\n"
  }

  private static func connectionClose(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(body)"
  }
}

private protocol LocalTestServer {
  var port: UInt16 { get }
}

private final class ControlledHTTPServer: @unchecked Sendable, LocalTestServer {
  enum Script: Sendable { case response(String), holdOpen }

  private let queue = DispatchQueue(label: "com.syc.linkdigest.peer-bound-http-tests")
  private let lock = NSLock()
  private var scripts: [Script]
  private var paths: [String] = []
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var listener: NWListener?
  private var storedPort: UInt16 = 0
  private var startupFailed = false
  private let requestReceived = DispatchSemaphore(value: 0)
  private let peerClosed = DispatchSemaphore(value: 0)

  init(scripts: [Script]) throws {
    self.scripts = scripts
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        self.lock.withLock { self.storedPort = listener.port?.rawValue ?? 0 }
        ready.signal()
      case .failed:
        self.lock.withLock { self.startupFailed = true }
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 1) == .success,
          lock.withLock({ !startupFailed && storedPort != 0 }) else {
      listener.cancel()
      throw FixtureError.startFailed
    }
  }

  var port: UInt16 { lock.withLock { storedPort } }
  var requestPaths: [String] { lock.withLock { paths } }

  func stop() {
    listener?.cancel()
    lock.withLock { () -> [NWConnection] in
      let values = Array(connections.values)
      connections.removeAll()
      return values
    }.forEach { $0.cancel() }
  }

  func waitForRequest(timeout: TimeInterval) -> Bool {
    requestReceived.wait(timeout: .now() + timeout) == .success
  }

  func waitForPeerClose(timeout: TimeInterval) -> Bool {
    peerClosed.wait(timeout: .now() + timeout) == .success
  }

  private func accept(_ connection: NWConnection) {
    let identifier = ObjectIdentifier(connection)
    lock.withLock { connections[identifier] = connection }
    connection.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else {
        if case .cancelled = state { self?.remove(connection, identifier: identifier) }
        return
      }
      self?.remove(connection, identifier: identifier)
    }
    connection.start(queue: queue)
    receiveRequest(on: connection, accumulated: Data(), identifier: identifier)
  }

  private func receiveRequest(on connection: NWConnection, accumulated: Data, identifier: ObjectIdentifier) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
      guard let self else { return }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        if complete || error != nil { self.remove(connection, identifier: identifier) }
        else { self.receiveRequest(on: connection, accumulated: bytes, identifier: identifier) }
        return
      }
      let requestLine = String(data: bytes[..<headerEnd.lowerBound], encoding: .utf8)?
        .components(separatedBy: "\r\n").first
      let path = requestLine?.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
      let script = self.lock.withLock { () -> Script in
        self.paths.append(path)
        return self.scripts.count > 1 ? self.scripts.removeFirst() : (self.scripts.first ?? .holdOpen)
      }
      self.requestReceived.signal()
      switch script {
      case let .response(raw):
        connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in connection.cancel() })
      case .holdOpen:
        self.observePeerClose(on: connection, identifier: identifier)
      }
    }
  }

  private func observePeerClose(on connection: NWConnection, identifier: ObjectIdentifier) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
      if complete || error != nil {
        self?.peerClosed.signal()
        self?.remove(connection, identifier: identifier)
      } else {
        self?.observePeerClose(on: connection, identifier: identifier)
      }
    }
  }

  private func remove(_ connection: NWConnection, identifier: ObjectIdentifier) {
    let removed = lock.withLock { connections.removeValue(forKey: identifier) != nil }
    if removed { peerClosed.signal() }
    connection.cancel()
  }

  private enum FixtureError: Error { case startFailed }
}

private final class TemporaryTLSFixture {
  let certificate: SecCertificate
  fileprivate let hostname: String
  fileprivate let directory: URL
  fileprivate let privateKeyURL: URL
  fileprivate let certificatePEMURL: URL

  init(hostname: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-tls-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let caPrivateKey = directory.appendingPathComponent("ca-key.pem")
      let caCertificatePEMURL = directory.appendingPathComponent("ca-certificate.pem")
      let caCertificateDER = directory.appendingPathComponent("ca-certificate.der")
      let privateKey = directory.appendingPathComponent("server-key.pem")
      let certificateRequest = directory.appendingPathComponent("server.csr")
      let serverCertificatePEMURL = directory.appendingPathComponent("server-certificate.pem")
      let certificatePEMURL = directory.appendingPathComponent("server-chain.pem")
      let extensions = directory.appendingPathComponent("server-extensions.cnf")

      try Self.runOpenSSL([
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-keyout", caPrivateKey.path,
        "-out", caCertificatePEMURL.path,
        "-subj", "/CN=LinkDigest Local Test CA",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign"
      ])
      try Self.runOpenSSL([
        "req", "-new", "-newkey", "rsa:2048", "-nodes",
        "-keyout", privateKey.path,
        "-out", certificateRequest.path,
        "-subj", "/CN=\(hostname)"
      ])
      try Self.writeFixtureFile(
        """
        subjectAltName=DNS:\(hostname)
        basicConstraints=critical,CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        """,
        to: extensions
      )
      try Self.runOpenSSL([
        "x509", "-req", "-days", "1", "-sha256",
        "-in", certificateRequest.path,
        "-CA", caCertificatePEMURL.path,
        "-CAkey", caPrivateKey.path,
        "-CAcreateserial",
        "-out", serverCertificatePEMURL.path,
        "-extfile", extensions.path
      ])
      try Self.runOpenSSL([
        "x509",
        "-in", caCertificatePEMURL.path,
        "-outform", "DER",
        "-out", caCertificateDER.path
      ])
      var certificateChain = try Data(contentsOf: serverCertificatePEMURL)
      if certificateChain.last != 0x0A { certificateChain.append(0x0A) }
      certificateChain.append(try Data(contentsOf: caCertificatePEMURL))
      try Self.writeFixtureFile(certificateChain, to: certificatePEMURL)

      let certificateData = try Data(contentsOf: caCertificateDER)
      guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
        throw FixtureError.invalidCertificate
      }
      self.hostname = hostname
      self.directory = directory
      self.privateKeyURL = privateKey
      self.certificatePEMURL = certificatePEMURL
      self.certificate = certificate
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  private static func runOpenSSL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FixtureError.certificateGenerationFailed }
  }

  private static func writeFixtureFile(_ contents: String, to url: URL) throws {
    try writeFixtureFile(Data(contents.utf8), to: url)
  }

  private static func writeFixtureFile(_ contents: Data, to url: URL) throws {
    guard FileManager.default.createFile(
      atPath: url.path,
      contents: contents,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw FixtureError.certificateGenerationFailed
    }
  }

  private enum FixtureError: Error {
    case certificateGenerationFailed, invalidCertificate
  }
}

private final class OpenSSLTLSHTTPServer: @unchecked Sendable, LocalTestServer {
  static let responsePath = "/response.html"
  static let responseBody = "<html><body>tls fixture</body></html>"

  private static let pythonServerScript = """
import signal
import socket
import ssl
import sys

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)

body = b"<html><body>tls fixture</body></html>"
response = (
    b"HTTP/1.1 200 OK\\r\\n"
    b"Content-Type: text/html\\r\\n"
    + b"Content-Length: " + str(len(body)).encode("ascii") + b"\\r\\n"
    + b"Connection: close\\r\\n\\r\\n"
    + body
)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.maximum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(sys.argv[2], sys.argv[3])
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[1])))
listener.listen()
listener.settimeout(0.2)
print("READY", flush=True)

while running:
    try:
        connection, _ = listener.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        connection.settimeout(0.2)
        secure = context.wrap_socket(connection, server_side=True)
        secure.settimeout(0.2)
        request = b""
        while running and b"\\r\\n\\r\\n" not in request and len(request) < 65536:
            try:
                chunk = secure.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            request += chunk
        if running and b"\\r\\n\\r\\n" in request:
            secure.sendall(response)
        secure.close()
    except Exception:
        try:
            connection.close()
        except Exception:
            pass

listener.close()
"""

  private let lock = NSLock()
  private var process: Process?
  private var termination: DispatchSemaphore?
  private var standardOutput: Pipe?
  private(set) var port: UInt16 = 0

  init(certificate: TemporaryTLSFixture) throws {
    for _ in 0..<8 {
      let candidate = UInt16.random(in: 49_152...64_000)
      let process = Process()
      let termination = DispatchSemaphore(value: 0)
      let standardOutput = Pipe()
      let ready = ProcessReadySignal()
      standardOutput.fileHandleForReading.readabilityHandler = { handle in
        ready.receive(handle.availableData)
      }
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "python3", "-c", Self.pythonServerScript,
        String(candidate), certificate.certificatePEMURL.path, certificate.privateKeyURL.path
      ]
      process.standardOutput = standardOutput
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { _ in
        termination.signal()
        ready.processExited()
      }
      do {
        try process.run()
      } catch {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        try? standardOutput.fileHandleForReading.close()
        continue
      }
      let didBecomeReady = ready.waitForExactReady(timeout: 2)
      standardOutput.fileHandleForReading.readabilityHandler = nil
      if didBecomeReady && process.isRunning {
        self.process = process
        self.termination = termination
        self.standardOutput = standardOutput
        self.port = candidate
        return
      }
      Self.stop(process, termination: termination, standardOutput: standardOutput)
    }
    throw FixtureError.startFailed
  }

  deinit { stop() }

  func stop() {
    let active: (Process, DispatchSemaphore, Pipe)? = lock.withLock {
      guard let process, let termination, let standardOutput else { return nil }
      self.process = nil
      self.termination = nil
      self.standardOutput = nil
      return (process, termination, standardOutput)
    }
    if let active { Self.stop(active.0, termination: active.1, standardOutput: active.2) }
  }

  private static func stop(_ process: Process, termination: DispatchSemaphore, standardOutput: Pipe) {
    standardOutput.fileHandleForReading.readabilityHandler = nil
    try? standardOutput.fileHandleForReading.close()
    if process.isRunning { process.terminate() }
    if termination.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
      let pid = process.processIdentifier
      if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
      _ = termination.wait(timeout: .now() + 1)
    }
    if !process.isRunning { process.waitUntilExit() }
    assert(!process.isRunning, "TLS fixture subprocess must exit during cleanup")
  }

  private enum FixtureError: Error { case startFailed }
}

private final class ProcessReadySignal: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private let expected = Data("READY\n".utf8)
  private var output = Data()
  private var result: Bool?

  func receive(_ data: Data) {
    let shouldSignal = lock.withLock { () -> Bool in
      guard result == nil else { return false }
      guard !data.isEmpty else {
        result = false
        return true
      }
      output.append(data)
      guard output.count <= expected.count, expected.starts(with: output) else {
        result = false
        return true
      }
      guard output.count == expected.count else { return false }
      result = true
      return true
    }
    if shouldSignal { semaphore.signal() }
  }

  func processExited() {
    let shouldSignal = lock.withLock { () -> Bool in
      guard result == nil else { return false }
      result = false
      return true
    }
    if shouldSignal { semaphore.signal() }
  }

  func waitForExactReady(timeout: TimeInterval) -> Bool {
    guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
    return lock.withLock { result == true }
  }
}

private final class HostRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func record(_ host: String) { lock.withLock { values.append(host) } }
  var hosts: [String] { lock.withLock { values } }
}

private final class EventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func record(_ event: String) { lock.withLock { values.append(event) } }
  var events: [String] { lock.withLock { values } }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
