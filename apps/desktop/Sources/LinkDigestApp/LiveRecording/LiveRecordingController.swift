import AVFoundation
import AppKit
import Foundation
import LinkDigestCore

struct LiveRecordingIngestPayload: Sendable {
  let fileURL: URL
  let platform: LiveRecordingPlatform
  let anchorName: String?
  let anchorID: String?
  let anchorAvatarURL: String?
  let anchorProfileURL: String?
  let title: String?
  let pageURL: String
  let roomID: String?
  let startedAt: Date
  let durationSeconds: Double?
  /// 实际录下来的清晰度（可能因为原画不可用而降档）。
  var quality: LiveQuality = .origin
  /// 同一场因编码不同拆成多个文件时的序号，从 1 开始；入库身份靠它区分。
  var part: Int = 1
}

/// 直播录制列表与后台任务。
///
/// 每条记录对应一次「开始录制」：一个 ffmpeg 进程录一段，断线后重新取地址再录
/// 下一段，结束时（手动停止 / 下播 / 放弃续录）合并成一个 MP4，再交给本机导入
/// 那条通道入库并接自动转写。网页关掉不影响，录的是子进程。
@MainActor
final class LiveRecordingController: ObservableObject {
  struct Item: Identifiable, Equatable {
    let id: String
    let requestID: String
    let platform: LiveRecordingPlatform
    let pageURL: String
    let roomID: String?
    var quality: LiveQuality
    let requestedQuality: LiveQuality
    let anchorName: String?
    let title: String?
    let startedAt: Date
    var phase: LiveRecordingPhase = .preparing
    var segmentCount = 0
    var elapsed: TimeInterval = 0
    var bytes: Int64 = 0
    var fileURL: URL?
    var additionalFileURLs: [URL] = []
    var stopReason: LiveRecordingStopReason?
    var failureMessage: String?
    var qualityNote: String?
    var taskIDs: [TaskID] = []
    /// 成品文件已经落地，但入库（建条目 + 自动转写）还没结束。
    /// 这期间不能出现「移除」：移掉之后入库失败的提示就无处可显示。
    var isIngesting = false
    /// 分段所在目录。合并失败时面板据此提供「打开分段文件夹」。
    var segmentsDirectory: URL?

    var displayName: String {
      let name = anchorName?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let name, !name.isEmpty { return name }
      let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let title, !title.isEmpty { return title }
      return "\(platform.displayName)直播 \(roomID ?? "")".trimmingCharacters(in: .whitespaces)
    }
  }

  /// 连续这么久文件不再增长就重启这一段：CDN 卡住时 ffmpeg 的 reconnect 不会触发。
  static let stallTimeout: TimeInterval = 180

  @Published private(set) var items: [Item] = []
  @Published var isPanelPresented = false
  /// 录制目录所在卷的剩余空间，面板据此显示「还能录约 N 小时」。
  @Published private(set) var freeBytes: Int64 = 0

  let preferences: LiveRecordingPreferences
  /// 录完入库。App 启动时接到本地导入通道；测试里可以不接。
  var ingest: (@MainActor (LiveRecordingIngestPayload) async throws -> TaskID)?

  private let ffmpegURL: URL?
  private let fetcher: LiveRoomFetching
  private let makeRunner: @MainActor () -> FFmpegProcessRunner
  private var runners: [String: FFmpegProcessRunner] = [:]
  /// 合并用的 ffmpeg。和录制 runner 分开登记，退出时同样要收掉。
  private var mergeRunners: [String: FFmpegProcessRunner] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private var stopRequested: Set<String> = []
  private var diskLowIDs: Set<String> = []
  private var shuttingDown = false

  init(
    preferences: LiveRecordingPreferences,
    ffmpegURL: URL? = try? FFmpegLocator.requireExecutable(),
    fetcher: LiveRoomFetching = FallbackLiveRoomFetcher(),
    makeRunner: @escaping @MainActor () -> FFmpegProcessRunner = { FFmpegProcessRunner() }
  ) {
    self.preferences = preferences
    self.ffmpegURL = ffmpegURL
    self.fetcher = fetcher
    self.makeRunner = makeRunner
  }

  var activeCount: Int {
    items.filter { $0.phase == .recording || isReconnecting($0.phase) || $0.phase == .merging }.count
  }

  private func isReconnecting(_ phase: LiveRecordingPhase) -> Bool {
    if case .reconnecting = phase { return true }
    return false
  }

  // MARK: - 对外入口

  func start(_ request: LiveRecordingRequest) -> CaptureReceiver.LiveRecordingAcceptance {
    guard let ffmpegURL else { return .rejected(code: "LIVE_FFMPEG_NOT_FOUND") }
    guard LiveRecordingRequest.select(
      variants: request.variants,
      requested: request.quality,
      platform: request.platform
    ) != nil else {
      return .rejected(code: "LIVE_STREAM_NOT_FOUND")
    }
    let incomingRoomID = request.roomID
      ?? DouyinLivePageParser.roomID(fromPageURL: request.pageURL)
      ?? XiaohongshuLivePageParser.roomID(fromPageURL: request.pageURL)
    if Self.hasActiveDuplicate(
      items: items,
      platform: request.platform,
      roomID: incomingRoomID,
      pageURL: request.pageURL
    ) {
      return .rejected(code: "LIVE_ALREADY_RECORDING")
    }
    let directory: URL
    do {
      directory = try preferences.ensureRecordingDirectory()
    } catch {
      return .rejected(code: "LIVE_DISK_UNAVAILABLE")
    }
    let available = LiveRecordingDiskSpace.availableBytes(at: directory)
    guard available >= LiveRecordingDiskSpace.requiredFreeBytes else {
      return .rejected(code: "LIVE_DISK_UNAVAILABLE")
    }
    freeBytes = available

    let startedAt = Date()
    let id = UUID().uuidString.lowercased()
    let fileName = LiveRecordingNaming.fileName(
      anchorName: request.anchorName,
      title: request.title,
      startedAt: startedAt
    )
    let finalURL = Self.availableURL(in: directory, fileName: fileName)
    var item = Item(
      id: id,
      requestID: request.requestId,
      platform: request.platform,
      pageURL: request.pageURL,
      roomID: incomingRoomID,
      quality: request.quality,
      requestedQuality: request.quality,
      anchorName: request.anchorName,
      title: request.title,
      startedAt: startedAt
    )
    item.fileURL = finalURL
    items.insert(item, at: 0)
    isPanelPresented = true
    tasks[id] = Task { [weak self] in
      await self?.drive(id: id, request: request, finalURL: finalURL, ffmpegURL: ffmpegURL)
    }
    return .accepted(recordingID: id)
  }

  static func hasActiveDuplicate(
    items: [Item],
    platform: LiveRecordingPlatform,
    roomID: String?,
    pageURL: String
  ) -> Bool {
    items.contains { item in
      guard item.platform == platform else { return false }
      switch item.phase {
      case .recording: break
      case .reconnecting, .preparing: break
      default: return false
      }
      if let roomID, let existing = item.roomID { return existing == roomID }
      return item.pageURL == pageURL
    }
  }

  static func qualityNote(requested: LiveQuality, actual: LiveQuality) -> String? {
    guard actual != requested else { return nil }
    return "\(requested.displayName)不可用，已改录\(actual.displayName)"
  }

  static func segmentsKeptMessage(_ reason: String?, directory: URL) -> String {
    let head = reason ?? "分段合并失败。"
    return "\(head)分段文件保留在 \(directory.path)，可以点「打开分段文件夹」手动处理。"
  }

  static func appendingNote(_ note: String, to existing: String?) -> String {
    guard let existing, !existing.isEmpty else { return note }
    return "\(existing)；\(note)"
  }

  func stop(_ id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    switch items[index].phase {
    case .recording:
      stopRequested.insert(id)
      runners[id]?.terminate()
    case .preparing, .reconnecting:
      stopRequested.insert(id)
    case .merging, .completed, .failed:
      break
    }
  }

  func dismiss(_ id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    // 入库还没结束时不移除：失败提示会跟着记录一起消失。
    guard !items[index].isIngesting else { return }
    switch items[index].phase {
    case .merging, .recording, .preparing, .reconnecting:
      return
    case .completed, .failed:
      items.remove(at: index)
    }
  }

  /// App 退出时调用：先停掉所有 ffmpeg，避免留下继续写盘的孤儿进程。
  /// 有界等待 1.5 秒，到点 SIGKILL；退出路径上不合并，半成品分段留在 `.parts`。
  func shutdown() {
    shuttingDown = true
    let runners = Array(runners.values) + Array(mergeRunners.values)
    for id in items.map(\.id) {
      stopRequested.insert(id)
    }
    for runner in runners {
      runner.terminate()
    }
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline, runners.contains(where: { $0.isRunning }) {
      usleep(50_000)
    }
    for runner in runners {
      runner.forceKill()
    }
    for task in tasks.values {
      task.cancel()
    }
    tasks.removeAll()
    self.runners.removeAll()
    self.mergeRunners.removeAll()
  }

  func reveal(_ id: String) {
    guard let item = items.first(where: { $0.id == id }) else { return }
    let urls = [item.fileURL].compactMap { $0 } + item.additionalFileURLs
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  /// 合并失败时打开分段所在的 `.parts` 目录，让用户能手动救回录到的内容。
  func revealSegments(_ id: String) {
    guard let directory = items.first(where: { $0.id == id })?.segmentsDirectory,
          FileManager.default.fileExists(atPath: directory.path)
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }

  /// 找不到 ffprobe 时，合并前必须在面板上说清楚风险，不能静默：
  /// 没有它就读不出分段的编码，断线前后换了编码的分段会被并成一组，合并会失败。
  var isProbeAvailable: Bool {
    guard let ffmpegURL else { return false }
    return FFmpegLocator.probeURL(near: ffmpegURL) != nil
  }

  static func probeWarning(isProbeAvailable: Bool, hasActiveRecording: Bool) -> String? {
    guard !isProbeAvailable, hasActiveRecording else { return nil }
    return "找不到 ffprobe：合并时无法识别分段编码，断线前后换了编码的场次可能合并失败。发版必须和 ffmpeg 一起带上 ffprobe。"
  }

  func refreshFreeSpace() {
    freeBytes = LiveRecordingDiskSpace.availableBytes(at: preferences.recordingDirectory)
  }

  // MARK: - 录制循环

  private func drive(id: String, request: LiveRecordingRequest, finalURL: URL, ffmpegURL: URL) async {
    var machine = LiveRecordingStateMachine()
    var segments: [URL] = []
    var variant = LiveRecordingRequest.select(
      variants: request.variants,
      requested: request.quality,
      platform: request.platform
    )
    var recordedSeconds: TimeInterval = 0
    var consecutiveEmptySegments = 0
    var action = machine.handle(.begin)

    let segmentsDirectory = LiveRecordingNaming.segmentsDirectory(
      recordingDirectory: finalURL.deletingLastPathComponent(),
      stem: finalURL.deletingPathExtension().lastPathComponent
    )
    try? FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
    update(id) { $0.segmentsDirectory = segmentsDirectory }

    while true {
      switch action {
      case .startSegment:
        if stopRequested.contains(id) {
          action = machine.handle(.userRequestedStop)
          update(id) { $0.phase = machine.phase }
          continue
        }
        guard let current = variant else {
          action = machine.handle(.streamRefreshEnded)
          continue
        }
        let output = LiveRecordingNaming.segmentURL(
          segmentsDirectory: segmentsDirectory,
          index: machine.segmentCount + 1
        )
        action = machine.handle(.segmentStarted)
        update(id) { state in
          state.phase = .recording
          state.segmentCount = machine.segmentCount
          state.quality = current.quality
          state.qualityNote = Self.qualityNote(requested: request.quality, actual: current.quality)
        }
        let runner = makeRunner()
        runners[id] = runner
        let segmentStart = Date()
        let ticker = startTicker(
          id: id,
          fileURL: output,
          baseElapsed: recordedSeconds,
          baseBytes: Self.totalSize(segments),
          directory: finalURL.deletingLastPathComponent()
        )
        let status = (try? await runner.run(
          executable: ffmpegURL,
          arguments: FFmpegCommand.record(
            inputURL: current.url,
            outputURL: output,
            userAgent: request.userAgent,
            referer: request.referer,
            quality: current.quality,
            platform: request.platform
          )
        )) ?? -1
        ticker.cancel()
        runners[id] = nil
        recordedSeconds += Date().timeIntervalSince(segmentStart)
        let size = Self.fileSize(output)
        if size > 0 {
          segments.append(output)
          consecutiveEmptySegments = 0
        } else {
          consecutiveEmptySegments += 1
        }
        update(id) { state in
          state.elapsed = recordedSeconds
          state.bytes = Self.totalSize(segments)
        }
        if consecutiveEmptySegments >= 3 {
          action = machine.handle(.recordingKeptFailing)
          update(id) { $0.phase = machine.phase }
          continue
        }
        if diskLowIDs.contains(id) {
          action = machine.handle(.diskSpaceLow)
          update(id) { $0.phase = machine.phase }
          continue
        }
        if stopRequested.contains(id) {
          _ = machine.handle(.userRequestedStop)
        }
        action = machine.handle(.segmentExited(status: status))
        update(id) { state in
          state.segmentCount = machine.segmentCount
          state.phase = machine.phase
        }

      case let .reconnect(delay):
        update(id) { $0.phase = machine.phase }
        if await sleepUnlessStopped(id: id, seconds: delay) {
          action = machine.handle(.userRequestedStop)
          update(id) { $0.phase = machine.phase }
          continue
        }
        do {
          let room = try await fetcher.fetchRoom(
            platform: request.platform,
            pageURL: request.pageURL,
            userAgent: request.userAgent,
            referer: request.referer
          )
          variant = LiveRecordingRequest.select(
            variants: room.variants,
            requested: request.quality,
            platform: request.platform
          )
          action = variant == nil
            ? machine.handle(.streamRefreshEnded)
            : machine.handle(.streamRefreshFoundLive)
        } catch LiveRoomFetchError.ended {
          action = machine.handle(.streamRefreshEnded)
        } catch LiveRoomFetchError.verificationRequired {
          action = machine.handle(.verificationRequired)
        } catch {
          action = machine.handle(.streamRefreshFailed)
        }
        update(id) { $0.phase = machine.phase }

      case let .merge(reason):
        update(id) { state in
          state.phase = .merging
          state.stopReason = reason
        }
        let result = await merge(
          id: id, segments: segments, finalURL: finalURL, ffmpegURL: ffmpegURL
        )
        if !result.outputs.isEmpty {
          _ = machine.handle(.mergeSucceeded)
          await finish(id: id, request: request, fileURLs: result.outputs, reason: reason)
          if let message = result.failureMessage {
            update(id) { state in
              state.failureMessage = Self.appendingNote(
                Self.segmentsKeptMessage(message, directory: segmentsDirectory),
                to: state.failureMessage
              )
            }
          }
        } else {
          _ = machine.handle(.mergeFailed)
          update(id) { state in
            state.phase = .failed(machine.phase.failureMessage ?? "分段合并失败。")
            state.stopReason = reason
            state.failureMessage = Self.segmentsKeptMessage(result.failureMessage, directory: segmentsDirectory)
          }
        }
        tasks[id] = nil
        return

      case .completed:
        guard !segments.isEmpty else {
          update(id) { state in
            state.phase = .failed("没有录到内容。可能是直播间刚结束，或者流地址已失效。")
            state.failureMessage = "没有录到内容。"
          }
          tasks[id] = nil
          return
        }
        update(id) { $0.phase = .merging }
        let result = await merge(
          id: id, segments: segments, finalURL: finalURL, ffmpegURL: ffmpegURL
        )
        if !result.outputs.isEmpty {
          _ = machine.handle(.mergeSucceeded)
          await finish(
            id: id,
            request: request,
            fileURLs: result.outputs,
            reason: machine.stopReason ?? .streamEnded
          )
          if let message = result.failureMessage {
            update(id) { state in
              state.failureMessage = Self.appendingNote(
                Self.segmentsKeptMessage(message, directory: segmentsDirectory),
                to: state.failureMessage
              )
            }
          }
        } else {
          update(id) { state in
            state.phase = .failed("分段合并失败。")
            state.failureMessage = Self.segmentsKeptMessage(result.failureMessage, directory: segmentsDirectory)
          }
        }
        tasks[id] = nil
        return

      case .failed:
        update(id) { state in
          state.phase = .failed(machine.phase.failureMessage ?? "录制失败。")
          state.failureMessage = machine.phase.failureMessage
        }
        tasks[id] = nil
        return

      case .none:
        // 状态机不该停在「无事可做」上；真遇到就当作异常收尾，不空转。
        update(id) { $0.phase = .failed("录制状态异常，已停止。") }
        tasks[id] = nil
        return
      }
    }
  }

  private func sleepUnlessStopped(id: String, seconds: TimeInterval) async -> Bool {
    var remaining = max(0, seconds)
    while remaining > 0 {
      if stopRequested.contains(id) { return true }
      let slice = min(0.2, remaining)
      try? await Task.sleep(for: .seconds(slice))
      remaining -= slice
    }
    return stopRequested.contains(id)
  }

  private func startTicker(
    id: String,
    fileURL: URL,
    baseElapsed: TimeInterval,
    baseBytes: Int64,
    directory: URL
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      let start = Date()
      var lastSize: Int64 = 0
      var lastGrowth = Date()
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        tick += 1
        let size = Self.fileSize(fileURL)
        let elapsed = baseElapsed + Date().timeIntervalSince(start)
        self.update(id) { state in
          if state.phase == .recording {
            state.elapsed = elapsed
            state.bytes = baseBytes + size
          }
        }
        if size > lastSize {
          lastSize = size
          lastGrowth = Date()
        } else if Date().timeIntervalSince(lastGrowth) > Self.stallTimeout {
          self.runners[id]?.terminate()
          lastGrowth = Date()
        }
        // 每 5 秒看一次剩余空间。阈值随已录大小抬高（分段总量 + 合并余量）：
        // 收尾之后还要再写一份同样大的成品，只按 1 GB 收尾会让合并没有地方写。
        if tick % 5 == 0 {
          let available = LiveRecordingDiskSpace.availableBytes(at: directory)
          self.freeBytes = available
          let recordedBytes = baseBytes + size
          if available < LiveRecordingDiskSpace.stopThresholdBytes(recordedBytes: recordedBytes) {
            self.diskLowIDs.insert(id)
            self.runners[id]?.terminate()
          }
        }
      }
    }
  }

  // MARK: - 合并与入库

  struct SegmentSignature: Equatable, Sendable {
    let codec: String
    let width: Int
    let height: Int
    var key: String { "\(codec)-\(width)x\(height)" }
  }

  /// 断线前后可能换了编码或分辨率（例如原画从 H.264 切到 H.265）。编码不同
  /// 的段不能硬拼：按编码+分辨率分组，每组各合成一个文件。
  static func groupedSegmentIndices(_ signatures: [SegmentSignature?]) -> [[Int]] {
    var order: [String] = []
    var groups: [String: [Int]] = [:]
    for (index, signature) in signatures.enumerated() {
      let key = signature?.key ?? "unknown"
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(index)
    }
    return order.compactMap { groups[$0] }
  }

  /// 一次合并的结果。
  struct MergeResult: Equatable {
    var outputs: [URL]
    /// 有值表示没全部合并成功；outputs 里的文件仍然可用，分段留在 .parts 供手动处理。
    var failureMessage: String?
  }

  /// 合并所有分段，返回可用成品。
  ///
  /// 磁盘策略（第 1 条）：先算一次需要的空间；不够就逐组合并，并且一组成功就删掉
  /// 这一组的分段，把峰值从「全部分段 + 整份产物」降到「剩余分段 + 单组产物」。
  /// 自动收尾阈值同时随已录大小抬高（见 `LiveRecordingDiskSpace.stopThresholdBytes`），
  /// 两道保险：阈值保证正常收尾留得出合并空间，逐组删除应对录制中磁盘被别的程序占掉。
  private func merge(
    id: String,
    segments: [URL],
    finalURL: URL,
    ffmpegURL: URL
  ) async -> MergeResult {
    guard !segments.isEmpty else {
      return MergeResult(outputs: [], failureMessage: "没有可合并的分段。")
    }
    var signatures: [SegmentSignature?] = []
    for segment in segments {
      signatures.append(await Self.segmentSignature(segment, ffmpegURL: ffmpegURL))
    }
    let groups = Self.groupedSegmentIndices(signatures)
    let mergedDirectory = finalURL.deletingLastPathComponent()
    let totalBytes = Self.totalSize(segments)
    let tightDisk = LiveRecordingDiskSpace.availableBytes(at: mergedDirectory)
      < LiveRecordingDiskSpace.mergeRequiredBytes(recordedBytes: totalBytes)
    var outputs: [URL] = []
    for (index, indices) in groups.enumerated() {
      let group = indices.map { segments[$0] }
      if tightDisk {
        // 空间紧时按组算：这一组的产物写完之前，磁盘必须放得下它。
        let required = LiveRecordingDiskSpace.mergeRequiredBytes(recordedBytes: Self.totalSize(group))
        let available = LiveRecordingDiskSpace.availableBytes(at: mergedDirectory)
        guard available >= required else {
          return MergeResult(
            outputs: outputs,
            failureMessage: "磁盘剩余空间不够合并第 \(index + 1) 组（需要约 \(Self.byteText(required))，剩余约 \(Self.byteText(available))）。"
          )
        }
      }
      let output = LiveRecordingNaming.numberedURL(finalURL, number: index + 1)
      let codec = indices.first.flatMap { signatures[$0]?.codec }
      guard await concatSegmentGroup(
        id: id,
        index: index + 1,
        group,
        outputURL: output,
        codecName: codec,
        ffmpegURL: ffmpegURL
      ) else {
        return MergeResult(
          outputs: outputs,
          failureMessage: "第 \(index + 1) 组合并失败。"
        )
      }
      outputs.append(output)
      // 这一组已经落成 MP4，分段不再需要：立刻删掉，后面的组才有空间。
      for segment in group {
        try? FileManager.default.removeItem(at: segment)
      }
    }
    if let directory = segments.first?.deletingLastPathComponent() {
      try? FileManager.default.removeItem(at: directory)
    }
    return MergeResult(outputs: outputs, failureMessage: nil)
  }

  private func concatSegmentGroup(
    id: String,
    index: Int,
    _ segments: [URL],
    outputURL: URL,
    codecName: String?,
    ffmpegURL: URL
  ) async -> Bool {
    guard !segments.isEmpty else { return false }
    guard !shuttingDown else { return false }
    // 「原画」不等于 H.265：有的房间这一档是 H.264。标签必须按真实编码打，
    // 打错时 ffmpeg 会以 0 字节失败（Tag hvc1 incompatible with avc1）。
    let tagHVC1 = FFmpegCommand.shouldTagHVC1(codecName: codecName)
    let segmentsDirectory = segments[0].deletingLastPathComponent()
    let listURL = segmentsDirectory.appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + ".concat.txt")
    let list = segments.map(FFmpegCommand.concatListLine).joined()
    do {
      try list.write(to: listURL, atomically: true, encoding: .utf8)
    } catch {
      return false
    }
    defer { try? FileManager.default.removeItem(at: listURL) }
    // 先写到 .parts 里的临时文件：App 中途退出只会留下它，不会被当成成品。
    let partialURL = LiveRecordingNaming.mergePartialURL(
      segmentsDirectory: segmentsDirectory,
      index: index
    )
    try? FileManager.default.removeItem(at: partialURL)
    defer { try? FileManager.default.removeItem(at: partialURL) }
    let runner = makeRunner()
    mergeRunners[id] = runner
    defer { mergeRunners[id] = nil }
    let status = (try? await runner.run(
      executable: ffmpegURL,
      arguments: FFmpegCommand.concat(listFile: listURL, outputURL: partialURL, tagHVC1: tagHVC1)
    )) ?? -1
    guard status == 0, !shuttingDown else { return false }
    return LiveRecordingNaming.finalizeMergeOutput(partial: partialURL, finalURL: outputURL)
  }

  private func finish(
    id: String,
    request: LiveRecordingRequest,
    fileURLs: [URL],
    reason: LiveRecordingStopReason
  ) async {
    guard let primary = fileURLs.first else { return }
    var totalDuration: TimeInterval = 0
    for url in fileURLs {
      totalDuration += (await Self.mediaDuration(url)) ?? 0
    }
    let startedAt = itemStartedAt(id) ?? Date()
    update(id) { state in
      state.phase = .completed
      state.stopReason = reason
      state.fileURL = primary
      state.additionalFileURLs = Array(fileURLs.dropFirst())
      state.bytes = fileURLs.reduce(0) { $0 + Self.fileSize($1) }
      if totalDuration > 0 { state.elapsed = totalDuration }
    }
    guard let ingest else { return }
    // 入库期间不出「移除」按钮：移除后入库失败的提示就丢了。
    update(id) { $0.isIngesting = true }
    let recordedQuality = items.first(where: { $0.id == id })?.quality ?? request.quality
    var taskIDs: [TaskID] = []
    var failures: [String] = []
    for (offset, url) in fileURLs.enumerated() {
      do {
        let taskID = try await ingest(
          LiveRecordingIngestPayload(
            fileURL: url,
            platform: request.platform,
            anchorName: request.anchorName,
            anchorID: request.anchorID,
            anchorAvatarURL: request.anchorAvatarURL,
            anchorProfileURL: request.anchorProfileURL,
            title: request.title,
            pageURL: request.pageURL,
            roomID: request.roomID,
            startedAt: startedAt,
            durationSeconds: await Self.mediaDuration(url),
            quality: recordedQuality,
            part: offset + 1
          )
        )
        taskIDs.append(taskID)
      } catch {
        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    update(id) { state in
      state.isIngesting = false
      state.taskIDs = taskIDs
      if !failures.isEmpty {
        state.failureMessage = "视频已保存，但有文件没能入库：\(failures.joined(separator: "；"))"
      }
    }
  }

  private func itemStartedAt(_ id: String) -> Date? {
    items.first(where: { $0.id == id })?.startedAt
  }

  static func mediaDuration(_ url: URL) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite && seconds > 0 ? seconds : nil
  }

  /// 读一路视频的编码与分辨率。ffprobe 不在就返回 nil，此时不打 hvc1 标签。
  static func segmentSignature(_ url: URL, ffmpegURL: URL) async -> SegmentSignature? {
    guard let probe = FFmpegLocator.probeURL(near: ffmpegURL) else { return nil }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = probe
        process.arguments = [
          "-v", "error",
          "-select_streams", "v:0",
          "-show_entries", "stream=codec_name,width,height",
          "-of", "default=nw=1:nk=1",
          url.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
        } catch {
          continuation.resume(returning: nil)
          return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var codec: String?
        var width = 0
        var height = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
          let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
          guard parts.count == 2 else { continue }
          switch parts[0] {
          case "codec_name": codec = parts[1]
          case "width": width = Int(parts[1]) ?? 0
          case "height": height = Int(parts[1]) ?? 0
          default: break
          }
        }
        guard let codec, !codec.isEmpty else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: SegmentSignature(codec: codec, width: width, height: height))
      }
    }
  }

  // MARK: - 小工具

  private func update(_ id: String, _ change: (inout Item) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    change(&items[index])
  }

  private static func fileSize(_ url: URL) -> Int64 {
    LiveRecordingNaming.fileSize(url)
  }

  private static func totalSize(_ urls: [URL]) -> Int64 {
    urls.reduce(0) { $0 + fileSize($1) }
  }

  static func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
  }

  private static func availableURL(in directory: URL, fileName: String) -> URL {
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = directory.appendingPathComponent(fileName)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
      index += 1
    }
    return candidate
  }
}

private extension LiveRecordingPhase {
  var failureMessage: String? {
    if case let .failed(message) = self { return message }
    return nil
  }
}
