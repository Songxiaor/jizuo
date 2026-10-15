import AppKit
import Foundation

/// 测速探针。只在测速构建里存在：`swift build -Xswiftc -DLINKDIGEST_PERF`，并且启动时
/// 设了 `LINKDIGEST_PERF_LOG=<日志文件>`。日用构建里下面每个函数都是空的，调用处编译后什么都不剩。
///
/// 记三类东西，全部按「1970 起的毫秒」落到同一个日志里，外部脚本按同一个时钟对齐：
/// - 里程碑（`mark`）：进程启动、App 初始化、库打开、第一页上屏、详情上屏……
/// - 主线程每一段连续占用（`busy`）：一次 RunLoop 从醒来到再睡下的时长，≥2ms 才记。
///   用户看到的「卡一下」「切过去慢」都落在这里。
/// - 场景脚本（`PerfScenario`）跑出来的每一步耗时，见那边。
#if LINKDIGEST_PERF
enum PerfProbe {
  static let logPath: String? = ProcessInfo.processInfo.environment["LINKDIGEST_PERF_LOG"]
  static var isEnabled: Bool { logPath != nil }

  /// 主线程占用 ≥ 这么多毫秒才写日志。滑动时每帧都在 1–3ms 上下，写下来才看得出分布。
  static let busyLogThresholdMilliseconds = 2.0

  private static let writer: PerfLogWriter? = logPath.map(PerfLogWriter.init(path:))
  nonisolated(unsafe) private static var activity: NSObjectProtocol?

  static func nowMilliseconds() -> Double { Date().timeIntervalSince1970 * 1_000 }

  /// 进程真正被拉起的时刻（内核记的），比 `main` 早：动态库加载、静态初始化都算在启动里。
  static let processStartMilliseconds: Double = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nowMilliseconds() }
    let start = info.kp_proc.p_un.__p_starttime
    return Double(start.tv_sec) * 1_000 + Double(start.tv_usec) / 1_000
  }()

  static func write(_ kind: String, _ detail: String) {
    writer?.append("\(String(format: "%.3f", nowMilliseconds()))\t\(kind)\t\(detail)")
  }

  static func write(at milliseconds: Double, _ kind: String, _ detail: String) {
    writer?.append("\(String(format: "%.3f", milliseconds))\t\(kind)\t\(detail)")
  }

  static func mark(_ name: @autoclosure () -> String) {
    guard writer != nil else { return }
    let text = name()
    write("mark", text)
    if Thread.isMainThread {
      MainActor.assumeIsolated { PerfRunLoopMonitor.shared.noteMark(text) }
    }
  }

  /// App.init 的第一行调用。
  @MainActor static func install() {
    guard writer != nil else { return }
    write(at: processStartMilliseconds, "mark", "process.start")
    mark("app.init.begin")
    // 测速时 App 多半不在前台：别让系统把它当后台程序降频（App Nap），否则数据没有意义。
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "LinkDigest performance measurement"
    )
    PerfRunLoopMonitor.shared.start()
  }
}

/// 主线程 RunLoop 的「醒着」时长。醒来记起点（排在所有观察者最前），睡前记终点（排在
/// 最后，Core Animation 提交之后），两者之差就是这一轮主线程连续干活的时间。
@MainActor
final class PerfRunLoopMonitor {
  static let shared = PerfRunLoopMonitor()

  private(set) var lastBusyEndMilliseconds: Double = 0
  private(set) var isBusy = true
  private var busyStart: Double = PerfProbe.processStartMilliseconds
  private var pendingMarks: [(name: String, time: Double)] = []
  /// 场景脚本读：每段 ≥ 阈值的占用（起点、时长）。
  private(set) var stretches: [(start: Double, duration: Double)] = []
  /// 场景脚本读：主线程上打的标记，以及它所在那一轮结束（画面提交）的时刻。
  private(set) var commits: [(name: String, markTime: Double, commitTime: Double)] = []
  private var observers: [CFRunLoopObserver] = []

  func start() {
    guard observers.isEmpty else { return }
    let wake = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
    ) { _, _ in
      MainActor.assumeIsolated { PerfRunLoopMonitor.shared.didWake() }
    }
    // 只看「睡下」不看「退出」：嵌套 RunLoop 退出后外层接着干活，那段也要算在占用里。
    let sleep = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
    ) { _, _ in
      MainActor.assumeIsolated { PerfRunLoopMonitor.shared.willSleep() }
    }
    for observer in [wake, sleep].compactMap({ $0 }) {
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      observers.append(observer)
    }
  }

  func noteMark(_ name: String) {
    pendingMarks.append((name, PerfProbe.nowMilliseconds()))
  }

  private func didWake() {
    guard !isBusy else { return }
    isBusy = true
    busyStart = PerfProbe.nowMilliseconds()
  }

  private func willSleep() {
    guard isBusy else { return }
    isBusy = false
    let end = PerfProbe.nowMilliseconds()
    let duration = end - busyStart
    lastBusyEndMilliseconds = end
    if duration >= PerfProbe.busyLogThresholdMilliseconds {
      stretches.append((busyStart, duration))
      PerfProbe.write(at: busyStart, "busy", String(format: "%.3f", duration))
    }
    if !pendingMarks.isEmpty {
      for mark in pendingMarks {
        commits.append((mark.name, mark.time, end))
        PerfProbe.write(at: end, "commit", mark.name)
      }
      pendingMarks.removeAll()
    }
  }

  /// 等主线程安静下来：最近一次占用结束后 `quiet` 内没有新的 ≥阈值 占用。返回最后那次占用结束的时刻。
  func waitForQuiet(
    quiet: Double = 300, timeout: Double = 15_000, after start: Double
  ) async -> Double {
    let deadline = start + timeout
    while true {
      try? await Task.sleep(for: .milliseconds(20))
      let now = PerfProbe.nowMilliseconds()
      let lastSignificant = stretches.last.map { $0.start + $0.duration } ?? start
      let settledAt = max(lastSignificant, start)
      if now - settledAt >= quiet { return settledAt }
      if now >= deadline { return now }
    }
  }

  /// 等某个标记（按前缀）在 `start` 之后打下并提交上屏，返回提交时刻；超时返回 nil。
  func waitForCommit(prefix: String, after start: Double, timeout: Double = 15_000) async -> Double? {
    let deadline = start + timeout
    while PerfProbe.nowMilliseconds() < deadline {
      if let hit = commits.last(where: { $0.markTime >= start && $0.name.hasPrefix(prefix) }) {
        return hit.commitTime
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  func stretches(from start: Double, to end: Double) -> [(start: Double, duration: Double)] {
    stretches.filter { $0.start >= start - 0.5 && $0.start <= end }
  }
}

/// 追加写日志。只有一把锁和一个文件句柄，任何线程都能调。
final class PerfLogWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle?

  init(path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
    handle = FileHandle(forWritingAtPath: path)
    handle?.seekToEndOfFile()
  }

  func append(_ line: String) {
    lock.lock(); defer { lock.unlock() }
    handle?.write(Data((line + "\n").utf8))
  }
}
#else
enum PerfProbe {
  @inline(__always) static func mark(_ name: @autoclosure () -> String) {}
  @inline(__always) static func install() {}
}
#endif
