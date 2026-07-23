import Foundation
import Darwin

public final class UnixSocketServer: @unchecked Sendable {
  public let path: String
  private let lock = NSLock()
  private var fd: Int32 = -1

  public init(path: String) { self.path = path }

  public func start() throws {
    guard lock.withLock({ fd < 0 }) else { throw POSIXError(.EALREADY) }
    let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
    guard candidate >= 0 else { throw POSIXError(.EIO) }
    var didStart = false
    defer {
      if !didStart {
        close(candidate)
        unlink(path)
      }
    }
    unlink(path)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    path.withCString { ptr in
      withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: UnsafeRawBufferPointer(start: ptr, count: min(path.utf8.count, raw.count - 1)))
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(candidate, $0, len) }
    }
    guard result == 0, listen(candidate, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
    chmod(path, 0o600)
    lock.withLock { fd = candidate }
    didStart = true
  }

  public func accept(timeout: TimeInterval = 10, ioTimeout: TimeInterval = 10) throws -> FileHandle {
    let listeningFD = lock.withLock { fd }
    guard listeningFD >= 0 else { throw POSIXError(.EBADF) }
    var pollfd = Darwin.pollfd(fd: listeningFD, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&pollfd, 1, Int32(timeout * 1_000)) > 0 else { throw POSIXError(.ETIMEDOUT) }
    let client = Darwin.accept(listeningFD, nil, nil)
    guard client >= 0 else { throw POSIXError(.EIO) }
    applyTimeout(client, ioTimeout)
    return FileHandle(fileDescriptor: client, closeOnDealloc: true)
  }

  /// Idempotently closes this server and removes only its exact socket node.
  public func stop() {
    let listeningFD = lock.withLock { () -> Int32 in
      let current = fd
      fd = -1
      return current
    }
    if listeningFD >= 0 {
      shutdown(listeningFD, SHUT_RDWR)
      close(listeningFD)
    }
    unlink(path)
  }

  deinit { stop() }
}

public enum UnixSocketClient {
  /// Probe whether the app's capture socket is accepting connections.
  public static func canConnect(path: String, timeout: TimeInterval = 0.25) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    applyTimeout(fd, timeout)
    return connectUnix(fd, path: path) == 0
  }

  public static func send(_ data: Data, path: String, timeout: TimeInterval = 10) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    applyTimeout(fd, timeout)
    let connected = connectUnix(fd, path: path)
    guard connected == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    try ChromiumFramer.writeFrame(data, to: handle)
    return try ChromiumFramer.readFrame(from: handle, timeout: timeout)
  }
}

private func applyTimeout(_ fd: Int32, _ timeout: TimeInterval) {
  let wholeSeconds = Int(timeout)
  var timeValue = timeval(
    tv_sec: wholeSeconds,
    tv_usec: Int32((timeout - Double(wholeSeconds)) * 1_000_000)
  )
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
}

private func connectUnix(_ fd: Int32, path: String) -> Int32 {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  path.withCString { ptr in
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: UnsafeRawBufferPointer(start: ptr, count: min(path.utf8.count, raw.count - 1)))
    }
  }
  return withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}
