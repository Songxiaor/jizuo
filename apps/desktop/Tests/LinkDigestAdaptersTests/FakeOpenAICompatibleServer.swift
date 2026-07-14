import Foundation
import Network

final class FakeOpenAICompatibleServer: @unchecked Sendable {
  struct ResponseScript: Sendable {
    struct Chunk: Sendable {
      let text: String
      let delay: TimeInterval

      init(_ text: String, delay: TimeInterval = 0) {
        self.text = text
        self.delay = delay
      }
    }

    let statusCode: Int
    let contentType: String
    let headers: [String: String]
    let chunks: [Chunk]
    let closesAbruptly: Bool

    init(
      statusCode: Int = 200,
      contentType: String = "text/event-stream",
      headers: [String: String] = [:],
      chunks: [Chunk] = [],
      closesAbruptly: Bool = false
    ) {
      self.statusCode = statusCode
      self.contentType = contentType
      self.headers = headers
      self.chunks = chunks
      self.closesAbruptly = closesAbruptly
    }
  }

  struct RecordedRequest: Sendable, CustomStringConvertible {
    let method: String
    let path: String
    let authorizationPresent: Bool
    let authorizationMatched: Bool
    let contentType: String?
    let accept: String?
    let body: String

    var description: String {
      let safeContentType = contentType ?? "nil"
      let safeAccept = accept ?? "nil"
      return "RecordedRequest(method: \(method), path: \(path), authorizationPresent: \(authorizationPresent), authorizationMatched: \(authorizationMatched), contentType: \(safeContentType), accept: \(safeAccept), body: \(body))"
    }
  }

  private let queue = DispatchQueue(label: "com.syc.linkdigest.fake-openai-server")
  private let lock = NSLock()
  private let expectedAuthorization: String
  private var scripts: [ResponseScript]
  private var recordedRequests: [RecordedRequest] = []
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var listener: NWListener?
  private var readyPort: NWEndpoint.Port?
  private var startupFailed = false

  init(expectedAPIKey: String, scripts: [ResponseScript]) {
    self.expectedAuthorization = "Bearer \(expectedAPIKey)"
    self.scripts = scripts
  }

  var attemptCount: Int {
    lock.withLock { recordedRequests.count }
  }

  var requests: [RecordedRequest] {
    lock.withLock { recordedRequests }
  }

  func start() throws -> URL {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.lock.withLock {
          self?.readyPort = listener.port
        }
        ready.signal()
      case .failed:
        self?.lock.withLock {
          self?.startupFailed = true
        }
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)

    guard ready.wait(timeout: .now() + 5) == .success else {
      listener.cancel()
      throw FakeServerError.startTimedOut
    }
    if lock.withLock({ startupFailed }) {
      listener.cancel()
      throw FakeServerError.startFailed
    }
    guard let port = lock.withLock({ readyPort }) else {
      listener.cancel()
      throw FakeServerError.startFailed
    }
    return URL(string: "http://127.0.0.1:\(port.rawValue)")!
  }

  func stop() {
    listener?.cancel()
    let currentConnections = lock.withLock { () -> [NWConnection] in
      let values = Array(connections.values)
      connections.removeAll()
      return values
    }
    currentConnections.forEach { $0.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    let identifier = ObjectIdentifier(connection)
    lock.withLock {
      connections[identifier] = connection
    }
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        _ = self?.lock.withLock {
          self?.connections.removeValue(forKey: identifier)
        }
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveRequest(on: connection, accumulated: Data())
  }

  private func receiveRequest(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var requestData = accumulated
      if let data { requestData.append(data) }

      if let parsed = self.parseCompleteRequest(requestData) {
        let script = self.record(parsed)
        self.send(script: script, on: connection)
        return
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      self.receiveRequest(on: connection, accumulated: requestData)
    }
  }

  private func parseCompleteRequest(_ data: Data) -> ParsedRequest? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator) else { return nil }
    let headerData = data[..<headerRange.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard requestParts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    let body = data[bodyStart..<(bodyStart + contentLength)]
    return ParsedRequest(
      method: requestParts[0],
      path: requestParts[1],
      headers: headers,
      body: String(data: body, encoding: .utf8) ?? ""
    )
  }

  private func record(_ request: ParsedRequest) -> ResponseScript {
    lock.withLock {
      let authorization = request.headers["authorization"]
      recordedRequests.append(RecordedRequest(
        method: request.method,
        path: request.path,
        authorizationPresent: authorization != nil,
        authorizationMatched: authorization == expectedAuthorization,
        contentType: request.headers["content-type"],
        accept: request.headers["accept"],
        body: request.body
      ))
      if scripts.count > 1 {
        return scripts.removeFirst()
      }
      return scripts.first ?? ResponseScript(statusCode: 500)
    }
  }

  private func send(script: ResponseScript, on connection: NWConnection) {
    var headerLines = [
      "HTTP/1.1 \(script.statusCode) \(reasonPhrase(for: script.statusCode))",
      "Content-Type: \(script.contentType)",
      "Transfer-Encoding: chunked",
      "Connection: close"
    ]
    headerLines.append(contentsOf: script.headers.map { "\($0.key): \($0.value)" })
    let header = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    connection.send(content: header, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        return
      }
      self.sendChunk(at: 0, script: script, on: connection)
    })
  }

  private func sendChunk(at index: Int, script: ResponseScript, on connection: NWConnection) {
    guard index < script.chunks.count else {
      if script.closesAbruptly {
        connection.cancel()
      } else {
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in
          connection.cancel()
        })
      }
      return
    }

    let chunk = script.chunks[index]
    queue.asyncAfter(deadline: .now() + chunk.delay) { [weak self] in
      guard let self else { return }
      let data = Data(chunk.text.utf8)
      let framed = Data("\(String(data.count, radix: 16))\r\n".utf8)
        + data
        + Data("\r\n".utf8)
      connection.send(content: framed, completion: .contentProcessed { error in
        if error != nil {
          connection.cancel()
          return
        }
        self.sendChunk(at: index + 1, script: script, on: connection)
      })
    }
  }

  private func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    case 503: "Service Unavailable"
    default: "Response"
    }
  }

  private struct ParsedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: String
  }

  private enum FakeServerError: Error {
    case startTimedOut
    case startFailed
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
