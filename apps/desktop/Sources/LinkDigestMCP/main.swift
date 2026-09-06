import Foundation
import LinkDigestMCPKit
import LinkDigestTransport
import Darwin

signal(SIGPIPE, SIG_IGN)
var server = MCPProtocol()
while let line = readLine() {
  guard let response = server.respond(Data(line.utf8), invoke: { request in
    try UnixSocketClient.send(request, path: MCPConfiguration.socketPath, timeout: 15)
  }) else { continue }
  do {
    try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
  } catch { break }
}
