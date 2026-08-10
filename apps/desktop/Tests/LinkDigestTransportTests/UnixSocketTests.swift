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
