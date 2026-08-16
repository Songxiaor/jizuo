import Foundation

// 临时诊断：验证完整体撤除
//
// 假设：阅读面板从 1 个挂到 3 个后，全文档 intrinsicContentSize / setFrameSize
// 的次数和耗时会成倍升高。本探针只读、只计数，不改任何布局或返回值。
//
// 为什么写文件而不是 NSLog：汲作用 `open` 启动时 stderr 没有去处，NSLog
// 也不落进统一日志——打了等于没打。写盘模式照抄 ProviderTimingLog。
//
// 探针本身不能成为新的性能问题：调用只在内存里累加，最多每秒写一行汇总。

enum ReadingLayoutProbe {
  /// 文件上限。超了就从头写，避免长期使用堆成一个没人清理的大文件。
  private static let byteLimit = 256 * 1_024

  private static let lock = NSLock()
  private static let writeQueue = DispatchQueue(label: "linkdigest.reading-layout-probe")

  /// 只在 `lock` 里碰它；`ISO8601DateFormatter` 本身不是 Sendable。
  private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let fileURL: URL? = {
    guard let root = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    ) else { return nil }
    return root.appendingPathComponent("LinkDigest/reading-layout-probe.log")
  }()

  private nonisolated(unsafe) static var mountedPaneCount = 1
  private nonisolated(unsafe) static var intrinsicCount = 0
  private nonisolated(unsafe) static var intrinsicMs = 0.0
  private nonisolated(unsafe) static var setFrameCount = 0
  private nonisolated(unsafe) static var lastFlush: CFAbsoluteTime = 0
  private nonisolated(unsafe) static var trailingFlushScheduled = false

  /// 详情页上报当前实际挂载的阅读面板数（visited ∪ {effective}）。
  static func setMountedPaneCount(_ count: Int) {
    lock.lock()
    mountedPaneCount = max(0, count)
    lock.unlock()
  }

  /// `usedRect` 前后用 `CFAbsoluteTimeGetCurrent()` 包住后传入秒数。
  static func recordIntrinsic(duration: CFAbsoluteTime) {
    lock.lock()
    intrinsicCount += 1
    intrinsicMs += duration * 1_000
    scheduleOrFlushLocked()
    lock.unlock()
  }

  static func recordSetFrameSize() {
    lock.lock()
    setFrameCount += 1
    scheduleOrFlushLocked()
    lock.unlock()
  }

  private static func scheduleOrFlushLocked() {
    let now = CFAbsoluteTimeGetCurrent()
    if lastFlush == 0 || now - lastFlush >= 1 {
      flushLocked(now: now)
      return
    }
    guard !trailingFlushScheduled else { return }
    trailingFlushScheduled = true
    writeQueue.asyncAfter(deadline: .now() + 1) {
      lock.lock()
      trailingFlushScheduled = false
      if intrinsicCount > 0 || setFrameCount > 0 {
        flushLocked(now: CFAbsoluteTimeGetCurrent())
      }
      lock.unlock()
    }
  }

  private static func flushLocked(now: CFAbsoluteTime) {
    lastFlush = now
    let line = [
      "mounted_panes=\(mountedPaneCount)",
      "intrinsic_count=\(intrinsicCount)",
      String(format: "intrinsic_ms=%.1f", intrinsicMs),
      "set_frame_count=\(setFrameCount)",
    ].joined(separator: " ")
    intrinsicCount = 0
    intrinsicMs = 0
    setFrameCount = 0
    writeQueue.async { write(line) }
  }

  private static func write(_ line: String) {
    guard let fileURL else { return }
    let now = Date()
    lock.withLock {
      guard let data = "\(formatter.string(from: now)) \(line)\n".data(using: .utf8) else { return }
      let existing = (try? FileHandle(forWritingTo: fileURL)).flatMap { handle -> UInt64? in
        defer { try? handle.close() }
        return try? handle.seekToEnd()
      }
      guard let existing, existing < UInt64(byteLimit),
            let handle = try? FileHandle(forWritingTo: fileURL)
      else {
        try? data.write(to: fileURL)
        return
      }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
