import Darwin
import Foundation

public enum FramingError: Error { case zeroLength, tooLarge, truncated, timeout, invalidJSON }

public struct ChromiumFramer: Sendable {
  public static let maxFrameBytes = 4 * 1024 * 1024

  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maxFrameBytes else { throw FramingError.tooLarge }
    var result = Data()
    var length = UInt32(body.count).littleEndian
    result.append(Data(bytes: &length, count: 4))
    result.append(body)
    return result
  }

  public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
    guard data.count >= 4 else { throw FramingError.truncated }
    let length = decodeLength(Data(data.prefix(4)))
    guard length > 0 else { throw FramingError.zeroLength }
    guard length <= maxFrameBytes else { throw FramingError.tooLarge }
    guard data.count >= Int(length) + 4 else { throw FramingError.truncated }
    do {
      return try JSONDecoder().decode(T.self, from: data.subdata(in: 4..<(4 + Int(length))))
    } catch {
      throw FramingError.invalidJSON
    }
  }

  public static func readFrame(from handle: FileHandle, timeout: TimeInterval? = nil) throws -> Data {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    let header = try readExactly(4, from: handle, deadline: deadline)
    let length = decodeLength(header)
    guard length > 0 else { throw FramingError.zeroLength }
    guard length <= maxFrameBytes else { throw FramingError.tooLarge }
    return try readExactly(Int(length), from: handle, deadline: deadline)
  }

  public static func writeFrame(_ body: Data, to handle: FileHandle) throws {
    guard !body.isEmpty else { throw FramingError.zeroLength }
    guard body.count <= maxFrameBytes else { throw FramingError.tooLarge }
    var length = UInt32(body.count).littleEndian
    try handle.write(contentsOf: Data(bytes: &length, count: 4))
    try handle.write(contentsOf: body)
  }

  private static func decodeLength(_ header: Data) -> UInt32 {
    header.enumerated().reduce(0) { partial, element in
      partial | (UInt32(element.element) << UInt32(element.offset * 8))
    }
  }

  private static func readExactly(_ count: Int, from handle: FileHandle, deadline: Date?) throws -> Data {
    var result = Data()
    while result.count < count {
      if let deadline {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw FramingError.timeout }
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000, Double(Int32.max))))
        guard ready > 0 else {
          if ready == 0 { throw FramingError.timeout }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
      let remaining = count - result.count
      var buffer = [UInt8](repeating: 0, count: remaining)
      let bytesRead = Darwin.read(handle.fileDescriptor, &buffer, remaining)
      if bytesRead == 0 { throw FramingError.truncated }
      if bytesRead < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { throw FramingError.timeout }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      result.append(contentsOf: buffer.prefix(bytesRead))
    }
    return result
  }
}
