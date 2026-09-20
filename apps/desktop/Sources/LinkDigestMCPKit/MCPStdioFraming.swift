import Darwin
import Foundation

/// MCP / LSP stdio framing: `Content-Length: N\\r\\n\\r\\n` then N bytes of JSON.
public enum MCPStdioFraming {
  public static let maxMessageBytes = 1_048_576

  public static func encode(_ body: Data) -> Data {
    Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
  }

  /// Reads one framed message from stdin. Returns nil on EOF before any bytes.
  public static func readMessage(from handle: FileHandle) throws -> Data? {
    guard let header = try readHeaders(from: handle) else { return nil }
    guard let length = contentLength(in: header) else {
      throw MCPFailure("invalid_framing", "缺少 Content-Length")
    }
    guard length > 0, length <= maxMessageBytes else {
      throw MCPFailure("invalid_framing", "消息过大")
    }
    return try readExactly(length, from: handle)
  }

  private static func contentLength(in header: String) -> Int? {
    for line in header.split(whereSeparator: { $0 == "\n" }) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = trimmed.lowercased()
      guard lower.hasPrefix("content-length:") else { continue }
      let value = trimmed.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
      return Int(value)
    }
    return nil
  }

  private static func readHeaders(from handle: FileHandle) throws -> String? {
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    while buffer.count < 8_192 {
      let byte = try readExactly(1, from: handle, allowEOF: buffer.isEmpty)
      if byte.isEmpty { return nil }
      buffer.append(byte)
      if buffer.count >= 4, buffer.suffix(4) == separator {
        return String(data: buffer, encoding: .utf8)
      }
    }
    throw MCPFailure("invalid_framing", "协议头过长")
  }

  private static func readExactly(_ count: Int, from handle: FileHandle, allowEOF: Bool = false) throws -> Data {
    var result = Data()
    while result.count < count {
      let remaining = count - result.count
      var buffer = [UInt8](repeating: 0, count: remaining)
      let n = Darwin.read(handle.fileDescriptor, &buffer, remaining)
      if n == 0 {
        if allowEOF, result.isEmpty { return Data() }
        throw MCPFailure("invalid_framing", "消息不完整")
      }
      if n < 0 {
        throw MCPFailure("invalid_framing", "读取失败")
      }
      result.append(contentsOf: buffer.prefix(n))
    }
    return result
  }
}
