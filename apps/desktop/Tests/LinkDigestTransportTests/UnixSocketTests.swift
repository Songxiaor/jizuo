import XCTest
@testable import LinkDigestTransport

final class UnixSocketTests: XCTestCase {
  func testClientReportsOfflineSocket() {
    let path = "/tmp/linkdigest-offline-\(UUID().uuidString).sock"
    XCTAssertThrowsError(try UnixSocketClient.send(Data("{}".utf8), path: path, timeout: 0.1))
  }

  func testCanConnectFalseWhenSocketMissing() {
    let path = "/tmp/linkdigest-missing-\(UUID().uuidString).sock"
    XCTAssertFalse(UnixSocketClient.canConnect(path: path, timeout: 0.05))
  }

  func testCanConnectTrueWhenServerListening() async throws {
    let path = "/tmp/linkdigest-canconnect-\(UUID().uuidString).sock"
    let server = UnixSocketServer(path: path)
    try server.start()
    // Drain the probe connection so it does not sit in the backlog.
    let drain = Task.detached {
      let client = try server.accept(timeout: 2)
      try? client.close()
    }
    XCTAssertTrue(UnixSocketClient.canConnect(path: path, timeout: 0.5))
    try await drain.value
  }

  func testClientServerRoundTrip() async throws {
    let path = "/tmp/linkdigest-roundtrip-\(UUID().uuidString).sock"
    let server = UnixSocketServer(path: path)
    try server.start()
    let response = Data("{\"kind\":\"taskAccepted\"}".utf8)
    let serverTask = Task.detached {
      let client = try server.accept(timeout: 2)
      defer { try? client.close() }
      _ = try ChromiumFramer.readFrame(from: client)
      try ChromiumFramer.writeFrame(response, to: client)
    }
    let received = try UnixSocketClient.send(Data("{}".utf8), path: path, timeout: 2)
    try await serverTask.value
    XCTAssertEqual(received, response)
  }

  func testStopIsIdempotentUnlinksExactSocketAndAllowsRestart() throws {
    let path = "/tmp/linkdigest-stop-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    defer { server.stop() }

    try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))

    try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testSecondServerCannotOrphanLiveListener() async throws {
    let path = "/tmp/linkdigest-exclusive-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let first = UnixSocketServer(path: path)
    let second = UnixSocketServer(path: path)
    defer {
      second.stop()
      first.stop()
    }

    try first.start()
    XCTAssertThrowsError(try second.start()) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EADDRINUSE)
    }
    XCTAssertTrue(first.isPublishedAtPath())

    let response = Data("{\"kind\":\"taskAccepted\"}".utf8)
    let serverTask = Task.detached {
      let client = try first.accept(timeout: 2)
      defer { try? client.close() }
      _ = try ChromiumFramer.readFrame(from: client)
      try ChromiumFramer.writeFrame(response, to: client)
    }
    let received = try UnixSocketClient.send(Data("{}".utf8), path: path, timeout: 2)
    try await serverTask.value
    XCTAssertEqual(received, response)
  }

  func testStopDoesNotDeleteAReplacementNodeItDoesNotOwn() throws {
    let path = "/tmp/linkdigest-replaced-\(UUID().uuidString).sock"
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let server = UnixSocketServer(path: path)
    try server.start()
    XCTAssertTrue(server.isPublishedAtPath())

    XCTAssertEqual(Darwin.unlink(path), 0)
    XCTAssertFalse(server.isPublishedAtPath())
    XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("replacement".utf8)))

    server.stop()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  // MARK: - 事件驱动的 accept

  /// 没有连接进来时，一次 accept 都不该发生。
  ///
  /// 以前是 1 秒超时的轮询：App 只要开着，这个线程每秒醒一次、做一次 accept、
  /// 再做一次文件系统检查，全程什么也没发生。这条断言钉的就是「闲着零唤醒」。
  func testIdleListenerNeverCallsAccept() throws {
    let path = "/tmp/linkdigest-idle-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    defer { server.stop() }
    try server.start()

    let seen = ConnectionSpy()
    try server.startAccepting(onClient: { handle in seen.record(handle) })

    Thread.sleep(forTimeInterval: 1.1)
    XCTAssertEqual(server.acceptSyscallCount, 0, "没有连接时不该有任何 accept 调用")
    XCTAssertEqual(seen.count, 0)
  }

  /// 有连接进来要立刻被处理，不能等到下一个轮询周期。
  func testListenerHandsOffConnectionImmediately() throws {
    let path = "/tmp/linkdigest-event-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    defer { server.stop() }
    try server.start()

    let response = Data("{\"kind\":\"taskAccepted\"}".utf8)
    let served = expectation(description: "连接被处理")
    try server.startAccepting(ioTimeout: 2, onClient: { client in
      defer { try? client.close() }
      _ = try? ChromiumFramer.readFrame(from: client, timeout: 2)
      try? ChromiumFramer.writeFrame(response, to: client)
      served.fulfill()
    })

    let received = try UnixSocketClient.send(Data("{}".utf8), path: path, timeout: 2)
    XCTAssertEqual(received, response)
    wait(for: [served], timeout: 2)
    XCTAssertGreaterThan(server.acceptSyscallCount, 0)
  }

  /// 一次事件里排了好几个连接也要全部取走，不能只取第一个就回去睡。
  func testListenerDrainsSeveralQueuedConnections() throws {
    let path = "/tmp/linkdigest-drain-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    defer { server.stop() }
    try server.start()

    let seen = ConnectionSpy()
    let served = expectation(description: "三个连接都被取走")
    served.expectedFulfillmentCount = 3
    try server.startAccepting(onClient: { handle in
      seen.record(handle)
      try? handle.close()
      served.fulfill()
    })

    for _ in 0..<3 { XCTAssertTrue(UnixSocketClient.canConnect(path: path, timeout: 1)) }
    wait(for: [served], timeout: 3)
    XCTAssertEqual(seen.count, 3)
  }

  /// stop 之后：socket 节点消失、连不上、也不会再有回调。
  func testStopSilencesTheListenerAndClosesTheDescriptor() throws {
    let path = "/tmp/linkdigest-stopped-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    try server.start()

    let seen = ConnectionSpy()
    try server.startAccepting(onClient: { handle in
      seen.record(handle)
      try? handle.close()
    })
    XCTAssertTrue(UnixSocketClient.canConnect(path: path, timeout: 1))
    Thread.sleep(forTimeInterval: 0.2)
    let before = seen.count
    XCTAssertGreaterThan(before, 0)

    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop 要把 socket 节点摘掉")
    XCTAssertFalse(server.isPublishedAtPath())
    XCTAssertFalse(UnixSocketClient.canConnect(path: path, timeout: 0.2))
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertEqual(seen.count, before, "stop 之后不该再有回调")

    // stop 是幂等的，重复调用不该崩。
    server.stop()
  }

  /// 停掉再开起来，语义和第一次一样。
  func testListenerCanBeRestartedAfterStop() throws {
    let path = "/tmp/linkdigest-relisten-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let server = UnixSocketServer(path: path)
    defer { server.stop() }

    for _ in 0..<2 {
      try server.start()
      let served = expectation(description: "连接被处理")
      try server.startAccepting(onClient: { handle in
        try? handle.close()
        served.fulfill()
      })
      XCTAssertTrue(UnixSocketClient.canConnect(path: path, timeout: 1))
      wait(for: [served], timeout: 2)
      server.stop()
    }
  }

  func testAppBundleLocatorWalksUpToCoLocatedApp() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-locator-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("LinkDigest.app", isDirectory: true)
    let host = app
      .appendingPathComponent("Contents/Resources/NativeHost/LinkDigestNativeHost-0.2.0-macos-arm64", isDirectory: true)
      .appendingPathComponent("LinkDigestNativeHost", isDirectory: false)
    try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: host.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = AppBundleLocator.resolveAppBundle(fromNativeHostExecutable: host)
    XCTAssertEqual(resolved?.standardizedFileURL, app.standardizedFileURL)
  }

  func testAppBundleLocatorHonorsEnvironmentOverride() {
    let host = URL(fileURLWithPath: "/tmp/not-inside-an-app/LinkDigestNativeHost")
    let override = URL(fileURLWithPath: "/Applications/LinkDigest.app", isDirectory: true)
    let resolved = AppBundleLocator.resolveAppBundle(
      fromNativeHostExecutable: host,
      environment: ["LINKDIGEST_APP_BUNDLE_PATH": override.path]
    )
    XCTAssertEqual(resolved?.path, override.path)
  }

  func testAppBundleLocatorRejectsNonAppOverride() {
    let host = URL(fileURLWithPath: "/tmp/x/LinkDigestNativeHost")
    let resolved = AppBundleLocator.resolveAppBundle(
      fromNativeHostExecutable: host,
      environment: ["LINKDIGEST_APP_BUNDLE_PATH": "/tmp/not-an-app"]
    )
    XCTAssertNil(resolved)
  }
}

/// accept 回调在后台队列上跑，计数要自己加锁。
private final class ConnectionSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var seen = 0
  var count: Int { lock.withLock { seen } }
  func record(_ handle: FileHandle) {
    lock.withLock { seen += 1 }
    try? handle.close()
  }
}
