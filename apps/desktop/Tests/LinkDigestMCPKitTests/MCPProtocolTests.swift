import XCTest
import Foundation
@testable import LinkDigestMCPKit

final class MCPProtocolTests: XCTestCase {
  private func request(_ method: String, params: [String: Any] = [:], id: Any = 1) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
  }
  private func decode(_ data: Data?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
  }
  private func initialize(_ server: inout MCPProtocol) throws {
    _ = server.respond(try request("initialize", params: ["protocolVersion": "2025-11-25", "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]])) { _ in XCTFail("Initialize must not access app data"); return Data() }
  }
  func testLifecycleAndToolDiscoveryDoNotReadTheLibrary() throws {
    var server = MCPProtocol()
    let before = try decode(server.respond(request("tools/list")) { _ in XCTFail(); return Data() })
    XCTAssertNotNil(before["error"])
    try initialize(&server)
    let response = try decode(server.respond(request("tools/list")) { _ in XCTFail(); return Data() })
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
    XCTAssertTrue(tools.contains { $0["name"] as? String == "jizuo_discover_creator" })
    XCTAssertTrue(tools.contains { $0["name"] as? String == "jizuo_transcribe" })
    XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").contains("delete") })
    XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, tools.count)
  }
  func testValidCallForwardsOnlyToolArgumentsAndPreservesStringID() throws {
    var server = MCPProtocol(); try initialize(&server)
    let response = try decode(server.respond(request("tools/call", params: ["name": "jizuo_status", "arguments": [:]], id: "abc")) { data in
      let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      XCTAssertEqual(params["name"] as? String, "jizuo_status")
      return Data("{\"connected\":true}".utf8)
    })
    XCTAssertEqual(response["id"] as? String, "abc")
    XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
  }
  func testInvalidArgumentsCannotReachApplication() throws {
    let bad: [[String: Any]] = [
      ["name": "jizuo_add_links", "arguments": ["urls": []]],
      ["name": "jizuo_add_links", "arguments": ["urls": ["https://example.org"], "download_video": "true"]],
      ["name": "jizuo_discover_creator", "arguments": ["url": "https://www.douyin.com/user/test", "limit": 100000]],
      ["name": "jizuo_search", "arguments": ["limit": true]],
      ["name": "jizuo_search", "arguments": ["limit": 1.2]],
      ["name": "jizuo_status", "arguments": ["shell": "anything"]],
      ["name": "jizuo_delete", "arguments": [:]],
      ["name": "jizuo_read", "arguments": [:]]
    ]
    for params in bad {
      var server = MCPProtocol(); try initialize(&server)
      let response = try decode(server.respond(request("tools/call", params: params)) { _ in XCTFail("Invalid call dispatched"); return Data() })
      XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
  }
  /// 合集（2026-09-29）：新增只读工具 jizuo_collections，jizuo_search 多一个可选的 collection。
  func testCollectionToolIsListedReadOnlyAndArgumentsAreValidated() throws {
    let tools = MCPTools.definitions
    let collections = try XCTUnwrap(tools.first { $0["name"] as? String == "jizuo_collections" })
    XCTAssertEqual((collections["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    let search = try XCTUnwrap(tools.first { $0["name"] as? String == "jizuo_search" })
    let schema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
    XCTAssertNotNil((schema["properties"] as? [String: Any])?["collection"])
    XCTAssertEqual(schema["required"] as? [String], [], "collection 是可选参数，不带它的调用照旧")
    XCTAssertNoThrow(try MCPTools.validate(name: "jizuo_search", arguments: ["collection": "Claude Code 教程", "limit": 5]))
    XCTAssertNoThrow(try MCPTools.validate(name: "jizuo_collections", arguments: [:]))
    XCTAssertThrowsError(try MCPTools.validate(name: "jizuo_search", arguments: ["collection": 3]))
    XCTAssertThrowsError(try MCPTools.validate(name: "jizuo_search", arguments: ["collection": ""]))
    XCTAssertThrowsError(try MCPTools.validate(name: "jizuo_collections", arguments: ["collection": "x"]))
  }
  func testUnavailableAppIsNotReportedAsSuccess() throws {
    var server = MCPProtocol(); try initialize(&server)
    let response = try decode(server.respond(request("tools/call", params: ["name": "jizuo_status"])) { _ in throw CocoaError(.fileNoSuchFile) })
    XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
  }
  func testAppPermissionDenialIsToolError() throws {
    var server = MCPProtocol(); try initialize(&server)
    let response = try decode(server.respond(request("tools/call", params: ["name": "jizuo_status"])) { _ in Data("{\"error\":\"disabled\"}".utf8) })
    XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
  }
  func testMalformedMessagesAndNotifications() throws {
    var server = MCPProtocol()
    XCTAssertNotNil(try decode(server.respond(Data("{".utf8)) { _ in Data() })["error"])
    XCTAssertNil(server.respond(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)) { _ in Data() })
    XCTAssertNotNil(try decode(server.respond(request("unknown")) { _ in Data() })["error"])
  }
  func testConfigUsesExactRelocatedAppPathWithoutShellEscapes() throws {
    let path = "/Applications/我的 App \"test\".app/Contents/MacOS/LinkDigestMCP"
    let config = try JSONSerialization.jsonObject(with: Data(MCPConfiguration.connectionJSON(executable: path).utf8)) as! [String: Any]
    let servers = config["mcpServers"] as! [String: [String: Any]]
    XCTAssertEqual(servers["jizuo"]?["command"] as? String, path)
    XCTAssertEqual(servers["jizuo"]?["args"] as? [String], [])
  }
}
