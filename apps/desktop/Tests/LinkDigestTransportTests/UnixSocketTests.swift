import XCTest
@testable import LinkDigestTransport

final class UnixSocketTests: XCTestCase {
  func testClientReportsOfflineSocket() {
    let path = "/tmp/linkdigest-offline-\(UUID().uuidString).sock"
    XCTAssertThrowsError(try UnixSocketClient.send(Data("{}".utf8), path: path, timeout: 0.1))
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
}
