#if LINKDIGEST_PERF
import AppKit
import Foundation
import LinkDigestCore
import QuartzCore

/// 测速场景：启动后自己点一遍常用路径，每一步记「内容上屏」和「主线程安静下来」两个时刻。
///
/// 只在测速构建里存在（`-DLINKDIGEST_PERF`），并且要设 `LINKDIGEST_PERF_SCENARIO=full`。
/// 直接调用户点击时调的那些方法（选侧栏、选一条、开设置），滑动用合成的触控板事件喂给
/// 列表和阅读区自己的滚动视图——不碰鼠标键盘，用户在用电脑也不受影响。
///
/// 每一步的结果写成一行 `result\t{json}`，外部脚本汇总多次启动的中位数。
@MainActor
enum PerfScenario {
  private static var started = false

  static func startIfRequested(historyModel: HistoryViewModel) {
    guard PerfProbe.isEnabled, !started else { return }
    let environment = ProcessInfo.processInfo.environment
    guard let scenario = environment["LINKDIGEST_PERF_SCENARIO"] else { return }
    started = true
    Task { @MainActor in
      await run(scenario: scenario, model: historyModel, environment: environment)
      PerfProbe.mark("scenario.done")
      if environment["LINKDIGEST_PERF_EXIT"] == "1" {
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
      }
    }
  }

  private static var monitor: PerfRunLoopMonitor { .shared }

  // MARK: - 场景

  private static func run(scenario: String, model: HistoryViewModel, environment: [String: String]) async {
    await measureLaunch()
    if scenario.hasPrefix("profile-") {
      await profileLoop(scenario, model: model, environment: environment)
      return
    }
    guard scenario == "full" else { return }

    // 打开：最新几条（刚抓的）。
    for (index, row) in model.rows.prefix(4).enumerated() where index > 0 {
      await measureDetail("open.recent.\(index)", taskID: row.taskID, model: model)
    }
    // 打开：旧内容（外部按库里实际数据挑好传进来，label=uuid,...）。
    for (label, taskID) in parseTasks(environment["LINKDIGEST_PERF_TASKS"]) {
      await measureDetail("open.old.\(label)", taskID: taskID, model: model)
    }
    // 再开一次同一批旧内容：第二次打开（本次运行内已开过）。
    for (label, taskID) in parseTasks(environment["LINKDIGEST_PERF_TASKS"]).prefix(3) {
      await measureDetail("reopen.old.\(label)", taskID: taskID, model: model)
    }

    // 切屏：侧栏常用入口。
    let scopes: [(String, HistoryListScope)] = [
      ("favorite", .favorite), ("unsummarized", .unsummarized), ("untranscribed", .untranscribed),
      ("notes", .notes), ("external", .external), ("own", .own), ("trash", .trash), ("all", .all),
    ]
    for (label, scope) in scopes {
      await measureStep("screen.scope.\(label)", readyPrefix: "list.applied") {
        model.selectScope(scope)
      }
    }
    for platform in model.navigationCounts.externalPlatforms.prefix(4) {
      await measureStep("screen.platform.\(platform.host)", readyPrefix: "list.applied") {
        model.selectHost(platform.host, scope: .external)
      }
    }
    if let tag = model.availableTags.first {
      await measureStep("screen.tag", readyPrefix: "list.applied") {
        model.toggleTag(tag, additive: false)
      }
    }
    if let collection = model.collections.first {
      await measureStep("screen.collection", readyPrefix: "list.applied") {
        model.selectCollection(collection.id)
      }
    }
    await measureStep("screen.creators", readyPrefix: nil) {
      model.enterCreatorDirectory()
    }
    await measureStep("screen.workbench", readyPrefix: nil) {
      model.enterWorkbench()
    }
    await measureStep("screen.back-to-all", readyPrefix: "list.applied") {
      model.selectScope(.all)
    }
    let windowsBeforeSettings = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    await measureStep("screen.settings", readyPrefix: nil) {
      // 和用户按 ⌘, 走同一个菜单项。
      if let item = settingsMenuItem(in: NSApp.mainMenu), let menu = item.menu {
        menu.performActionForItem(at: menu.index(of: item))
      } else {
        PerfProbe.write("error", "settings menu item not found")
      }
    }
    for window in NSApp.windows where window.isVisible && !windowsBeforeSettings.contains(ObjectIdentifier(window)) {
      window.performClose(nil)
    }
    _ = await monitor.waitForQuiet(quiet: 500, after: PerfProbe.nowMilliseconds())

    // 滑动：中间列表，往下滑 6 秒（会顺带翻好几页旧内容）。
    if let first = model.rows.first {
      await measureDetail("open.list-top", taskID: first.taskID, model: model)
    }
    await measureScroll("scroll.list", target: .list, pointsPerSecond: 2_800, seconds: 6)

    // 滑动：阅读区，长文章。
    if let reading = parseTasks(environment["LINKDIGEST_PERF_READING_TASK"]).first {
      await measureDetail("open.reading.\(reading.label)", taskID: reading.taskID, model: model)
      await measureScroll("scroll.reading.\(reading.label)", target: .reading, pointsPerSecond: 2_000, seconds: 5)
    }
    if let transcript = parseTasks(environment["LINKDIGEST_PERF_TRANSCRIPT_TASK"]).first {
      await measureDetail("open.reading.\(transcript.label)", taskID: transcript.taskID, model: model)
      await measureScroll("scroll.reading.\(transcript.label)", target: .reading, pointsPerSecond: 2_000, seconds: 5)
    }
  }

  /// 给采样用：同一类动作连做 `LINKDIGEST_PERF_PROFILE_SECONDS`（默认 20）秒，外面用 `sample` 抓调用栈。
  private static func profileLoop(_ scenario: String, model: HistoryViewModel, environment: [String: String]) async {
    let seconds = Double(environment["LINKDIGEST_PERF_PROFILE_SECONDS"] ?? "") ?? 20
    let tasks = parseTasks(environment["LINKDIGEST_PERF_TASKS"])
    PerfProbe.mark("profile.begin \(scenario)")
    let deadline = PerfProbe.nowMilliseconds() + seconds * 1_000
    var index = 0
    switch scenario {
    case "profile-detail":
      while PerfProbe.nowMilliseconds() < deadline, !tasks.isEmpty {
        let task = tasks[index % tasks.count]
        await measureDetail("profile.open.\(task.label)", taskID: task.taskID, model: model)
        index += 1
      }
    case "profile-screens":
      let scopes: [HistoryListScope] = [.favorite, .unsummarized, .notes, .external, .own, .all]
      while PerfProbe.nowMilliseconds() < deadline {
        let scope = scopes[index % scopes.count]
        await measureStep("profile.screen.\(scope.rawValue)", readyPrefix: "list.applied") { model.selectScope(scope) }
        index += 1
      }
    case "profile-reading":
      // 每次都换一篇、从头往下滑：用户第一次读一篇时的那种滑动（排版是头一回做）。
      let readings = parseTasks(environment["LINKDIGEST_PERF_PROFILE_READING"] ?? environment["LINKDIGEST_PERF_READING_TASK"])
      while PerfProbe.nowMilliseconds() < deadline, !readings.isEmpty {
        let reading = readings[index % readings.count]
        await measureDetail("open.reading.\(reading.label)", taskID: reading.taskID, model: model)
        await measureScroll("profile.scroll.reading.\(reading.label)", target: .reading, pointsPerSecond: 2_000, seconds: 3)
        index += 1
      }
    case "profile-list":
      while PerfProbe.nowMilliseconds() < deadline {
        await measureScroll("profile.scroll.list", target: .list, pointsPerSecond: index % 2 == 0 ? 2_800 : -2_800, seconds: 4)
        index += 1
      }
    default:
      break
    }
    PerfProbe.mark("profile.end")
  }

  private static func settingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
    guard let menu else { return nil }
    for item in menu.items {
      if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command { return item }
      if let found = settingsMenuItem(in: item.submenu) { return found }
    }
    return nil
  }

  private static func parseTasks(_ raw: String?) -> [(label: String, taskID: TaskID)] {
    guard let raw else { return [] }
    return raw.split(separator: ",").compactMap { item in
      let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
      let label = parts.count == 2 ? parts[0] : "task"
      guard let uuid = UUID(uuidString: parts.last ?? "") else { return nil }
      return (label, TaskID(uuid))
    }
  }

  // MARK: - 启动

  private static func measureLaunch() async {
    let processStart = PerfProbe.processStartMilliseconds
    let firstList = await monitor.waitForCommit(prefix: "list.applied", after: processStart, timeout: 30_000)
    let firstDetail = await monitor.waitForCommit(prefix: "detail.applied", after: processStart, timeout: 30_000)
    let settled = await monitor.waitForQuiet(
      quiet: 1_000, timeout: 30_000, after: max(firstDetail ?? 0, firstList ?? 0)
    )
    func commit(_ prefix: String) -> Double? {
      monitor.commits.first(where: { $0.name.hasPrefix(prefix) }).map { $0.commitTime - processStart }
    }
    func markTime(_ prefix: String) -> Double? {
      monitor.commits.first(where: { $0.name.hasPrefix(prefix) }).map { $0.markTime - processStart }
    }
    let stretches = monitor.stretches(from: processStart, to: settled)
    emit([
      "step": "launch",
      "appInitBegin": json(markTime("app.init.begin")),
      "appInitEnd": json(markTime("app.init.end")),
      "windowTask": json(commit("window.task")),
      "bootstrapDone": json(markTime("bootstrap.done")),
      "firstListReady": json(firstList.map { $0 - processStart }),
      "firstDetailReady": json(firstDetail.map { $0 - processStart }),
      "settled": settled - processStart,
      "busyTotal": stretches.reduce(0) { $0 + $1.duration },
      "longestStall": stretches.map(\.duration).max() ?? 0,
    ])
  }

  // MARK: - 一步

  private static func measureDetail(_ name: String, taskID: TaskID, model: HistoryViewModel) async {
    await measureStep(name, readyPrefix: "detail.applied \(taskID.rawValue)") {
      model.selectedTaskID = taskID
    }
  }

  private static func measureStep(_ name: String, readyPrefix: String?, action: () -> Void) async {
    _ = await monitor.waitForQuiet(quiet: 600, timeout: 10_000, after: PerfProbe.nowMilliseconds())
    let start = PerfProbe.nowMilliseconds()
    PerfProbe.mark("step.begin \(name)")
    action()
    var ready: Double?
    if let readyPrefix {
      ready = await monitor.waitForCommit(prefix: readyPrefix, after: start, timeout: 15_000)
    }
    let settled = await monitor.waitForQuiet(quiet: 500, timeout: 15_000, after: ready ?? start)
    let stretches = monitor.stretches(from: start, to: settled)
    emit([
      "step": name,
      "ready": json(ready.map { $0 - start }),
      "settled": settled - start,
      "busyTotal": stretches.reduce(0) { $0 + $1.duration },
      "longestStall": stretches.map(\.duration).max() ?? 0,
      "stallsOver50": stretches.filter { $0.duration > 50 }.count,
    ])
  }

  // MARK: - 滑动

  enum ScrollTarget { case list, reading }

  private static func measureScroll(
    _ name: String, target: ScrollTarget, pointsPerSecond: Double, seconds: Double
  ) async {
    _ = await monitor.waitForQuiet(quiet: 600, timeout: 10_000, after: PerfProbe.nowMilliseconds())
    guard let window = mainWindow(), let scrollView = findScrollView(target, in: window) else {
      emit(["step": name, "error": "scroll view not found"])
      return
    }
    let driver = ScrollDriver(scrollView: scrollView, pointsPerSecond: pointsPerSecond, seconds: seconds)
    let start = PerfProbe.nowMilliseconds()
    let startOffset = scrollView.contentView.bounds.origin.y
    PerfProbe.mark("step.begin \(name)")
    await driver.run(window: window)
    let end = PerfProbe.nowMilliseconds()
    let settled = await monitor.waitForQuiet(quiet: 500, timeout: 10_000, after: end)
    let during = monitor.stretches(from: start, to: end).map(\.duration).sorted()
    let after = monitor.stretches(from: end, to: settled).map(\.duration)
    func percentile(_ p: Double) -> Double {
      guard !during.isEmpty else { return 0 }
      return during[min(during.count - 1, Int((Double(during.count) * p).rounded(.down)))]
    }
    emit([
      "step": name,
      "frames": driver.frames,
      "droppedFrames": driver.droppedFrames,
      "frameDuration": driver.nominalFrameDuration * 1_000,
      "timerFallback": driver.usedFallbackTimer,
      "boundsScrolling": driver.usesBoundsScrolling,
      "distance": scrollView.contentView.bounds.origin.y - startOffset,
      "busyFrames": during.count,
      "busyP50": percentile(0.5),
      "busyP95": percentile(0.95),
      "busyMax": during.last ?? 0,
      "over8ms": during.filter { $0 > 8.3 }.count,
      "over16ms": during.filter { $0 > 16.7 }.count,
      "over50ms": during.filter { $0 > 50 }.count,
      "busyTotal": during.reduce(0, +),
      "afterBusyTotal": after.reduce(0, +),
    ])
  }

  private static func mainWindow() -> NSWindow? {
    NSApp.windows
      .filter { $0.isVisible && $0.frame.width >= 900 }
      .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
  }

  private static func allScrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    if let scroll = view as? NSScrollView { found.append(scroll) }
    for subview in view.subviews { found += allScrollViews(in: subview) }
    return found
  }

  /// 列表：文档视图是表格、又不在最左边（最左边是侧栏）的那个。阅读区：列表右边面积最大的那个。
  private static func findScrollView(_ target: ScrollTarget, in window: NSWindow) -> NSScrollView? {
    guard let content = window.contentView else { return nil }
    let all = allScrollViews(in: content)
    let candidates = all.filter { !$0.isHidden && $0.frame.height > 200 }
    func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    for scroll in all {
      let rect = frame(scroll)
      PerfProbe.write("scrollview", "\(type(of: scroll)) doc=\(scroll.documentView.map { "\(type(of: $0))" } ?? "-") x=\(Int(rect.minX)) w=\(Int(rect.width)) h=\(Int(rect.height))")
    }
    let tables = candidates
      .filter { $0.documentView is NSTableView && frame($0).minX > 60 }
      .sorted { frame($0).minX < frame($1).minX }
    switch target {
    case .list:
      return tables.first
    case .reading:
      let listMaxX = tables.first.map { frame($0).maxX } ?? 0
      return candidates
        .filter { frame($0).minX >= listMaxX - 4 && !($0.documentView is NSTableView) }
        .max { frame($0).width * frame($0).height < frame($1).width * frame($1).height }
    }
  }

  private static func json(_ value: Double?) -> Any { value ?? NSNull() }

  private static func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    PerfProbe.write("result", text)
  }
}

/// 按屏幕刷新节奏，每帧喂一个触控板滚动事件。帧回调来晚了（主线程忙）就记掉帧。
@MainActor
private final class ScrollDriver: NSObject {
  let scrollView: NSScrollView
  let pointsPerSecond: Double
  let seconds: Double
  private(set) var frames = 0
  private(set) var droppedFrames = 0
  private(set) var nominalFrameDuration: Double = 1.0 / 120
  private var link: CADisplayLink?
  private var startTimestamp: CFTimeInterval?
  private var lastTimestamp: CFTimeInterval?
  private var carry: Double = 0
  private var continuation: CheckedContinuation<Void, Never>?

  init(scrollView: NSScrollView, pointsPerSecond: Double, seconds: Double) {
    self.scrollView = scrollView
    self.pointsPerSecond = pointsPerSecond
    self.seconds = seconds
  }

  /// 窗口被别的窗口完全挡住时系统会停掉它的帧回调；这时退回 120Hz 定时器，照样喂事件、照样量主线程。
  private var fallbackTimer: Timer?
  private(set) var usedFallbackTimer = false

  func run(window: NSWindow) async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      let link = window.displayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, self.startTimestamp == nil, self.continuation != nil else { return }
        self.link?.invalidate()
        self.link = nil
        self.usedFallbackTimer = true
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.step(now: CACurrentMediaTime(), duration: 1.0 / 120) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.fallbackTimer = timer
      }
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    step(now: link.timestamp, duration: link.duration)
  }

  private func step(now: CFTimeInterval, duration: CFTimeInterval) {
    if duration > 0 { nominalFrameDuration = duration }
    guard let start = startTimestamp, let last = lastTimestamp else {
      startTimestamp = now
      lastTimestamp = now
      _ = startOffset
      send(delta: 0, phase: 1)
      return
    }
    frames += 1
    let interval = now - last
    if interval > nominalFrameDuration * 1.5 {
      droppedFrames += Int((interval / nominalFrameDuration).rounded()) - 1
    }
    lastTimestamp = now
    if now - start >= seconds {
      send(delta: 0, phase: 4)
      if usesBoundsScrolling {
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
      }
      link?.invalidate()
      link = nil
      fallbackTimer?.invalidate()
      fallbackTimer = nil
      continuation?.resume()
      continuation = nil
      return
    }
    carry += pointsPerSecond * interval
    let step = carry.rounded(.towardZero)
    carry -= step
    if usesBoundsScrolling {
      scrollBounds(by: step)
    } else {
      send(delta: step, phase: 2)
      // 系统列表（ListCoreScrollView）走「响应式滚动」，不认程序合成的滚轮事件。
      // 喂了几帧位置纹丝不动，就改成直接挪可视区域，并补上开始/结束滑动的通知。
      if frames == 8, abs(scrollView.contentView.bounds.origin.y - startOffset) < 1 {
        usesBoundsScrolling = true
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
      }
    }
  }

  private(set) var usesBoundsScrolling = false
  private lazy var startOffset: CGFloat = scrollView.contentView.bounds.origin.y

  private func scrollBounds(by delta: Double) {
    let clip = scrollView.contentView
    let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
    var origin = clip.bounds.origin
    origin.y = max(0, min(maxY, origin.y + delta))
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
  }

  /// phase: 1 began, 2 changed, 4 ended（CGScrollPhase）。往下看内容 = 负的滚轮值。
  private func send(delta: Double, phase: Int64) {
    guard let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
      wheel1: Int32(-delta), wheel2: 0, wheel3: 0
    ) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -delta)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -delta)
    if let window = scrollView.window {
      let rect = scrollView.convert(scrollView.bounds, to: nil)
      let screenPoint = window.convertPoint(toScreen: NSPoint(x: rect.midX, y: rect.midY))
      let height = NSScreen.screens.first?.frame.height ?? 0
      event.location = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
    }
    guard let nsEvent = NSEvent(cgEvent: event) else { return }
    scrollView.scrollWheel(with: nsEvent)
  }
}
#endif
