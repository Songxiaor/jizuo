import Foundation

enum FFmpegProcessError: Error, Equatable {
  case launchFailed
  case logUnavailable
}

private final class ResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !done else { return false }
    done = true
    return true
  }
}

/// 跑一个 ffmpeg 子进程，直到它退出。只做这件事：不解释退出码，也不重试。
///
/// 输出重定向到日志文件而不是 Pipe：Pipe 写满 64 KB 后子进程会卡在写 stderr，
/// 表现为「录制无缘无故停住」。
final class FFmpegProcessRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var logHandle: FileHandle?
  /// 子进程启动后回调 pid。诊断与端到端测试用它模拟一次断线（SIGTERM）。
  var onLaunch: (@Sendable (Int32) -> Void)?

  var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return process?.isRunning == true
  }

  var currentPID: Int32? {
    lock.withLock {
      guard let process, process.isRunning else { return nil }
      return process.processIdentifier
    }
  }

  /// `logURL` 为 nil 时 stderr 直接丢弃。录制一律传 nil：ffmpeg 的报错会带上
  /// 限时签名地址，不能落盘。
  func run(executable: URL, arguments: [String], logURL: URL? = nil) async throws -> Int32 {
    let logHandle: FileHandle?
    if let logURL {
      do {
        if !FileManager.default.fileExists(atPath: logURL.path) {
          FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        logHandle = handle
      } catch {
        throw FFmpegProcessError.logUnavailable
      }
    } else {
      logHandle = nil
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = logHandle ?? FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    lock.withLock {
      self.process = process
      self.logHandle = logHandle
    }

    defer { try? logHandle?.close() }
    return try await withCheckedThrowingContinuation { continuation in
      let gate = ResumeGate()
      process.terminationHandler = { finished in
        guard gate.claim() else { return }
        continuation.resume(returning: finished.terminationStatus)
      }
      do {
        try process.run()
        onLaunch?(process.processIdentifier)
      } catch {
        guard gate.claim() else { return }
        continuation.resume(throwing: FFmpegProcessError.launchFailed)
      }
    }
  }

  /// 先 SIGTERM，让 ffmpeg 把文件尾写完；1.5 秒后还活着再 SIGKILL。
  func terminate() {
    let process = lock.withLock { self.process }
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
      // 进程在 1.5 秒内已经退出时不要再 kill：那个 pid 可能已被系统复用给别的进程。
      // 只认同一个 runner 上仍在跑的那个 pid，避免误杀后来启动的新进程。
      guard let self, self.currentPID == pid else { return }
      kill(pid, SIGKILL)
    }
  }

  /// 退出路径用：同步等在界内，到点还没退就 SIGKILL。总等待由调用方给。
  func terminateAndWait(timeout: TimeInterval) {
    let process = lock.withLock { self.process }
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while Date() < deadline, process.isRunning {
      usleep(50_000)
    }
    if process.isRunning {
      kill(pid, SIGKILL)
    }
  }

  func forceKill() {
    guard let pid = currentPID else { return }
    kill(pid, SIGKILL)
  }
}
