import Foundation
import Darwin

public final class UnixSocketServer: @unchecked Sendable {
  public let path: String
  private let lock = NSLock()
  private var fd: Int32 = -1
  private var ownershipFD: Int32 = -1
  private var publishedIdentity: SocketNodeIdentity?

  public init(path: String) { self.path = path }

  public func start() throws {
    guard lock.withLock({ fd < 0 && ownershipFD < 0 }) else { throw POSIXError(.EALREADY) }

    // A pathname Unix socket can be unlinked while its original server keeps
    // listening. Without a separate lifetime lock, a second App instance can
    // therefore delete the live path, bind its own node, then remove that node
    // on exit — leaving the first App alive but permanently unreachable.
    let ownershipPath = path + ".lock"
    let candidateOwnershipFD = open(
      ownershipPath,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard candidateOwnershipFD >= 0 else { throw currentPOSIXError() }
    guard flock(candidateOwnershipFD, LOCK_EX | LOCK_NB) == 0 else {
      close(candidateOwnershipFD)
      throw POSIXError(.EADDRINUSE)
    }

    let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
    guard candidate >= 0 else {
      let failure = currentPOSIXError()
      flock(candidateOwnershipFD, LOCK_UN)
      close(candidateOwnershipFD)
      throw failure
    }
    var didStart = false
    var candidateIdentity: SocketNodeIdentity?
    defer {
      if !didStart {
        close(candidate)
        unlink(path, ifMatching: candidateIdentity)
        flock(candidateOwnershipFD, LOCK_UN)
        close(candidateOwnershipFD)
      }
    }
    if unlink(path) != 0, errno != ENOENT { throw currentPOSIXError() }
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
    guard let identity = socketNodeIdentity(at: path) else { throw POSIXError(.EIO) }
    candidateIdentity = identity
    lock.withLock {
      fd = candidate
      ownershipFD = candidateOwnershipFD
      publishedIdentity = identity
    }
    didStart = true
  }

  /// Whether this server still owns the filesystem node clients connect to.
  /// The listening file descriptor alone is insufficient: an unlinked server
  /// continues to appear in `lsof` but new clients receive ENOENT.
  public func isPublishedAtPath() -> Bool {
    let owned = lock.withLock { (fd, publishedIdentity) }
    guard owned.0 >= 0, let identity = owned.1 else { return false }
    return socketNodeIdentity(at: path) == identity
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
    let owned = lock.withLock { () -> (Int32, Int32, SocketNodeIdentity?) in
      let current = (fd, ownershipFD, publishedIdentity)
      fd = -1
      ownershipFD = -1
      publishedIdentity = nil
      return current
    }
    if owned.0 >= 0 {
      shutdown(owned.0, SHUT_RDWR)
      close(owned.0)
    }
    unlink(path, ifMatching: owned.2)
    if owned.1 >= 0 {
      flock(owned.1, LOCK_UN)
      close(owned.1)
    }
  }

  deinit { stop() }
}

private struct SocketNodeIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
}

private func socketNodeIdentity(at path: String) -> SocketNodeIdentity? {
  var value = stat()
  guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFSOCK else { return nil }
  return .init(device: value.st_dev, inode: value.st_ino)
}

private func unlink(_ path: String, ifMatching identity: SocketNodeIdentity?) {
  guard let identity, socketNodeIdentity(at: path) == identity else { return }
  Darwin.unlink(path)
}

private func currentPOSIXError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
