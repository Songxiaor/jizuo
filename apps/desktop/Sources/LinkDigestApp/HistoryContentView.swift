import AppKit
import AVKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import LinkDigestAdapters
import LinkDigestCore

/// The first meaningful wheel delta decides the gesture's owner. A normal
/// gesture end keeps that answer just long enough for AppKit's optional
/// momentum events; the next normal (or phase-less) event starts over.
enum VideoScrollGestureAxis: Equatable {
  case vertical
  case horizontal
}

struct VideoScrollGestureRoute: Equatable {
  let axis: VideoScrollGestureAxis
  let usesExistingLock: Bool
  let resetsTarget: Bool
  let endsMomentum: Bool
}

/// Pure gesture policy kept separate from AppKit routing so the important
/// vertical/horizontal and momentum cases remain directly testable.
struct VideoScrollGestureAxisLock {
  private(set) var lockedAxis: VideoScrollGestureAxis?
  private var pendingMomentumAxis: VideoScrollGestureAxis?

  var hasGestureLock: Bool {
    lockedAxis != nil || pendingMomentumAxis != nil
  }

  mutating func route(
    deltaX: CGFloat,
    deltaY: CGFloat,
    phase: NSEvent.Phase,
    momentumPhase: NSEvent.Phase
  ) -> VideoScrollGestureRoute? {
    let isMomentum = !momentumPhase.isEmpty
    var resetsTarget = false

    // A fresh ordinary gesture must never inherit an unfinished axis from a
    // prior gesture. Phase-less mice use the same per-event reset rule.
    if !isMomentum, phase.contains(.began) || phase.isEmpty {
      resetsTarget = hasGestureLock
      reset()
    } else if !isMomentum, pendingMomentumAxis != nil {
      resetsTarget = true
      reset()
    }

    let existingAxis = isMomentum ? (lockedAxis ?? pendingMomentumAxis) : lockedAxis
    let axis = existingAxis ?? Self.dominantAxis(deltaX: deltaX, deltaY: deltaY)
    guard let axis else { return nil }

    let usesExistingLock = existingAxis != nil
    let endsMomentum = isMomentum && (momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled))

    if !usesExistingLock, (!phase.isEmpty || !momentumPhase.isEmpty) {
      lockedAxis = axis
    }

    if endsMomentum {
      lockedAxis = nil
      pendingMomentumAxis = nil
    } else if !isMomentum, phase.contains(.ended) || phase.contains(.cancelled) {
      // Preserve only the axis for a possible next momentum event. The active
      // ordinary lock is reset now, so a new normal gesture cannot inherit it.
      pendingMomentumAxis = axis
      lockedAxis = nil
    }

    return VideoScrollGestureRoute(
      axis: axis,
      usesExistingLock: usesExistingLock,
      resetsTarget: resetsTarget,
      endsMomentum: endsMomentum
    )
  }

  mutating func reset() {
    lockedAxis = nil
    pendingMomentumAxis = nil
  }

  private static func dominantAxis(deltaX: CGFloat, deltaY: CGFloat) -> VideoScrollGestureAxis? {
    let horizontal = abs(deltaX)
    let vertical = abs(deltaY)
    guard horizontal > 0 || vertical > 0, horizontal != vertical else { return nil }
    return vertical > horizontal ? .vertical : .horizontal
  }
}

struct VideoScrollWheelAnchorCandidate: Equatable {
  let id: UUID
  let windowID: ObjectIdentifier
  let bounds: NSRect
  let visibleRect: NSRect
  /// The cursor expressed in *this* anchor's coordinate space. Comparing the
  /// window-space point against view-space bounds only matched when the view
  /// happened to sit at the window origin, so the hit test silently failed for
  /// every player that was scrolled down the page.
  let localPoint: NSPoint
  let isVisible: Bool
  let hasEnclosingScrollView: Bool
}

struct VideoScrollWheelRouteSample {
  let windowID: ObjectIdentifier
  let point: NSPoint
  let deltaX: CGFloat
  let deltaY: CGFloat
  let phase: NSEvent.Phase
  let momentumPhase: NSEvent.Phase
  let isForwarding: Bool
  let candidates: [VideoScrollWheelAnchorCandidate]
}

enum VideoScrollWheelRouteDecision: Equatable {
  case passThrough
  case forward(UUID)
}

/// The broker's small, AppKit-free ownership decision. The actual local event
/// monitor and unit tests both call this seam; only the final scroll forwarding
/// remains in the broker because it needs the real NSEvent and NSScrollView.
struct VideoScrollWheelRoutePlanner {
  private var registeredAnchorIDs: Set<UUID> = []
  private var axisLock = VideoScrollGestureAxisLock()
  private(set) var lockedAnchorID: UUID?
  private var lockedWindowID: ObjectIdentifier?

  var registeredAnchorCount: Int { registeredAnchorIDs.count }

  mutating func register(_ anchorID: UUID) {
    registeredAnchorIDs.insert(anchorID)
  }

  mutating func unregister(_ anchorID: UUID) {
    registeredAnchorIDs.remove(anchorID)
    if lockedAnchorID == anchorID || registeredAnchorIDs.isEmpty {
      resetGesture()
    }
  }

  mutating func resetGesture() {
    axisLock.reset()
    lockedAnchorID = nil
    lockedWindowID = nil
  }

  mutating func route(_ sample: VideoScrollWheelRouteSample) -> VideoScrollWheelRouteDecision {
    guard !sample.isForwarding else { return .passThrough }

    if let lockedWindowID, lockedWindowID != sample.windowID {
      resetGesture()
    }

    // A fresh gesture clears the previous target here rather than relying on the
    // axis lock's `resetsTarget`: when a `.began` event carries zero or equal
    // deltas the axis is undeterminable, `route` returns nil, and the planner
    // would never see the reset — silently inheriting the last gesture's anchor.
    let isMomentum = !sample.momentumPhase.isEmpty
    if !isMomentum, sample.phase.contains(.began) || sample.phase.isEmpty {
      lockedAnchorID = nil
      lockedWindowID = nil
    }

    guard let gesture = axisLock.route(
      deltaX: sample.deltaX,
      deltaY: sample.deltaY,
      phase: sample.phase,
      momentumPhase: sample.momentumPhase
    ) else {
      return .passThrough
    }

    if gesture.resetsTarget {
      lockedAnchorID = nil
      lockedWindowID = nil
    }

    defer {
      if gesture.endsMomentum {
        resetGesture()
      }
    }

    guard gesture.axis == .vertical else { return .passThrough }

    // Once a vertical target is chosen, follow it through pointer drift. If
    // the gesture began outside every video, there is no target yet, so a later
    // entry may select the current matching anchor and begin page scrolling.
    if let lockedAnchorID,
       let candidate = selectableCandidate(id: lockedAnchorID, in: sample) {
      return .forward(candidate.id)
    }

    guard let candidate = sample.candidates.first(where: { candidate in
      registeredAnchorIDs.contains(candidate.id)
        && candidate.windowID == sample.windowID
        && candidate.isVisible
        && candidate.hasEnclosingScrollView
        && candidate.bounds.contains(candidate.localPoint)
        && candidate.visibleRect.contains(candidate.localPoint)
    }) else {
      return .passThrough
    }

    if axisLock.hasGestureLock {
      lockedAnchorID = candidate.id
      lockedWindowID = sample.windowID
    }
    return .forward(candidate.id)
  }

  private func selectableCandidate(
    id: UUID,
    in sample: VideoScrollWheelRouteSample
  ) -> VideoScrollWheelAnchorCandidate? {
    sample.candidates.first { candidate in
      candidate.id == id
        && registeredAnchorIDs.contains(candidate.id)
        && candidate.windowID == sample.windowID
        && candidate.isVisible
        && candidate.hasEnclosingScrollView
    }
  }
}

@MainActor
private final class VideoScrollWheelBroker {
  static let shared = VideoScrollWheelBroker()

  private final class WeakAnchor {
    weak var value: VideoScrollWheelAnchorView?

    init(_ value: VideoScrollWheelAnchorView) {
      self.value = value
    }
  }

  private var anchors: [UUID: WeakAnchor] = [:]
  private var monitor: Any?
  private var routePlanner = VideoScrollWheelRoutePlanner()
  private var isForwarding = false

  func register(_ anchor: VideoScrollWheelAnchorView) {
    anchors[anchor.routingID] = WeakAnchor(anchor)
    routePlanner.register(anchor.routingID)
    installMonitorIfNeeded()
  }

  func unregister(_ anchor: VideoScrollWheelAnchorView) {
    anchors.removeValue(forKey: anchor.routingID)
    routePlanner.unregister(anchor.routingID)
    removeMonitorIfUnused()
  }

  private func installMonitorIfNeeded() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      precondition(Thread.isMainThread, "AppKit local monitors must run on the main thread")
      return self.handle(event)
    }
  }

  private func removeMonitorIfUnused() {
    pruneReleasedAnchors()
    guard anchors.isEmpty, let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
    routePlanner.resetGesture()
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard !isForwarding, let eventWindow = event.window else { return event }
    pruneReleasedAnchors()
    let sample = VideoScrollWheelRouteSample(
      windowID: ObjectIdentifier(eventWindow),
      point: event.locationInWindow,
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      phase: event.phase,
      momentumPhase: event.momentumPhase,
      isForwarding: isForwarding,
      candidates: anchors.compactMap { id, entry in
        guard let anchor = entry.value, let window = anchor.window else { return nil }
        return VideoScrollWheelAnchorCandidate(
          id: id,
          windowID: ObjectIdentifier(window),
          bounds: anchor.bounds,
          visibleRect: anchor.visibleRect,
          localPoint: anchor.convert(event.locationInWindow, from: nil),
          isVisible: !anchor.isHidden && !anchor.visibleRect.isEmpty,
          hasEnclosingScrollView: anchor.enclosingScrollView != nil
        )
      }
    )

    guard case let .forward(anchorID) = routePlanner.route(sample),
          let anchor = anchors[anchorID]?.value,
          let scrollView = anchor.enclosingScrollView
    else { return event }

    isForwarding = true
    defer { isForwarding = false }
    scrollView.scrollWheel(with: event)
    return nil
  }

  private func pruneReleasedAnchors() {
    let releasedIDs = anchors.compactMap { id, entry in entry.value == nil ? id : nil }
    for id in releasedIDs {
      anchors.removeValue(forKey: id)
      routePlanner.unregister(id)
    }
  }
}

@MainActor
private final class VideoScrollWheelAnchorView: NSView {
  let routingID = UUID()

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      VideoScrollWheelBroker.shared.unregister(self)
    } else {
      VideoScrollWheelBroker.shared.register(self)
    }
  }
}

@MainActor
private struct VideoScrollWheelAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> VideoScrollWheelAnchorView {
    VideoScrollWheelAnchorView(frame: .zero)
  }

  func updateNSView(_ nsView: VideoScrollWheelAnchorView, context: Context) {}

  static func dismantleNSView(_ nsView: VideoScrollWheelAnchorView, coordinator: ()) {
    VideoScrollWheelBroker.shared.unregister(nsView)
  }
}

struct HistoryContentView: View {
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @Environment(\.openSettings) private var openSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var navigationTagsExpanded = true
  @FocusState private var isSearchFocused: Bool
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  /// 灯箱打开时窗口级分栏细线需要让位，避免画在放大的图片上。
  @ObservedObject private var inlineImageLightbox = InlineImageLightboxController.shared
  @ObservedObject private var videoCinema = VideoCinemaController.shared
  /// 列表选中即可预热远程播放；详情卡与预热共享，快速切换时由 controller 取消上一次 prepare。
  @StateObject private var remotePreviewPlayback = RemotePreviewPlayerController()

  private var appearanceTheme: AppearanceTheme { AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass }
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }

  private func synchronizeRemotePreviewPreheat() {
    // 1) 当前抓取可播
    if let target = RemotePlaybackPreheat.playableTarget(
      selectedTaskID: model.selectedTaskID,
      currentCapture: appModel.currentCapture
    ) {
      let duration = appModel.currentCapture?.mediaDescriptor?.durationSeconds
      remotePreviewPlayback.prepare(
        url: target.url,
        companionAudioURL: target.companionAudioURL,
        durationSeconds: duration
      )
      return
    }
    // 2) 历史会话 LRU 里的 descriptor（切换条目时不要 release 毁掉已就绪播放器）
    if let taskID = model.selectedTaskID,
       let descriptor = sessionMediaPlayback.cachedDescriptor(for: taskID),
       case let .playable(url, _, companion) = CurrentCaptureMediaPreview.resolve(descriptor) {
      remotePreviewPlayback.prepare(
        url: url,
        companionAudioURL: companion,
        durationSeconds: descriptor.durationSeconds
      )
      return
    }
    // 3) 无可播目标：驻留当前 ready 播放器，不销毁（回来可秒开）
    remotePreviewPlayback.parkAndIdle()
  }

  var body: some View {
    themedBody
      .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
      // 图片灯箱盖在整个窗口内容之上；点击图外区域或 Esc 退出。
      .overlay { InlineImageLightboxOverlay() }
      // 「已复制」药丸浮层：任何复制动作的统一视觉确认。
      .overlay { CopyFeedbackOverlay() }
      // 视频影院放大 overlay（任何来源）：自己的框，替代坑多的原生全屏。
      .overlay { VideoCinemaOverlay() }
      .foregroundStyle(theme.primaryText)
      .tint(theme.accent)
      .accentColor(theme.accent)
      .onAppear {
        AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw)
        synchronizeRemotePreviewPreheat()
      }
      .onChange(of: model.selectedTaskID) { _, _ in
        synchronizeRemotePreviewPreheat()
      }
      // 自动处理管线：新捕获（浏览器/手动链接）到达即按设置勾选步骤串行处理。
      .onChange(of: appModel.currentCapture?.taskID) { _, newTaskID in
        synchronizeRemotePreviewPreheat()
        guard let taskID = newTaskID else { return }
        let settings = providerSettings
        model.startAutoPipeline(
          taskID: taskID,
          transcribe: settings.autoTranscribeNewCaptures,
          tidy: settings.autoTidyTranscription,
          summarize: settings.autoSummarizeNewCaptures,
          mindMap: settings.autoMindMapNewCaptures,
          tidyModel: settings.effectiveTidyModelName,
          summarizeAction: { [weak model, weak appModel] in
            guard let model, let appModel,
                  let detail = model.detail, detail.task.id == taskID else { return }
            await appModel.summarize(historyDetail: detail, preferences: settings.runPreferences)
          }
        )
      }
      .onChange(of: appearanceThemeRaw) { _, newValue in
        AppearanceTheme.applyApplicationAppearance(newValue)
      }
  }

  private var themedBody: some View {
    Group {
      if model.blockingErrorCode != nil {
        blockingError
      } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          // 两侧辅助列保持紧凑，剩余宽度全部让给右侧正文详情。
          navigationRail.navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } content: {
          sidebar.navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: { detail }
          // 窗口级分栏细线：贯通工具栏直达窗口顶；系统玻璃主题走原生外观，
          // 图片灯箱打开时移除，避免细线盖在放大的图片上。
          .background(WindowColumnDividerInstaller(
            lineColor: (theme.isNative || inlineImageLightbox.url != nil || videoCinema.isPresented) ? nil : NSColor(theme.hairline)
          ))
          .alert(model.deletionConfirmationTitle, isPresented: $model.isDeleteConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelDeletion() }
            Button("删除", role: .destructive) { model.confirmDeletion(protectedTaskIDs: protectedTaskIDs) }
          } message: { Text(model.deletionConfirmationMessage) }
          .alert("正在生成结果", isPresented: $model.isProtectedDeletionAlertPresented) {
            Button("好") { model.dismissProtectedDeletionAlert() }
          } message: {
            Text("选中的记录正在执行生成、转写或识别任务。请先取消对应任务，再删除记录。")
          }
          .alert("无法删除这条历史记录", isPresented: $model.isDeleteFailurePresented) {
            Button("好") { model.dismissDeleteFailure() }
          } message: { Text("本地历史未发生删除，请稍后重试。") }
          .alert("删除结果", isPresented: $model.isDeleteOutcomePresented) {
            Button("好") { model.dismissDeleteOutcome() }
          } message: { Text(model.deleteOutcomeMessage) }
          // 批量总结要花钱，确认弹窗里先给出粗估 token 量级再让用户点。
          .alert(
            model.batchSummaryConfirmationTitle,
            isPresented: $model.isBatchSummaryConfirmationPresented
          ) {
            Button("取消", role: .cancel) { model.cancelBatchSummaryRequest() }
            Button("开始总结") {
              let preferences = providerSettings.runPreferences
              model.confirmBatchSummary(
                summarize: { [weak appModel] detail in
                  await appModel?.summarize(historyDetail: detail, preferences: preferences)
                },
                // 数据去向确认弹窗开着也算「忙」：首条常常要等用户确认一次，
                // 不把它算进去就会被误判成「没能开始」而中止整批。
                isBusy: { [weak appModel] in
                  guard let appModel else { return false }
                  return appModel.runState.isActive
                    || appModel.isDataDestinationDisclosurePresented
                    || appModel.isConfirmingDataDestinationDisclosure
                }
              )
            }
          } message: { Text(model.batchSummaryConfirmationMessage) }
          .alert("批量总结结果", isPresented: $model.isBatchSummaryOutcomePresented) {
            Button("好") { model.dismissBatchSummaryOutcome() }
          } message: { Text(model.batchSummaryOutcomeMessage) }
          .alert("无法准备导出", isPresented: $model.isExportPreparationFailurePresented) {
            Button("好") { model.dismissExportPreparationFailure() }
          } message: { Text("无法准备导出，请检查历史记录后重试。") }
          .alert("无法保存导出文件", isPresented: $model.isExportSaveFailurePresented) {
            Button("好") { model.dismissExportSaveFailure() }
          } message: { Text("请检查所选文件夹的权限后重试。") }
          .alert("视频自动保存失败", isPresented: $model.isCapturedMediaAutoSaveFailurePresented) {
            Button("好") { model.dismissCapturedMediaAutoSaveFailure() }
          } message: { Text(model.capturedMediaAutoSaveFailureMessage) }
          .alert("需要下载 Apple 中文离线模型", isPresented: $model.isTranscriptionModelConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelModelDownloadConfirmation() }
            Button("下载并转写") { model.confirmModelDownloadAndTranscribe() }
          } message: {
            Text("Apple 中文离线模型可能需要下载并占用本机空间。模型准备完成后，视频音频只在这台 Mac 上处理，不会上传。")
          }
          .alert("将视频音频发送到在线转写服务？", isPresented: $model.isOnlineTranscriptionConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelOnlineTranscriptionConfirmation() }
            Button("同意并在线转写") { model.confirmOnlineTranscription() }
          } message: {
            Text("App 会在本机从视频流提取短音频分片，再发送到你配置的 /audio/transcriptions 服务。完整视频和带签名的视频 URL 不会交给模型商家；文字会保存到本机历史。")
          }
          .alert("将转写文字发送给聊天模型整理？", isPresented: $model.isTranscriptTidyConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelTranscriptTidyConfirmation() }
            Button("同意并整理") { model.confirmTranscriptTidy() }
          } message: {
            Text("App 只发送转写文字本身，用于修正标点、分段和明显错别字，不发送视频、音频或链接。整理稿保存为最新原文，原始转写稿保留在历史中。")
          }
          .fileExporter(
            isPresented: $model.isExportPanelPresented,
            document: model.exportFile.map(HistoryExportDocument.init),
            contentType: uniformType(for: model.exportFile?.format ?? .plainText),
            defaultFilename: model.exportFile?.suggestedFilename ?? "LinkDigest 历史.1.txt"
          ) { result in
            switch result {
            case .success: model.completeExportSave()
            case let .failure(error) where isUserCancelledExport(error): model.cancelExport()
            case .failure: model.failExportSave()
            }
          }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        // 批量总结进行中：进度和停止按钮必须一直可见，否则「跑了十几分钟、
        // 现在到哪了、能不能停」全靠猜。
        if model.isBatchSummarizing {
          Text(model.batchSummaryProgressText)
            .font(.callout)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 280, alignment: .trailing)
            .accessibilityIdentifier("batch-summarize-progress")
          Button("停止") { model.stopBatchSummary() }
            .disabled(model.batchSummaryProgress?.isStopping == true)
            .accessibilityIdentifier("batch-summarize-stop")
        }
        if model.selectedTaskCount > 1 {
          Button { model.requestBatchSummary() } label: {
            Label("总结选中项", systemImage: "text.badge.checkmark")
          }
          .disabled(!model.canBatchSummarize)
          .accessibilityIdentifier("batch-summarize-history")
          Button { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) } label: {
            Label("删除选中项", systemImage: "trash")
          }
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
          .accessibilityIdentifier("delete-selected-history")
        }
        Button(action: { openSettings() }) {
          Label("模型设置", systemImage: "gearshape")
        }
        .accessibilityIdentifier("open-provider-settings")
        Menu {
          Button("添加链接", action: manualLink.open)
          Button("从剪贴板添加链接", action: manualLink.readClipboardAndOpen)
        } label: {
          Label("添加链接", systemImage: "link.badge.plus")
        }
        .disabled(!manualLink.canOpen)
        .accessibilityIdentifier("manual-link-add-toolbar")
      }
    }
    .sheet(isPresented: Binding(
      get: { appModel.isDataDestinationDisclosurePresented },
      set: { if !$0 { appModel.cancelDataDestinationDisclosure() } }
    )) {
      if let disclosure = appModel.dataDestinationDisclosure {
        DataDestinationDisclosureView(
          disclosure: disclosure,
          isConfirming: appModel.isConfirmingDataDestinationDisclosure,
          confirm: { Task { await appModel.confirmDataDestinationDisclosure() } },
          cancel: appModel.cancelDataDestinationDisclosure
        )
      }
    }
    .sheet(isPresented: Binding(get: { manualLink.isPresented }, set: { if !$0 { manualLink.dismiss() } })) {
      ManualLinkSheet(model: manualLink)
    }
  }

  private var protectedTaskIDs: Set<TaskID> {
    var result: Set<TaskID> = []
    if let taskID = appModel.activeRunTaskID { result.insert(taskID) }
    if model.transcriptionState.isActive, let taskID = model.transcriptionTaskID { result.insert(taskID) }
    if model.imageTextRecognitionState == .recognizing,
       let taskID = model.imageTextRecognitionTaskID { result.insert(taskID) }
    return result
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("搜索历史", text: $model.searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      // 白底圆角搜索胶囊浮在暖色列表面板上，与参考稿的搜索框一致。
      .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.hairline, lineWidth: 1))
      .padding(.horizontal, 10).padding(.vertical, 10)
        .accessibilityIdentifier("history-search")
        .background(ReleaseInitialSearchFocus().allowsHitTesting(false))
      if model.isReadOnly {
        Label("只读", systemImage: "lock.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.primaryText)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.orange.opacity(0.16), in: Capsule())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10).padding(.bottom, 8)
          .accessibilityIdentifier("history-read-only-banner")
      }
      if let suggestion = manualLink.clipboardSuggestion {
        ClipboardSuggestionBanner(
          suggestion: suggestion,
          capture: manualLink.captureClipboardSuggestion,
          ignore: manualLink.ignoreClipboardSuggestion
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
      switch model.listState {
      case .idle where model.rows.isEmpty:
        ProgressView("正在载入历史记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loading where model.rows.isEmpty:
        ProgressView("正在载入历史记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        if model.hasActiveFilter {
          VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.title3)
            Text(model.hasCategoryFilter ? "该分类下暂无内容" : "没有符合当前筛选条件的历史记录")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-filter-empty")
        } else {
          Spacer()
        }
      case .failed where model.rows.isEmpty:
        VStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle").font(.title2)
          Text("无法载入历史记录").font(.headline)
          if model.canRetryList { Button("重试", action: model.retryList) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded, .loading, .failed, .idle:
        List(selection: $model.selectedTaskIDs) {
          // 排队抓取区：提交链接后立刻回到列表，这里可见进度/失败重试，
          // 不再让用户守着弹窗转圈。
          if !manualLink.pendingCaptures.isEmpty {
            Section {
              ForEach(manualLink.pendingCaptures) { pending in
                PendingCaptureRow(pending: pending, model: manualLink)
              }
            } header: {
              Text("抓取队列").font(.caption).foregroundStyle(.secondary)
            }
          }
          ForEach(model.rows, id: \.taskID) { row in
            HistoryRowView(row: row, model: model).tag(row.taskID).onAppear { model.loadNextPageIfNeeded(after: row) }
              .contextMenu {
                Button { openHistoryURL(row.canonicalURL) } label: { Label("在浏览器中打开", systemImage: "safari") }
                Button { copyHistoryURL(row.canonicalURL) } label: { Label("复制链接", systemImage: "doc.on.doc") }
                if model.selectedTaskIDs.contains(row.taskID), model.selectedTaskCount > 1 {
                  Divider()
                  Button { model.requestBatchSummary() } label: {
                    Label("总结选中的 \(model.selectedTaskCount) 条…", systemImage: "text.badge.checkmark")
                  }
                  .disabled(!model.canBatchSummarize)
                  .accessibilityIdentifier("batch-summarize-history-context")
                }
                Divider()
                Button(role: .destructive) {
                  if !model.selectedTaskIDs.contains(row.taskID) {
                    model.selectedTaskIDs = [row.taskID]
                  }
                  model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
                } label: { Label("删除…", systemImage: "trash") }
                .disabled(model.isReadOnly || model.isDeleting)
              }
          }
          if model.isLoadingNextPage { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() } }
          else if model.listErrorCode != nil, model.canRetryList {
            HStack { Text("无法载入更多").foregroundStyle(.secondary); Spacer(); Button("重试", action: model.retryList) }
          }
        }.listStyle(.sidebar)
          .scrollContentBackground(.hidden)
          .onDeleteCommand { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) }
          // macOS List 对插入行沿用估算行高，新到卡片被压扁；初始构建
          // 的测量始终正确，因此新条目登顶时整表重建（新行本就在顶部，
          // 不损失滚动位置），行高恢复按真实内容计算。
          .id(model.rows.first?.taskID)
      }
    }
    .frame(maxWidth: .infinity)
    .background(theme.isNative ? Color.clear : theme.listPane)
    .focusedSceneValue(\.focusHistorySearch, FocusHistorySearchAction { isSearchFocused = true })
  }

  private var navigationRail: some View {
    List {
      Section {
        navigationButton("全部", systemImage: "tray.full", count: model.navigationCounts.all, selected: model.selectedScope == .all && !model.hasCategoryFilter) {
          model.selectScope(.all)
        }
        .accessibilityIdentifier("history-navigation-all")
        navigationButton("最近", systemImage: "clock", count: model.navigationCounts.recent, selected: model.selectedScope == .recent) {
          model.selectScope(.recent)
        }
        .accessibilityIdentifier("history-navigation-recent")
        navigationButton("未总结", systemImage: "text.badge.xmark", count: model.navigationCounts.unsummarized, selected: model.selectedScope == .unsummarized) {
          model.selectScope(.unsummarized)
        }
        .accessibilityIdentifier("history-navigation-unsummarized")
      }

      if !model.navigationCounts.platforms.isEmpty {
        // 公共平台各占一行；杂项来源聚合进"待分类"，避免侧栏被长域名占满。
        let knownPlatforms = model.navigationCounts.platforms.filter { HistoryPlatformDisplay.isWellKnown(host: $0.host) }
        let miscPlatforms = model.navigationCounts.platforms.filter { !HistoryPlatformDisplay.isWellKnown(host: $0.host) }
        Section("平台") {
          ForEach(knownPlatforms) { platform in
            Button { model.selectHost(platform.host) } label: {
              HStack(spacing: 8) {
                PlatformNavigationIcon(host: platform.host)
                // 平台是"内容从哪来"：展示中文平台名，未知来源回退为域名。
                Text(HistoryPlatformDisplay.name(forHost: platform.host)).lineLimit(1)
                Spacer()
                countBadge(platform.count, selected: model.selectedHosts.contains(platform.host))
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(
              model.selectedHosts.contains(platform.host) ? theme.selectionFill : .clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(model.selectedHosts.contains(platform.host) ? theme.selectionText : theme.primaryText)
            .padding(.horizontal, -6)
            .fontWeight(model.selectedHosts.contains(platform.host) ? .semibold : .regular)
            .accessibilityIdentifier("history-navigation-platform-\(platform.host)")
          }
          if !miscPlatforms.isEmpty {
            let miscHosts = miscPlatforms.map(\.host)
            let miscSelected = model.selectedHosts == Set(miscHosts)
            Button { model.selectHosts(miscHosts) } label: {
              HStack(spacing: 8) {
                Image(systemName: "tray")
                  .font(.system(size: 11))
                  .foregroundStyle(miscSelected ? theme.selectionText : .secondary)
                  .frame(width: 16)
                Text("待分类").lineLimit(1)
                Spacer()
                countBadge(miscPlatforms.reduce(0) { $0 + $1.count }, selected: miscSelected)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(miscSelected ? theme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(miscSelected ? theme.selectionText : theme.primaryText)
            .padding(.horizontal, -6)
            .fontWeight(miscSelected ? .semibold : .regular)
            .help("不常见来源统一归入待分类；点击筛选全部杂项来源。")
            .accessibilityIdentifier("history-navigation-platform-misc")
          }
        }
      }

      if model.navigationCounts.tags.isEmpty {
        // 标签是"内容讲什么"：总结后由模型生成，也可在详情里手动添加。
        // 空态保留区块存在感，而不是让整块消失。
        Section("标签") {
          Text("总结后自动生成，也可在详情中手动添加")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      } else {
        Section {
          DisclosureGroup("标签", isExpanded: $navigationTagsExpanded) {
            // 标签是跨内容的分类关键词：按引用数降序的药丸云，
            // 大类自然浮到最前。
            let ordered = model.navigationCounts.tags.sorted { $0.count > $1.count }
            let tags = model.showsAllNavigationTags ? ordered : Array(ordered.prefix(12))
            TagPillFlowLayout(spacing: 6) {
              ForEach(tags) { item in
                let selected = model.selectedTagNormalizedNames.contains(item.tag.normalizedName)
                Button {
                  // 普通点击即叠加（AND 缩小范围），再点取消；⌘点击=只看这个。
                  model.toggleTag(item.tag, additive: !NSEvent.modifierFlags.contains(.command))
                } label: {
                  HStack(spacing: 4) {
                    Text(item.tag.name).lineLimit(1)
                    Text("\(item.count)")
                      .font(.caption2.monospacedDigit())
                      .foregroundStyle(selected ? theme.selectionText.opacity(0.8) : .secondary)
                  }
                  .font(.caption)
                  .padding(.vertical, 4).padding(.horizontal, 9)
                  .background(
                    selected ? AnyShapeStyle(theme.selectionFill) : AnyShapeStyle(theme.primaryText.opacity(0.06)),
                    in: Capsule()
                  )
                  .overlay(
                    Capsule().strokeBorder(
                      selected ? Color.clear : theme.primaryText.opacity(0.12),
                      lineWidth: 1
                    )
                  )
                  .foregroundStyle(selected ? theme.selectionText : theme.primaryText)
                  .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-navigation-tag-\(item.tag.normalizedName)")
                .help("单击叠加筛选（同时命中所有已选标签），再次单击取消；按住 Command 单击只看此标签。")
              }
            }
            .padding(.vertical, 2)
            if !model.showsAllNavigationTags, model.navigationCounts.tags.count > 12 {
              Button("全部标签…") { model.showsAllNavigationTags = true }
                .accessibilityIdentifier("history-navigation-tags-all")
            }
            if !model.selectedTagNormalizedNames.isEmpty {
              Button("清空标签筛选（\(model.selectedTagNormalizedNames.count)）") { model.clearTagSelection() }
                .accessibilityIdentifier("history-navigation-tags-clear")
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(theme.isNative ? .automatic : .hidden)
    .background(theme.isNative ? Color.clear : theme.canvas)
    .accessibilityIdentifier("history-navigation-rail")
  }

  private func navigationButton(
    _ title: String,
    systemImage: String,
    count: Int,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
        Spacer()
        countBadge(count, selected: selected)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // 图24 的选中态：蓝色实心药丸 + 白字。
    .padding(.vertical, 3).padding(.horizontal, 6)
    .background(selected ? theme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 6))
    .foregroundStyle(selected ? theme.selectionText : theme.primaryText)
    .padding(.horizontal, -6)
    .fontWeight(selected ? .semibold : .regular)
  }

  /// 图24 式计数徽章：灰底小胶囊；选中时反白依附在蓝色药丸上。
  private func countBadge(_ count: Int, selected: Bool) -> some View {
    Text("\(count)")
      .font(.caption.weight(.medium))
      .foregroundStyle(selected ? theme.selectionText : .secondary)
      .padding(.horizontal, 6).padding(.vertical, 1)
      .background(selected ? Color.white.opacity(0.22) : theme.badge, in: Capsule())
  }

  private func openHistoryURL(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    // Same inert-resolver syntax gate as Markdown links: shape check only,
    // navigation stays in the user's default browser.
    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    guard (try? policy.validateSyntax(url)) != nil else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyHistoryURL(_ raw: String) {
    CopyFeedbackController.shared.copy(raw)
  }

  @ViewBuilder private var detail: some View {
    // 系统主题保持原生平铺；浅色/深色主题让内容浮在画布上的圆角卡片里，
    // 给大面积留白一个边界。
    if theme.isNative {
      detailStateContent
    } else {
      detailStateContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.hairline, lineWidth: 1))
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 12))
        .background(theme.canvas)
    }
  }

  @ViewBuilder private var detailStateContent: some View {
    if model.selectedTaskCount > 1 {
      VStack(spacing: 12) {
        Image(systemName: "checklist.checked").font(.system(size: 40)).foregroundStyle(.secondary)
        Text("已选择 \(model.selectedTaskCount) 项").font(.title2.weight(.semibold))
        Text("可从工具栏、右键菜单或 Delete 键批量删除；导出、标签、识别和转写等单条能力暂不可用。")
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("history-multi-selection-placeholder")
    } else {
      switch model.detailState {
    case .loading:
      ProgressView("正在载入详情…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.title2); Text("无法载入这条记录").font(.headline); Button("重试", action: model.retryDetail) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      if let detail = model.detail {
        HistoryDetailView(
          detail: detail,
          model: model,
          appModel: appModel,
          providerSettings: providerSettings,
          appearanceTheme: appearanceTheme,
          localImageURLs: model.localImageURLs,
          localMediaFileURL: model.localMediaFileURL,
          openSettings: { openSettings() },
          remotePreviewPlayback: remotePreviewPlayback,
          sessionMediaPlayback: sessionMediaPlayback
        )
      }
    case .idle:
      emptyDetail
      }
    }
  }

  private var emptyDetail: some View {
    VStack(spacing: 0) {
      // 图标放进软底圆角瓦片，参考稿里 Browse channels 卡片的图形语言。
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 72, height: 72)
        .background(theme.badge, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.hairline, lineWidth: 1))
        .padding(.bottom, 18)
      Text("还没有保存页面").font(.title2.weight(.semibold))
        .padding(.bottom, 6)
      Text("粘贴公开网页链接，或从 \(ProductDisplay.extensionName) 接收已打开的页面后，可在这里总结或翻译。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        .padding(.bottom, 20)
      HStack(spacing: 10) {
        Button(action: manualLink.open) { Label("添加链接", systemImage: "link.badge.plus") }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!manualLink.canOpen)
          .accessibilityIdentifier("manual-link-add")
        Button(action: manualLink.readClipboardAndOpen) { Label("从剪贴板添加链接", systemImage: "doc.on.clipboard") }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(!manualLink.canOpen)
          .accessibilityIdentifier("manual-link-clipboard")
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var blockingError: some View {
    VStack(spacing: 14) {
      Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
      Text("无法打开历史记录").font(.title2.weight(.semibold))
      Text("LinkDigest 未对数据进行写入。请检查本机存储后重新启动 LinkDigest。")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(minWidth: 820, minHeight: 560).accessibilityIdentifier("history-blocking-error")
  }
}

/// 窗口工具栏的主题背景。主窗口与设置窗口共用，避免两处各写一份判据再各自漂移
/// ——设置窗口原来自己写了一份且判据是 `== .paper`，深色主题下工具栏没跟上。
struct HistoryWindowToolbarThemeModifier: ViewModifier {
  let theme: HistoryThemeTokens

  @ViewBuilder func body(content: Content) -> some View {
    if theme.isNative {
      content
    } else {
      content
        .toolbarBackground(theme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }
  }
}

private struct ClipboardSuggestionBanner: View {
  let suggestion: ClipboardLinkSuggestion
  let capture: () -> Void
  let ignore: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("检测到剪贴板链接：\(suggestion.host)")
        .font(.callout.weight(.semibold))
      Text(suggestion.displayURL)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 10) {
        Button("抓取", action: capture)
          .accessibilityIdentifier("history-clipboard-capture")
        Button("忽略", action: ignore)
          .accessibilityIdentifier("history-clipboard-ignore")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("history-clipboard-suggestion")
  }
}

private struct PlatformNavigationIcon: View {
  let host: String

  var body: some View {
    if let image = PlatformIconCatalog.image(for: host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
    } else {
      Text(PlatformIconCatalog.fallbackInitial(for: host))
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(PlatformIconCatalog.fallbackColor(for: host), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
  }
}

private struct ManualLinkSheet: View {
  @ObservedObject var model: ManualLinkViewModel
  @FocusState private var focusURL: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加网页链接").font(.title3.weight(.semibold))
      Text("只读取你主动提交的公开 HTML 页面；登录页面请使用 \(ProductDisplay.extensionName)。")
        .font(.callout).foregroundStyle(.secondary)
      TextField("https://example.com/article", text: $model.input)
        .textFieldStyle(.roundedBorder).focused($focusURL)
        .disabled(model.isBusy).accessibilityIdentifier("manual-link-url-input")
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(.red).accessibilityIdentifier("manual-link-error")
      }
      if model.isFetching { ProgressView(model.fetchingMessage).accessibilityIdentifier("manual-link-fetching") }
      if model.isSaving { ProgressView("正在保存到本机历史…").accessibilityIdentifier("manual-link-saving") }
      HStack {
        Button("取消") { model.dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if model.isFetching {
          Button("停止读取", action: model.cancelFetch).accessibilityIdentifier("manual-link-cancel")
        } else if model.isSaving {
          Text("保存中").foregroundStyle(.secondary).accessibilityIdentifier("manual-link-saving-label")
        } else {
          Button("添加") { model.submit() }
            .keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
            .accessibilityIdentifier("manual-link-submit")
        }
      }
    }
    .padding(24).frame(width: 480)
    .onAppear { focusURL = true }
    .alert("这个链接已在库中", isPresented: $model.isDuplicatePromptPresented) {
      Button("取消", role: .cancel) { model.cancelDuplicateSubmit() }
      Button("仍要重新抓取") { model.confirmDuplicateSubmit() }
    } message: {
      Text("重复添加不会产生新条目：重新抓取的内容会併入原条目成为最新快照。若只想查看，请直接在列表中打开。")
    }
  }
}

/// 抓取队列行：URL + 阶段状态；失败可重试/移除，进行中可取消。
private struct PendingCaptureRow: View {
  let pending: ManualLinkViewModel.PendingCapture
  @ObservedObject var model: ManualLinkViewModel

  var body: some View {
    HStack(spacing: 8) {
      switch pending.phase {
      case .queued:
        Image(systemName: "clock").foregroundStyle(.secondary)
      case .fetching, .saving:
        ProgressView().controlSize(.small)
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(pending.urlString)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        switch pending.phase {
        case .queued: Text("排队中").font(.caption2).foregroundStyle(.tertiary)
        case .fetching: Text("正在抓取…").font(.caption2).foregroundStyle(.tertiary)
        case .saving: Text("正在保存…").font(.caption2).foregroundStyle(.tertiary)
        case let .failed(message):
          Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      if case .failed = pending.phase {
        Button("重试") { model.retryPendingCapture(pending.id) }
          .controlSize(.mini)
      }
      Button {
        model.removePendingCapture(pending.id)
      } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help(pending.phase == .queued ? "移出队列" : "取消并移除")
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("pending-capture-row")
  }
}

private struct HistoryRowView: View {
  let row: HistoryRowProjection
  @ObservedObject var model: HistoryViewModel

  /// 图24 式状态点：已有总结产物为绿色，未总结为橙色。
  private var isSummarized: Bool {
    row.artifactPreview?.trimmedNonEmpty != nil
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(isSummarized ? Color.green : Color.orange)
        .frame(width: 7, height: 7)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 8) {
          Text(CapturedDocumentTitle.display(row.title, for: row.canonicalURL))
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 4)
          favicon
        }
        if let preview = row.artifactPreview?.trimmedNonEmpty ?? row.author?.trimmedNonEmpty {
          Text(preview)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        // 两排时间：第一排发布、第二排创建；发布时间未抓取到时只留创建一排。
        HStack(alignment: .bottom, spacing: 6) {
          VStack(alignment: .leading, spacing: 2) {
            if row.published?.trimmedNonEmpty != nil {
              Text("发布 \(historyPublishedDate(row.published))")
            }
            Text("创建 \(historyCreatedDate(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))")
          }
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          Spacer(minLength: 4)
          // 处理状态徽标：一眼分清生料和成品，自动管线跑完什么立刻可见。
          HStack(spacing: 4) {
            if row.hasTranscript == true {
              Image(systemName: "waveform").help("已转写")
            }
            if row.hasSummary == true {
              Image(systemName: "text.alignleft").help("已总结")
            }
            if row.hasMindMap == true {
              Image(systemName: "brain").help("已生成脑图")
            }
          }
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("history-row-status-badges")
        }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 9)
    .frame(minHeight: 68, alignment: .leading)
    // 新到行在 macOS List 里可能沿用估算行高并把内容压扁；
    // 固定纵向 intrinsic 高度 + 内容变化换 identity，强制按真实内容测量。
    .fixedSize(horizontal: false, vertical: true)
    .id("\(row.taskID.rawValue)-\(row.updatedAtMilliseconds)")
  }

  @ViewBuilder private var favicon: some View {
    if let image = PlatformIconCatalog.image(for: row.host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16).padding(.top, 1)
        .accessibilityLabel("\(row.host) 图标")
    } else if let url = model.faviconImageURL(for: row), let image = HistoryFaviconImageMemoryCache.image(
      at: url,
      host: row.host,
      taskID: row.taskID
    ) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16).padding(.top, 1)
        .accessibilityHidden(true)
    } else {
      // Deterministic initial mark. A source with neither a bundled icon nor a
      // reachable favicon still gets a stable, identifiable badge.
      Text(PlatformIconCatalog.fallbackInitial(for: row.host))
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(PlatformIconCatalog.fallbackColor(for: row.host), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.top, 1)
        .accessibilityLabel("\(row.host) 图标")
    }
  }
}

/// SwiftUI can recompute a row's body many times while selection, scrolling,
/// or favicon callbacks change. This process-local cache keeps disk image
/// decoding out of that hot path. `NSCache` is thread-safe and bounded, so it
/// remains safe when AppKit asks for a view from a different rendering thread.
private enum HistoryFaviconImageMemoryCache {
  nonisolated(unsafe) private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    return cache
  }()

  static func image(at url: URL, host: String, taskID: TaskID) -> NSImage? {
    let hostKey = "host:\(PlatformIconCatalog.normalizedHost(host))" as NSString
    let taskKey = "task:\(taskID.rawValue):\(url.absoluteString)" as NSString
    if let cached = images.object(forKey: taskKey) ?? images.object(forKey: hostKey) { return cached }
    guard let decoded = NSImage(contentsOf: url) else { return nil }
    images.setObject(decoded, forKey: hostKey)
    images.setObject(decoded, forKey: taskKey)
    return decoded
  }
}

/// The detail header needs a recognizable source, not a wire-format URL.
/// Opening and copying still use the untouched value; this is display-only.
enum HistorySourceLinkPresentation {
  static func text(_ rawURL: String) -> String {
    guard let components = URLComponents(string: rawURL),
          var host = components.host?.lowercased(),
          !host.isEmpty
    else { return rawURL }

    if host.hasPrefix("www.") {
      host.removeFirst(4)
    }

    let segments = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).removingPercentEncoding ?? String($0) }

    if (host == "x.com" || host == "twitter.com"),
       segments.count >= 3,
       segments[1].lowercased() == "status" {
      return "\(host) · @\(segments[0]) 的帖子"
    }

    if host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
       segments.count >= 2,
       segments[0].lowercased() == "video" {
      return "\(host) · 视频 \(shortened(segments[1], limit: 18))"
    }

    guard !segments.isEmpty else { return host }
    let path = segments.joined(separator: "/")
    return "\(host) · /\(shortened(path, limit: 32))"
  }

  private static func shortened(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return "\(value.prefix(limit))…"
  }
}

private struct HistoryDetailView: View {
  let detail: HistoryDetailProjection
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel
  let appearanceTheme: AppearanceTheme
  let localImageURLs: [URL]
  let localMediaFileURL: URL?
  let openSettings: () -> Void
  /// 与列表预热共享：选中当前抓取时已开始 prepare，详情卡复用同一 controller。
  @ObservedObject var remotePreviewPlayback: RemotePreviewPlayerController
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isRegeneratePopoverPresented = false
  @State private var isRunPanelExpanded = false
  @State private var showsPlainText = false
  @State private var temporaryModel = ""
  /// Brief completion feedback after summarize/translate finishes.
  @State private var completionBanner: String?
  /// When both a model artifact and the captured source exist, user can switch.
  @State private var readingPane: ReadingPane = .result
  @State private var measuredTitleHeight: CGFloat = HistoryDetailView.titleLineHeight
  /// 转写校对：编辑态与草稿只属于当前详情页，切换条目即复位。
  @State private var isEditingTranscription = false
  @State private var transcriptionDraft = ""
  @AppStorage(ReadingFontSelection.storageKey)
  private var readingFontRaw = ReadingFontSelection.defaultStoredValue
  @AppStorage(ReadingFontSize.storageKey)
  private var readingFontSizeRaw = Double(ReadingFontSize.default)
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }
  /// 用户阅读字体与字号偏好；「跟随主题」回落到主题的编辑排版标记。
  private var readingFont: ResolvedReadingFont {
    ReadingFontSelection(storedValue: readingFontRaw)
      .resolved(
        usesEditorialReadingTypography: appearanceTheme.usesEditorialReadingTypography,
        bodySize: CGFloat(readingFontSizeRaw)
      )
  }
  private enum ReadingPane: String, CaseIterable, Identifiable {
    case result
    case source
    var id: String { rawValue }
  }
  private var newestRun: HistoryDetailProjection.RunDetail? { detail.runs.last }
  /// Newest run that actually produced readable artifact text.
  private var latestArtifactRun: HistoryDetailProjection.RunDetail? {
    detail.runs.reversed().first { run in
      guard let body = run.artifact?.bodyText else { return false }
      return !body.isEmpty
    }
  }
  private var latestArtifact: HistoryArtifact? { latestArtifactRun?.artifact }
  private var latestSnapshot: ContentSnapshot? { detail.snapshots.last }
  /// Source frontmatter belongs to the newest captured source, not a later
  /// local transcription snapshot that may have become the effective body.
  private var latestSourceSnapshot: ContentSnapshot? {
    detail.snapshots.reversed().first { $0.sourceKind != CapturedDocument.Origin.localTranscription.rawValue }
  }
  private var latestTranscriptionSnapshot: ContentSnapshot? {
    detail.snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue && !$0.bodyText.isEmpty
    }
  }
  private var isDouyinCapture: Bool { latestSourceSnapshot?.platform == "douyin" }
  /// 抖音图文帖：正文本身就是内容（文案 + 图集），不像视频帖那样只是重复标题的
  /// caption。原文面板必须给它抓取正文，否则整篇图集会被空的「尚未转写」顶掉。
  /// 判据与 `RemoteMarkdownImageStagingPolicy.isDouyinImagePost` 保持一致。
  private var isDouyinImagePostCapture: Bool {
    guard isDouyinCapture, detail.media == nil, let snapshot = latestSourceSnapshot else { return false }
    return snapshot.bodyText.range(
      of: #"!\[[^\]]*\]\(https?://[^)]*douyinpic\.com/"#,
      options: .regularExpression
    ) != nil
  }
  private var isWeChatCapture: Bool { latestSourceSnapshot?.platform == "wechat" }
  /// Picker label follows the latest successful action — 总结 / 翻译, never a vague「结果」.
  private var resultPaneLabel: String {
    switch latestArtifactRun?.run.kind {
    case .translate: return "翻译"
    case .summarize, .none: return "总结"
    }
  }
  private func paneLabel(_ pane: ReadingPane) -> String {
    pane == .result ? resultPaneLabel : "原文"
  }
  private var title: String { CapturedDocumentTitle.display(detail.snapshots.last?.title, for: sourceURL) }
  private var sourceURL: String { detail.snapshots.last?.sourceURL ?? detail.task.canonicalURL }
  private var sourceURLDisplay: String { HistorySourceLinkPresentation.text(sourceURL) }
  /// Tolaria-style properties from capture frontmatter (author / published / description).
  private var sourceFrontmatter: MarkdownNoteFrontmatter {
    MarkdownNoteFrontmatter.parse(latestSourceSnapshot?.bodyText ?? "")
  }
  private var showsCurrentCapture: Bool { appModel.currentCapture?.taskID == detail.task.id }
  private var showsVisibleRun: Bool { appModel.showsVisibleRun(for: detail.task.id) }
  private var canRunHistory: Bool { appModel.canStartRun(from: detail) }
  private var showsRunControls: Bool { canRunHistory || showsCurrentCapture || showsVisibleRun }
  private var presentsArticleBeforeMedia: Bool {
    guard let latestSnapshot else { return false }
    // X 帖子的正文就是帖子本身，视频是它的附件——按原帖的顺序读才对：文字在上、
    // 视频在下。抖音那类视频帖正好相反（正文只是一句 caption），仍旧视频在前。
    if latestSnapshot.platform == "x" { return true }
    return RemoteMarkdownImageStagingPolicy.isSubstantiveWeChatArticle(
      platform: latestSnapshot.platform,
      markdown: latestSnapshot.bodyText
    )
  }
  private var suppressesEmbeddedMedia: Bool { latestSnapshot?.platform == "wechat" }
  private var hasResultBody: Bool {
    guard let artifact = latestArtifact else { return false }
    return !artifact.bodyText.isEmpty
  }
  /// YouTube 是加密流，不落盘；官方 embed 通道在 App 内直接播放，
  /// 无字幕视频提供内嵌播放音频实时转写入口。
  @ViewBuilder private func youTubeCard(videoID: String) -> some View {
    YouTubeEmbedPlayerCard(videoID: videoID, hasCaptions: youTubeHasCaptions)
      .padding(.top, 14)
      .accessibilityIdentifier("history-youtube-embed-card")
  }

  /// YouTube 正文是否已含字幕（抓取时写入的「## 字幕」节）。
  private var youTubeHasCaptions: Bool {
    guard let body = latestSnapshot?.bodyText else { return false }
    return body.contains("## 字幕")
  }

  private var hasSourceBody: Bool {
    guard let snapshot = isDouyinCapture ? latestTranscriptionSnapshot : latestSnapshot else { return false }
    return !snapshot.bodyText.isEmpty
  }
  private var liveTranscriptionState: TranscriptionUIState {
    model.transcriptionState(for: detail.task.id)
  }
  private var liveTranscriptionText: String {
    model.transcriptionText(for: detail.task.id)
  }
  private var hasLiveTranscription: Bool {
    liveTranscriptionState.isActive || (!liveTranscriptionText.isEmpty && latestTranscriptionSnapshot == nil)
  }
  private var hasPresentableSourceBody: Bool {
    guard let snapshot = latestSnapshot, hasSourceBody else { return false }
    return !CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: snapshot.platform,
      title: title,
      markdown: snapshot.bodyText
    )
  }
  private var availableReadingPanes: [ReadingPane] {
    if isDouyinCapture {
      return ReadingPane.allCases.filter { pane in
        pane == .result ? hasResultBody : (hasSourceBody || hasLiveTranscription)
      }
    }
    return ReadingPane.allCases
  }
  /// For Douyin, source means a saved local transcription—not the duplicate
  /// caption. Other platforms retain their existing source-pane behavior.
  private var showsReadingPanePicker: Bool { hasResultBody || hasSourceBody || hasLiveTranscription }
  private var defaultReadingPane: ReadingPane {
    if hasResultBody { return .result }
    if hasLiveTranscription { return .source }
    if hasPresentableSourceBody { return .source }
    return hasSourceBody ? .source : .result
  }
  /// The preview card exists for the live stream and for failures the reading
  /// pane cannot show. Once a run completed and its result reads in the
  /// 总结/翻译 pane, keeping the card would duplicate the same text on screen.
  private var showsStreamingResultCard: Bool {
    guard showsVisibleRun else { return false }
    if case .completed = appModel.runState, hasResultBody { return false }
    return !appModel.runResultText.isEmpty || appModel.runState.isActive
  }
  private var protectedTaskIDs: Set<TaskID> {
    var result: Set<TaskID> = []
    if let taskID = appModel.activeRunTaskID { result.insert(taskID) }
    if model.transcriptionState.isActive, let taskID = model.transcriptionTaskID { result.insert(taskID) }
    if model.imageTextRecognitionState == .recognizing,
       let taskID = model.imageTextRecognitionTaskID { result.insert(taskID) }
    return result
  }

  var body: some View {
    ScrollView {
      // Title → URL → run/capture metadata (top) → action toolbar → reading → tags.
      VStack(alignment: .leading, spacing: 0) {
        if model.isReadOnly {
          ReadOnlyHistoryCallout(reason: model.historyReadOnlyReason)
            .padding(.bottom, 16)
        }
        if let completionBanner {
          Label(completionBanner, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
            .padding(.bottom, 10)
            .accessibilityIdentifier("history-run-completion-banner")
            .transition(historyBannerTransition(reduceMotion: reduceMotion))
        }
        titleView
        HStack(spacing: 10) {
          Text(sourceURLDisplay)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .textSelection(.enabled)
            .help(sourceURL)
            .accessibilityLabel("来源链接 \(sourceURL)")
          Button("打开") { openSourceURL() }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .linkCursor()
            .accessibilityIdentifier("history-source-url-open")
          Button("复制链接") { CopyFeedbackController.shared.copy(sourceURL) }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .linkCursor()
            .accessibilityIdentifier("history-source-url-copy")
        }
        .padding(.top, 8)

        if sourceFrontmatter.hasProperties || (!isWeChatCapture && sourceFrontmatter.hasEngagementStats) {
          notePropertiesStrip(sourceFrontmatter)
            .padding(.top, 10)
        }

        // Keep run stats under the title (not after the body). Capture-only
        // items show creation time only — never a wall of empty dashes.
        metadata
          .padding(.top, 12)

        if showsRunControls {
          actionToolbar
            .padding(.top, 14)
            .accessibilityIdentifier("history-action-toolbar")
        }

        if presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            .padding(.top, 18)
        }

        if !suppressesEmbeddedMedia {
          // Source properties, run metadata and summarize/translate controls all
          // remain above media; tall portrait video can never hide primary actions.
          if let localMediaFileURL,
             LocalMediaExport.isSupportedLocalFile(localMediaFileURL) {
            HistoryVideoPlayerCard(
              fileURL: localMediaFileURL,
              media: detail.media,
              taskID: detail.task.id,
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              tidyModel: providerSettings.effectiveTidyModelName,
              autoTidyEnabled: providerSettings.autoTidyTranscription
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-player-card")
          } else if localMediaFileURL == nil,
                    showsCurrentCapture,
                    let capture = appModel.currentCapture,
                    let captureDescriptor = capture.mediaDescriptor {
            // 手选清晰度后，优先播放本次会话刚刷新的地址；刷新前仍可立即播放
            // 扩展随抓取带回的地址。否则当前抓取分支会一直压在 session cache
            // 前面，菜单虽然能点，播放器却永远还是旧清晰度。
            let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID)
              ?? captureDescriptor
            CurrentCaptureMediaPreviewCard(
              descriptor: descriptor,
              taskID: capture.taskID,
              snapshotID: capture.snapshotID,
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              playback: remotePreviewPlayback,
              onRefreshStream: {
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: capture.taskID,
                  platform: latestSourceSnapshot?.platform ?? capture.document.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              },
              onSelectQuality: { quality in
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: capture.taskID,
                  platform: latestSourceSnapshot?.platform ?? capture.document.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author,
                  qualityOverride: quality
                )
              },
              selectedQuality: sessionMediaPlayback.chosenQuality(for: capture.taskID)
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-preview-card")
            .id(sessionMediaPlayback.generation)
            streamSelectionDiagnostic
          } else if let youTubeVideoID = YouTubeWatchLink.videoID(from: detail.task.canonicalURL) {
            youTubeCard(videoID: youTubeVideoID)
          } else if let failure = model.localMediaResolutionFailure {
            VStack(alignment: .leading, spacing: 8) {
              Label(failure, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
              Text("请在“设置 → 视频存储”重新选择文件夹，或把已保存的视频移回原位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-local-missing")
          } else if localMediaFileURL == nil,
                    let sessionDescriptor = sessionMediaPlayback.cachedDescriptor(for: detail.task.id),
                    case .playable = CurrentCaptureMediaPreview.resolve(sessionDescriptor) {
            // Session LRU hit: restored streaming without re-persisting signed URLs.
            CurrentCaptureMediaPreviewCard(
              descriptor: sessionDescriptor,
              taskID: detail.task.id,
              snapshotID: latestSourceSnapshot?.id ?? detail.snapshots.last?.id ?? ContentSnapshotID(),
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              playback: remotePreviewPlayback,
              onRefreshStream: {
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              },
              onSelectQuality: { quality in
                // 换档必须丢掉当前播放器：驻留的是旧清晰度那一份，留着会切不过去。
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author,
                  qualityOverride: quality
                )
              },
              selectedQuality: sessionMediaPlayback.chosenQuality(for: detail.task.id)
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-session-restored-card")
            // generation is read so cache/refresh updates re-render this branch.
            .id(sessionMediaPlayback.generation)
            streamSelectionDiagnostic
          } else if HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
            hadMediaDescriptor: detail.hadMediaDescriptor,
            hasLocalMediaFile: localMediaFileURL != nil,
            hasLocalMediaRow: detail.media != nil,
            hasLocalMediaResolutionFailure: model.localMediaResolutionFailure != nil,
            isCurrentCaptureWithDescriptor: showsCurrentCapture
              && appModel.currentCapture?.mediaDescriptor != nil,
            isYouTube: YouTubeWatchLink.videoID(from: detail.task.canonicalURL) != nil,
            isDouyinImagePost: isDouyinImagePostCapture,
            legacyPlatformHint: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
          ) {
            HistorySessionMediaUnavailableCard(
              sourceURL: sourceURL,
              phase: sessionMediaPlayback.activeTaskID == detail.task.id
                ? sessionMediaPlayback.phase
                : .idle,
              refreshAttempts: sessionMediaPlayback.refreshAttempts,
              onRefresh: {
                sessionMediaPlayback.requestRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              }
            )
            .padding(.top, 14)
            .id(sessionMediaPlayback.generation)
          }
        }

        // 脑图区固定在媒体与原文之间：结构化输出先于全文，读图再读文。
        MindMapSectionView(taskID: detail.task.id, model: model)
          .padding(.top, 16)
          .id(ReadingAnchor.module("mindmap"))

        // Video-first captures keep playback before their short source text.
        // Substantive WeChat articles already rendered the reading surface above.
        if !presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            .padding(.top, 18)
        }

        if !localImageURLs.isEmpty {
          imageTextRecognitionCard
            .padding(.top, 16)
            .id(ReadingAnchor.module("images"))
        }

        AnnotationSectionView(taskID: detail.task.id, model: model)
          .padding(.top, 20)
          .id(ReadingAnchor.module("annotations"))

        HistoryTagEditor(tags: detail.tags, model: model)
          .padding(.top, 20)
          .id(ReadingAnchor.module("tags"))
      }
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 40)
      .padding(.top, 32)
      .padding(.bottom, 48)
    }
    // `initial: true` so the first item rendered also lands on the right pane;
    // previously the @State default won and a summary-less item opened on an
    // empty 总结 pane.
    .onChange(of: detail.task.id, initial: true) { _, _ in
      isRunPanelExpanded = false
      showsPlainText = false
      completionBanner = nil
      readingPane = defaultReadingPane
      measuredTitleHeight = HistoryDetailView.titleLineHeight
      // 切换条目时丢弃未保存的转写草稿，避免草稿串到别的记录。
      isEditingTranscription = false
      transcriptionDraft = ""
      sessionMediaPlayback.detailBecameActive(
        taskID: detail.task.id,
        platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
        sourceURL: sourceURL,
        author: sourceFrontmatter.author,
        hadMediaDescriptor: detail.hadMediaDescriptor,
        hasLocalMedia: localMediaFileURL != nil || detail.media != nil,
        isCurrentCaptureWithDescriptor: showsCurrentCapture
          && appModel.currentCapture?.mediaDescriptor != nil,
        isYouTube: YouTubeWatchLink.videoID(from: detail.task.canonicalURL) != nil
      )
    }
    .alert("无法保存转写修改", isPresented: Binding(
      get: { model.snapshotEditFailure != nil },
      set: { if !$0 { model.dismissSnapshotEditFailure() } }
    )) {
      Button("好") { model.dismissSnapshotEditFailure() }
    } message: { Text(model.snapshotEditFailure ?? "") }
    .onChange(of: hasResultBody) { _, hasResult in
      // Prefer the fresh result when a run lands, but keep 原文 one tap away.
      if hasResult { readingPane = .result }
    }
    .onChange(of: showsStreamingResultCard) { wasShown, isShown in
      // The card collapses once the completed result reads in the pane below;
      // flip to 总结/翻译 and flash a banner. Stops and failures keep the card.
      guard wasShown, !isShown, hasResultBody else { return }
      guard case .completed = appModel.runState else { return }
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        readingPane = .result
        completionBanner = latestArtifactRun?.run.kind == .translate ? "翻译已完成" : "总结已完成"
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { completionBanner = nil }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Button("拷贝全文") { copyFullArticle() }
            .accessibilityIdentifier("history-copy-full-text")
          Divider()
          Button("导出 Markdown (.md)") { exportCleanText(.markdown) }
          Button("导出纯文本 (.txt)") { exportCleanText(.plainText) }
          Button("导出 PDF (.pdf)") { exportStyledDocument(.pdf) }
            .accessibilityIdentifier("history-export-pdf")
          Button("导出 Word (.docx)") { exportStyledDocument(.docx) }
            .accessibilityIdentifier("history-export-docx")
          Divider()
          Button("导出完整数据 (.json)") { model.requestExport(.json) }
          Divider()
          Toggle("以纯文本查看正文", isOn: $showsPlainText)
            .accessibilityIdentifier("history-content-plain-text-toggle")
        } label: {
          Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.canExport && !hasReadableBody)
        .accessibilityIdentifier("export-history")
        Button { isRegeneratePopoverPresented = true } label: { Label("重新生成", systemImage: "arrow.clockwise") }
          .disabled(!canRunHistory || !providerSettings.arePreferencesReady)
          .popover(isPresented: $isRegeneratePopoverPresented) { regeneratePopover }
          .accessibilityIdentifier("regenerate-history")
        Button { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) } label: { Label("删除", systemImage: "trash") }
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs)).accessibilityIdentifier("delete-history")
      }
    }
    .accessibilityIdentifier("history-detail")
  }

  private var hasReadableBody: Bool {
    if let artifact = latestArtifact, !artifact.bodyText.isEmpty { return true }
    if let snapshot = detail.snapshots.last, !snapshot.bodyText.isEmpty { return true }
    return false
  }

  /// 拷贝全文：与阅读区同源的正文 Markdown（不含导出 YAML 头）。
  private func copyFullArticle() {
    guard let composed = model.composeExportMarkdown() else { return }
    let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
    CopyFeedbackController.shared.copy(body.isEmpty ? composed.markdown : body)
  }

  /// 富格式导出：按 App 阅读排版渲染 PDF / Word，NSSavePanel 落盘。
  /// 干净正文导出（md / txt）：与阅读区一致，不含 Core 档案元数据。
  private func exportCleanText(_ format: HistoryExportFormat) {
    guard let composed = model.composeExportMarkdown() else { return }
    let content: String
    let ext: String
    switch format {
    case .plainText:
      // 纯文本：剥 Markdown 标记与 frontmatter，只留可读正文。
      let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
      content = MarkdownPresentation.plainTextPresentation(body.isEmpty ? composed.markdown : body)
      ext = "txt"
    default:
      content = composed.markdown
      ext = "md"
    }
    guard let data = content.data(using: .utf8), !data.isEmpty else { model.failExportSave(); return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(composed.baseFilename).\(ext)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url) } catch { model.failExportSave() }
  }

  private func exportStyledDocument(_ kind: StyledExportKind) {
    guard let composed = model.composeExportMarkdown() else { return }
    let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
    let attributed = ReadingDocumentExport.attributedDocument(
      markdown: body.isEmpty ? composed.markdown : body,
      readingFont: readingFont,
      localImageURLs: localImageURLs
    )
    let data: Data?
    switch kind {
    case .pdf: data = ReadingDocumentExport.pdfData(from: attributed)
    case .docx: data = try? ReadingDocumentExport.docxData(from: attributed)
    }
    guard let data, !data.isEmpty else {
      model.failExportSave()
      return
    }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [kind.contentType]
    panel.nameFieldStringValue = "\(composed.baseFilename).\(kind.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url) } catch { model.failExportSave() }
  }

  /// Capsule tool strip under the title — product control, not system Disclosure.
  /// Captions from short-video platforms are the document title here and can run
  /// to several hundred characters. The title stays visually a title (never the
  /// tallest thing on screen) by capping at three lines and scrolling the rest,
  /// rather than truncating text the reader cannot recover any other way.
  private static let titleFontSize: CGFloat = 22
  private static let titleLineHeight: CGFloat = 28
  private static var titleMaximumHeight: CGFloat { titleLineHeight * 3 }

  private var titleNeedsScrolling: Bool { measuredTitleHeight > Self.titleMaximumHeight }

  /// 「登录了为什么还是 720P」只能由这行回答：API 给了哪些档、我们最后选了哪条。
  /// 读代码查不出来，每一环读起来都是通的。
  ///
  /// 必须挂在**每一个**带清晰度菜单的播放卡片下面。之前只有「会话恢复」分支有，
  /// 当前抓取分支没有——于是手选高清后拿不到更高档时，那条分支只是重新加载一遍，
  /// 不给任何说明，表现就是「点了尽量高清没反应」。
  @ViewBuilder private var streamSelectionDiagnostic: some View {
    if let selection = sessionMediaPlayback.selectionDiagnostic {
      Text(selection)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
        .accessibilityIdentifier("history-video-selection-diagnostic")
    }
  }

  @ViewBuilder private var titleView: some View {
    if titleNeedsScrolling {
      ScrollView(.vertical) {
        measuredTitleText
      }
      .frame(height: Self.titleMaximumHeight)
      .scrollBounceBehavior(.basedOnSize)
      .scrollIndicators(.automatic)
      .accessibilityIdentifier("history-detail-title")
    } else {
      measuredTitleText
        .accessibilityIdentifier("history-detail-title")
    }
  }

  private var measuredTitleText: some View {
    Text(title)
      .font(readingFont.font(size: Self.titleFontSize, weight: .bold))
      .foregroundStyle(theme.primaryText)
      .tracking(-0.4)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: TitleHeightPreferenceKey.self, value: proxy.size.height)
        }
      )
      .onPreferenceChange(TitleHeightPreferenceKey.self) { height in
        guard height > 0 else { return }
        measuredTitleHeight = height
      }
  }

  private var actionToolbar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        actionPill(
          title: "总结",
          systemImage: "text.alignleft",
          disabled: !providerSettings.arePreferencesReady || !(showsCurrentCapture ? appModel.canStartRun : appModel.canStartRun(from: detail)),
          identifier: showsCurrentCapture ? "summarize-current-capture" : "summarize-history-detail"
        ) {
          Task {
            if showsCurrentCapture {
              await appModel.summarize(preferences: providerSettings.runPreferences)
            } else {
              await appModel.summarize(historyDetail: detail, preferences: providerSettings.runPreferences)
            }
          }
        }
        actionPill(
          title: "翻译",
          systemImage: "character.book.closed",
          disabled: !providerSettings.arePreferencesReady || !(
            showsCurrentCapture
              ? appModel.canTranslate(preferences: providerSettings.runPreferences)
              : appModel.canTranslate(from: detail, preferences: providerSettings.runPreferences)
          ),
          identifier: showsCurrentCapture ? "translate-current-capture" : "translate-history-detail"
        ) {
          Task {
            if showsCurrentCapture {
              await appModel.translate(preferences: providerSettings.runPreferences)
            } else {
              await appModel.translate(historyDetail: detail, preferences: providerSettings.runPreferences)
            }
          }
        }
        if !providerSettings.arePreferencesReady {
          Button("设置模型") { openSettings() }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .accessibilityIdentifier("history-open-model-settings")
        } else {
          Text(providerSettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "模型未命名" : providerSettings.modelName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        // Live run stays in this row: status + stop. Full stream goes to the
        // reading card (capped height), not an ever-growing chrome panel.
        if showsVisibleRun {
          if appModel.canStopVisibleRun(for: detail.task.id) {
            Button("停止", role: .cancel) { Task { await appModel.stop() } }
              .controlSize(.small)
              .accessibilityIdentifier("stop-model-run")
          }
          if appModel.runState.isActive {
            ProgressView()
              .controlSize(.small)
          }
          Text(appModel.runStatusText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(appModel.runHasFailure ? .red : .secondary)
            .lineLimit(1)
            .accessibilityIdentifier("model-run-status")
        }
        if canRunHistory || showsCurrentCapture || isRunPanelExpanded {
          Button(isRunPanelExpanded ? "收起" : "详情") {
            withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isRunPanelExpanded.toggle() }
          }
          .buttonStyle(.borderless)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-run-panel-toggle")
        }
      }

      // Optional model hints only — never dump streaming tokens here.
      if isRunPanelExpanded {
        captureAndRunControlsExtras
          .transition(historyBannerTransition(reduceMotion: reduceMotion))
      }
    }
  }

  private func actionPill(
    title: String,
    systemImage: String,
    disabled: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(disabled)
    .accessibilityIdentifier(identifier)
  }

  /// Optional hints only (model names / storage). Streaming body lives in the reading card.
  private var captureAndRunControlsExtras: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsCurrentCapture {
        currentCaptureExtras
      } else if canRunHistory {
        Text("使用本机已保存正文生成；结果作为新运行保存。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          settingsModelButton(providerSettings.modelName)
          settingsModelButton(providerSettings.effectiveTranslationModelName)
          Text("输出：\(providerSettings.runPreferences.outputLanguage)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      if showsVisibleRun, appModel.runHasFailure {
        Text(appModel.runStatusText)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("model-run-status-detail")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }

  private var currentCaptureExtras: some View {
    Group {
      HStack(spacing: 8) {
        Text(appModel.connection)
        Text("·")
        Text(appModel.storageStatusText)
      }
      .font(.caption)
      .foregroundStyle(appModel.storageAvailability.isWriteReady ? Color.secondary : Color.orange)
      .accessibilityIdentifier("storage-availability")
      if let notice = appModel.dataDestinationNotice {
        Label(notice, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("data-destination-notice")
      }
    }
  }

  /// 正文下方实际存在的模块。
  ///
  /// 按真实存在与否构造，不写死一张表：列出点了跳不到的死链接比不列更糟。
  /// 脑图、标注、标签区永远渲染（本身带空状态与添加入口），所以恒列；
  /// 图片区只在有本地图片时才存在。
  private var navigationModules: [ReadingModuleLink] {
    var links: [ReadingModuleLink] = [
      .init(anchor: "mindmap", title: "脑图", systemImage: "circle.hexagongrid")
    ]
    if !localImageURLs.isEmpty {
      links.append(.init(
        anchor: "images",
        title: "图片 \(localImageURLs.count)",
        systemImage: "photo.on.rectangle"
      ))
    }
    links.append(.init(anchor: "annotations", title: "标注", systemImage: "highlighter"))
    links.append(.init(anchor: "tags", title: "标签", systemImage: "tag"))
    return links
  }

  private var readingSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsStreamingResultCard {
        streamingResultCard
          .transition(historyBannerTransition(reduceMotion: reduceMotion))
      }
      if showsReadingPanePicker {
        readingPanePicker
      }
      content
    }
    .animation(historyUIAnimation(reduceMotion: reduceMotion), value: showsStreamingResultCard)
    .frame(maxWidth: 590, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, showsReadingPanePicker ? 12 : 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
    )
  }

  private var showsReadingSurface: Bool {
    showsStreamingResultCard || hasResultBody || hasSourceBody || isDouyinCapture
  }

  private var readingPanePicker: some View {
    Picker("阅读内容", selection: $readingPane) {
      ForEach(availableReadingPanes) { pane in
        Text(paneLabel(pane)).tag(pane)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .labelsHidden()
    .frame(maxWidth: 168)
    .accessibilityIdentifier("history-reading-pane-picker")
  }

  /// Generation lives in the reading surface with a fixed max height so the
  /// page does not keep growing as tokens arrive (Apple: status feedback + restraint).
  private var streamingResultCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if appModel.runState.isActive {
          ProgressView().controlSize(.small)
        }
        Text(appModel.runState.isActive ? "生成预览" : "本次结果")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(appModel.runStatusText)
          .font(.subheadline)
          .foregroundStyle(appModel.runHasFailure ? Color.red : Color.secondary)
          .lineLimit(1)
      }
      if appModel.runResultText.isEmpty {
        Text(appModel.runStatusText)
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 12)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            Text(appModel.runResultText)
              .font(.system(size: 15))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.bottom, 4)
              .id("stream-tail")
          }
          .frame(maxHeight: 320)
          .onChange(of: appModel.runResultText) { _, _ in
            withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
              proxy.scrollTo("stream-tail", anchor: .bottom)
            }
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.accentColor.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
    )
    .accessibilityIdentifier("model-run-output")
  }

  @ViewBuilder
  private var metadata: some View {
    if let run = newestRun {
      // Full run strip: only after summarize/translate has produced a Run.
      VStack(alignment: .leading, spacing: 6) {
        metadataRow {
          MetadataItem(symbol: "wand.and.stars", title: "操作", value: historyAction(run.run.kind))
          MetadataItem(symbol: "cpu", title: "模型", value: run.run.model?.trimmedNonEmpty ?? "—")
          MetadataItem(symbol: "calendar", title: "创建时间", value: historyDate(detail.task.createdAtMilliseconds))
        }
        metadataRow {
          // 全文总账：总结/翻译 Run + 整理/脑图台账的累计花费；
          // 各功能的单次用量在各自状态行单独显示。
          MetadataItem(
            symbol: "number",
            title: "Token",
            value: model.taskTokenGrandTotals.map { String($0.totalTokens) } ?? "—",
            detail: model.taskTokenGrandTotals.map {
              "输入 \($0.promptTokens) / 输出 \($0.completionTokens)"
            }
          )
          MetadataItem(symbol: "checkmark.circle", title: "状态", value: historyStatus(run.run.status))
          if let videoMetadataValue {
            MetadataItem(symbol: "play.rectangle", title: "视频", value: videoMetadataValue)
              .accessibilityIdentifier("history-video-metadata")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
      .accessibilityIdentifier("history-run-metadata")
    } else {
      // Capture-only: real creation time, no fake 操作/模型 dashes；
      // 但整理/脑图已产生花费时，Token 总账照样显示。
      metadataRow {
        MetadataItem(
          symbol: "calendar",
          title: "创建时间",
          value: historyDate(detail.task.createdAtMilliseconds)
        )
        if let totals = model.taskTokenGrandTotals {
          MetadataItem(
            symbol: "number",
            title: "Token",
            value: String(totals.totalTokens),
            detail: "输入 \(totals.promptTokens) / 输出 \(totals.completionTokens)"
          )
        }
        if let videoMetadataValue {
          MetadataItem(symbol: "play.rectangle", title: "视频", value: videoMetadataValue)
            .accessibilityIdentifier("history-video-metadata")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
      .accessibilityIdentifier("history-capture-metadata")
    }
  }

  private func metadataRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var videoMetadataValue: String? {
    guard !suppressesEmbeddedMedia else { return nil }

    func descriptorValue(_ descriptor: MediaDescriptor) -> String {
      var parts = [CurrentCaptureMediaPreview.kindLabel(descriptor.kind)]
      if let duration = descriptor.durationSeconds, duration > 0 {
        parts.append(formatMediaDuration(duration))
      }
      if let format = descriptor.mimeType?.split(separator: "/").last,
         !format.isEmpty {
        parts.append(format.uppercased())
      }
      return parts.joined(separator: " · ")
    }

    if showsCurrentCapture,
       let capture = appModel.currentCapture,
       let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID)
         ?? capture.mediaDescriptor {
      return descriptorValue(descriptor)
    }
    if let descriptor = sessionMediaPlayback.cachedDescriptor(for: detail.task.id),
       case .playable = CurrentCaptureMediaPreview.resolve(descriptor) {
      return descriptorValue(descriptor)
    }
    if let media = detail.media {
      var parts = ["本机视频"]
      if let duration = media.durationSeconds, duration > 0 {
        parts.append(formatMediaDuration(duration))
      }
      if media.byteSize > 0 {
        parts.append(ByteCountFormatter.string(fromByteCount: media.byteSize, countStyle: .file))
      }
      return parts.joined(separator: " · ")
    }
    // 无 schema 迁移：用 V2 抓取事实（或极老 V1 抖音）标出「这是视频记录」，不编造时长。
    if HistorySessionMediaPresentation.expectsSessionMedia(
      hadMediaDescriptor: detail.hadMediaDescriptor,
      isDouyinImagePost: isDouyinImagePostCapture,
      legacyPlatformHint: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
    ) {
      return "已抓取 · 此处不可播"
    }
    return nil
  }

  private func formatMediaDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// Lightweight properties strip (Tolaria/Obsidian frontmatter fields), not a full editor.
  @ViewBuilder
  private func notePropertiesStrip(_ note: MarkdownNoteFrontmatter) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let accountName = note.accountName {
        propertyRow(symbol: "building.2", title: "公众号", value: accountName)
      }
      if let author = note.author {
        propertyRow(symbol: "person", title: "作者", value: author)
      }
      if let published = note.published {
        // Raw frontmatter values are often ISO 8601 ("2026-07-21T19:47:07.000Z");
        // present them in the same localized style as the list rows.
        propertyRow(symbol: "calendar", title: "发布", value: historyPublishedDate(published))
      }
      // No cover thumbnail here. The article body already carries its images in
      // the author's own order, and a WeChat cover is usually either a repeat of
      // the first body image or a promotional card that was never part of the
      // reading flow — showing it above the text displaced the actual opening.
      // Do not show meta/og description: often promotional and not article-faithful.
      if !isWeChatCapture && note.hasEngagementStats {
        HStack(spacing: 16) {
          if let likes = note.likes {
            Label(likes, systemImage: "heart")
              .accessibilityIdentifier("history-stats-likes")
          }
          if let comments = note.comments {
            Label(comments, systemImage: "bubble.right")
              .accessibilityIdentifier("history-stats-comments")
          }
          if let shares = note.shares {
            Label(shares, systemImage: "arrowshape.turn.up.right")
              .accessibilityIdentifier("history-stats-shares")
          }
          if let collects = note.collects {
            Label(collects, systemImage: "bookmark")
              .accessibilityIdentifier("history-stats-collects")
          }
          if let views = note.views {
            Label(views, systemImage: "eye")
              .accessibilityIdentifier("history-stats-views")
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .accessibilityIdentifier("history-engagement-stats")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("history-note-properties")
  }

  private func propertyRow(symbol: String, title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).frame(width: 14)
      Text(title).frame(width: 36, alignment: .leading)
      Text(value)
        .foregroundStyle(theme.primaryText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func localImageURL(forRemoteURL remoteURL: String) -> URL? {
    let digest = SHA256.hash(data: Data(remoteURL.utf8)).map { String(format: "%02x", $0) }.joined()
    return localImageURLs.first { $0.lastPathComponent == digest }
  }

  @ViewBuilder private var content: some View {
    switch effectiveReadingPane {
    case .result:
      if let artifact = latestArtifact, !artifact.bodyText.isEmpty {
        if artifact.completeness == .partial {
          Label("\(resultPaneLabel)不完整", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
        }
        // Summaries rarely carry images; still allow local map if present.
        MarkdownContentView(
          source: MarkdownNoteFrontmatter.parse(artifact.bodyText).body,
          sourceURL: URL(string: sourceURL),
          localImageURLs: localImageURLs,
          appendsUnusedLocalImages: !isWeChatCapture,
          readingFont: readingFont,
          primaryTextColor: theme.primaryText,
          secondaryTextColor: theme.secondaryText,
          accentColor: theme.accent,
          showsPlainText: $showsPlainText,
          showsInlinePlainTextToggle: false,
          navigationModules: navigationModules
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-reading-result")
      } else {
        missingPaneNotice(for: .result)
      }
    case .source:
      // 转写进行中时无条件走流式视图：重新转写要立即清掉旧文本并流式
      // 上屏，而不是等落库后整体替换（旧条件只在首次无 snapshot 时流式）。
      if isDouyinCapture, hasLiveTranscription {
        VStack(alignment: .leading, spacing: 12) {
          if liveTranscriptionText.isEmpty {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("正在准备转写内容…").foregroundStyle(.secondary)
            }
          } else {
            Text(liveTranscriptionText)
              .font(readingFont.body())
              .foregroundStyle(theme.primaryText)
              .lineSpacing(MarkdownPresentation.bodyLineSpacing)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .accessibilityIdentifier("history-reading-source-live-transcription")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if let snapshot = (isDouyinCapture && !isDouyinImagePostCapture)
        ? latestTranscriptionSnapshot
        : latestSnapshot, !snapshot.bodyText.isEmpty {
        if captureWasTruncated(snapshot.completeness) {
          Label("捕获内容已截断，生成结果可能不完整。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .accessibilityIdentifier("capture-truncated-notice")
        }
        // 转写是机器听写结果，错别字与分段需要人工兜底；只有本机转写
        // snapshot 提供原地编辑，网页捕获正文保持只读。
        if snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue {
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            if isEditingTranscription {
              Button("取消") {
                isEditingTranscription = false
                transcriptionDraft = ""
              }
              .accessibilityIdentifier("history-transcription-edit-cancel")
              Button("保存") { saveTranscriptionDraft(snapshot) }
                .buttonStyle(.borderedProminent)
                .disabled(transcriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("history-transcription-edit-save")
            } else {
              Button("编辑转写", systemImage: "pencil") {
                transcriptionDraft = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
                isEditingTranscription = true
              }
              .disabled(model.isReadOnly)
              .help("修正听写错别字或调整分段；保存后总结、翻译与导出都使用校对后的文本。")
              .accessibilityIdentifier("history-transcription-edit")
            }
          }
          .padding(.bottom, 8)
        }
        if isEditingTranscription, snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue {
          TextEditor(text: $transcriptionDraft)
            .font(readingFont.body())
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 320, maxHeight: .infinity)
            .padding(10)
            .background(theme.isNative ? Color(nsColor: .textBackgroundColor) : theme.listPane)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.hairline, lineWidth: 1))
            .accessibilityIdentifier("history-transcription-editor")
        } else {
          MarkdownContentView(
            source: MarkdownNoteFrontmatter.parse(snapshot.bodyText).body,
            sourceURL: URL(string: sourceURL),
            localImageURLs: localImageURLs,
            appendsUnusedLocalImages: !isWeChatCapture,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            accentColor: theme.accent,
            showsPlainText: $showsPlainText,
            showsInlinePlainTextToggle: false,
            navigationModules: navigationModules
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-reading-source")
        }
      } else {
        missingPaneNotice(for: .source)
      }
    }
  }

  /// 保留原 frontmatter，只把正文替换为校对稿；无 frontmatter 时整体替换。
  private func saveTranscriptionDraft(_ snapshot: ContentSnapshot) {
    let original = snapshot.bodyText
    let body = MarkdownNoteFrontmatter.parse(original).body
    let newText: String
    if !body.isEmpty, let range = original.range(of: body) {
      newText = original.replacingCharacters(in: range, with: transcriptionDraft)
    } else {
      newText = transcriptionDraft
    }
    model.saveEditedSnapshotText(taskID: detail.task.id, snapshotID: snapshot.id, bodyText: newText)
    isEditingTranscription = false
    transcriptionDraft = ""
  }

  private var effectiveReadingPane: ReadingPane {
    // With neither summary nor transcription, keep the Douyin empty-state in
    // the reading surface without reintroducing an unavailable 原文 segment.
    if isDouyinCapture && !hasResultBody && !hasSourceBody && !hasLiveTranscription { return .source }
    if isDouyinCapture && !availableReadingPanes.contains(readingPane) {
      return defaultReadingPane
    }
    return readingPane
  }

  /// Selecting an empty pane explains itself instead of showing a bare
  /// "暂无可显示的内容", which read as a failure rather than a pending action.
  @ViewBuilder private func missingPaneNotice(for pane: ReadingPane) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch pane {
      case .result:
        Text("尚未生成总结").foregroundStyle(.secondary)
        if canRunHistory || showsCurrentCapture {
          Text("点击上方「生成总结」开始")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
      case .source:
        Text(isDouyinCapture && !isDouyinImagePostCapture ? "尚未转写" : "本条没有抓取到正文")
          .foregroundStyle(.secondary)
        if isDouyinCapture, !isDouyinImagePostCapture,
           model.canTranscribeVideo || (showsCurrentCapture && appModel.currentCapture?.mediaDescriptor.map {
             model.canTranscribeCurrentCapture($0, taskID: detail.task.id)
           } == true) {
          Text("点击上方的『转写』开始")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 24)
    .accessibilityIdentifier(pane == .result ? "history-reading-result-empty" : "history-reading-source-empty")
  }

  private var imageTextRecognitionCard: some View {
    let recognitionState = model.imageTextRecognitionState(for: detail.task.id)
    let recognizedText = model.recognizedImageText(for: detail.task.id)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.indigo.opacity(0.12))
          Image(systemName: "text.viewfinder")
            .foregroundStyle(.indigo)
        }
        .frame(width: 34, height: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text("图片文字识别").font(.headline)
          Text("Apple Vision 本机处理，图片不会上传。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if recognitionState == .recognizing {
          Button("取消", role: .cancel, action: model.cancelImageTextRecognition)
            .controlSize(.small)
        } else {
          Button(recognitionState == .completed ? "重新识别" : "识别文字", action: model.recognizeImageText)
            .controlSize(.small)
            .disabled(!model.canRecognizeImageText)
            .accessibilityIdentifier("history-image-ocr-start")
        }
      }
      switch recognitionState {
      case .idle:
        Text("从正文缓存的 \(localImageURLs.count) 张图片提取可复制文字。")
          .font(.caption).foregroundStyle(.secondary)
      case .recognizing:
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机识别…") }
          .font(.caption).foregroundStyle(.secondary)
      case .completed:
        HStack {
          Label("识别完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          Spacer()
          Button("复制文字") {
            CopyFeedbackController.shared.copy(recognizedText)
          }
          .controlSize(.small)
        }
        .font(.caption)
      case .cancelled:
        Text(LocalImageTextRecognitionError.cancelled.userMessage)
          .font(.caption).foregroundStyle(.secondary)
      case let .failed(message):
        Text(message).font(.caption).foregroundStyle(.red)
      }
      if !recognizedText.isEmpty {
        ScrollView {
          Text(recognizedText)
            .font(.system(size: readingFont.bodySize))
            .lineSpacing(MarkdownPresentation.bodyLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("history-image-ocr-text")
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
  }

  private func settingsModelButton(_ modelName: String) -> some View {
    Button(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未选择模型" : modelName) {
      openSettings()
    }
    .buttonStyle(.link)
    .font(.caption)
    .help("打开模型设置")
  }

  private var regeneratePopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("重新生成").font(.headline)
      Text("直接使用本机保存的正文，不会重新抓取网页。可只为本次运行临时换模型。")
        .font(.caption).foregroundStyle(.secondary)
      TextField("临时模型（留空使用当前模型）", text: $temporaryModel)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("总结") {
          let override = temporaryModel.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
          isRegeneratePopoverPresented = false
          Task {
            await appModel.summarize(
              historyDetail: detail,
              preferences: providerSettings.runPreferences,
              modelOverride: override
            )
          }
        }
        Button("翻译") {
          let override = temporaryModel.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
          isRegeneratePopoverPresented = false
          Task {
            await appModel.translate(
              historyDetail: detail,
              preferences: providerSettings.runPreferences,
              modelOverride: override
            )
          }
        }
        .disabled(!appModel.canTranslate(from: detail, preferences: providerSettings.runPreferences))
      }
    }
    .padding(16)
    .frame(width: 340)
  }

  @ViewBuilder private var localImageGallery: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(localImageURLs, id: \.path) { url in
        if let image = NSImage(contentsOf: url) {
          Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420, alignment: .leading)
        } else {
          Label("图片缓存不可用", systemImage: "photo").foregroundStyle(.secondary)
        }
      }
    }
    .padding(.top, 4)
    .accessibilityIdentifier("github-readme-local-images")
  }

  private func captureWasTruncated(_ completeness: String) -> Bool {
    ["visible_only", "selection_only"].contains(completeness.lowercased())
  }

  private func openSourceURL() {
    guard let url = URL(string: sourceURL) else { return }
    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    guard (try? policy.validateSyntax(url)) != nil else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct TitleHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct HistoryTagEditor: View {
  let tags: [HistoryTag]
  @ObservedObject var model: HistoryViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var input = ""
  @State private var isComposerExpanded = false

  private var canAdd: Bool {
    model.canEditTags
      && tags.count < HistoryTagNormalizer.maximumTagsPerTask
      && HistoryTagNormalizer.normalized(input) != nil
  }

  private var canOpenComposer: Bool {
    model.canEditTags && tags.count < HistoryTagNormalizer.maximumTagsPerTask
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Chips-first: tags sit on the metadata density row, not a heavy form.
      if !tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(tags) { tag in
              HStack(spacing: 4) {
                Text(tag.name).lineLimit(1)
                if model.canEditTags {
                  Button { model.removeTag(tag) } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("移除标签 \(tag.name)")
                }
              }
              .font(.caption)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
            }
            if canOpenComposer {
              addTagControl
            }
          }
        }
        .accessibilityIdentifier("history-tag-chips")
      } else if model.canEditTags {
        // Minimal empty state — no long grey instructional line.
        HStack(spacing: 6) {
          if canOpenComposer {
            addTagControl
          }
        }
        .accessibilityIdentifier("history-tag-empty-hint")
      }

      if isComposerExpanded && model.canEditTags {
        HStack(spacing: 8) {
          TextField("标签名", text: $input)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            .onSubmit(add)
            .accessibilityIdentifier("history-tag-input")
          Button("添加", action: add)
            .disabled(!canAdd)
            .accessibilityIdentifier("history-tag-add")
          Button("取消") {
            isComposerExpanded = false
            input = ""
          }
          .buttonStyle(.borderless)
        }
        let suggestions = model.suggestedTags(matching: input, excluding: tags)
        if !suggestions.isEmpty {
          HStack(spacing: 6) {
            ForEach(suggestions.prefix(5)) { tag in
              Button(tag.name) {
                input = tag.name
                add()
              }
              .buttonStyle(.link)
              .font(.caption)
              .accessibilityIdentifier("history-tag-suggestion-\(tag.normalizedName)")
            }
          }
          .accessibilityIdentifier("history-tag-suggestions")
        }
      }

      if model.tagErrorCode != nil {
        Text("无法更新标签；历史记录未发生更改。")
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("history-tag-error")
      }
    }
    .accessibilityIdentifier("history-tag-editor")
  }

  @ViewBuilder private var addTagControl: some View {
    Button {
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        isComposerExpanded.toggle()
        if !isComposerExpanded { input = "" }
      }
    } label: {
      Label(isComposerExpanded ? "收起" : "添加标签", systemImage: isComposerExpanded ? "xmark" : "plus")
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("history-tag-add-toggle")
  }

  private func add() {
    guard canAdd else { return }
    model.addTag(input)
    input = ""
    isComposerExpanded = false
  }
}

private struct DataDestinationDisclosureView: View {
  let disclosure: DataDestinationDisclosure
  let isConfirming: Bool
  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "arrow.up.doc")
          .font(.largeTitle)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("发送前确认")
            .font(.title3.weight(.semibold))
          Text(actionText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      Text("本次将把网页标题和正文发送到以下模型目的地：")
        .font(.body)

      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("服务") {
          Text(disclosure.identity.host)
            .textSelection(.enabled)
            .accessibilityLabel("模型服务主机 \(disclosure.identity.host)")
        }
        LabeledContent("Base URL") {
          Text(disclosure.identity.normalizedBaseURL)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        LabeledContent("模型", value: disclosure.identity.model)
        LabeledContent("接口", value: "OpenAI-compatible Chat Completions")
      }
      .font(.body)
      .padding(12)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 5) {
        Label("API Key 仍只保存在本机 Keychain，不会显示在此处。", systemImage: "key.horizontal")
        Label("历史记录与导出仍只保存在本机。", systemImage: "internaldrive")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("取消", role: .cancel, action: cancel)
          .disabled(isConfirming)
          .accessibilityIdentifier("data-destination-cancel")
        Button("确认并发送", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(isConfirming)
          .accessibilityIdentifier("data-destination-confirm")
      }
      if isConfirming {
        ProgressView("正在确认发送目的地…")
          .controlSize(.small)
      }
    }
    .padding(24)
    .frame(width: 480)
    .accessibilityIdentifier("data-destination-disclosure")
  }

  private var actionText: String {
    disclosure.intent == .translate ? "确认翻译正文的发送目的地。" : "确认总结正文的发送目的地。"
  }
}

private struct HistoryExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { writableContentTypes }
  static var writableContentTypes: [UTType] { [markdownContentType, .plainText, .json] }
  let data: Data

  init(_ file: HistoryExportFile) { data = file.data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private let markdownContentType = UTType(filenameExtension: "md", conformingTo: .plainText)
  ?? UTType(exportedAs: "com.linkdigest.markdown", conformingTo: .plainText)

private func uniformType(for format: HistoryExportFormat) -> UTType {
  switch format {
  case .markdown: markdownContentType
  case .plainText: .plainText
  case .json: .json
  }
}

private func isUserCancelledExport(_ error: Error) -> Bool {
  let cocoa = error as NSError
  return cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue
}

private struct ReadOnlyHistoryCallout: View {
  let reason: RepositoryRecoveryReason?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock.fill")
        .foregroundStyle(.orange)
        .padding(.top, 1)
      Text(message)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  private var message: String {
    switch reason {
    case .futureSchema:
      "这份历史由较新版本创建，当前仅可浏览。原数据未修改；请使用较新版本的 LinkDigest 后再编辑或删除。"
    case .migrationFailed:
      "这份历史的迁移未完成，当前仅可浏览。原数据未修改；请在恢复后重新启动 LinkDigest，再编辑或删除。"
    case .storageUnavailable:
      "本地历史暂时无法以可写方式打开，当前仅可浏览。原数据未修改；请检查本机存储后重新启动 LinkDigest，再编辑或删除。"
    case nil:
      "本地历史当前仅可浏览。原数据未修改；请在恢复后重新启动 LinkDigest，再编辑或删除。"
    }
  }
}

private struct MetadataItem: View {
  let symbol: String; let title: String; let value: String; let detail: String?
  init(symbol: String, title: String, value: String, detail: String? = nil) {
    self.symbol = symbol; self.title = title; self.value = value; self.detail = detail
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: symbol).frame(width: 14)
        Text(title)
        Text(value).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
      }
      if let detail {
        Text(detail).font(.caption).padding(.leading, 19)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
private extension String {
  var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
  var emptyToNil: String? { trimmedNonEmpty }
}
enum HistoryTimestampFormatter {
  static func text(
    _ milliseconds: Int64?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    guard let milliseconds else { return "—" }
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    var localCalendar = calendar
    localCalendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = localCalendar
    formatter.timeZone = timeZone
    formatter.dateStyle = localCalendar.isDate(date, inSameDayAs: now) ? .none : .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}
private func historyDate(_ milliseconds: Int64?) -> String { HistoryTimestampFormatter.text(milliseconds) }
enum HistoryPublishedTimestampFormatter {
  static func text(
    _ value: String?,
    calendar: Calendar = .autoupdatingCurrent,
    // The app's entire UI is Simplified Chinese but ships unlocalized, so an
    // autoupdating locale falls back to English ("Jul 22, 2026 at 03:47").
    // Pin zh_CN so dates read like the rest of the interface.
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    // 旧抓取可能存有抖音 DOM 的「· 」装饰前缀；展示层剥掉它兜底。
    let cleanedValue = value?
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "^[·•|｜,，\\s]+|[·•|｜,，\\s]+$", with: "", options: .regularExpression)
    guard let value = cleanedValue?.trimmedNonEmpty else { return "发布时间未获取" }
    let standard = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions.insert(.withFractionalSeconds)
    guard let date = standard.date(from: value) ?? fractional.date(from: value) else { return value }
    let localized = DateFormatter()
    localized.locale = locale
    localized.calendar = calendar
    localized.timeZone = timeZone
    localized.dateStyle = .medium
    localized.timeStyle = .short
    return localized.string(from: date)
  }
}
private func historyPublishedDate(_ value: String?) -> String { HistoryPublishedTimestampFormatter.text(value) }
private func historyUpdatedDate(_ milliseconds: Int64) -> String {
  let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "zh_CN")
  formatter.dateStyle = .medium
  formatter.timeStyle = .none
  return formatter.string(from: date)
}
/// 列表行的创建时间：与更新时间同一套 zh_CN 日期样式。
private func historyCreatedDate(_ milliseconds: Int64) -> String { historyUpdatedDate(milliseconds) }
private func historyAction(_ kind: RunKind?) -> String { kind == .translate ? "翻译" : kind == .summarize ? "总结" : "—" }
private func historyStatus(_ status: RunStatus) -> String { switch status { case .queued: "等待中"; case .running: "处理中"; case .completed: "已完成"; case .stopped: "已停止"; case .failed: "未完成"; case .interrupted: "已中断" } }
private func historyTokenBreakdown(_ usage: RunUsageCost?) -> String? {
  guard let usage, usage.inputTokens != nil || usage.outputTokens != nil else { return nil }
  return "输入 \(usage.inputTokens.map(String.init) ?? "—") / 输出 \(usage.outputTokens.map(String.init) ?? "—")"
}

/// Menu-command handle for focusing the sidebar search field (⌘F). Always
/// compares equal so re-rendering does not churn the focused-value registry.
struct FocusHistorySearchAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct FocusHistorySearchKey: FocusedValueKey { typealias Value = FocusHistorySearchAction }

extension FocusedValues {
  var focusHistorySearch: FocusHistorySearchAction? {
    get { self[FocusHistorySearchKey.self] }
    set { self[FocusHistorySearchKey.self] = newValue }
  }
}

enum CapturedSourceBodyPresentation {
  static func isRedundantDouyinBody(
    platform: String?,
    title: String,
    markdown: String
  ) -> Bool {
    guard platform == "douyin" else { return false }
    let titleKey = canonicalText(title)
    var remainder = canonicalText(MarkdownNoteFrontmatter.parse(markdown).body)
    guard !titleKey.isEmpty, !remainder.isEmpty else { return false }
    while remainder.hasPrefix(titleKey) {
      remainder.removeFirst(titleKey.count)
    }
    return remainder.isEmpty
  }

  private static func canonicalText(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
  }
}

struct RemoteMediaDegradationPresentation: Equatable {
  let kindLabel: String
  let message: String
  let nextAction: String
}

enum CurrentCaptureMediaPreviewState: Equatable {
  case playable(url: URL, kind: MediaKind, companionAudioURL: URL?)
  case expired
  case degraded(RemoteMediaDegradationPresentation)
}

/// 远程预览准备阶段：双轨 `loadTracks` 可能要数秒拉 moov，期间必须有文案。
enum RemotePreviewPreparePhase: Equatable {
  case idle
  case preparing
  case ready
  case failed(RemotePreviewPlaybackFailure)
}

/// 可区分的远程播放失败：断网 vs 地址/播放器问题。
enum RemotePreviewPlaybackFailure: Equatable {
  case networkUnavailable
  case generic
  /// 长片仍带着 DASH 双轨地址：应改拉 progressive mp4，不要卡在合成。
  case longFormDualNeedsRefresh

  var message: String {
    switch self {
    case .networkUnavailable:
      return "网络似乎不可用，暂时无法读取视频流。"
    case .generic:
      return "高清流连接失败（可能是杜比视界/编码不兼容或地址失效）。请点「重新获取可播地址」拉取 AVPlayer 能播的最高清档。"
    case .longFormDualNeedsRefresh:
      return "长视频不适合双轨合成。请点「重新获取可播地址」拉取整段可播 MP4。"
    }
  }
}

/// 历史条目在「没有可播放 descriptor」时的展示决策。
/// descriptor / 签名 URL 只在当前抓取内存中有效，从不写入历史——这是设计，不是故障。
enum HistorySessionMediaPresentation {
  /// 是否应把这条历史当作「曾有会话媒体」。
  ///
  /// 优先用抓取事实，而不是平台白名单：
  /// - `hadMediaDescriptor`：来自 `capture_deliveries.capture_contract_version == 2`。
  ///   扩展侧只有存在 `MediaDescriptor` 时才发 V2（见 `captureEnvelopeForPage`），
  ///   因此覆盖 x / bilibili / xiaohongshu / github / generic 等所有会带媒体的抓取，
  ///   而不会把纯文字的 X 帖误判成视频。
  /// - `wechat` 在扩展 `attachDetectedMedia` 里被显式丢弃 media，不会进 V2，不受影响。
  /// - 抖音图文帖不带 mediaDescriptor，也不是 V2 视频路径；若正文仍命中图文启发式则排除。
  /// - `legacyPlatformHint` 仅兜底极老的 V1 抖音视频（无 V2 合同行）；新平台不要往这里加白名单。
  static func expectsSessionMedia(
    hadMediaDescriptor: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    if isDouyinImagePost { return false }
    if hadMediaDescriptor { return true }
    // Legacy V1 douyin video-only path (optional CaptureMedia, not MediaDescriptor).
    return legacyPlatformHint == "douyin"
  }

  /// 是否应显示「有视频但此处不可播」卡片，而不是整块消失。
  static func shouldShowSessionOnlyUnavailable(
    hadMediaDescriptor: Bool,
    hasLocalMediaFile: Bool,
    hasLocalMediaRow: Bool,
    hasLocalMediaResolutionFailure: Bool,
    isCurrentCaptureWithDescriptor: Bool,
    isYouTube: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    guard !hasLocalMediaFile,
          !hasLocalMediaRow,
          !hasLocalMediaResolutionFailure,
          !isCurrentCaptureWithDescriptor,
          !isYouTube else { return false }
    return expectsSessionMedia(
      hadMediaDescriptor: hadMediaDescriptor,
      isDouyinImagePost: isDouyinImagePost,
      legacyPlatformHint: legacyPlatformHint
    )
  }

  static let title = "此记录包含视频"
  static let explanation =
    "临时播放地址只在抓取当次有效，从不写入历史。这是设计行为，不是故障；换到其它条目后，这里不能继续在线播放。"
  static let openSourceActionTitle = "回到原页面观看"
  static let refreshActionTitle = "重新获取播放"
}

/// 列表选中时即可预热：只要 selected 仍是当前抓取且 descriptor 可播，不必等详情 SQLite 载入。
enum RemotePlaybackPreheat {
  static func playableTarget(
    selectedTaskID: TaskID?,
    currentCapture: CurrentCapture?,
    now: Date = Date()
  ) -> (url: URL, companionAudioURL: URL?)? {
    guard let selectedTaskID,
          let capture = currentCapture,
          capture.taskID == selectedTaskID,
          let descriptor = capture.mediaDescriptor,
          case let .playable(url, _, companion) = CurrentCaptureMediaPreview.resolve(descriptor, now: now)
    else { return nil }
    return (url, companion)
  }
}

/// Pure projection from the transient V2 descriptor to user-visible playback state.
/// It never stores or serializes the signed URL; callers may only use the returned
/// URL while the current capture remains in memory.
enum CurrentCaptureMediaPreview {
  static func resolve(
    _ descriptor: MediaDescriptor,
    now: Date = Date()
  ) -> CurrentCaptureMediaPreviewState {
    switch descriptor.kind {
    case .directFile, .hls:
      if let rawExpiry = descriptor.expiresAt {
        guard let expiry = parseExpiry(rawExpiry) else {
          return .degraded(.init(
            kindLabel: kindLabel(descriptor.kind),
            message: "播放地址的有效期无法确认。",
            nextAction: "请回到浏览器重新发送当前视频。"
          ))
        }
        guard expiry > now else { return .expired }
      }
      guard let rawURL = descriptor.ephemeralPlaybackURL,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https" else {
        return .degraded(.init(
          kindLabel: kindLabel(descriptor.kind),
          message: "没有可安全移交给 APP 的播放地址。",
          nextAction: "请回到浏览器重新发送当前视频。"
        ))
      }
      // B 站 DASH 等拆轨源：画面在 ephemeralPlaybackURL，声音在 companionAudioURL。
      let companion: URL? = {
        guard let raw = descriptor.companionAudioURL,
              let audioURL = URL(string: raw),
              audioURL.scheme?.lowercased() == "https" else { return nil }
        return audioURL
      }()
      return .playable(url: url, kind: descriptor.kind, companionAudioURL: companion)
    case .embed:
      return .degraded(.init(
        kindLabel: kindLabel(descriptor.kind),
        message: "这是嵌入式视频。本轮只显示承接容器，不在 APP 内加载网页播放器。",
        nextAction: "请返回原浏览器继续观看。"
      ))
    case .browserSessionOnly, .unsupported:
      return .degraded(failurePresentation(for: descriptor))
    }
  }

  static func isFavoriteEligible(_ descriptor: MediaDescriptor) -> Bool {
    descriptor.kind == .directFile
      && descriptor.ephemeralPlaybackURL.flatMap(URL.init(string:))?.scheme?.lowercased() == "https"
  }

  static func favoriteMedia(_ descriptor: MediaDescriptor) -> CaptureMedia? {
    guard isFavoriteEligible(descriptor), let playbackURL = descriptor.ephemeralPlaybackURL else { return nil }
    return CaptureMedia(
      platform: descriptor.platform,
      videoURL: playbackURL,
      // 画面与声音分成两条流时，音轨要一起传下去，否则存到本机的会是无声视频。
      companionAudioURL: descriptor.companionAudioURL,
      coverURL: descriptor.posterURL,
      durationSeconds: descriptor.durationSeconds,
      author: descriptor.author
    )
  }

  static func favoriteUnavailableMessage(_ descriptor: MediaDescriptor) -> String {
    switch descriptor.kind {
    case .hls: "暂不支持保存 HLS；你仍可在当前会话中速览。"
    case .embed: "嵌入式视频暂不支持收藏到本机。"
    case .browserSessionOnly: "该视频只能在原浏览器会话观看，不能收藏到本机。"
    case .unsupported: "该视频当前不能收藏到本机。"
    case .directFile: "当前直连视频地址不可用，请回到浏览器重新发送。"
    }
  }

  static func kindLabel(_ kind: MediaKind) -> String {
    switch kind {
    case .directFile: "直连视频"
    case .hls: "HLS 串流"
    case .embed: "嵌入式视频"
    case .browserSessionOnly: "浏览器会话视频"
    case .unsupported: "暂不支持的视频"
    }
  }

  private static func parseExpiry(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = fractional.date(from: raw) { return value }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: raw)
  }

  private static func failurePresentation(for descriptor: MediaDescriptor) -> RemoteMediaDegradationPresentation {
    let message: String
    let nextAction: String
    // X 的 blob/MSE 不是死路：App 会用嵌入式推文的公开端点换回直链，在后台把
    // 视频下下来。下载完成前先如实说「正在获取」，别让用户以为抓失败了——
    // 这段空窗正是「刚抓进来那几秒显示受限、刷新后才正常」的由来。
    if descriptor.platform == "x", descriptor.failureReason == .blobOrMSE {
      return .init(
        kindLabel: "浏览器会话视频",
        message: "正在为这条帖子获取视频…",
        nextAction: "获取完成后会自动出现在这里；若稍后仍是这条提示，说明这条视频没能取到。"
      )
    }
    switch descriptor.failureReason ?? .unknown {
    case .blobOrMSE:
      message = "这个视频使用 blob/MSE，只能在原浏览器会话观看。"
      nextAction = "请返回原浏览器继续观看。"
    case .drmOrEncrypted:
      message = "这个视频受 DRM 或加密保护，APP 不能接管播放。"
      nextAction = "请返回提供内容的原浏览器页面观看。"
    case .multipleCandidates:
      message = "页面上有多个视频，暂时无法唯一确定你要观看的那一个。"
      nextAction = "请在浏览器中播放目标视频后重新发送。"
    case .videoNotLoaded:
      message = "视频尚未加载，浏览器还没有可移交的媒体源。"
      nextAction = "请先在浏览器中播放视频，再重新发送。"
    case .browserSessionRequired:
      message = "播放依赖原浏览器登录会话，APP 不会读取或转移 Cookie。"
      nextAction = "请返回原浏览器继续观看。"
    case .noTransferableSource:
      message = "浏览器没有找到可安全移交给 APP 的媒体源。"
      nextAction = "请回到浏览器确认视频已播放后重新发送。"
    case .unsupportedMediaType:
      message = "当前媒体格式不受 APP 播放器支持。"
      nextAction = "请返回原浏览器继续观看。"
    case .unknown:
      message = "当前视频无法安全移交给 APP。"
      nextAction = "请返回原浏览器继续观看，或稍后重新发送。"
    }
    return .init(kindLabel: kindLabel(descriptor.kind), message: message, nextAction: nextAction)
  }
}

/// Builds AVURLAssets for remote playback. Douyin (`*.douyinvod.com`) and WeChat
/// (`*.qpic.cn`) video CDNs return HTTP 403 to any request that lacks a browser
/// User-Agent and the matching site Referer — AVFoundation's defaults (its own
/// UA, no Referer) are rejected. We attach the required headers for https sources
/// so the App's player is accepted; local `file://` assets are returned unchanged.
///
/// B 站 DASH 的 `.m4s` 常返回 `application/octet-stream`，需额外注入
/// `AVURLAssetOutOfBandMIMETypeKey`（与 HTTP header key 一样是非公开常量字符串）。
/// 构造失败或 playerItem 失败时由 `RemotePreviewPlayerController` 回退到仅 header 路径。
enum RemotePlaybackAsset {
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  static func referer(forHost host: String?) -> String? {
    guard let host = host?.lowercased() else { return nil }
    if host == "douyin.com" || host.hasSuffix(".douyin.com")
      || host.hasSuffix("douyinvod.com") || host.hasSuffix("douyincdn.com") {
      return "https://www.douyin.com/"
    }
    if host.hasSuffix("qpic.cn") || host.hasSuffix("qq.com") {
      return "https://mp.weixin.qq.com/"
    }
    // 实测 `*.bilivideo.com` 无 Referer 一律 403，带站点根 Referer 即 206。
    if host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
      || host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
      return "https://www.bilibili.com/"
    }
    return nil
  }

  static func isBilibiliPlaybackHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
      || host == "bilibili.com" || host.hasSuffix(".bilibili.com")
      || host.hasSuffix("hdslb.com")
  }

  /// HTTPS 源需要的浏览器 UA + 平台 Referer。`file://` 返回 nil。
  /// B 站会员/高清 CDN 常需会话 Cookie；只用于内存播放请求，永不落盘。
  static func httpHeaders(for url: URL, cookieHeader: String? = nil) -> [String: String]? {
    guard url.scheme?.lowercased() == "https" else { return nil }
    var headers: [String: String] = ["User-Agent": browserUserAgent]
    if let referer = referer(forHost: url.host) {
      headers["Referer"] = referer
      if isBilibiliPlaybackHost(url.host) {
        headers["Origin"] = "https://www.bilibili.com"
      }
    }
    if let cookieHeader, !cookieHeader.isEmpty, isBilibiliPlaybackHost(url.host) {
      headers["Cookie"] = cookieHeader
    }
    return headers
  }

  /// 带 out-of-band MIME 提示的远程资产。`file://` 本地资产维持原样。
  static func make(
    url: URL,
    role: StreamingComposition.MIMERole = .video,
    cookieHeader: String? = nil
  ) -> AVURLAsset {
    StreamingComposition.urlAsset(
      url: url,
      role: role,
      httpHeaders: httpHeaders(for: url, cookieHeader: cookieHeader),
      applyOutOfBandMIME: true
    )
  }

  /// 回退路径：只注入 HTTP header，不加 MIME 提示（改动前的行为）。
  static func makeLegacy(url: URL, cookieHeader: String? = nil) -> AVURLAsset {
    guard let headers = httpHeaders(for: url, cookieHeader: cookieHeader) else {
      return AVURLAsset(url: url)
    }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
  }
}

@MainActor
final class RemotePreviewPlayerController: ObservableObject {
  /// 双轨远程流式合成最长等待；超时后改走「带 Cookie 下载到临时文件再合成」。
  /// 长片 DASH 不宜拖太久——选流层应已优先 progressive。
  static var dualTrackPrepareTimeoutSeconds: TimeInterval = 12
  /// 手选清晰度时的双轨准备超时。12 秒是按 480p 双轨调的（实测 3.3 秒余量充足）；
  /// 4K 的 moov 大好几倍，实测 12 秒内经常下不完，手选高清就多等一会。
  static var dualTrackPrepareTimeoutSecondsUserChosen: TimeInterval = 40
  /// 当前 prepare 是否来自用户手选清晰度（决定超时档位与诊断文案）。
  private var currentAllowsLongFormDual = false
  /// 下载双轨兜底最长等待；仍失败才进入 failed（禁止黑屏假 ready）。
  /// 长片/高清整轨下载通常会因体积预检直接放弃，无需等满。
  static var dualTrackDownloadTimeoutSeconds: TimeInterval = 45
  /// HEAD 预检超时（不可达地址应快速放弃，避免拖死 UI）。
  static var dualTrackProbeTimeoutSeconds: TimeInterval = 2
  /// 已就绪播放器驻留条数：切换历史再回来可秒开，不必黑屏重连。
  static var parkedPlayerCapacity = 4

  @Published private(set) var player: AVPlayer?
  @Published private(set) var preparePhase: RemotePreviewPreparePhase = .idle
  /// 失败时可见的技术细节：走的哪条路、片长、错误码。
  /// 只放非敏感信息——不含签名 URL、不含 Cookie。
  /// 这一层之前完全没有，失败了只能靠猜，反复改了七轮都没定位到根因。
  @Published private(set) var playbackDiagnostic: String?
  private var currentURL: URL?
  private var currentCompanionAudioURL: URL?
  /// 当前准备使用的会话 Cookie（B 站等）；仅内存，不写历史。
  private var currentCookieHeader: String?
  /// 已经走完「仅 header、无 MIME / 无合成」回退时为 true，避免无限重试。
  private var usedLegacyPath = false
  private var prepareTask: Task<Void, Never>?
  /// 双轨下载兜底产生的临时目录；release / 下次 prepare 时清理。
  private var dualTrackTempDirectory: URL?
  /// 最近若干条已就绪播放器（MRU 在末尾）；切走时 park，切回时 restore。
  private var parkedPlayers: [ParkedRemotePlayback] = []

  var hasPlayer: Bool { player != nil }

  /// 增强路径失败后能否退单 URL。双轨 DASH（画面+声音）的 video-only 回退通常黑屏不可播，禁止假 ready。
  var canFallbackToLegacy: Bool {
    !usedLegacyPath && currentURL != nil && currentCompanionAudioURL == nil
  }

  var isPreparing: Bool { preparePhase == .preparing }

  /// 测试/诊断：当前驻留的 ready 播放器数量。
  var parkedPlayerCount: Int { parkedPlayers.count }

  func prepare(
    url: URL,
    companionAudioURL: URL? = nil,
    cookieHeader: String? = nil,
    durationSeconds: Double? = nil,
    allowLongFormDual: Bool = false
  ) {
    // 长片 + DASH 双轨：禁止进入易卡死的合成路径。
    // progressive mp4 可单轨；纯 m4s 双轨则立刻 failed，催促重新获取整段 MP4。
    // 例外：用户手选了清晰度（allowLongFormDual）——高清只存在于双轨里，
    // 硬闸不让位的话会和粘住的 override 打成刷新死循环。合成路径自身有
    // 12 秒超时和下载兜底，不会无限卡。
    var companion = companionAudioURL
    if companion != nil,
       !allowLongFormDual,
       BilibiliPlaybackRefresher.prefersProgressiveForDuration(durationSeconds) {
      if Self.isLikelyProgressiveMuxedURL(url) {
        companion = nil
      } else {
        if currentURL == url, currentCompanionAudioURL == companionAudioURL,
           case .failed(.longFormDualNeedsRefresh) = preparePhase {
          return
        }
        parkCurrentIfReady()
        cancelPrepare()
        cleanupDualTrackTemp()
        currentURL = url
        currentCompanionAudioURL = companionAudioURL
        currentCookieHeader = cookieHeader
        usedLegacyPath = false
        player = nil
        preparePhase = .failed(.longFormDualNeedsRefresh)
        return
      }
    }

    // 同一目标已在准备中或已就绪：列表预热与详情卡 onAppear 共用，禁止重启 cancel。
    if currentURL == url,
       currentCompanionAudioURL == companion,
       (cookieHeader == nil || cookieHeader == currentCookieHeader) {
      switch preparePhase {
      case .preparing, .ready:
        return
      case .failed:
        break // 允许重试
      case .idle:
        if player != nil { return }
      }
    }

    // 驻留命中：切回历史条目时直接恢复，避免黑屏重连。
    if let parked = takeParked(url: url, companionAudioURL: companion) {
      parkCurrentIfReady()
      cancelPrepare()
      cleanupDualTrackTemp()
      currentURL = parked.url
      currentCompanionAudioURL = parked.companionAudioURL
      currentCookieHeader = parked.cookieHeader ?? cookieHeader
      usedLegacyPath = parked.usedLegacyPath
      player = parked.player
      preparePhase = .ready
      return
    }

    // 切换目标：把当前 ready 播放器 park 起来，而不是毁掉。
    parkCurrentIfReady()
    cancelPrepare()
    cleanupDualTrackTemp()
    player = nil
    currentURL = url
    currentCompanionAudioURL = companion
    currentCookieHeader = cookieHeader
    currentAllowsLongFormDual = allowLongFormDual
    usedLegacyPath = false
    preparePhase = .preparing

    if companion != nil || needsSessionCookieLookup(for: url) {
      // 双轨 / B 站：异步取 Cookie 再合成；禁止无限 preparing。
      prepareTask = Task { @MainActor in
        await self.prepareRemotePlayback(
          url: url,
          companionAudioURL: companion,
          providedCookie: cookieHeader
        )
      }
    } else {
      installEnhancedVideoOnly(url: url, cookieHeader: cookieHeader)
    }
  }

  /// 离开可播上下文时：驻留 ready 播放器，清空当前展示（不销毁缓存）。
  func parkAndIdle() {
    parkCurrentIfReady()
    cancelPrepare()
    cleanupDualTrackTemp()
    player = nil
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  static func isLikelyProgressiveMuxedURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let abs = url.absoluteString.lowercased()
    return path.hasSuffix(".mp4") || path.contains(".mp4") || abs.contains(".mp4")
  }

  private func needsSessionCookieLookup(for url: URL) -> Bool {
    RemotePlaybackAsset.isBilibiliPlaybackHost(url.host)
  }

  /// 取会话 Cookie（若调用方未传）→ 双轨合成或单轨增强。
  private func prepareRemotePlayback(
    url: URL,
    companionAudioURL: URL?,
    providedCookie: String?
  ) async {
    var cookie = providedCookie
    if cookie == nil || cookie?.isEmpty == true,
       RemotePlaybackAsset.isBilibiliPlaybackHost(url.host) {
      cookie = await SiteSessionController.bilibili.cookieHeader()
      if !Task.isCancelled, currentURL == url {
        currentCookieHeader = cookie
      }
    }
    guard !Task.isCancelled, currentURL == url else { return }

    if let companionAudioURL {
      await prepareDualTrack(
        url: url,
        companionAudioURL: companionAudioURL,
        cookieHeader: cookie
      )
    } else {
      installEnhancedVideoOnly(url: url, cookieHeader: cookie)
    }
  }

  /// 1) 远程流式双轨合成（快）→ 2) 带 Cookie 下载到临时文件再合成（稳）→ 3) failed。
  /// 绝不回退到「仅画面 m4s 假 ready」（黑屏 --:--）。
  private func prepareDualTrack(
    url: URL,
    companionAudioURL: URL,
    cookieHeader: String?
  ) async {
    let headers = RemotePlaybackAsset.httpHeaders(for: url, cookieHeader: cookieHeader)
    let box = DualTrackAssetBox()
    let work = Task { @MainActor in
      do {
        box.asset = try await StreamingComposition.makePlayableAsset(
          videoURL: url,
          companionAudioURL: companionAudioURL,
          httpHeaders: headers,
          applyOutOfBandMIME: true
        )
      } catch {
        box.error = error
      }
      box.done = true
    }
    let timeoutSeconds = currentAllowsLongFormDual
      ? Self.dualTrackPrepareTimeoutSecondsUserChosen
      : Self.dualTrackPrepareTimeoutSeconds
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(timeoutSeconds)
    var timedOut = false
    while !box.done {
      if Task.isCancelled {
        work.cancel()
        return
      }
      if Date() >= deadline {
        work.cancel()
        timedOut = true
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    guard !Task.isCancelled, currentURL == url else { return }

    if let asset = box.asset {
      player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      preparePhase = .ready
      return
    }
    if Self.isNetworkUnavailable(box.error) {
      playbackDiagnostic = Self.diagnosticLine(
        stage: "准备阶段",
        isDual: true,
        host: url.host,
        error: box.error
      )
      preparePhase = .failed(.networkUnavailable)
      return
    }

    // 远程流式失败/超时：改用「带 Cookie 下载双轨 → 本地合成」。
    // AVPlayer 对流式 m4s 偶发挂起，但同一 URL 用 URLSession 下载通常可通。
    if let asset = await downloadAndComposeDualTrack(
      videoURL: url,
      audioURL: companionAudioURL,
      headers: headers
    ) {
      guard !Task.isCancelled, currentURL == url else { return }
      player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      preparePhase = .ready
      return
    }
    guard !Task.isCancelled, currentURL == url else { return }
    // 超时和真失败必须分开写：超时时 box.error 是 nil，混在一起就成了
    // 没有任何线索的「连接失败」。附上实际等待秒数和超时档位。
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    let stage = timedOut
      ? "流式合成超时（等了 \(elapsed)s / 上限 \(Int(timeoutSeconds))s）· 下载兜底也未成"
      : "准备阶段（含下载兜底）"
    playbackDiagnostic = Self.diagnosticLine(
      stage: stage,
      isDual: true,
      host: url.host,
      error: box.error
    )
    preparePhase = .failed(.generic)
  }

  /// 用与 AVPlayer 相同的 UA/Referer/Cookie 下载两条轨到临时目录，再内存合成。
  /// 跳过超大体积（4K 整片数 GB）——会拖死 90s 超时且占满磁盘；应依赖可播档位选流。
  private static let dualTrackDownloadMaxBytes: Int64 = 180 * 1_024 * 1_024

  private func downloadAndComposeDualTrack(
    videoURL: URL,
    audioURL: URL,
    headers: [String: String]?
  ) async -> AVAsset? {
    cleanupDualTrackTemp()

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-dual-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    dualTrackTempDirectory = dir

    let videoDest = dir.appendingPathComponent("video.m4s")
    let audioDest = dir.appendingPathComponent("audio.m4s")
    let maxBytes = Self.dualTrackDownloadMaxBytes
    let box = DualTrackAssetBox()
    let work = Task { @MainActor in
      do {
        // HEAD 体积预检放在限时 work 内，避免不可达地址拖死 preparing。
        let probeTimeout = Self.dualTrackProbeTimeoutSeconds
        if let videoLen = await Self.probeContentLength(
          url: videoURL, headers: headers, timeout: probeTimeout
        ), videoLen > maxBytes {
          throw URLError(.dataLengthExceedsMaximum)
        }
        if let audioLen = await Self.probeContentLength(
          url: audioURL, headers: headers, timeout: probeTimeout
        ), audioLen > maxBytes {
          throw URLError(.dataLengthExceedsMaximum)
        }
        // 并行下载两条轨；合成仍在 MainActor。
        async let videoDL: Void = Self.downloadFile(from: videoURL, to: videoDest, headers: headers)
        async let audioDL: Void = Self.downloadFile(from: audioURL, to: audioDest, headers: headers)
        try await videoDL
        try await audioDL
        // 本地 file:// 不再需要 MIME/header。
        box.asset = try await StreamingComposition.makePlayableAsset(
          videoURL: videoDest,
          companionAudioURL: audioDest,
          httpHeaders: nil,
          applyOutOfBandMIME: false
        )
      } catch {
        box.error = error
      }
      box.done = true
    }

    let deadline = Date().addingTimeInterval(Self.dualTrackDownloadTimeoutSeconds)
    while !box.done {
      if Task.isCancelled {
        work.cancel()
        cleanupDualTrackTemp()
        return nil
      }
      if Date() >= deadline {
        work.cancel()
        cleanupDualTrackTemp()
        return nil
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if let asset = box.asset {
      return asset
    }
    cleanupDualTrackTemp()
    return nil
  }

  nonisolated private static func downloadFile(
    from url: URL,
    to destination: URL,
    headers: [String: String]?
  ) async throws {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    if let headers {
      for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    let (tempURL, response) = try await URLSession.shared.download(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: tempURL, to: destination)
  }

  nonisolated private static func probeContentLength(
    url: URL,
    headers: [String: String]?,
    timeout: TimeInterval
  ) async -> Int64? {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = max(0.05, timeout)
    if let headers {
      for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode)
    else { return nil }
    let length = http.expectedContentLength
    return length > 0 ? length : nil
  }

  /// playerItem 进入 `.failed` 时调用：退回旧的单 URL + header 路径（仅单轨源）。
  @discardableResult
  func fallbackToLegacyIfNeeded() -> Bool {
    guard canFallbackToLegacy, let url = currentURL else { return false }
    installLegacy(url: url, cookieHeader: currentCookieHeader)
    return true
  }

  /// 播放器运行时失败：区分断网与一般失败，供 UI 展示与重试。
  func markPlaybackFailed(error: Error?) {
    playbackDiagnostic = Self.diagnosticLine(
      stage: "播放中",
      isDual: currentCompanionAudioURL != nil,
      error: error
    )
    if Self.isNetworkUnavailable(error) {
      preparePhase = .failed(.networkUnavailable)
    } else {
      preparePhase = .failed(.generic)
    }
  }

  /// 拼一行可见的失败细节。只用非敏感字段：轨道形态、主机名、错误域与码。
  /// 明确不含签名 URL 的 query（里面有 deadline / 鉴权串）和 Cookie。
  static func diagnosticLine(
    stage: String,
    isDual: Bool,
    host: String? = nil,
    durationSeconds: Double? = nil,
    error: Error?
  ) -> String {
    var parts: [String] = [stage, isDual ? "双轨合成" : "整段单轨"]
    if let durationSeconds, durationSeconds > 0 {
      parts.append(String(format: "片长 %.0f 分钟", durationSeconds / 60))
    }
    if let host, !host.isEmpty { parts.append(host) }
    if let error = error as NSError? {
      parts.append("\(error.domain) \(error.code)")
    }
    return parts.joined(separator: " · ")
  }

  /// 用户点「重试」：同一 URL 重新 prepare（含网络恢复后 / 重新取 Cookie）。
  func retry() {
    guard let url = currentURL else { return }
    let companion = currentCompanionAudioURL
    let cookie = currentCookieHeader
    // 丢掉该 URL 的驻留，强制重连。
    removeParked(url: url, companionAudioURL: companion)
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    player = nil
    usedLegacyPath = false
    preparePhase = .idle
    prepare(url: url, companionAudioURL: companion, cookieHeader: cookie)
  }

  /// 彻底释放：清空当前 + 全部驻留（App 退出可播区或显式销毁时用）。
  func release() {
    cancelPrepare()
    cleanupDualTrackTemp()
    disposePlayer(player)
    player = nil
    for slot in parkedPlayers {
      disposePlayer(slot.player)
    }
    parkedPlayers.removeAll()
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  /// 单 URL 增强路径（muxed mp4 / HLS 等）。DASH 拆轨不应走这里当「成功」。
  private func installEnhancedVideoOnly(url: URL, cookieHeader: String? = nil) {
    usedLegacyPath = false
    player = AVPlayer(
      playerItem: AVPlayerItem(
        asset: RemotePlaybackAsset.make(url: url, cookieHeader: cookieHeader)
      )
    )
    preparePhase = .ready
  }

  private func installLegacy(url: URL, cookieHeader: String? = nil) {
    usedLegacyPath = true
    player = AVPlayer(
      playerItem: AVPlayerItem(
        asset: RemotePlaybackAsset.makeLegacy(url: url, cookieHeader: cookieHeader)
      )
    )
    preparePhase = .ready
  }

  private func cancelPrepare() {
    prepareTask?.cancel()
    prepareTask = nil
  }

  private func cleanupDualTrackTemp() {
    if let dir = dualTrackTempDirectory {
      try? FileManager.default.removeItem(at: dir)
      dualTrackTempDirectory = nil
    }
  }

  /// 把当前 ready 播放器放进驻留表，供切回秒开。
  private func parkCurrentIfReady() {
    guard preparePhase == .ready,
          let player,
          let url = currentURL else {
      if preparePhase == .preparing {
        cancelPrepare()
        disposePlayer(self.player)
        self.player = nil
      }
      return
    }
    player.pause()
    // 同 key 只保留一份最新。
    removeParked(url: url, companionAudioURL: currentCompanionAudioURL)
    parkedPlayers.append(
      ParkedRemotePlayback(
        url: url,
        companionAudioURL: currentCompanionAudioURL,
        cookieHeader: currentCookieHeader,
        player: player,
        usedLegacyPath: usedLegacyPath
      )
    )
    while parkedPlayers.count > Self.parkedPlayerCapacity {
      let evicted = parkedPlayers.removeFirst()
      disposePlayer(evicted.player)
    }
    self.player = nil
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  private func takeParked(url: URL, companionAudioURL: URL?) -> ParkedRemotePlayback? {
    guard let index = parkedPlayers.firstIndex(where: {
      $0.url == url && $0.companionAudioURL == companionAudioURL
    }) else { return nil }
    return parkedPlayers.remove(at: index)
  }

  private func removeParked(url: URL, companionAudioURL: URL?) {
    parkedPlayers.removeAll {
      guard $0.url == url, $0.companionAudioURL == companionAudioURL else { return false }
      disposePlayer($0.player)
      return true
    }
  }

  private func disposePlayer(_ player: AVPlayer?) {
    player?.pause()
    player?.replaceCurrentItem(with: nil)
  }

  /// 用 NSURLError 域判断断网；不依赖 Network.framework，测试可用 fake NSError。
  static func isNetworkUnavailable(_ error: Error?) -> Bool {
    guard let error else { return false }
    var current: Error? = error
    while let ns = current as NSError? {
      if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
          return true
        default:
          break
        }
      }
      current = ns.userInfo[NSUnderlyingErrorKey] as? Error
    }
    return false
  }
}

/// 双轨合成结果盒：仅在 MainActor 上读写，避免 AVAsset 跨隔离传递。
@MainActor
private final class DualTrackAssetBox {
  var done = false
  var asset: AVAsset?
  var error: Error?
}

/// 已就绪远程播放器驻留项（进程内 LRU，不落盘）。
private struct ParkedRemotePlayback {
  let url: URL
  let companionAudioURL: URL?
  let cookieHeader: String?
  let player: AVPlayer
  let usedLegacyPath: Bool
}

private struct CurrentCaptureMediaPreviewCard: View {
  let descriptor: MediaDescriptor
  let taskID: TaskID
  let snapshotID: ContentSnapshotID
  @ObservedObject var model: HistoryViewModel
  let onlineTranscriptionModel: String?
  /// 与列表预热共享；卡片不 release，由 HistoryContentView 在离开可播上下文时释放。
  @ObservedObject var playback: RemotePreviewPlayerController
  /// 会话流失败时：清缓存并重新拉取可播档（避开 DV 等不可播编码）。
  var onRefreshStream: (() -> Void)? = nil
  /// 用户手动选清晰度。默认档以起播速度优先，这里让他知情地换成画质优先。
  var onSelectQuality: ((BilibiliStreamQualityPreference) -> Void)? = nil
  var selectedQuality: BilibiliStreamQualityPreference? = nil
  /// 「长片双轨 → 自动重拉整段」只许触发一次；重拉结果仍是双轨时绝不再来，
  /// 否则和粘住的清晰度 override 形成 1 秒一圈的刷新死循环。
  @State private var hasAutoRequestedProgressive = false
  @ObservedObject private var cinema = VideoCinemaController.shared
  private var isInCinema: Bool { cinema.isPresenting(player: playback.player) }
  @State private var videoDisplaySize: CGSize?
  /// 实际解码出来的画面高度（像素），取自轨道 naturalSize——是真正在播的那一档，
  /// 不是 API 声称的档位。「画质到底多少」只有这个数说了算。
  @State private var videoPixelHeight: Int?
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var playerStatusTask: Task<Void, Never>?

  private var previewState: CurrentCaptureMediaPreviewState {
    CurrentCaptureMediaPreview.resolve(descriptor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.headline)
        Text(CurrentCaptureMediaPreview.kindLabel(descriptor.kind))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
        // 真正在播的那一档。标题写「4K」不代表播的是 4K——
        // 拿不到会员档时会退到公开档，不显示出来根本无从判断。
        // 选的哪条路：整段 mp4（快、上限 720P/1080P）还是 DASH 双轨（能到 4K，慢）。
        // 没有这个标签，「选了高清没变化」分不清是没换路还是换了路仍拿不到高档。
        Text(descriptor.companionAudioURL == nil ? "整段" : "双轨")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
          .accessibilityIdentifier("history-video-preview-track-mode")
        if let videoPixelHeight {
          Text("\(videoPixelHeight)P")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .accessibilityIdentifier("history-video-preview-resolution")
        }
        Spacer(minLength: 0)
        if let author = descriptor.author?.trimmedNonEmpty {
          Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }

      switch previewState {
      case let .playable(url, kind, companionAudioURL):
        playableContent(url: url, kind: kind, companionAudioURL: companionAudioURL)
      case .expired:
        degradationContent(
          message: "播放地址已过期，请回到浏览器重新发送。",
          nextAction: "APP 不会在后台静默重新解析播放地址。",
          identifier: "history-video-preview-expired"
        )
      case let .degraded(presentation):
        degradationContent(
          message: presentation.message,
          nextAction: presentation.nextAction,
          identifier: "history-video-preview-degradation"
        )
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear { synchronizePlayback() }
    .onChange(of: descriptor) { _, _ in
      cancelGeometryAndStatusMonitors()
      synchronizePlayback()
    }
    .onDisappear {
      // 不 release 共享 controller：列表预热与快速切回同一抓取需要保留。
      cancelGeometryAndStatusMonitors()
    }
    .accessibilityIdentifier("history-video-preview-card")
  }

  @ViewBuilder
  private func playableContent(url: URL, kind: MediaKind, companionAudioURL: URL?) -> some View {
    switch playback.preparePhase {
    case let .failed(failure):
      VStack(alignment: .leading, spacing: 8) {
        Label(
          failure.message,
          systemImage: failure == .networkUnavailable ? "wifi.slash" : "exclamationmark.triangle.fill"
        )
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        // 失败时把走的哪条路、哪个主机、什么错误码摆出来。没有这一行，
        // 排查只能靠猜——之前就是这么反复改了七轮还没定位到根因。
        if let diagnostic = playback.playbackDiagnostic {
          Text(diagnostic)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("history-video-preview-diagnostic")
        }
        HStack(spacing: 10) {
          if let onRefreshStream {
            Button(
              failure == .longFormDualNeedsRefresh ? "重新获取整段 MP4" : "重新获取可播地址"
            ) {
              onRefreshStream()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("history-video-preview-refresh-stream")
          }
          if failure != .longFormDualNeedsRefresh {
            Button("重试") { playback.retry() }
              .controlSize(.small)
              .accessibilityIdentifier("history-video-preview-retry")
          }
          Button("回到原页面观看") { openInBrowser() }
            .controlSize(.small)
        }
      }
      .accessibilityIdentifier(
        failure == .networkUnavailable
          ? "history-video-preview-network-unavailable"
          : "history-video-preview-degradation"
      )
      .onAppear {
        // 长片 dual：有重拉回调则自动拉 progressive，少一次手动点击。
        if failure == .longFormDualNeedsRefresh, let onRefreshStream {
          onRefreshStream()
        }
      }
    case .preparing:
      preparingPlaceholder(url: url, companionAudioURL: companionAudioURL)
    case .idle where playback.player == nil:
      preparingPlaceholder(url: url, companionAudioURL: companionAudioURL)
    case .ready, .idle:
      VideoPlayer(player: playback.player)
        .aspectRatio(
          videoDisplaySize.map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0),
          contentMode: .fit
        )
        .frame(
          maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
          maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
          alignment: .leading
        )
        .background(Color.black)
        .background(VideoScrollWheelAnchor().allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-video-remote-player")
    }

    // Action bar: playback is streaming by default. Download is a separate,
    // optional action. This separation makes "watch without saving" obvious.
    HStack(spacing: 10) {
      if kind == .directFile {
        Button {
          Task {
            await model.favoriteCurrentCaptureMedia(
              descriptor,
              taskID: taskID,
              snapshotID: snapshotID
            )
          }
        } label: {
          Label("保存到本地", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canFavoriteCurrentCaptureMedia)
        .accessibilityIdentifier("history-video-preview-favorite")
      } else {
        Text("暂不支持保存 HLS")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-video-preview-favorite")
      }
      favoriteStatus
      Spacer(minLength: 0)
      if kind == .directFile {
        remoteTranscriptionControl
      } else {
        Text("当前 Debug 暂不支持 HLS 转写")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("remote-transcribe")
      }
      qualityMenu
      // 「放大」是所有视频卡的固定能力，这张卡之前漏了。
      if let player = playback.player, !isInCinema {
        Button {
          cinema.present(
            player: player,
            // 尺寸还没读到时用 16:9 兜底，别因为这个挡住放大。
            aspectRatio: videoDisplaySize
              .map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0)
          )
        } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
          .buttonStyle(.link)
          .font(.caption)
          .accessibilityIdentifier("history-video-preview-cinema")
      }
      Button("在浏览器中打开", action: openInBrowser)
        .buttonStyle(.link)
        .controlSize(.small)
    }

    remoteTranscriptionStatus
  }

  /// 清晰度切换。默认走「最快起播」，想细看再手动升档——
  /// 升档可能要换成 DASH 双轨，长视频起播会明显变慢，所以菜单里如实写清楚。
  @ViewBuilder
  private var qualityMenu: some View {
    if let onSelectQuality, descriptor.platform == "bilibili" {
      Menu {
        ForEach(BilibiliStreamQualityPreference.allCases, id: \.self) { option in
          Button {
            onSelectQuality(option)
          } label: {
            if option == selectedQuality {
              Label(option.settingsTitle, systemImage: "checkmark")
            } else {
              Text(option.settingsTitle)
            }
          }
        }
      } label: {
        Label("清晰度", systemImage: "slider.horizontal.3")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .font(.caption)
      .accessibilityIdentifier("history-video-preview-quality")
    }
  }

  /// 菜单里禁用的「在线转写」必须自己说明为什么灰。
  /// 「没配模型」和「地址过期」的解法完全不同，只灰不说等于让用户猜。
  private var onlineTranscribeTitle: String {
    let trimmed = onlineTranscriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed?.isEmpty != false {
      return "在线转写（未配置模型，见 设置 → 模型与识别）"
    }
    return "在线转写"
  }

  @ViewBuilder private var remoteTranscriptionControl: some View {
    let state = model.transcriptionState(for: taskID)
    switch state {
    case .preparingMedia, .checkingModel, .preparingModel, .extractingAudio, .transcribing:
      Button("取消转写", role: .cancel, action: model.cancelTranscription)
        .controlSize(.small)
        .accessibilityIdentifier("remote-transcribe-cancel")
    case .failed, .cancelled:
      Menu("重试转写") {
        Button("本机转写") { model.retryRemoteTranscription(descriptor, taskID: taskID) }
        Button(onlineTranscribeTitle) {
          model.requestOnlineTranscription(descriptor, taskID: taskID, model: onlineTranscriptionModel)
        }
        .disabled(!model.canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: onlineTranscriptionModel))
      }
      .controlSize(.small)
      .accessibilityIdentifier("remote-transcribe-retry")
    case .idle, .completed:
      Menu {
        Button("本机转写") { model.requestRemoteTranscription(descriptor, taskID: taskID) }
          .disabled(!model.canTranscribeCurrentCapture(descriptor, taskID: taskID))
        Button(onlineTranscribeTitle) {
          model.requestOnlineTranscription(descriptor, taskID: taskID, model: onlineTranscriptionModel)
        }
        .disabled(!model.canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: onlineTranscriptionModel))
      } label: {
        Label(state == .completed ? "重新转写" : "转写", systemImage: "waveform")
      }
      .controlSize(.small)
      .accessibilityIdentifier("remote-transcribe")
    case .awaitingModelDownload:
      Text("等待模型下载确认")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("remote-transcribe-state")
    }
  }

  @ViewBuilder private var remoteTranscriptionStatus: some View {
    VStack(alignment: .leading, spacing: 7) {
      switch model.transcriptionState(for: taskID) {
      case .idle:
        EmptyView()
      case .preparingMedia:
        HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在准备临时媒体…") }
      case .checkingModel:
        HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在检查中文离线模型…") }
      case .awaitingModelDownload:
        Text("等待确认 Apple 中文离线模型下载")
      case .preparingModel:
        HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在准备中文离线模型…") }
      case .extractingAudio:
        HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在提取音频…") }
      case .transcribing:
        HStack(spacing: 7) {
          ProgressView().controlSize(.small)
          Text(
            model.transcriptionUsesOnlineService
              ? (model.onlineTranscriptionPhase ?? "正在在线转写…")
              : "正在本机转写，音频不会上传…"
          )
        }
      case .completed:
        Label("转写已保存为最新原文", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .cancelled:
        Text(LocalVideoTranscriptionError.cancelled.userMessage).foregroundStyle(.secondary)
      case let .failed(message):
        Text(message).foregroundStyle(.red)
      }
      // 流式通道边转写边出字：先看到文字，等待感就和总耗时脱钩了。
      if let preview = model.onlineTranscriptionPreview, !preview.isEmpty {
        ScrollView {
          Text(preview)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        .accessibilityIdentifier("remote-transcribe-preview")
      }
      if let timings = model.onlineTranscriptionTimings {
        Text(timings)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("remote-transcribe-timings")
      }
      if let cleanupFailure = model.transcriptionCleanupFailure {
        VStack(alignment: .leading, spacing: 6) {
          Text(cleanupFailure).foregroundStyle(.red)
          Button("重试清理", action: model.retryTranscriptionCleanup)
            .controlSize(.small)
            .accessibilityIdentifier("remote-transcribe-cleanup-retry")
        }
        .accessibilityIdentifier("remote-transcribe-cleanup-failure")
      }
    }
    .font(.caption)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("remote-transcribe-state")
  }

  @ViewBuilder private var favoriteStatus: some View {
    switch model.remoteMediaFavoriteState {
    case .idle:
      EmptyView()
    case .saving:
      HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在保存到本地…") }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    case .saved:
      Label("已保存到本地", systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    case let .failed(message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    }
  }

  private func degradationContent(message: String, nextAction: String, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: descriptor.kind == .embed ? "rectangle.on.rectangle.slash" : "exclamationmark.triangle.fill")
        .font(.callout.weight(.medium))
      Text(nextAction).font(.caption).foregroundStyle(.secondary)
      Button("返回浏览器", action: openInBrowser)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    .accessibilityIdentifier(identifier)
  }

  private func preparingPlaceholder(url: URL, companionAudioURL: URL?) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.black.opacity(0.9))
      VStack(spacing: 10) {
        ProgressView("正在连接视频流…")
          .tint(.white)
          .foregroundStyle(.white)
        Text(companionAudioURL == nil
          ? "正在读取远程视频信息"
          : "正在连接高清双轨（会员清晰度）；必要时会短暂下载后播放")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.75))
          .multilineTextAlignment(.center)
        Button("取消并重试") {
          playback.retry()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("history-video-preview-preparing-retry")
      }
      .padding()
    }
    .frame(height: 220)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("history-video-preview-preparing")
  }

  private func synchronizePlayback() {
    guard case let .playable(url, _, companionAudioURL) = previewState else {
      cancelGeometryAndStatusMonitors()
      return
    }
    // 长片仍带着 DASH 双轨：自动清缓存重拉 progressive，避免卡在「连接高清双轨」。
    //
    // 两个例外，缺一个就会闭环（实测烧到过第 107 次尝试，约 1 秒一圈）：
    // - 用户手选了清晰度：粘住的 override 每次都会重新拿回双轨，这里再触发重拉
    //   就和它互相打架。手选高清本来就该走双轨合成（有 12 秒超时和下载兜底）。
    // - 自动重拉只许一次：重拉的结果如果仍是双轨（缓存、账号档位等原因），
    //   第二次触发就是死循环的开始，改为交给失败卡片让用户手动决定。
    if companionAudioURL != nil,
       selectedQuality == nil,
       !hasAutoRequestedProgressive,
       BilibiliPlaybackRefresher.prefersProgressiveForDuration(descriptor.durationSeconds),
       !RemotePreviewPlayerController.isLikelyProgressiveMuxedURL(url),
       let onRefreshStream {
      hasAutoRequestedProgressive = true
      onRefreshStream()
      return
    }
    preparePlayback(url, companionAudioURL: companionAudioURL)
  }

  private func preparePlayback(_ url: URL, companionAudioURL: URL?) {
    playback.prepare(
      url: url,
      companionAudioURL: companionAudioURL,
      durationSeconds: descriptor.durationSeconds,
      // 手选清晰度 = 用户明确要画质，长片双轨硬闸让位。
      allowLongFormDual: selectedQuality != nil
    )
    loadVideoGeometry(url)
    monitorPlayerStatus()
  }

  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    videoDisplaySize = nil
    videoPixelHeight = nil
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform),
            !Task.isCancelled else { return }
      let displaySize = VideoDisplayGeometry.displaySize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
      guard displaySize.width > 0, displaySize.height > 0 else { return }
      videoDisplaySize = displaySize
      // 竖屏经 transform 后宽高互换，取短边才是「多少 P」。
      videoPixelHeight = Int(min(displaySize.width, displaySize.height).rounded())
    }
  }

  private func monitorPlayerStatus() {
    playerStatusTask?.cancel()
    // 双轨异步 prepare 时 currentItem 可能尚未就绪，轮询等待后再观察 status。
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        if case .failed = playback.preparePhase { return }
        guard let item = playback.player?.currentItem else {
          try? await Task.sleep(for: .milliseconds(50))
          continue
        }
        if item.status == .failed {
          // MIME / 合成路径失败时退回旧的单 URL 路径；仍失败再暴露给 UI。
          if playback.fallbackToLegacyIfNeeded() {
            continue
          }
          playback.markPlaybackFailed(error: item.error)
          return
        }
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
  }

  private func cancelGeometryAndStatusMonitors() {
    videoGeometryTask?.cancel()
    videoGeometryTask = nil
    playerStatusTask?.cancel()
    playerStatusTask = nil
    videoDisplaySize = nil
  }

  private func openInBrowser() {
    guard let url = URL(string: descriptor.pageURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    NSWorkspace.shared.open(url)
  }
}

/// 历史条目有视频事实，但临时播放地址不在内存时：说明设计边界，并提供恢复动作。
private struct HistorySessionMediaUnavailableCard: View {
  let sourceURL: String
  let phase: SessionMediaPlaybackController.RefreshPhase
  /// 已发起的刷新次数；大于 1 表示在被反复重启，而不是单次请求慢。
  var refreshAttempts: Int = 1
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(HistorySessionMediaPresentation.title, systemImage: "play.rectangle")
        .font(.headline)
      Text(HistorySessionMediaPresentation.explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      switch phase {
      case .refreshing:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          // 次数大于 1 说明刷新在被反复取消重启，而不是请求慢——两者界面本来一模一样。
          Text(refreshAttempts > 1 ? "正在重新获取播放…（第 \(refreshAttempts) 次尝试）" : "正在重新获取播放…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("history-video-session-refreshing")
      case let .failed(message):
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history-video-session-refresh-failed")
        HStack(spacing: 10) {
          Button(HistorySessionMediaPresentation.refreshActionTitle, action: onRefresh)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-refresh")
          Button(HistorySessionMediaPresentation.openSourceActionTitle, action: openSource)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-open-source")
        }
      case .idle:
        HStack(spacing: 10) {
          Button(HistorySessionMediaPresentation.refreshActionTitle, action: onRefresh)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-refresh")
          Button(HistorySessionMediaPresentation.openSourceActionTitle, action: openSource)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-open-source")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .accessibilityIdentifier("history-video-session-unavailable")
  }

  private func openSource() {
    guard let url = URL(string: sourceURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    NSWorkspace.shared.open(url)
  }
}

/// Top-of-detail video card for Loop V captures. Plays a local file only —
/// never streams a remote signed URL from History.
/// 空格播放/暂停的窗口级兜底：AVPlayerView 只在自己是 first responder 时
/// 响应空格，而阅读区视图切换（转写流式面板出现/消失等）会把窗口焦点清空，
/// 空格随之失效。此视图不参与命中，只挂本窗口的 keyDown 监视器；焦点在
/// 输入框或其它控件上时空格原样放行，焦点空置时由本卡播放器接管。
/// macOS 会把窗口里第一个文本控件设成 `initialFirstResponder`，搜索框因此一开
/// 窗就叼着光标——空格全打进搜索框，到不了播放器。窗口首次出现时把 first
/// responder 交还给空；只在搜索框确实空着时才动，不打断已经输入的搜索词。
/// 用户点搜索框或按 ⌘F 仍能正常聚焦。
private struct ReleaseInitialSearchFocus: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ReleaseView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class ReleaseView: NSView {
    private var released = false

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !released, window != nil else { return }
      released = true
      // 让 SwiftUI 先把它的初始焦点设完，再交还，否则会被下一帧覆盖回去。
      DispatchQueue.main.async { [weak self] in
        guard let window = self?.window,
              let editor = window.firstResponder as? NSText,
              editor.isEditable,
              editor.string.isEmpty
        else { return }
        window.makeFirstResponder(nil)
      }
    }
  }
}

private struct PlayerSpaceKeyToggle: NSViewRepresentable {
  let player: AVPlayer?

  func makeNSView(context: Context) -> CatcherView { CatcherView() }

  func updateNSView(_ nsView: CatcherView, context: Context) {
    nsView.player = player
  }

  final class CatcherView: NSView {
    var player: AVPlayer?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        removeMonitor()
      } else {
        installMonitor()
      }
    }

    private func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }

        // 点击输入框外的区域时结束输入焦点：搜索框（SwiftUI FocusState）
        // 会一直持有 first responder，点静态内容不会自动交出，空格便
        // 永远打进搜索框而到不了播放器。
        if event.type == .leftMouseDown {
          if let editor = window.firstResponder as? NSText, editor.isEditable {
            let point = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
            let hit = window.contentView?.hitTest(point)
            if !(hit is NSText), !(hit is NSTextField), hit !== editor.delegate as? NSView {
              window.makeFirstResponder(nil)
            }
          }
          return event
        }

        guard event.keyCode == 49, // Space
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let player = self.player else { return event }
        // 正在输入的文本框、以及真的把空格当激活键的控件，自己消费空格。
        //
        // 这里不能笼统地放行 NSControl：NSTableView 也是 NSControl 子类，而
        // macOS 上 SwiftUI 的 List 底层正是它。抓取完成后列表刷新、新条目被
        // 选中，first responder 就落在列表上，空格于是被让给滚动视图当翻页
        // 用——屏幕一闪一闪就是不播放，必须先点几下视频把 first responder
        // 抢给 AVPlayerView 才有反应。
        switch window.firstResponder {
        case let text as NSText where text.isEditable:
          // 搜索框空着只是叼着光标（macOS 会把窗口里第一个文本控件设成
          // initialFirstResponder），此时空格的意图是播放而不是打字。真在
          // 输入的搜索词仍旧能正常敲空格。
          if text.string.isEmpty { break }
          return event
        case is NSButton, is NSTextField, is NSComboBox,
             is NSPopUpButton, is NSSegmentedControl: return event
        default: break
        }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        return nil
      }
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

private struct HistoryVideoPlayerCard: View {
  let fileURL: URL
  let media: MediaAsset?
  let taskID: TaskID
  @ObservedObject var model: HistoryViewModel
  let onlineTranscriptionModel: String?
  let tidyModel: String?
  let autoTidyEnabled: Bool
  @State private var player: AVPlayer?
  @State private var surfaceGeometry: PlaybackSurfaceGeometry = .loading
  /// 既有版式按"有尺寸/没尺寸"分支，这里保持它的语义不变。
  private var videoDisplaySize: CGSize? { surfaceGeometry.displaySize }
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var saveFeedback: String?
  @State private var saveFeedbackTask: Task<Void, Never>?
  @State private var isSaveFailurePresented = false
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 本卡的播放器正被影院 overlay 放大：卡内显示占位，避免双重渲染。
  private var isInCinema: Bool { cinema.isPresenting(player: player) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // All facts and actions precede playback so the player never pushes its
      // ownership/status controls below a tall portrait video.
      HStack(spacing: 12) {
        if let author = media?.author, !author.isEmpty {
          Label(author, systemImage: "person.crop.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let durationSeconds = media?.durationSeconds, durationSeconds > 0 {
          Label(Self.formatDuration(durationSeconds), systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let byteSize = media?.byteSize, byteSize > 0 {
          Label("已保存到本机 · \(Self.formatByteSize(byteSize))", systemImage: "internaldrive.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history-video-local-size")
        }
        Spacer(minLength: 0)
        if let saveFeedback {
          Label(saveFeedback, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .accessibilityIdentifier("history-video-save-feedback")
        }
      }

      HStack(spacing: 10) {
        transcriptionControl
        Button("另存一份", systemImage: "square.and.arrow.down", action: saveToLocalFile)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!LocalMediaExport.isSupportedLocalFile(fileURL))
          .accessibilityIdentifier("history-video-save-local")
        if model.isReadOnly {
          Text("只读模式不能保存转写结果；恢复可写存储后可重试。")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("history-video-transcription-read-only")
        } else {
          transcriptionStatus
          transcriptTidyStatus
        }
        Spacer(minLength: 0)
      }
      .onChange(of: model.transcriptionState) { _, newState in
        // 设置勾选即持久授权：自动整理不再逐次弹发送确认。
        guard autoTidyEnabled, newState == .completed,
              model.transcriptionTaskID == taskID,
              model.canTidyTranscript(taskID: taskID) else { return }
        model.startTranscriptTidyAuto(taskID: taskID, model: tidyModel)
      }

      playerSurface

      // 「放大」是所有视频卡的固定能力，与 YouTube 卡同位：视频正下方右对齐。
      if let videoDisplaySize, player != nil, !isInCinema {
        HStack {
          Spacer()
          Button {
            guard let player else { return }
            cinema.present(
              player: player,
              aspectRatio: VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize)
            )
          } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("history-video-cinema")
        }
        // 右对齐要对到视频右边缘，不是阅读区右边缘：竖屏视频收窄后，按整行
        // 右对齐会把按钮甩到离视频很远的地方。
        .frame(maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize))
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear {
      if player == nil {
        player = AVPlayer(url: fileURL)
      }
      loadVideoGeometry(fileURL)
    }
    .onChange(of: fileURL) { _, newURL in
      if isInCinema { cinema.dismiss() }
      player?.pause()
      player = AVPlayer(url: newURL)
      loadVideoGeometry(newURL)
    }
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      player?.pause()
      videoGeometryTask?.cancel()
      videoGeometryTask = nil
      saveFeedbackTask?.cancel()
      saveFeedbackTask = nil
    }
    .alert("无法保存视频", isPresented: $isSaveFailurePresented) {
      Button("好", role: .cancel) {}
    } message: {
      Text("原本机视频没有被改动。请检查保存位置的权限或可用空间后重试。")
    }
  }

  @MainActor
  private func saveToLocalFile() {
    guard LocalMediaExport.isSupportedLocalFile(fileURL) else {
      isSaveFailurePresented = true
      return
    }

    let panel = NSSavePanel()
    panel.title = "另存一份视频"
    panel.prompt = "保存"
    panel.nameFieldStringValue = fileURL.lastPathComponent
    panel.allowedContentTypes = [LocalMediaExport.contentType(for: fileURL)]
    panel.allowsOtherFileTypes = false
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

    do {
      try LocalMediaExport.copyLocalFile(from: fileURL, to: destinationURL)
      saveFeedbackTask?.cancel()
      saveFeedback = "已保存"
      saveFeedbackTask = Task { @MainActor in
        do {
          try await Task.sleep(nanoseconds: 2_200_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        saveFeedback = nil
        saveFeedbackTask = nil
      }
    } catch {
      isSaveFailurePresented = true
    }
  }

  @ViewBuilder private var playerSurface: some View {
    if let videoDisplaySize {
      if isInCinema {
        // 影院放大期间，卡内显示占位；播放器只存在于 overlay。
        // 空格监视器保留在占位上，影院里空格依旧切换同一个播放器。
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.black.opacity(0.85))
          .aspectRatio(VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize), contentMode: .fit)
          .frame(
            maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
            maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
            alignment: .leading
          )
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .overlay {
            VStack(spacing: 6) {
              Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
              Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
          }
      } else {
        VideoPlayer(player: player)
          .aspectRatio(VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize), contentMode: .fit)
          // 竖屏视频（9:16）的黑底必须收到视频自身宽度，否则两侧就是死黑边。
          // 横屏仍被阅读区宽度约束，表现与之前一致。
          .frame(
            maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
            maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
            alignment: .leading
          )
          .background(Color.black)
          .background(VideoScrollWheelAnchor().allowsHitTesting(false))
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-video-player")
      }
    } else if surfaceGeometry == .loading {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.black.opacity(0.9))
        ProgressView("正在读取视频尺寸…")
          .tint(.white)
          .foregroundStyle(.white)
      }
      .frame(height: 220)
      .accessibilityIdentifier("history-video-geometry-placeholder")
    } else {
      // 没有画面可显示时给一条可播放的音频条，而不是继续转圈。转写照常可用，
      // 它本来就只需要声音。
      VStack(alignment: .leading, spacing: 8) {
        Label(
          surfaceGeometry == .audioOnly
            ? "这条媒体只有声音，没有画面"
            : "读不出画面，仅按声音播放",
          systemImage: "waveform"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        VideoPlayer(player: player)
          .frame(height: 64)
          .background(Color.black)
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("history-audio-only-player")
    }
  }

  @ViewBuilder private var transcriptionControl: some View {
    let state = model.transcriptionState(for: taskID)
    switch state {
    case .preparingMedia, .checkingModel, .preparingModel, .extractingAudio, .transcribing:
      Button("取消", role: .cancel, action: model.cancelTranscription)
        .controlSize(.small)
        .accessibilityIdentifier("history-video-transcription-cancel")
    case .failed, .cancelled:
      Button("重试", action: model.retryTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo)
        .accessibilityIdentifier("history-video-transcription-retry")
    case .completed:
      Button("重新转写", action: model.requestTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo)
        .accessibilityIdentifier("history-video-transcription-start")
    case .idle, .awaitingModelDownload:
      Button("转写", action: model.requestTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo || state == .awaitingModelDownload)
        .accessibilityIdentifier("history-video-transcription-start")
    }
    // 本机模型准确率与标点有限；已存视频随时可改走在线转写换取
    // Whisper 级质量。音频分片在本机提取后上传，发送前必经同意弹窗。
    if !state.isActive {
      Button("在线转写") {
        model.requestOnlineTranscriptionFromLocalMedia(taskID: taskID, model: onlineTranscriptionModel)
      }
      .controlSize(.small)
      .disabled(!model.canTranscribeLocalMediaOnline(taskID: taskID, model: onlineTranscriptionModel))
      .help("把本机提取的音频分片发送到你配置的在线转写服务，获得更准的文字和标点。需在设置中配置在线转写模型。")
      .accessibilityIdentifier("history-video-transcription-online")
      // 转写后整理：只发送文字给聊天模型修标点/分段/错别字，不发送媒体。
      Button("整理文稿") {
        model.requestTranscriptTidy(taskID: taskID, model: tidyModel)
      }
      .controlSize(.small)
      .disabled(!model.canTidyTranscript(taskID: taskID))
      .help("把转写文字发送给你配置的聊天模型，修正标点、分段和明显错别字，不改写内容。原始转写稿保留在历史中。")
      .accessibilityIdentifier("history-transcript-tidy")
    }
  }

  @ViewBuilder private var transcriptTidyStatus: some View {
    switch model.transcriptTidyState(for: taskID) {
    case .idle: EmptyView()
    case .running: ProgressView().controlSize(.small); Text("正在整理文稿…").font(.caption)
    case .completed:
      let tokens = model.transcriptTidyTokenSummary(for: taskID)
      Label(
        tokens.map { "整理稿已保存 · \($0)" } ?? "整理稿已保存为最新原文",
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption).foregroundStyle(.green)
    case .cancelled: Text(TranscriptTidyError.cancelled.userMessage).font(.caption).foregroundStyle(.secondary)
    case let .failed(message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
    }
  }

  @ViewBuilder private var transcriptionStatus: some View {
    switch model.transcriptionState(for: taskID) {
    case .idle:
      if let status = media?.transcriptionStatus, status != .none {
        Text(Self.transcriptionStatusText(status)).font(.caption).foregroundStyle(.secondary)
      }
    case .preparingMedia: ProgressView().controlSize(.small); Text("正在准备临时媒体…").font(.caption)
    case .checkingModel: ProgressView().controlSize(.small); Text("正在检查中文离线模型…").font(.caption)
    case .awaitingModelDownload: Text("等待确认模型下载").font(.caption).foregroundStyle(.secondary)
    case .preparingModel: ProgressView().controlSize(.small); Text("正在准备中文离线模型…").font(.caption)
    case .extractingAudio: ProgressView().controlSize(.small); Text("正在从本机视频提取音频…").font(.caption)
    case .transcribing: ProgressView().controlSize(.small); Text("正在本机转写，音频不会上传…").font(.caption)
    case .completed: Label("转写已保存为最新原文", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
    case .cancelled: Text(LocalVideoTranscriptionError.cancelled.userMessage).font(.caption).foregroundStyle(.secondary)
    case let .failed(message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
    }
  }

  /// 必须落到一个确定状态。旧实现在拿不到视频轨时直接 return，界面就永远停在
  /// "正在读取视频尺寸…"——纯音轨的媒体每次都会这样。
  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    surfaceGeometry = .loading
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      var videoTrack: (naturalSize: CGSize, preferredTransform: CGAffineTransform)?
      if let track = try? await asset.loadTracks(withMediaType: .video).first,
         let naturalSize = try? await track.load(.naturalSize),
         let preferredTransform = try? await track.load(.preferredTransform) {
        videoTrack = (naturalSize, preferredTransform)
      }
      let hasAudioTrack = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
      guard !Task.isCancelled else { return }
      surfaceGeometry = VideoDisplayGeometry.surfaceGeometry(
        videoTrack: videoTrack,
        hasAudioTrack: hasAudioTrack
      )
    }
  }

  private static func formatByteSize(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  private static func transcriptionStatusText(_ status: TranscriptionStatus) -> String {
    switch status {
    case .none: "尚未转写"
    case .pending: "等待本机转写"
    case .running: "本机转写中"
    case .completed: "已完成本机转写"
    case .failed: "上次转写未完成"
    }
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%d:%02d", minutes, remainder)
  }
}

/// Streaming video card for persisted browser captures whose V2 media
/// descriptor was mapped to `CaptureMedia`. Plays the ephemeral HTTPS URL
/// without requiring a local download. If the URL has expired or playback
/// fails, the user can reopen the source page in the browser.
private struct HistoryStreamingMediaCard: View {
  let media: CaptureMedia
  let sourceURL: String
  @ObservedObject var model: HistoryViewModel
  @StateObject private var playback = RemotePreviewPlayerController()
  @State private var videoDisplaySize: CGSize?
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var playerStatusTask: Task<Void, Never>?
  @State private var playbackFailed = false
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 本卡的播放器正被影院 overlay 放大：卡内显示占位，避免双重渲染。
  private var isInCinema: Bool { cinema.isPresenting(player: playback.player) }

  private var streamingAspectRatio: CGFloat {
    videoDisplaySize.map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0)
  }

  private var videoURL: URL? {
    guard let url = URL(string: media.videoURL),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  private var companionAudioURL: URL? {
    guard let raw = media.companionAudioURL,
          let url = URL(string: raw),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.headline)
        Text("联网播放")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
        Spacer(minLength: 0)
        if let author = media.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
          Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if let durationSeconds = media.durationSeconds, durationSeconds > 0 {
          Text(Self.formatDuration(durationSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      if playbackFailed {
        VStack(alignment: .leading, spacing: 8) {
          Label("远程播放失败。地址可能已失效。", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
          Text("临时播放地址不会写入历史；APP 重启或地址过期后，请回到浏览器重新同步。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("在浏览器中打开", action: openInBrowser)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-video-streaming-failed")
      } else if videoURL != nil {
        if isInCinema {
          // 影院放大期间，卡内显示占位；播放器只存在于 overlay。
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.85))
            .aspectRatio(streamingAspectRatio, contentMode: .fit)
            .frame(
              maxWidth: VideoDisplayGeometry.inlineMaximumHeight * streamingAspectRatio,
              maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
              alignment: .leading
            )
            .background(PlayerSpaceKeyToggle(player: playback.player).allowsHitTesting(false))
            .overlay {
              VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
                Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
              }
            }
        } else {
          VideoPlayer(player: playback.player)
            .aspectRatio(streamingAspectRatio, contentMode: .fit)
            .frame(
              maxWidth: VideoDisplayGeometry.inlineMaximumHeight * streamingAspectRatio,
              maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
              alignment: .leading
            )
            .background(Color.black)
            .background(VideoScrollWheelAnchor().allowsHitTesting(false))
            .background(PlayerSpaceKeyToggle(player: playback.player).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history-video-streaming-player")
        }
      }

      HStack(spacing: 10) {
        Button("在浏览器中打开", action: openInBrowser)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("history-video-streaming-open-browser")
        Spacer(minLength: 0)
        // 「放大」是所有视频卡的固定能力。
        if let player = playback.player, !playbackFailed, !isInCinema {
          Button {
            cinema.present(player: player, aspectRatio: streamingAspectRatio)
          } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("history-video-streaming-cinema")
        }
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear {
      if let url = videoURL {
        playback.prepare(url: url, companionAudioURL: companionAudioURL)
        loadVideoGeometry(url)
        monitorPlayerStatus()
      }
    }
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      // 这里原本是 release()，而 release() 会 parkedPlayers.removeAll()。
      // 切换历史条目必然触发 onDisappear，于是那份 4 条驻留缓存每次都被清空，
      // 切回来还得重连——驻留等于没做。park 只收起当前这个，保留其余。
      playback.parkAndIdle()
      videoGeometryTask?.cancel()
      videoGeometryTask = nil
      playerStatusTask?.cancel()
      playerStatusTask = nil
    }
  }

  private func openInBrowser() {
    if let url = URL(string: sourceURL) {
      NSWorkspace.shared.open(url)
    }
  }

  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    videoDisplaySize = nil
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform),
            !Task.isCancelled else { return }
      let displaySize = VideoDisplayGeometry.displaySize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
      guard displaySize.width > 0, displaySize.height > 0 else { return }
      videoDisplaySize = displaySize
    }
  }

  private func monitorPlayerStatus() {
    playerStatusTask?.cancel()
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        guard let item = playback.player?.currentItem else {
          try? await Task.sleep(nanoseconds: 50_000_000)
          continue
        }
        if item.status == .failed {
          if playback.fallbackToLegacyIfNeeded() {
            continue
          }
          playbackFailed = true
          return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
    }
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%d:%02d", minutes, remainder)
  }
}

/// Geometry-only helper so rotation and fit behavior can be tested without AVKit.
/// 播放面的几何状态。**只有音轨的媒体读不出画面尺寸**——B 站的 DASH 把画面和
/// 声音拆成两条流，抓取拿到的是声音那条——所以"没有画面"必须与"仍在读取"分开，
/// 否则界面会永远停在转圈上。读取失败同理：给它一个明确出口，而不是无限等待。
enum PlaybackSurfaceGeometry: Equatable {
  case loading
  case video(CGSize)
  case audioOnly
  case unavailable

  var displaySize: CGSize? {
    if case let .video(size) = self { return size }
    return nil
  }
}

struct VideoDisplayGeometry {
  /// 内联播放器高度上限。竖屏视频按它算出的宽度约 292，横屏先撞阅读区宽度。
  static let inlineMaximumHeight: CGFloat = 520

  /// 由已读到的轨道信息判定播放面状态。抽成纯函数是为了能脱离 AVFoundation 资源
  /// 直接测：有画面就给尺寸，没画面但有声音就是纯音频，两者都没有才是读不出。
  static func surfaceGeometry(
    videoTrack: (naturalSize: CGSize, preferredTransform: CGAffineTransform)?,
    hasAudioTrack: Bool
  ) -> PlaybackSurfaceGeometry {
    if let videoTrack {
      let size = displaySize(
        naturalSize: videoTrack.naturalSize,
        preferredTransform: videoTrack.preferredTransform
      )
      if size.width > 0, size.height > 0 { return .video(size) }
    }
    return hasAudioTrack ? .audioOnly : .unavailable
  }

  /// 内联播放器的宽度上限：让黑底收到视频自身宽度，竖屏才不会挂着两条死黑边。
  /// 单给 `maxHeight` 不够——弹性 frame 会把整块可用宽度占满，比例只作用在内部。
  static func inlineMaximumWidth(displaySize: CGSize?) -> CGFloat {
    let ratio = displaySize.map(aspectRatio(displaySize:)) ?? (16.0 / 9.0)
    return inlineMaximumHeight * ratio
  }

  static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    return CGSize(width: abs(transformed.width), height: abs(transformed.height))
  }

  static func aspectRatio(displaySize: CGSize) -> CGFloat {
    guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
    return displaySize.width / displaySize.height
  }

  static func fittedSize(displaySize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard displaySize.width > 0, displaySize.height > 0, maxWidth > 0, maxHeight > 0 else { return .zero }
    let scale = min(maxWidth / displaySize.width, maxHeight / displaySize.height)
    return CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
  }
}

/// Copies an already-cached local video to a user-selected destination. This
/// component deliberately has no remote URL or downloader responsibility.
enum LocalMediaExport {
  private static let allowedExtensions: Set<String> = ["mp4", "mov"]

  static func contentType(for url: URL) -> UTType {
    url.pathExtension.lowercased() == "mov" ? .quickTimeMovie : .mpeg4Movie
  }

  static func isSupportedLocalFile(
    _ url: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    guard url.isFileURL,
          allowedExtensions.contains(url.pathExtension.lowercased()) else { return false }
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  static func copyLocalFile(
    from sourceURL: URL,
    to destinationURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let sourceExtension = sourceURL.pathExtension.lowercased()
    guard isSupportedLocalFile(sourceURL, fileManager: fileManager),
          destinationURL.isFileURL,
          destinationURL.pathExtension.lowercased() == sourceExtension else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }

    let source = sourceURL.standardizedFileURL
    let destination = destinationURL.standardizedFileURL
    guard source != destination else { return }

    let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
      ".linkdigest-export-\(UUID().uuidString).\(destination.pathExtension)"
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try fileManager.copyItem(at: source, to: temporaryURL)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }
  }
}

/// UI state changes use a critically damped spring; Reduce Motion keeps a
/// short non-spatial fade so state changes stay visible without movement.
func historyUIAnimation(reduceMotion: Bool) -> Animation {
  reduceMotion ? .easeInOut(duration: 0.1) : .snappy(duration: 0.3)
}

/// Banner enter/exit slides from its top anchor; Reduce Motion falls back to a
/// plain cross-fade instead of positional movement.
func historyBannerTransition(reduceMotion: Bool) -> AnyTransition {
  reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
}

private struct PointingHandOnHover: ViewModifier {
  func body(content: Content) -> some View {
    content.onHover { inside in
      (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
  }
}

extension View {
  /// Desktop pointer affordance for link-styled buttons.
  func linkCursor() -> some View { modifier(PointingHandOnHover()) }
}
