import Foundation
import LinkDigestMCPKit
import LinkDigestTransport
import Darwin

signal(SIGPIPE, SIG_IGN)
var server = MCPProtocol()
let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput
while true {
  let body: Data
  do {
    guard let message = try MCPStdioFraming.readMessage(from: stdin) else { break }
    body = message
  } catch {
    let encoded = try? JSONSerialization.data(
      withJSONObject: ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid framing"]],
      options: [.sortedKeys]
    )
    if let encoded {
      try? stdout.write(contentsOf: MCPStdioFraming.encode(encoded))
    }
    break
  }
  guard let response = server.respond(body, invoke: { request in
    try UnixSocketClient.send(request, path: MCPConfiguration.socketPath, timeout: 15)
  }) else { continue }
  do {
    try stdout.write(contentsOf: MCPStdioFraming.encode(response))
  } catch { break }
}
