import AppKit
import AVKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
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
  @Environment(\.openSettings) private var openSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var navigationTagsExpanded = true
  @FocusState private var isSearchFocused: Bool
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  /// 灯箱打开时窗口级分栏细线需要让位，避免画在放大的图片上。
  @ObservedObject private var inlineImageLightbox = InlineImageLightboxController.shared
  @ObservedObject private var videoCinema = VideoCinemaController.shared

  private var appearanceTheme: AppearanceTheme { AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass }
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }

  var body: some View {
    themedBody
      .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
      // 图片灯箱盖在整个窗口内容之上；点击图外区域或 Esc 退出。
      .overlay { InlineImageLightboxOverlay() }
      // 视频影院放大 overlay（任何来源）：自己的框，替代坑多的原生全屏。
      .overlay { VideoCinemaOverlay() }
      .foregroundStyle(theme.primaryText)
      .tint(theme.accent)
      .accentColor(theme.accent)
      .onAppear { AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw) }
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
        if model.selectedTaskCount > 1 {
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
          ForEach(model.rows, id: \.taskID) { row in
            HistoryRowView(row: row, model: model).tag(row.taskID).onAppear { model.loadNextPageIfNeeded(after: row) }
              .contextMenu {
                Button { openHistoryURL(row.canonicalURL) } label: { Label("在浏览器中打开", systemImage: "safari") }
                Button { copyHistoryURL(row.canonicalURL) } label: { Label("复制链接", systemImage: "doc.on.doc") }
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
            let tags = model.showsAllNavigationTags
              ? model.navigationCounts.tags
              : Array(model.navigationCounts.tags.prefix(8))
            ForEach(tags) { item in
              Button {
                model.toggleTag(item.tag, additive: NSEvent.modifierFlags.contains(.command))
              } label: {
                HStack {
                  Text(item.tag.name).lineLimit(1)
                  Spacer()
                  Text("\(item.count)").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .padding(.vertical, 3).padding(.horizontal, 6)
              .background(
                model.selectedTagNormalizedNames.contains(item.tag.normalizedName) ? theme.selectionFill : .clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .foregroundStyle(model.selectedTagNormalizedNames.contains(item.tag.normalizedName) ? theme.selectionText : theme.primaryText)
              .padding(.horizontal, -6)
              .fontWeight(model.selectedTagNormalizedNames.contains(item.tag.normalizedName) ? .semibold : .regular)
              .accessibilityIdentifier("history-navigation-tag-\(item.tag.normalizedName)")
              .help("单击仅筛选此标签；按住 Command 单击可交集筛选。")
            }
            if !model.showsAllNavigationTags, model.navigationCounts.tags.count > 8 {
              Button("全部标签…") { model.showsAllNavigationTags = true }
                .accessibilityIdentifier("history-navigation-tags-all")
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
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(raw, forType: .string)
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
          openSettings: { openSettings() }
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

private struct HistoryWindowToolbarThemeModifier: ViewModifier {
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
        VStack(alignment: .leading, spacing: 2) {
          if row.published?.trimmedNonEmpty != nil {
            Text("发布 \(historyPublishedDate(row.published))")
          }
          Text("创建 \(historyCreatedDate(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
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

private struct HistoryDetailView: View {
  let detail: HistoryDetailProjection
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel
  let appearanceTheme: AppearanceTheme
  let localImageURLs: [URL]
  let localMediaFileURL: URL?
  let openSettings: () -> Void
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
  @AppStorage(ReadingFontPreference.storageKey) private var readingFontRaw = ReadingFontPreference.theme.rawValue
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }
  /// 用户阅读字体偏好；「跟随主题」回落到主题的编辑排版标记。
  private var readingFont: ResolvedReadingFont {
    (ReadingFontPreference(rawValue: readingFontRaw) ?? .theme)
      .resolved(usesEditorialReadingTypography: appearanceTheme.usesEditorialReadingTypography)
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
          Text(sourceURL)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Button("打开") { openSourceURL() }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .linkCursor()
            .accessibilityIdentifier("history-source-url-open")
          Button("复制链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sourceURL, forType: .string) }
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
                    let descriptor = capture.mediaDescriptor {
            CurrentCaptureMediaPreviewCard(
              descriptor: descriptor,
              taskID: capture.taskID,
              snapshotID: capture.snapshotID,
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-preview-card")
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
                    !showsCurrentCapture,
                    detail.media == nil,
                    detail.snapshots.last?.platform == "douyin" {
            VStack(alignment: .leading, spacing: 8) {
              Label("此视频未保存到本地，需要联网播放。", systemImage: "wifi")
              Text("临时播放地址不会写入历史。若要永久保留，请在“设置 → 视频存储”打开“抓取视频后自动保存到本地”，或在每次投送后点击“保存到本地”；当前地址已丢失时需回到浏览器重新同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-resync-required")
          }
        }

        // Video-first captures keep playback before their short source text.
        // Substantive WeChat articles already rendered the reading surface above.
        if !presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            .padding(.top, 18)
        }

        if !localImageURLs.isEmpty {
          imageTextRecognitionCard
            .padding(.top, 16)
        }

        HistoryTagEditor(tags: detail.tags, model: model)
          .padding(.top, 20)
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
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(body.isEmpty ? composed.markdown : body, forType: .string)
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
          MetadataItem(
            symbol: "number",
            title: "Token",
            value: run.run.usageCost.totalTokens.map(String.init) ?? "—",
            detail: historyTokenBreakdown(run.run.usageCost)
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
      // Capture-only: real creation time, no fake 操作/模型/Token dashes.
      metadataRow {
        MetadataItem(
          symbol: "calendar",
          title: "创建时间",
          value: historyDate(detail.task.createdAtMilliseconds)
        )
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
    if showsCurrentCapture,
       let descriptor = appModel.currentCapture?.mediaDescriptor {
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
          showsInlinePlainTextToggle: false
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
              .font(readingFont.font(size: MarkdownPresentation.bodyFontSize))
              .foregroundStyle(theme.primaryText)
              .lineSpacing(MarkdownPresentation.bodyLineSpacing)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .accessibilityIdentifier("history-reading-source-live-transcription")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if let snapshot = isDouyinCapture ? latestTranscriptionSnapshot : latestSnapshot, !snapshot.bodyText.isEmpty {
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
            .font(readingFont.font(size: MarkdownPresentation.bodyFontSize))
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
            showsInlinePlainTextToggle: false
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
        Text(isDouyinCapture ? "尚未转写" : "本条没有抓取到正文").foregroundStyle(.secondary)
        if isDouyinCapture,
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recognizedText, forType: .string)
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
            .font(.system(size: MarkdownPresentation.bodyFontSize))
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
  case playable(url: URL, kind: MediaKind)
  case expired
  case degraded(RemoteMediaDegradationPresentation)
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
      return .playable(url: url, kind: descriptor.kind)
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
enum RemotePlaybackAsset {
  private static let browserUserAgent =
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
    return nil
  }

  static func make(url: URL) -> AVURLAsset {
    guard url.scheme?.lowercased() == "https" else { return AVURLAsset(url: url) }
    var headers: [String: String] = ["User-Agent": browserUserAgent]
    if let referer = referer(forHost: url.host) { headers["Referer"] = referer }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
  }
}

@MainActor
final class RemotePreviewPlayerController: ObservableObject {
  @Published private(set) var player: AVPlayer?
  private var currentURL: URL?

  var hasPlayer: Bool { player != nil }

  func prepare(url: URL) {
    guard currentURL != url || player == nil else { return }
    release()
    currentURL = url
    player = AVPlayer(playerItem: AVPlayerItem(asset: RemotePlaybackAsset.make(url: url)))
  }

  func release() {
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    currentURL = nil
  }
}

private struct CurrentCaptureMediaPreviewCard: View {
  let descriptor: MediaDescriptor
  let taskID: TaskID
  let snapshotID: ContentSnapshotID
  @ObservedObject var model: HistoryViewModel
  let onlineTranscriptionModel: String?
  @StateObject private var playback = RemotePreviewPlayerController()
  @State private var videoDisplaySize: CGSize?
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var playerStatusTask: Task<Void, Never>?
  @State private var runtimePlaybackFailure = false

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
        Spacer(minLength: 0)
        if let author = descriptor.author?.trimmedNonEmpty {
          Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }

      switch previewState {
      case let .playable(url, kind):
        playableContent(url: url, kind: kind)
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
      releasePlayback()
      synchronizePlayback()
    }
    .onDisappear { releasePlayback() }
    .accessibilityIdentifier("history-video-preview-card")
  }

  @ViewBuilder
  private func playableContent(url: URL, kind: MediaKind) -> some View {
    // Player first — streaming playback is the default action, not download.
    if runtimePlaybackFailure {
      HStack(spacing: 10) {
        Label("远程播放失败。地址可能已失效，或播放器不支持当前媒体。", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
        Button("重试") { preparePlayback(url) }
          .controlSize(.small)
        Button("重新发送") { openInBrowser() }
          .controlSize(.small)
      }
      .accessibilityIdentifier("history-video-preview-degradation")
    }

    VideoPlayer(player: playback.player)
      .aspectRatio(
        videoDisplaySize.map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0),
        contentMode: .fit
      )
      .frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)
      .background(Color.black)
      .background(VideoScrollWheelAnchor().allowsHitTesting(false))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityIdentifier("history-video-remote-player")

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
      Button("在浏览器中打开", action: openInBrowser)
        .buttonStyle(.link)
        .controlSize(.small)
    }

    remoteTranscriptionStatus
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
        Button("在线转写") {
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
        Button("在线转写") {
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
          Text(model.transcriptionUsesOnlineService ? "正在在线转写…" : "正在本机转写，音频不会上传…")
        }
      case .completed:
        Label("转写已保存为最新原文", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .cancelled:
        Text(LocalVideoTranscriptionError.cancelled.userMessage).foregroundStyle(.secondary)
      case let .failed(message):
        Text(message).foregroundStyle(.red)
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

  private func synchronizePlayback() {
    guard case let .playable(url, _) = previewState else {
      releasePlayback()
      return
    }
    preparePlayback(url)
  }

  private func preparePlayback(_ url: URL) {
    runtimePlaybackFailure = false
    playback.prepare(url: url)
    loadVideoGeometry(url)
    monitorPlayerStatus()
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
    guard let item = playback.player?.currentItem else { return }
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        if item.status == .failed {
          runtimePlaybackFailure = true
          return
        }
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
  }

  private func releasePlayback() {
    videoGeometryTask?.cancel()
    videoGeometryTask = nil
    playerStatusTask?.cancel()
    playerStatusTask = nil
    videoDisplaySize = nil
    playback.release()
  }

  private func openInBrowser() {
    guard let url = URL(string: descriptor.pageURL),
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
        // 正在输入的文本框和获得焦点的控件自己消费空格。
        switch window.firstResponder {
        case let text as NSText where text.isEditable: return event
        case is NSControl: return event
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
  @State private var videoDisplaySize: CGSize?
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
        // 自动整理只代替点按钮，不代替同意：仍会先弹发送确认。
        guard autoTidyEnabled, newState == .completed,
              model.transcriptionTaskID == taskID,
              model.canTidyTranscript(taskID: taskID) else { return }
        model.requestTranscriptTidy(taskID: taskID, model: tidyModel)
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
          .frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)
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
          .frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)
          .background(Color.black)
          .background(VideoScrollWheelAnchor().allowsHitTesting(false))
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
          .accessibilityIdentifier("history-video-player")
      }
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.black.opacity(0.9))
        ProgressView("正在读取视频尺寸…")
          .tint(.white)
          .foregroundStyle(.white)
      }
      .frame(height: 220)
      .accessibilityIdentifier("history-video-geometry-placeholder")
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

  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    videoDisplaySize = nil
    videoGeometryTask = Task {
      let asset = RemotePlaybackAsset.make(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform),
            !Task.isCancelled
      else { return }
      let displaySize = VideoDisplayGeometry.displaySize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
      guard displaySize.width > 0, displaySize.height > 0 else { return }
      videoDisplaySize = displaySize
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
            .frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)
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
            .frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)
            .background(Color.black)
            .background(VideoScrollWheelAnchor().allowsHitTesting(false))
            .background(PlayerSpaceKeyToggle(player: playback.player).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        playback.prepare(url: url)
        loadVideoGeometry(url)
        monitorPlayerStatus()
      }
    }
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      playback.release()
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
    guard let item = playback.player?.currentItem else { return }
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        if item.status == .failed {
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
struct VideoDisplayGeometry {
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
