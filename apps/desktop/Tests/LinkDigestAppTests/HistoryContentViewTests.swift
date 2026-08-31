import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestApp

final class HistoryContentViewTests: XCTestCase {
  func testCurrentCapturePreviewResolvesPlayableDirectAndHLSWithoutDownload() throws {
    let now = Date(timeIntervalSince1970: 1_784_500_000)
    let direct = mediaDescriptor(kind: .directFile, playbackURL: "https://media.example.test/video.mp4")
    let hls = mediaDescriptor(kind: .hls, playbackURL: "https://media.example.test/master.m3u8")

    XCTAssertEqual(
      CurrentCaptureMediaPreview.resolve(direct, now: now),
      .playable(
        url: try XCTUnwrap(URL(string: "https://media.example.test/video.mp4")),
        kind: .directFile,
        companionAudioURL: nil
      )
    )
    XCTAssertEqual(
      CurrentCaptureMediaPreview.resolve(hls, now: now),
      .playable(
        url: try XCTUnwrap(URL(string: "https://media.example.test/master.m3u8")),
        kind: .hls,
        companionAudioURL: nil
      )
    )
    XCTAssertTrue(CurrentCaptureMediaPreview.isFavoriteEligible(direct))
    XCTAssertFalse(CurrentCaptureMediaPreview.isFavoriteEligible(hls))
    XCTAssertEqual(
      CurrentCaptureMediaPreview.favoriteUnavailableMessage(hls),
      "暂不支持保存 HLS；你仍可在当前会话中速览。"
    )
  }

  func testCurrentCapturePreviewRejectsExpiredPlaybackURL() {
    let descriptor = mediaDescriptor(
      kind: .directFile,
      playbackURL: "https://media.example.test/expired.mp4",
      expiresAt: "2026-07-20T00:00:00Z"
    )

    XCTAssertEqual(
      CurrentCaptureMediaPreview.resolve(
        descriptor,
        now: Date(timeIntervalSince1970: 1_784_524_801)
      ),
      .expired
    )
  }

  func testCurrentCapturePreviewMapsBrowserAndUnsupportedFailuresToStableChinese() {
    let cases: [(MediaKind, MediaFailureReason, String)] = [
      (.browserSessionOnly, .blobOrMSE, "只能在原浏览器会话观看"),
      (.unsupported, .drmOrEncrypted, "DRM"),
      (.unsupported, .multipleCandidates, "多个视频"),
      (.unsupported, .videoNotLoaded, "尚未加载"),
    ]

    for (kind, reason, expectedText) in cases {
      let descriptor = mediaDescriptor(kind: kind, failureReason: reason)
      guard case let .degraded(presentation) = CurrentCaptureMediaPreview.resolve(descriptor) else {
        return XCTFail("Expected degradation for \(kind)/\(reason)")
      }
      XCTAssertTrue(presentation.message.contains(expectedText), "presentation: \(presentation)")
      XCTAssertFalse(presentation.nextAction.isEmpty)
    }
  }

  @MainActor
  func testRemotePlaybackControllerReleasesPlayerOnCaptureSwitch() {
    let controller = RemotePreviewPlayerController()
    controller.prepare(url: URL(string: "https://media.example.test/a.mp4")!)
    XCTAssertTrue(controller.hasPlayer)

    controller.release()
    XCTAssertFalse(controller.hasPlayer)
  }

  func testVideoScrollAxisLockKeepsVerticalGestureThroughHorizontalJitterAndMomentum() {
    var lock = VideoScrollGestureAxisLock()

    XCTAssertEqual(lock.route(deltaX: 1, deltaY: -20, phase: .began, momentumPhase: [] )?.axis, .vertical)
    XCTAssertEqual(lock.route(deltaX: 30, deltaY: -1, phase: .changed, momentumPhase: [])?.axis, .vertical)
    XCTAssertEqual(lock.route(deltaX: 35, deltaY: -1, phase: [], momentumPhase: .began)?.axis, .vertical)
    XCTAssertEqual(lock.route(deltaX: 40, deltaY: -1, phase: [], momentumPhase: .changed)?.axis, .vertical)
  }

  func testVideoScrollAxisLockKeepsHorizontalGestureThroughVerticalJitter() {
    var lock = VideoScrollGestureAxisLock()

    XCTAssertEqual(lock.route(deltaX: 20, deltaY: 1, phase: .began, momentumPhase: [])?.axis, .horizontal)
    XCTAssertEqual(lock.route(deltaX: 1, deltaY: 30, phase: .changed, momentumPhase: [])?.axis, .horizontal)
  }

  func testVideoScrollAxisLockResetsForFreshGestureAfterEndAndMomentum() {
    var lock = VideoScrollGestureAxisLock()

    XCTAssertEqual(lock.route(deltaX: 0, deltaY: 20, phase: .began, momentumPhase: [])?.axis, .vertical)
    XCTAssertEqual(lock.route(deltaX: 0, deltaY: 8, phase: .ended, momentumPhase: [])?.axis, .vertical)
    XCTAssertNil(lock.lockedAxis, "ordinary end must release the active lock before a fresh gesture")
    XCTAssertEqual(lock.route(deltaX: 20, deltaY: 0, phase: .began, momentumPhase: [])?.axis, .horizontal)

    XCTAssertEqual(lock.route(deltaX: 20, deltaY: 0, phase: [], momentumPhase: .began)?.axis, .horizontal)
    XCTAssertEqual(lock.route(deltaX: 1, deltaY: 9, phase: [], momentumPhase: .ended)?.axis, .horizontal)
    XCTAssertNil(lock.lockedAxis)
  }

  func testVideoScrollAxisLockFreshBeganResetsStaleHorizontalLockBeforeClassifyingVertical() {
    var lock = VideoScrollGestureAxisLock()

    XCTAssertEqual(lock.route(deltaX: 20, deltaY: 0, phase: .began, momentumPhase: [])?.axis, .horizontal)
    XCTAssertEqual(lock.route(deltaX: 0, deltaY: 20, phase: .began, momentumPhase: [])?.axis, .vertical)
    XCTAssertEqual(lock.lockedAxis, .vertical)
  }

  func testVideoScrollAxisLockClassifiesPhaseLessWheelsIndependently() {
    var lock = VideoScrollGestureAxisLock()

    XCTAssertEqual(lock.route(deltaX: 0, deltaY: 5, phase: [], momentumPhase: [])?.axis, .vertical)
    XCTAssertNil(lock.lockedAxis)
    XCTAssertEqual(lock.route(deltaX: 5, deltaY: 0, phase: [], momentumPhase: [])?.axis, .horizontal)
    XCTAssertNil(lock.lockedAxis)
    XCTAssertNil(lock.route(deltaX: 4, deltaY: 4, phase: [], momentumPhase: []))
  }

  /// The anchor sits partway down a scrolled page, so its own coordinate space
  /// is offset from the window's. Comparing the window-space cursor against
  /// view-space bounds — as the first implementation did — matched only when the
  /// player happened to be at the window origin, so the interception silently
  /// did nothing for any player the user had scrolled to.
  @MainActor
  func testVideoScrollRoutePlannerHitTestsInEachAnchorsOwnCoordinateSpace() {
    let window = testWindow()
    let anchorOrigin = NSPoint(x: 300, y: 420)
    let base = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 200, height: 150))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(base.id)

    // Cursor inside the player: window (360, 470) is local (60, 50).
    let inside = withLocalPoint(base, windowPoint: NSPoint(x: 360, y: 470), anchorOriginInWindow: anchorOrigin)
    XCTAssertEqual(
      planner.route(.init(
        windowID: ObjectIdentifier(window), point: NSPoint(x: 360, y: 470),
        deltaX: 0, deltaY: 14, phase: .began, momentumPhase: [],
        isForwarding: false, candidates: [inside]
      )),
      .forward(base.id)
    )

    planner.resetGesture()

    // Same window point, but the anchor moved: now local (-240, -370), outside.
    let scrolledAway = withLocalPoint(base, windowPoint: NSPoint(x: 360, y: 470), anchorOriginInWindow: NSPoint(x: 600, y: 840))
    XCTAssertEqual(
      planner.route(.init(
        windowID: ObjectIdentifier(window), point: NSPoint(x: 360, y: 470),
        deltaX: 0, deltaY: 14, phase: .began, momentumPhase: [],
        isForwarding: false, candidates: [scrolledAway]
      )),
      .passThrough
    )
  }

  /// A `.began` carrying zero or equal deltas has no determinable axis, so the
  /// axis lock returns nil and its `resetsTarget` flag never reaches the
  /// planner. Without an independent reset the new gesture inherited the
  /// previous one's anchor and scrolled the wrong player.
  @MainActor
  func testVideoScrollRoutePlannerDropsStaleAnchorOnAmbiguousGestureStart() {
    let window = testWindow()
    let first = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(first.id)

    XCTAssertEqual(
      planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 14, phase: .began, candidates: [first])),
      .forward(first.id)
    )
    XCTAssertEqual(planner.lockedAnchorID, first.id)

    // Ambiguous start: no axis, but the stale target must still be released.
    _ = planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaX: 0, deltaY: 0, phase: .began, candidates: [first]))
    XCTAssertNil(planner.lockedAnchorID, "A new gesture must not inherit the previous anchor")

    // Equal deltas are likewise undeterminable and must not resurrect it.
    _ = planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaX: 7, deltaY: 7, phase: .began, candidates: [first]))
    XCTAssertNil(planner.lockedAnchorID)
  }

  @MainActor
  func testVideoScrollRoutePlannerRoutesEntryAfterVerticalGestureStartedOutsideAnchor() {
    let window = testWindow()
    let anchor = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(anchor.id)

    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 180, y: 40), deltaY: 12, phase: .began, candidates: [anchor])), .passThrough)
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 12, phase: .changed, candidates: [anchor])), .forward(anchor.id))
  }

  @MainActor
  func testVideoScrollRoutePlannerRejectsOtherWindowRangeHiddenAndMissingScrollView() {
    let window = testWindow()
    let otherWindow = testWindow()
    let valid = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(valid.id)

    let outside = testSample(window: window, point: NSPoint(x: 180, y: 40), deltaY: 12, phase: .began, candidates: [valid])
    XCTAssertEqual(planner.route(outside), .passThrough)

    let other = testCandidate(window: otherWindow, bounds: valid.bounds)
    planner.register(other.id)
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 12, phase: .began, candidates: [other])), .passThrough)

    let hidden = testCandidate(window: window, bounds: valid.bounds, isVisible: false)
    planner.register(hidden.id)
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 12, phase: .began, candidates: [hidden])), .passThrough)

    let invisible = testCandidate(window: window, bounds: valid.bounds, visibleRect: .zero)
    planner.register(invisible.id)
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 12, phase: .began, candidates: [invisible])), .passThrough)

    let noScrollView = testCandidate(window: window, bounds: valid.bounds, hasEnclosingScrollView: false)
    planner.register(noScrollView.id)
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 40, y: 40), deltaY: 12, phase: .began, candidates: [noScrollView])), .passThrough)
  }

  @MainActor
  func testVideoScrollRoutePlannerRegistrationIsIdempotentAndRemovingActiveAnchorClearsLock() {
    let window = testWindow()
    let first = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    let second = testCandidate(window: window, bounds: NSRect(x: 120, y: 0, width: 100, height: 100))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(first.id)
    planner.register(first.id)
    planner.register(second.id)
    XCTAssertEqual(planner.registeredAnchorCount, 2)

    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 20, y: 20), deltaY: 12, phase: .began, candidates: [first, second])), .forward(first.id))
    XCTAssertEqual(planner.lockedAnchorID, first.id)
    planner.unregister(second.id)
    XCTAssertEqual(planner.lockedAnchorID, first.id, "removing another anchor must not disturb the active target")
    planner.unregister(first.id)
    XCTAssertNil(planner.lockedAnchorID)
    XCTAssertEqual(planner.registeredAnchorCount, 0)
  }

  @MainActor
  func testVideoScrollRoutePlannerSelectsOnlyOneAnchorAndBypassesWhileForwarding() {
    let window = testWindow()
    let first = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    let second = testCandidate(window: window, bounds: NSRect(x: 0, y: 0, width: 100, height: 100))
    var planner = VideoScrollWheelRoutePlanner()
    planner.register(first.id)
    planner.register(second.id)

    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 20, y: 20), deltaY: 12, phase: .began, candidates: [first, second])), .forward(first.id))
    XCTAssertEqual(planner.route(testSample(window: window, point: NSPoint(x: 20, y: 20), deltaY: 12, phase: .changed, candidates: [first, second], isForwarding: true)), .passThrough)
  }

  func testVideoScrollBrokerUsesOneNonHitTestingAnchorAndGuardsFailedApproaches() {
    let source = historyContentViewSource()
    let component = section(
      in: source,
      from: "enum VideoScrollGestureAxis: Equatable",
      to: "struct HistoryContentView: View"
    )

    XCTAssertEqual(source.components(separatedBy: "VideoScrollWheelAnchor().allowsHitTesting(false)").count - 1, 3)
    XCTAssertTrue(component.contains("NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)"))
    XCTAssertTrue(component.contains("NSEvent.removeMonitor"))
    XCTAssertTrue(component.contains("override func viewDidMoveToWindow()"))
    XCTAssertTrue(component.contains("static func dismantleNSView"))
    XCTAssertTrue(component.contains("VideoScrollWheelBroker.shared.unregister(nsView)"))
    XCTAssertTrue(component.contains("override func hitTest"))
    XCTAssertTrue(component.contains("isForwarding"))
    XCTAssertTrue(component.contains("scrollView.scrollWheel(with: event)"))
    XCTAssertTrue(component.contains("guard gesture.axis == .vertical else { return .passThrough }"))

    // Regression guards for the nine rejected experiments. Keep this scope to
    // the new component: RemotePreviewPlayerController.release() legitimately
    // owns a different player lifecycle elsewhere in this source file.
    for forbidden in [
      "wantsLayer", "AVPlayerView", "override func scrollWheel", "seek(",
      "focusable", "onKeyPress", "makeFirstResponder", "controlsStyle", "player = nil", "NSApp.sendEvent",
    ] {
      XCTAssertFalse(component.contains(forbidden), "new scroll component must not use \(forbidden)")
    }
  }

  func testRootToolbarOwnsManualLinkMenuAndBindsAvailability() {
    let source = historyContentViewSource()
    let root = section(in: source, from: "struct HistoryContentView: View", to: "struct HistoryWindowToolbarThemeModifier")

    XCTAssertTrue(root.contains(".toolbar {"))
    XCTAssertTrue(root.contains("ToolbarItemGroup(placement: .primaryAction)"))
    XCTAssertTrue(root.contains("Button(\"添加链接\", action: manualLink.open)"))
    XCTAssertTrue(root.contains("Button(\"从剪贴板添加链接\", action: manualLink.readClipboardAndOpen)"))
    XCTAssertTrue(root.contains(".disabled(!manualLink.canOpen)"))
    XCTAssertTrue(root.contains(".accessibilityIdentifier(\"manual-link-add-toolbar\")"))
  }

  func testClipboardSuggestionBannerUsesHistoryAccessibilityIdentifiers() {
    let source = historyContentViewSource()
    let sidebar = section(in: source, from: "private var sidebar: some View", to: "private var navigationRail: some View")
    XCTAssertTrue(sidebar.contains("ClipboardSuggestionBanner"))
    XCTAssertTrue(source.contains("history-clipboard-suggestion"))
    XCTAssertTrue(source.contains("history-clipboard-capture"))
    XCTAssertTrue(source.contains("history-clipboard-ignore"))
  }

  func testDetailToolbarDoesNotDuplicateManualLinkMenu() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")

    XCTAssertFalse(detail.contains("manualLink"))
    XCTAssertFalse(detail.contains("manual-link-add-toolbar"))
    XCTAssertTrue(detail.contains(".accessibilityIdentifier(\"export-history\")"))
    XCTAssertTrue(detail.contains(".accessibilityIdentifier(\"delete-history\")"))
  }

  func testDetailMoreMenuOffersAccessibleSourceRecaptureThroughExistingFlow() {
    let source = historyContentViewSource()
    let root = section(in: source, from: "struct HistoryContentView: View", to: "struct HistoryWindowToolbarThemeModifier")
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")

    XCTAssertTrue(root.contains("openRecapture: { manualLink.openForRecapture($0) }"))
    XCTAssertTrue(detail.contains("Button(\"重新抓取原文…\") { openRecapture(sourceURL) }"))
    XCTAssertTrue(detail.contains(".accessibilityIdentifier(\"history-recapture-source\")"))
    XCTAssertTrue(detail.contains("guard !isOwnWriting"))
  }

  func testRunActionsWaitForStartupPreferencesBeforeGenerating() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    // 禁用与理由必须同源：不能再各写一套 `canStartRun` / `arePreferencesReady`。
    XCTAssertTrue(detail.contains("disabled: summarizeUnavailableReason != nil"))
    XCTAssertTrue(detail.contains("disabled: translateUnavailableReason != nil"))
    XCTAssertTrue(detail.contains("disabled: mindMapUnavailableReason != nil"))
    XCTAssertTrue(detail.contains("history-run-blocked-reason"))
    XCTAssertTrue(detail.contains("regenerate-blocked-reason"))
    XCTAssertTrue(detail.contains("preferencesReady: providerSettings.arePreferencesReady"))
    XCTAssertTrue(detail.contains("actionPill"))
    XCTAssertTrue(detail.contains("summarize-history-detail") || detail.contains("summarize-current-capture"))
    XCTAssertFalse(
      detail.contains(".disabled(!canRunHistory || !providerSettings.arePreferencesReady)"),
      "重新生成不能再另写一套门禁，必须复用 summarizeUnavailableReason"
    )
    XCTAssertTrue(detail.contains("已排队，等当前这条做完"))
    XCTAssertTrue(detail.contains("isManualGenerationQueued(taskID: detail.task.id, kind: .summarize)"))
    XCTAssertTrue(detail.contains("canEnqueueManualGeneration(for: detail.task.id)"))
  }

  func testThreeColumnNavigationKeepsSearchInTheContentList() {
    let source = historyContentViewSource()
    let sidebar = section(in: source, from: "private var sidebar: some View", to: "@ViewBuilder private var detail")

    XCTAssertTrue(source.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
    XCTAssertTrue(source.contains("content: {"))
    // The split view must consume the shared layout tokens. Hard-coded widths
    // previously drifted below the token minimums and truncated both sidebars.
    XCTAssertTrue(source.contains("min: DesignTokens.Layout.sidebarMin"))
    XCTAssertTrue(source.contains("ideal: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(source.contains("min: DesignTokens.Layout.listMin"))
    XCTAssertTrue(source.contains("ideal: DesignTokens.Layout.listIdeal"))
    XCTAssertTrue(source.contains(".modifier(HistoryWindowToolbarThemeModifier(theme: theme))"))
    // 工具栏背景必须逐列挂载：根部那一份对 macOS 分栏窗口不生效，表现是
    // 详情列滚动时标题从工具栏图标底下原样穿过。详情列用正文色当挡板。
    XCTAssertTrue(source.contains(".toolbarBackground(background ?? theme.canvas, for: .windowToolbar)"))
    XCTAssertTrue(source.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
    XCTAssertTrue(source.contains("HistoryWindowToolbarThemeModifier(theme: theme, background: theme.card)"))
    // Column dividers are drawn by a window-level AppKit overlay so the 1pt
    // line pierces the toolbar and reaches the window top; the in-content
    // SwiftUI hairline approach must not return (it cannot reach the toolbar).
    XCTAssertTrue(source.contains("WindowColumnDividerInstaller("))
    XCTAssertTrue(source.contains("lineColor: (theme.isNative || inlineImageLightbox.url != nil || videoCinema.isPresented) ? nil : NSColor(theme.hairline)"))
    XCTAssertFalse(source.contains("themedColumnDivider"))
    XCTAssertTrue(source.contains("private var navigationRail: some View"))
    XCTAssertTrue(source.contains("history-navigation-all"))
    XCTAssertTrue(source.contains("history-navigation-recent"))
    XCTAssertTrue(source.contains("history-navigation-unsummarized"))
    XCTAssertTrue(source.contains("history-navigation-tags-all"))
    XCTAssertTrue(source.contains("@State private var navigationTagsExpanded = false"))
    XCTAssertTrue(source.contains("Array(ordered.prefix(6))"))
    let platforms = appSource("PlatformGridView.swift")
    XCTAssertTrue(platforms.contains("Text(name)"), "Platform names must remain visible without hover")
    XCTAssertTrue(platforms.contains("PlatformNavigationRow"))
    // 普通点击=叠加（AND 缩小范围），⌘点击=只看此标签；Syc 2026-07-23 拍板翻转。
    XCTAssertTrue(source.contains("model.toggleTag(item.tag, additive: !NSEvent.modifierFlags.contains(.command))"))
    XCTAssertTrue(sidebar.contains(".frame(maxWidth: .infinity)"))
    XCTAssertFalse(sidebar.contains("history-tag-filters"), "The old horizontal tag rail must not coexist with navigation")
  }

  func testNavigationTagsAndDetailEditorBindToViewModelWithoutRemoteImages() {
    let source = historyContentViewSource()
    let sidebar = section(in: source, from: "private var sidebar: some View", to: "@ViewBuilder private var detail")
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")

    // 钉「侧栏有一个绑到 searchText 的搜索框」，不钉占位文字怎么写——
    // 原来钉的是完整字面量，于是调整占位文字就假失败。
    //
    // 但要求两个片段落在同一行：拆成两个 contains 的话，一个无关的 TextField
    // 加上另一处对 searchText 的引用就能凑合通过，等于什么都没钉住。
    XCTAssertTrue(
      sidebar.split(separator: "\n").contains {
        $0.contains("TextField(") && $0.contains("text: $model.searchText)")
      }
    )
    XCTAssertTrue(sidebar.contains("history-filter-empty"))
    XCTAssertTrue(detail.contains("HistoryTagEditor(tags: detail.tags, model: model)"))
    // Chips-first: composer is collapsed behind a toggle; no always-on heavy form.
    XCTAssertTrue(source.contains("history-tag-add-toggle"))
    XCTAssertTrue(source.contains("history-tag-add"))
    XCTAssertTrue(source.contains("history-tag-suggestions"))
    XCTAssertTrue(source.contains("isComposerExpanded"))
    XCTAssertTrue(source.contains("history-tag-empty-hint"))
    XCTAssertFalse(source.contains("AsyncImage"), "Tags must not add a new remote rendering path")
  }

  func testReadingModeKeepsActionToolbarUnderTitleBeforeReadingSurface() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")

    XCTAssertTrue(detail.contains("history-action-toolbar"))
    XCTAssertTrue(detail.contains("actionToolbar"))
    XCTAssertTrue(detail.contains("readingSurface"))
    XCTAssertTrue(detail.contains("actionPill"))
    XCTAssertFalse(
      detail.contains("summaryArtifact != nil && translationArtifact == nil"),
      "翻译醒目不能再暗示必须先总结"
    )
    let actions = section(in: detail, from: "private var actionToolbar", to: "private var captureAndRunControlsExtras")
    XCTAssertTrue(actions.contains(".buttonStyle(.borderless)"), "生成动作不应再用填充主按钮和标题抢权重")
    XCTAssertFalse(actions.contains(".buttonStyle(.borderedProminent)"))
    // Run/capture metadata sits under the title, not after the reading body.
    XCTAssertTrue(detail.contains("history-run-metadata") || detail.contains("if let run = newestRun"))
    XCTAssertTrue(detail.contains("history-capture-metadata"))
    if let meta = detail.range(of: "metadata"), let reading = detail.range(of: "readingSurface") {
      XCTAssertLessThan(meta.lowerBound, reading.lowerBound, "metadata must appear above the reading surface")
    } else {
      XCTFail("metadata/readingSurface order anchors missing")
    }
    // Result and source stay reachable after summarize/translate.
    XCTAssertTrue(detail.contains("history-reading-pane-picker"))
    XCTAssertTrue(detail.contains("history-reading-result"))
    XCTAssertTrue(detail.contains("history-reading-source"))
    // Completion feedback + no dead "格式" placeholder in the toolbar.
    XCTAssertTrue(detail.contains("history-run-completion-banner"))
    XCTAssertFalse(detail.contains("disabledAction(\"格式\""))
    // Plain text lives in the share menu, not as an inline checkbox over body.
    XCTAssertTrue(detail.contains("以纯文本查看正文"))
    XCTAssertTrue(detail.contains("showsInlinePlainTextToggle: false"))
    XCTAssertTrue(detail.contains("onFollowWikiLink:"), "阅读区双链必须接到 followWikiLink，不能只在编辑器里可点")
    // 转写 / 笔记默认排版，单击进编辑；空笔记仍一打开就写。
    XCTAssertTrue(detail.contains("onRequestEdit:"))
    XCTAssertTrue(detail.contains("beginSourceEditing"))
    XCTAssertTrue(detail.contains("finishSourceEditing"))
    XCTAssertTrue(detail.contains("if body.isEmpty"))
    XCTAssertFalse(
      detail.contains("\"编辑转写\""),
      "进入编辑不应再依赖右上角「编辑转写」按钮"
    )
    XCTAssertTrue(
      detail.contains("suppressSourceEditFinishUntil"),
      "打开编辑器的那次点击不能立刻被当成失焦退出"
    )
    XCTAssertTrue(source.contains("SourceEditClickOutsideMonitor"))
    XCTAssertTrue(detail.contains("sourceEditClickOutside.start()"))
  }

  func testDetailUsesCenteredReadingColumnAndShowsStandaloneEngagementStats() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(
      detail.contains("maxWidth: DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: readingFont.bodySize)"),
      "内容列上限应随字号联动，而不是钉死的 680pt"
    )
    XCTAssertTrue(detail.contains(".frame(maxWidth: .infinity, alignment: .center)"))
    XCTAssertTrue(detail.contains(".padding(.horizontal, DesignTokens.Layout.readingHorizontalInset)"))
    XCTAssertFalse(detail.contains(".padding(.leading, 48)"))
    // Non-WeChat captures retain their independently extracted social stats;
    // WeChat deliberately never presents that row, including old imports.
    XCTAssertTrue(detail.contains("!isWeChatCapture && sourceFrontmatter.hasEngagementStats"))
    XCTAssertTrue(detail.contains("history-engagement-stats"))
    XCTAssertTrue(detail.contains("sourceByline"), "作者、日期、站点应收成一行，不再各占一列表单")
  }

  func testWeChatPropertiesShowSourceFieldsWithoutInventingEngagementStats() {
    let source = historyContentViewSource()
    let byline = section(in: source, from: "private var sourceBylineText", to: "private var hasCollapsedRunMetadata")
    XCTAssertTrue(byline.contains("sourceFrontmatter.accountName"), "公众号名应出现在 byline，不再单独占一行")
    // The cover thumbnail was removed on purpose: a WeChat cover is usually a
    // repeat of the first body image or a promotional card, and showing it above
    // the text displaced the article's real opening. The body carries its own
    // images in the author's order, which is the only ordering worth trusting.
    XCTAssertFalse(source.contains("history-wechat-cover-image"))
    XCTAssertTrue(source.contains("!isWeChatCapture && sourceFrontmatter.hasEngagementStats"))
    XCTAssertFalse(source.contains("read_num"))
    XCTAssertFalse(source.contains("like_num"))
    XCTAssertTrue(source.contains("appendsUnusedLocalImages: !isWeChatCapture"))
    XCTAssertTrue(source.contains("groupsConsecutiveImages: !isWeChatCapture"))
  }

  func testWeChatArticleBodyPrecedesTheGeneralMediaSection() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("presentsArticleBeforeMedia"))
    XCTAssertTrue(detail.contains("RemoteMarkdownImageStagingPolicy.isSubstantiveWeChatArticle"))
    XCTAssertTrue(detail.contains("if presentsArticleBeforeMedia"))
    XCTAssertTrue(detail.contains("if !presentsArticleBeforeMedia"))
    guard let articleBranch = detail.range(of: "if presentsArticleBeforeMedia"),
          let articleReading = detail.range(of: "readingSurface", range: articleBranch.upperBound..<detail.endIndex),
          let media = detail.range(of: "if let localMediaFileURL", range: articleReading.upperBound..<detail.endIndex),
          let videoFirstBranch = detail.range(of: "if !presentsArticleBeforeMedia", range: media.upperBound..<detail.endIndex),
          let videoFirstReading = detail.range(of: "readingSurface", range: videoFirstBranch.upperBound..<detail.endIndex),
          let mindMap = detail.range(of: "MindMapSectionView", range: videoFirstReading.upperBound..<detail.endIndex)
    else { return XCTFail("WeChat/article and video-first ordering anchors are unavailable") }
    XCTAssertLessThan(articleReading.lowerBound, media.lowerBound)
    XCTAssertLessThan(media.lowerBound, videoFirstReading.lowerBound)
    XCTAssertLessThan(videoFirstReading.lowerBound, mindMap.lowerBound, "Derived mind map must not displace reading content")
  }

  func testWeChatNeverRendersEmbeddedVideoOrVideoMetadata() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("private var suppressesEmbeddedMedia: Bool { latestSnapshot?.platform == \"wechat\" }"))
    XCTAssertTrue(detail.contains("if !suppressesEmbeddedMedia"))
    XCTAssertTrue(detail.contains("guard !suppressesEmbeddedMedia else { return nil }"))
  }

  func testDouyinRepeatedSourceBodyIsHiddenUnlessItAddsNewInformation() {
    let title = "@杨一面对面 · 5天前 2人共创创业第24集：商业问道已是最新集"
    let repeated = "---\nauthor: \"杨一面对面\"\n---\n\n# \(title)\n\n\(title)"
    XCTAssertTrue(CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: "douyin",
      title: title,
      markdown: repeated
    ))
    XCTAssertFalse(CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: "douyin",
      title: title,
      markdown: "\(repeated)\n\n这是标题之外的新信息。"
    ))
    XCTAssertFalse(CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: "wechat",
      title: title,
      markdown: repeated
    ))

    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")
    // The redundancy check survives, but its only job now is picking the default
    // pane. It must not remove the source pane from reach: a Douyin capture whose
    // body echoes the title still carries author / published / engagement
    // frontmatter that exists nowhere else in the UI.
    XCTAssertTrue(detail.contains("hasPresentableSourceBody"))
    XCTAssertTrue(detail.contains("defaultReadingPane"))
    XCTAssertTrue(detail.contains("showsLiveRunInReadingPane || hasResultBody || hasSourceBody"))
    XCTAssertTrue(detail.contains("if !presentsArticleBeforeMedia, showsReadingSurface"))
  }

  func testEchoedOpeningTitleIsStrippedFromTheReadingCard() {
    let title = "The deepseek of DeepSeek Harness: Overengineering or built for self-evolution?"
    let body = """
    # \(title)

    2026-08-20 36 min

    对 DeepSeek Harness 的一次 deepseek。
    """
    let stripped = CapturedSourceBodyPresentation.strippingEchoedOpening(title: title, from: body)
    XCTAssertFalse(stripped.contains(title), "阅读卡不应再印一遍已经在页眉的标题")
    XCTAssertFalse(stripped.contains("36 min"), "紧跟标题的日期/时长行也是重复信息")
    XCTAssertTrue(stripped.contains("对 DeepSeek Harness 的一次 deepseek。"))
    XCTAssertEqual(
      CapturedSourceBodyPresentation.strippingEchoedOpening(title: title, from: "目录\n\n第一节"),
      "目录\n\n第一节",
      "对不上标题的开头不能剥"
    )
    let source = historyContentViewSource()
    XCTAssertTrue(source.contains("strippingEchoedOpening(title: title, from: cleaned)"))
    XCTAssertTrue(source.contains("guard !isOwnWriting else { return cleaned }"))
  }

  func testHistoryTagEmptyStateIsMinimalWithoutLongHint() {
    let source = historyContentViewSource()
    XCTAssertFalse(source.contains("标签将在总结后自动生成"))
    XCTAssertTrue(source.contains("history-tag-empty-hint"))
  }

  func testGitHubReadmeImagesAreLoadedOnlyFromHistoryLocalCache() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("localImageURLs"))
    XCTAssertTrue(detail.contains("localImageURLs: localImageURLs"))
    XCTAssertTrue(detail.contains("showsInlinePlainTextToggle: false"))
    XCTAssertTrue(source.contains("LocalMarkdownImageLayout") || source.contains("localImageURLs: localImageURLs"))
    XCTAssertFalse(detail.contains("AsyncImage"), "History must not load README images from the network at render time")
    // 旧的 localImageGallery 已删除：它在 body 里同步全分辨率解码（NSImage(contentsOf:)），
    // 本地图片统一走 InlineArticleImageView 的后台下采样路径。
    XCTAssertFalse(detail.contains("NSImage(contentsOf:"), "Detail must not decode full-resolution images synchronously in body")
  }

  func testDetailHostsLocalAVKitVideoCardForLoopVMedia() {
    let source = historyContentViewSource()
    XCTAssertTrue(source.contains("HistoryVideoPlayerCard"))
    XCTAssertTrue(source.contains("localMediaFileURL"))
    XCTAssertTrue(source.contains("import AVKit"))
    XCTAssertTrue(source.contains("history-video-player-card"))
    XCTAssertFalse(source.contains("AVPlayer(url: URL(string:"), "Must not stream remote signed URLs from History")
  }

  func testCurrentCapturePreviewCardHasLifecycleAndAccessibilityGates() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    let preview = section(in: source, from: "struct CurrentCaptureMediaPreviewCard: View", to: "/// Top-of-detail video card")

    XCTAssertTrue(detail.contains("showsCurrentCapture"))
    XCTAssertTrue(detail.contains("let captureDescriptor = capture.mediaDescriptor"))
    XCTAssertTrue(detail.contains("localMediaFileURL == nil"))
    XCTAssertTrue(detail.contains("CurrentCaptureMediaPreviewCard"))
    XCTAssertTrue(detail.contains("HistorySessionMediaUnavailableCard"))
    XCTAssertTrue(detail.contains("HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable"))
    XCTAssertTrue(preview.contains(".onChange(of: descriptor)"))
    XCTAssertTrue(preview.contains(".onDisappear"))
    // 共享 controller：卡片不 release，由列表预热宿主在离开可播上下文时 release。
    XCTAssertTrue(preview.contains("cancelGeometryAndStatusMonitors()"))
    XCTAssertTrue(source.contains("synchronizeRemotePreviewPreheat"))
    XCTAssertTrue(source.contains("remotePreviewPlayback.release()"))
    XCTAssertTrue(preview.contains("VideoPlayer(player: playback.player)"))
    XCTAssertTrue(preview.contains("history-video-preview-card"))
    XCTAssertTrue(preview.contains("history-video-remote-player"))
    XCTAssertTrue(preview.contains("history-video-preview-degradation"))
    XCTAssertTrue(preview.contains("history-video-preview-favorite"))
    XCTAssertTrue(preview.contains("history-video-preview-favorite-status"))
    XCTAssertTrue(preview.contains("history-video-preview-expired"))
    XCTAssertTrue(preview.contains("正在连接视频流"))
    XCTAssertTrue(preview.contains("history-video-preview-preparing"))
    XCTAssertTrue(preview.contains("history-video-preview-network-unavailable"))
    XCTAssertTrue(preview.contains("history-video-preview-retry"))
  }

  func testCurrentAndRestoredBilibiliPreviewCardsExposeQualitySelection() {
    let source = historyContentViewSource()
    let detail = section(
      in: source,
      from: "private struct HistoryDetailView: View",
      to: "private struct DataDestinationDisclosureView"
    )
    let currentCapture = section(
      in: detail,
      from: "let captureDescriptor = capture.mediaDescriptor",
      to: "} else if let youTubeVideoID"
    )
    let restoredCapture = section(
      in: detail,
      from: "let sessionDescriptor = sessionMediaPlayback.cachedDescriptor",
      to: "} else if HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable"
    )

    for branch in [currentCapture, restoredCapture] {
      XCTAssertTrue(branch.contains("onSelectQuality: { quality in"))
      XCTAssertTrue(branch.contains("qualityOverride: quality"))
      XCTAssertTrue(branch.contains("selectedQuality: sessionMediaPlayback.chosenQuality"))
      XCTAssertTrue(branch.contains(".id(sessionMediaPlayback.generation)"))
      let select = section(
        in: branch,
        from: "onSelectQuality: { quality in",
        to: "selectedQuality:"
      )
      XCTAssertTrue(select.contains("requestRefresh("))
      XCTAssertFalse(
        select.contains("remotePreviewPlayback.release()"),
        "换档不能先拆掉正在播的画面"
      )
      XCTAssertFalse(
        select.contains("invalidateAndRefresh("),
        "换档不能先清掉还能播的旧地址"
      )
      // 诊断仍挂在带清晰度菜单的分支上，但出货默认不渲染。
      XCTAssertTrue(
        branch.contains("streamSelectionDiagnostic"),
        "带清晰度菜单的分支必须同时挂上选流诊断"
      )
    }
    XCTAssertTrue(
      detail.contains("showsStreamSelectionDiagnostic"),
      "选流诊断必须有出货开关，不能把 Cookie / API 档位直接铺在播放器下"
    )
    XCTAssertTrue(detail.contains("LINKDIGEST_PRINT_CHANGES"))
    XCTAssertTrue(
      currentCapture.contains(
        "sessionMediaPlayback.cachedDescriptor(for: capture.taskID)"
      ),
      "当前抓取手选清晰度后必须改用刚刷新的会话地址"
    )
  }

  func testVideoMetadataUsesRefreshedSessionDescriptorBeforeUnavailableFallback() {
    let source = historyContentViewSource()
    let metadata = section(
      in: source,
      from: "private var videoMetadataValue: String?",
      to: "private func formatMediaDuration"
    )

    XCTAssertTrue(
      metadata.contains("sessionMediaPlayback.cachedDescriptor(for: detail.task.id)")
    )
    XCTAssertTrue(metadata.contains("case .playable = CurrentCaptureMediaPreview.resolve(descriptor)"))
    XCTAssertLessThan(
      metadata.range(of: "sessionMediaPlayback.cachedDescriptor(for: detail.task.id)")!.lowerBound,
      metadata.range(of: "return \"已抓取 · 此处不可播\"")!.lowerBound
    )
  }

  func testSessionOnlyUnavailablePresentationIsDesignNotError() {
    // 抓取事实优先：V2 MediaDescriptor（任意平台，含 x / github / generic）。
    for platform in ["bilibili", "xiaohongshu", "douyin", "x", "github", "generic"] {
      XCTAssertTrue(
        HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
          hadMediaDescriptor: true,
          hasLocalMediaFile: false,
          hasLocalMediaRow: false,
          hasLocalMediaResolutionFailure: false,
          isCurrentCaptureWithDescriptor: false,
          isYouTube: false,
          legacyPlatformHint: platform
        ),
        "V2 media fact must show session card for \(platform)"
      )
    }

    // 纯文字 X（V1，无 MediaDescriptor）不得冒充视频。
    XCTAssertFalse(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: false,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false,
        legacyPlatformHint: "x"
      )
    )
    // wechat 扩展侧丢弃 media，不会有 V2 事实；平台名本身也不应触发。
    XCTAssertFalse(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: false,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false,
        legacyPlatformHint: "wechat"
      )
    )

    // 当前抓取仍有 descriptor：走播放卡。
    XCTAssertFalse(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: true,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: true,
        isYouTube: false
      )
    )
    // 本机已保存：走本地播放卡。
    XCTAssertFalse(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: true,
        hasLocalMediaFile: true,
        hasLocalMediaRow: true,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false
      )
    )
    // 抖音图文帖即使误带事实也不当视频速览。
    XCTAssertFalse(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: true,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false,
        isDouyinImagePost: true,
        legacyPlatformHint: "douyin"
      )
    )
    // 极老 V1 抖音视频：无 V2 合同行时仍用平台兜底。
    XCTAssertTrue(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: false,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false,
        legacyPlatformHint: "douyin"
      )
    )
    // 极老 V1 B 站视频：合同是 v1、库里没有 media_assets，重启后会话缓存清空
    // 时仍应出现「重新获取播放」，不能整块消失只剩转写稿。
    XCTAssertTrue(
      HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
        hadMediaDescriptor: false,
        hasLocalMediaFile: false,
        hasLocalMediaRow: false,
        hasLocalMediaResolutionFailure: false,
        isCurrentCaptureWithDescriptor: false,
        isYouTube: false,
        legacyPlatformHint: "bilibili"
      )
    )

    XCTAssertEqual(HistorySessionMediaPresentation.title, "此记录包含视频")
    XCTAssertTrue(HistorySessionMediaPresentation.explanation.contains("只在抓取当次有效"))
    XCTAssertFalse(HistorySessionMediaPresentation.explanation.contains("加载失败"))
    XCTAssertFalse(HistorySessionMediaPresentation.explanation.contains("地址已失效"))
    XCTAssertEqual(HistorySessionMediaPresentation.openSourceActionTitle, "回到原页面观看")
    XCTAssertEqual(HistorySessionMediaPresentation.refreshActionTitle, "重新获取播放")
  }

  func testDesktopExecutableExplicitlyLinksAVKitFramework() {
    let package = desktopPackageSource()
    let appTarget = section(
      in: package,
      from: ".executableTarget(\n    name: \"LinkDigestApp\"",
      to: ".executableTarget(name: \"LinkDigestNativeHost\""
    )

    XCTAssertTrue(appTarget.contains("linkerSettings: [.linkedFramework(\"AVKit\")]"))
  }

  func testVideoSaveUsesNativePanelAndLocalOnlyCopyPath() {
    let source = historyContentViewSource()
    let video = section(in: source, from: "struct HistoryVideoPlayerCard: View", to: "/// UI state changes")

    XCTAssertTrue(video.contains("NSSavePanel()"))
    XCTAssertTrue(video.contains("Button(\"另存一份\""))
    XCTAssertTrue(video.contains("history-video-save-local"))
    XCTAssertTrue(video.contains("LocalMediaExport.isSupportedLocalFile"))
    XCTAssertTrue(video.contains("fileManager.copyItem(at: source, to: temporaryURL)"))
    XCTAssertTrue(video.contains("fileManager.replaceItemAt(destination, withItemAt: temporaryURL)"))
    XCTAssertFalse(video.contains("URLSession"))
    XCTAssertFalse(video.contains("downloadTask"))
    XCTAssertFalse(video.contains("dataTask"))
  }

  func testVideoMetadataAndAllActionsPrecedeAspectCorrectPlayer() {
    // 播放卡片已拆到 HistoryMediaPlayback.swift；整份读，不再切片。
    let video = appSource("HistoryMediaPlayback.swift")

    let local = video.range(of: "已保存到本机")
    let transcribe = video.range(of: "transcriptionControl")
    let save = video.range(of: "Button(\"另存一份\"")
    let player = video.range(of: "playerSurface")
    XCTAssertNotNil(local); XCTAssertNotNil(transcribe); XCTAssertNotNil(save); XCTAssertNotNil(player)
    XCTAssertLessThan(local!.lowerBound, player!.lowerBound)
    XCTAssertLessThan(transcribe!.lowerBound, player!.lowerBound)
    XCTAssertLessThan(save!.lowerBound, player!.lowerBound)
    XCTAssertTrue(video.contains("media?.byteSize"))
    // 作者不再出现在播放卡片的事实行：详情属性区已有「作者」一栏，
    // 卡片里重复一遍只会挤占时长/体积的空间。
    XCTAssertFalse(video.contains("media?.author"))
    XCTAssertTrue(video.contains("media?.durationSeconds"))
    XCTAssertTrue(video.contains(".aspectRatio(VideoDisplayGeometry.aspectRatio"))
    XCTAssertTrue(video.contains("naturalSize"))
    XCTAssertTrue(video.contains("preferredTransform"))
    XCTAssertFalse(video.contains(".frame(minHeight: 220, maxHeight: 360)"))
    XCTAssertTrue(video.contains("history-video-geometry-placeholder"))
  }

  func testRemotePreviewTranscriptionIsExplicitDirectOnlyAndExposesRecoveryIdentifiers() {
    let preview = appSource("HistoryMediaPlayback.swift")
    for identifier in [
      "remote-transcribe", "remote-transcribe-state",
      "remote-transcribe-cancel", "remote-transcribe-retry",
      "remote-transcribe-cleanup-failure", "remote-transcribe-cleanup-retry",
    ] {
      XCTAssertTrue(preview.contains(identifier), "missing \(identifier)")
    }
    XCTAssertTrue(preview.contains("当前 Debug 暂不支持 HLS 转写"))
    XCTAssertTrue(preview.contains("model.requestRemoteTranscription"))
    XCTAssertFalse(preview.contains("TranscriptionTempStore"))
    XCTAssertFalse(preview.contains("fetchResource"))
    XCTAssertFalse(preview.contains("VideoMediaDownloader"))
    XCTAssertFalse(preview.contains("remote-transcribe-partial"), "streaming body belongs in the source pane")
  }

  func testDetailPropertiesMetadataAndPrimaryActionsPrecedeVideoCard() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    let byline = detail.range(of: "sourceByline")
    let actions = detail.range(of: "actionToolbar\n")
    let video = detail.range(of: "HistoryVideoPlayerCard(")
    XCTAssertNotNil(byline); XCTAssertNotNil(actions); XCTAssertNotNil(video)
    XCTAssertLessThan(byline!.lowerBound, video!.lowerBound)
    XCTAssertLessThan(actions!.lowerBound, video!.lowerBound)
  }

  func testVideoDisplayGeometryAppliesRotationAndFitsWithoutCropping() {
    let landscape = VideoDisplayGeometry.displaySize(
      naturalSize: CGSize(width: 2_880, height: 2_160),
      preferredTransform: .identity
    )
    XCTAssertEqual(landscape.width, 2_880)
    XCTAssertEqual(landscape.height, 2_160)
    XCTAssertEqual(VideoDisplayGeometry.aspectRatio(displaySize: landscape), 4.0 / 3.0, accuracy: 0.0001)

    let portrait = VideoDisplayGeometry.displaySize(
      naturalSize: CGSize(width: 1_920, height: 1_080),
      preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
    )
    XCTAssertEqual(portrait.width, 1_080, accuracy: 0.001)
    XCTAssertEqual(portrait.height, 1_920, accuracy: 0.001)
    let fitted = VideoDisplayGeometry.fittedSize(displaySize: portrait, maxWidth: 680, maxHeight: 520)
    XCTAssertLessThanOrEqual(fitted.width, 680)
    XCTAssertEqual(fitted.height, 520, accuracy: 0.001)
    XCTAssertEqual(fitted.width / fitted.height, portrait.width / portrait.height, accuracy: 0.0001)
  }

  func testAudioOnlyMediaResolvesToAPlayableSurfaceInsteadOfWaitingForVideoSize() {
    // B 站的 DASH 把画面与声音拆成两条流，抓取拿到的是声音那条：没有视频轨，
    // 读不出画面尺寸。旧实现在这种情况下直接 return，界面永远停在"正在读取
    // 视频尺寸…"。三种输入都必须落到确定状态。
    XCTAssertEqual(
      VideoDisplayGeometry.surfaceGeometry(videoTrack: nil, hasAudioTrack: true),
      .audioOnly
    )
    XCTAssertEqual(
      VideoDisplayGeometry.surfaceGeometry(videoTrack: nil, hasAudioTrack: false),
      .unavailable
    )
    XCTAssertEqual(
      VideoDisplayGeometry.surfaceGeometry(
        videoTrack: (CGSize(width: 1_920, height: 1_080), .identity),
        hasAudioTrack: true
      ),
      .video(CGSize(width: 1_920, height: 1_080))
    )
    // 尺寸为零的视频轨不是可显示的画面，按有没有声音退化。
    XCTAssertEqual(
      VideoDisplayGeometry.surfaceGeometry(videoTrack: (.zero, .identity), hasAudioTrack: true),
      .audioOnly
    )

    // 只有 `.loading` 才画转圈；其余状态都要给出可播放的音频条。
    let source = historyContentViewSource()
    let surface = section(
      in: source,
      from: "@ViewBuilder private var playerSurface: some View",
      to: "@ViewBuilder private var transcriptionControl"
    )
    XCTAssertTrue(surface.contains("else if surfaceGeometry == .loading"))
    XCTAssertTrue(surface.contains("history-audio-only-player"))
  }

  func testVideoPostsPlayBeforeTranscriptAndWeChatArticlesStayTextFirst() {
    let source = historyContentViewSource()
    let rule = section(
      in: source,
      from: "private var presentsArticleBeforeMedia: Bool",
      to: "private var suppressesEmbeddedMedia"
    )
    // 有视频时播放器在上，文稿在下；只有微信长文仍旧正文在前。
    XCTAssertFalse(rule.contains("latestSnapshot.platform == \"x\""))
    XCTAssertTrue(rule.contains("isSubstantiveWeChatArticle"))
    XCTAssertFalse(rule.contains("douyin"))
  }

  func testSpaceKeyFallbackDoesNotSurrenderToTheSelectedList() {
    let source = historyContentViewSource()
    // NSTableView 是 NSControl 子类，macOS 上 SwiftUI 的 List 底层正是它。
    // 笼统放行 NSControl 会让「抓取完成后列表被选中」这一最常见的状态把空格
    // 让给滚动视图翻页——表现就是闪屏且不播放。
    XCTAssertFalse(source.contains("case is NSControl: return event"))
    XCTAssertTrue(source.contains("case is NSButton, is NSTextField, is NSComboBox,"))
    // 输入中的文本仍旧自己消费空格，否则打字会变成播放/暂停；但空着的搜索框
    // 只是叼着 initialFirstResponder，不该把空格吃掉。
    XCTAssertTrue(source.contains("if text.string.isEmpty { break }"))
    XCTAssertTrue(source.contains("case let text as NSText where text.isEditable:"))

    // 更根上的一道：开窗时就把空搜索框的焦点交还，别让它叼着光标。
    XCTAssertTrue(source.contains("struct ReleaseInitialSearchFocus"))
    XCTAssertTrue(source.contains("ReleaseInitialSearchFocus().allowsHitTesting(false)"))
    let release = section(
      in: source,
      from: "struct ReleaseInitialSearchFocus",
      to: "private struct PlayerSpaceKeyToggle"
    )
    // 只在搜索框确实空着时才交还，不能打断已经输入的搜索词。
    XCTAssertTrue(release.contains("editor.string.isEmpty"))
  }

  func testQualitySwitchRebuildsPlayerViewSoHighResDoesNotStayBlurry() {
    let playback = appSource("HistoryMediaPlayback.swift")
    XCTAssertTrue(playback.contains("struct VideoPlayerDisplayRefresh"))
    XCTAssertTrue(playback.contains("preferredMaximumResolution = .zero"))
    XCTAssertTrue(playback.contains("contentsScale"))
    XCTAssertTrue(playback.contains("drawableSize"))
    XCTAssertTrue(playback.contains("nudgeBounds"))
    XCTAssertTrue(playback.contains("resumeIfNeeded"))
    XCTAssertTrue(playback.contains("不要 `.id(player)`"))
    let surface = section(
      in: playback,
      from: "func linkDigestVideoSurface(player: AVPlayer?)",
      to: "盖在 AVKit 片尾 overlay 上面"
    )
    XCTAssertFalse(
      surface.contains(".id(player.map"),
      "换播放器时拆 AVPlayerView 会把已经播到的进度暂停"
    )
    let preview = section(
      in: playback,
      from: "case .ready, .idle, .preparing:",
      to: "accessibilityIdentifier(\"history-video-remote-player\")"
    )
    XCTAssertTrue(preview.contains("linkDigestVideoSurface(player: playback.player)"))
  }

  func testNativeVideoPlayersEnterCinemaOnDoubleClick() {
    let playback = appSource("HistoryMediaPlayback.swift")
    let cinema = appSource("YouTubeEmbedPlayer.swift")
    XCTAssertTrue(cinema.contains("struct VideoCinemaDoubleClickCatcher"))
    XCTAssertTrue(cinema.contains("event.clickCount == 2"))
    XCTAssertTrue(cinema.contains(".videoCinemaDoubleClick { cinema.dismiss() }"))
    let doubleClickCount = playback.components(separatedBy: "videoCinemaDoubleClick").count - 1
    XCTAssertEqual(doubleClickCount, 3, "预览、本机、流媒体三张卡都要能双击放大")
  }

  func testCinemaButtonAlignsToTheVideoEdgeNotTheReadingColumnEdge() {
    // 播放卡片已拆到 HistoryMediaPlayback.swift。
    let source = appSource("HistoryMediaPlayback.swift")
    // 竖屏视频收窄后，按整行右对齐会把「放大」甩到离视频很远的地方。这个单行
    // 写法只用在放大按钮那一处——播放器自身的 frame 是多行的，不会误命中。
    let button = source.range(of: "history-video-cinema")
    let alignment = source.range(
      of: ".frame(maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize))"
    )
    XCTAssertNotNil(button)
    XCTAssertNotNil(alignment)
    // 约束挂在按钮所在的那个 HStack 上，所以出现在按钮之后。
    XCTAssertLessThan(button!.lowerBound, alignment!.lowerBound)
  }

  func testInlinePlayerWidthFollowsAspectRatioSoPortraitVideoDropsItsBlackBars() {
    // 竖屏 9:16：宽度必须收到视频自身宽度，否则黑底铺满整行就是两条死黑边。
    let portrait = CGSize(width: 1_080, height: 1_920)
    let portraitWidth = VideoDisplayGeometry.inlineMaximumWidth(displaySize: portrait)
    XCTAssertEqual(portraitWidth, VideoDisplayGeometry.inlineMaximumHeight * (1_080.0 / 1_920.0), accuracy: 0.001)
    XCTAssertLessThan(portraitWidth, 400)

    // 横屏算出的宽度远大于阅读区，仍旧先撞阅读区宽度，表现与改动前一致。
    let landscape = CGSize(width: 1_920, height: 1_080)
    XCTAssertGreaterThan(VideoDisplayGeometry.inlineMaximumWidth(displaySize: landscape), 680)

    // 尺寸未知时退回 16:9，不能塌成 0 宽。
    XCTAssertEqual(
      VideoDisplayGeometry.inlineMaximumWidth(displaySize: nil),
      VideoDisplayGeometry.inlineMaximumHeight * (16.0 / 9.0),
      accuracy: 0.001
    )
  }

  func testInlineMediaFramesBoundWidthByRatioInsteadOfFillingTheRow() {
    let source = historyContentViewSource()
    // 弹性 `maxWidth: .infinity` 会把整行占满，比例只作用在内部——这正是
    // 竖屏黑边与竖图右侧空白的成因，播放器 frame 不能再用它。
    XCTAssertFalse(source.contains(".frame(maxWidth: .infinity, maxHeight: 520, alignment: .center)"))
    XCTAssertTrue(source.contains("VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize)"))

    let image = try? String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/ArticleImageViewing.swift"),
      encoding: .utf8
    )
    let imageSource = try! XCTUnwrap(image)
    XCTAssertTrue(imageSource.contains(".aspectRatio(ratio, contentMode: .fit)"))
    XCTAssertFalse(imageSource.contains(".frame(maxHeight: 420, alignment: .leading)"))
  }

  func testTranscriptionConfirmationStatesNoAudioUploadAndUsesSecondExplicitAction() {
    let source = historyContentViewSource()
    XCTAssertTrue(source.contains("需要下载 Apple 离线听写模型"))
    XCTAssertTrue(source.contains("Button(\"下载并转写\")"))
    XCTAssertTrue(source.contains("model.confirmModelDownloadAndTranscribe()"))
    XCTAssertTrue(source.contains("视频音频只在这台 Mac 上处理，不会上传"))
    XCTAssertTrue(source.contains("只读模式不能保存转写结果"))
  }

  func testVideoSaveFeedbackDelayBelongsToLatestSaveAndCancelsOnDisappear() {
    let source = historyContentViewSource()
    let video = section(in: source, from: "struct HistoryVideoPlayerCard: View", to: "/// UI state changes")

    XCTAssertTrue(video.contains("@State private var saveFeedbackTask: Task<Void, Never>?"))
    XCTAssertTrue(video.contains("saveFeedbackTask?.cancel()"))
    XCTAssertTrue(video.contains("saveFeedbackTask = Task { @MainActor in"))
    XCTAssertTrue(video.contains("guard !Task.isCancelled else { return }"))
    XCTAssertTrue(video.contains(".onDisappear"))
    XCTAssertTrue(video.contains("saveFeedbackTask = nil"))
  }

  func testLocalMediaExportCopiesMP4AndAtomicallyReplacesExistingDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HistoryContentViewTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("cached.mp4")
    let destination = root.appendingPathComponent("saved.mp4")
    let sourceBytes = Data("local-video".utf8)
    try sourceBytes.write(to: source)
    try Data("older-copy".utf8).write(to: destination)

    XCTAssertTrue(LocalMediaExport.isSupportedLocalFile(source))
    try LocalMediaExport.copyLocalFile(from: source, to: destination)

    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasPrefix(".linkdigest-export-") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testLocalMediaExportRejectsRemoteAndUnsupportedSources() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HistoryContentViewTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unsupported = root.appendingPathComponent("cached.webm")
    try Data("video".utf8).write(to: unsupported)
    let quickTime = root.appendingPathComponent("cached.mov")
    try Data("video".utf8).write(to: quickTime)

    XCTAssertFalse(LocalMediaExport.isSupportedLocalFile(URL(string: "https://example.invalid/video.mp4")!))
    XCTAssertFalse(LocalMediaExport.isSupportedLocalFile(unsupported))
    XCTAssertTrue(LocalMediaExport.isSupportedLocalFile(quickTime))
    XCTAssertThrowsError(
      try LocalMediaExport.copyLocalFile(
        from: quickTime,
        to: root.appendingPathComponent("renamed.mp4")
      )
    )
  }

  func testDetailAndSidebarUseDocumentTitleDisplayNotURLFallback() {
    let source = historyContentViewSource()
    XCTAssertTrue(source.contains("CapturedDocumentTitle.display"))
    XCTAssertFalse(source.contains("CapturedDocumentTitle.fallback(for: row.canonicalURL)"))
    XCTAssertFalse(source.contains("CapturedDocumentTitle.fallback(for: sourceURL)"))
  }

  func testHistorySourceLinkPresentationUsesHumanReadablePlatformLabels() {
    XCTAssertEqual(
      HistorySourceLinkPresentation.text("https://x.com/zjp1997720/status/2080660613530038730"),
      "x.com · @zjp1997720 的帖子"
    )
    XCTAssertEqual(
      HistorySourceLinkPresentation.text("https://www.bilibili.com/video/BV1xx411c7mD?spm_id_from=333"),
      "bilibili.com · 视频 BV1xx411c7mD"
    )
  }

  func testHistorySourceLinkPresentationKeepsACompactGenericPathAndSafeFallback() {
    XCTAssertEqual(
      HistorySourceLinkPresentation.text("https://www.example.com/articles/readable-title?utm_source=test"),
      "example.com · /articles/readable-title"
    )
    XCTAssertEqual(
      HistorySourceLinkPresentation.text("https://example.com/this/is/a/very/long/path/that/needs/truncation"),
      "example.com · /this/is/a/very/long/path/that/ne…"
    )
    XCTAssertEqual(HistorySourceLinkPresentation.text("not a url"), "not a url")
    XCTAssertEqual(HistorySourceLinkPresentation.host("https://www.zhenjia.dev/posts/x"), "zhenjia.dev")
    XCTAssertNil(HistorySourceLinkPresentation.host("not a url"))
  }

  func testDetailBindsLatestRunMetadataAndTokenBreakdownWithoutCostEstimate() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    let header = section(in: source, from: "private var sourceByline: some View {", to: "private var hasCollapsedRunMetadata")
    let extras = section(in: source, from: "private var collapsedRunMetadata: some View {", to: "private func metadataRow")
    XCTAssertTrue(header.contains("sourceBylineText"), "标题下应是一行 byline，不再单独占「创建时间」表单行")
    XCTAssertFalse(header.contains("title: \"创建时间\""), "创建时间已并入 byline")
    XCTAssertFalse(header.contains("title: \"操作\""), "操作不应再占标题下那一行")
    XCTAssertFalse(header.contains("title: \"Token\""), "Token 总账应进运行详情")
    XCTAssertFalse(header.contains("title: \"视频\""), "视频描述应进运行详情")
    XCTAssertTrue(extras.contains("if let run = newestRun"))
    XCTAssertTrue(extras.contains("historyAction(run.run.kind)"))
    XCTAssertTrue(extras.contains("run.run.model?.trimmedNonEmpty"))
    XCTAssertTrue(extras.contains("historyStatus(run.run.status)"))
    // Token 行改为全文总账（Run + 整理/脑图台账），分项用量在各功能状态行显示。
    XCTAssertTrue(extras.contains("model.taskTokenGrandTotals"))
    XCTAssertTrue(detail.contains("hasCollapsedRunMetadata"))
    XCTAssertFalse(detail.contains("title: \"费用\""), "BYOK prices are not reliable enough to display an estimate")
  }

  func testDetailExposesModelJumpAndTruncationLabel() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("openSettings: () -> Void"))
    XCTAssertTrue(detail.contains("settingsModelButton(providerSettings.activeSummaryModelName)"))
    XCTAssertTrue(detail.contains("history-open-model-settings") || detail.contains("openSettings()"))
    XCTAssertTrue(detail.contains("capture-truncated-notice"))
    XCTAssertTrue(detail.contains(".disabled(translateUnavailableReason != nil)"))
  }

  func testListIconsUseBuiltInPlatformMapThenLocalFaviconFallbackWithoutRemoteLoading() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    // 行不再整体观察 ViewModel：favicon 地址由父层算好传值进来。
    XCTAssertTrue(row.contains("let faviconURL: URL?"))
    XCTAssertTrue(source.contains("faviconURL: model.faviconImageURL(for: row)"))
    // 内存缓存命中直接画；未命中先占位、后台读盘。body 里不许同步磁盘 I/O。
    XCTAssertTrue(row.contains("HistoryFaviconImageMemoryCache.cachedImage"))
    XCTAssertTrue(row.contains("HistoryFaviconImageMemoryCache.decodeImage"))
    XCTAssertFalse(row.contains("NSImage(contentsOf:"), "行渲染路径不允许同步读盘解码图标")
    XCTAssertTrue(row.contains("PlatformIconCatalog.image(for: row.host)"))
    XCTAssertTrue(row.contains("PlatformIconCatalog.fallbackInitial(for: row.host)"))
    XCTAssertFalse(
      row.contains("Image(systemName: \"doc.text\")"),
      "Sources without an icon get a deterministic initial mark, not an anonymous document glyph"
    )
    XCTAssertFalse(row.contains("AsyncImage"), "List rendering must not load a remote favicon")
  }

  func testPlatformIconCatalogResolvesDouyinAndOtherPreviouslyUnmappedHosts() {
    // These hosts used to fall through to the network favicon path, which never
    // resolved for Douyin — the row stayed iconless forever.
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "www.douyin.com"), "douyin")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "douyin.com"), "douyin")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "v.douyin.com"), "douyin")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "www.iesdouyin.com"), "douyin")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "www.xiaohongshu.com"), "xiaohongshu")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "m.weibo.cn"), "weibo")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "juejin.cn"), "juejin")
    // Existing mappings keep working through the shared normalizer.
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "zhuanlan.zhihu.com"), "zhihu")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "mp.weixin.qq.com"), "wechat")
    XCTAssertEqual(PlatformIconCatalog.assetName(for: "WWW.X.COM"), "x.com")
    XCTAssertNil(PlatformIconCatalog.assetName(for: "news.ycombinator.com"))
    XCTAssertNil(PlatformIconCatalog.assetName(for: "example.test"))
  }

  func testPlatformNavigationCanUseLocalFaviconBeforeInitialFallback() {
    let source = historyContentViewSource()
    let grid = appSource("PlatformGridView.swift")
    let icon = section(in: source, from: "struct PlatformNavigationIcon: View", to: "private struct HistoryDetailView")
    XCTAssertTrue(grid.contains("faviconURL: item.faviconURL"))
    XCTAssertTrue(grid.contains(".accessibilityHidden(true)"))
    XCTAssertTrue(icon.contains("HistoryFaviconDiskImage"))
    XCTAssertTrue(icon.contains("fallbackBadge"))
  }

  func testMonochromePlatformMarksFollowTheCurrentThemeTextColor() {
    XCTAssertTrue(PlatformIconCatalog.usesTemplateRendering(forAssetName: "x.com"))
    XCTAssertTrue(PlatformIconCatalog.usesTemplateRendering(forAssetName: "github"))
    XCTAssertFalse(PlatformIconCatalog.usesTemplateRendering(forAssetName: "wechat"))
    XCTAssertFalse(PlatformIconCatalog.usesTemplateRendering(forAssetName: "youtube"))
  }

  func testUnmappedHostStillGetsAStableNonEmptyMark() {
    XCTAssertEqual(PlatformIconCatalog.fallbackInitial(for: "example.test"), "E")
    XCTAssertEqual(PlatformIconCatalog.fallbackInitial(for: "www.example.test"), "E")
    XCTAssertEqual(PlatformIconCatalog.fallbackInitial(for: "-.-"), "#")
    XCTAssertEqual(
      PlatformIconCatalog.fallbackColor(for: "example.test"),
      PlatformIconCatalog.fallbackColor(for: "www.example.test"),
      "The same source must keep the same colour across launches and spellings"
    )
  }

  /// The bundled asset set, the catalog table and the frozen packaging tuple are
  /// one contract: a mapping without a file ships an iconless row, and a file
  /// outside the tuple makes release verification reject the candidate.
  func testBundledIconAssetsMatchCatalogTableAndPackagingContract() throws {
    let assets = repositoryRoot()
      .appendingPathComponent("apps/desktop/Assets/PlatformIcons", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
      .filter { $0.hasSuffix(".svg") }
    let names = Set(files.map { String($0.dropLast(4)) })

    for host in [
      "douyin.com", "xiaohongshu.com", "weibo.com", "toutiao.com", "douban.com",
      "juejin.cn", "x.com", "zhihu.com", "bilibili.com", "github.com",
      "youtube.com", "reddit.com", "medium.com", "mp.weixin.qq.com",
    ] {
      let asset = try XCTUnwrap(PlatformIconCatalog.assetName(for: host), "\(host) has no mapping")
      XCTAssertTrue(names.contains(asset), "\(host) maps to missing asset \(asset).svg")
    }

    let releaseUnit = try String(
      contentsOf: repositoryRoot().appendingPathComponent("scripts/native-host/release_unit.py"),
      encoding: .utf8
    )
    for file in files.sorted() {
      XCTAssertTrue(
        releaseUnit.contains("\"\(file)\""),
        "\(file) is not in PLATFORM_ICON_FILES; release verification would reject the candidate"
      )
    }
  }

  /// What actually matters about a bundled icon: it is sized for the list cell,
  /// it draws something, and it can never reach the network. Whether the mark is
  /// a traced path or the platform's own bitmap embedded as a data URI is an
  /// acquisition detail — pinning `<path>` would have blocked using the real
  /// official artwork, which is the whole point of shipping these locally.
  func testBundledPlatformIconsAreSelfContainedSixteenPointAssets() throws {
    let icons = ["douyin", "xiaohongshu", "weibo", "toutiao", "douban", "juejin"]
    let directory = repositoryRoot().appendingPathComponent("apps/desktop/Assets/PlatformIcons", isDirectory: true)
    for icon in icons {
      let url = directory.appendingPathComponent("\(icon).svg")
      let source = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(source.contains("viewBox=\"0 0 16 16\""), "\(icon) must be a 16×16 asset")
      XCTAssertTrue(
        source.contains("<path") || source.contains("<image"),
        "\(icon) must actually draw something"
      )
      XCTAssertNil(
        source.range(of: #"(href|src)\s*=\s*"\s*(https?:)?//"#, options: .regularExpression),
        "\(icon) must not reference a remote resource — rendering happens offline"
      )
      let byteCount = try Data(contentsOf: url).count
      XCTAssertLessThanOrEqual(byteCount, 32 * 1024, "\(icon) exceeds the 32 KB asset budget")
    }
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testSummaryAndTranslationOccupySeparateReadingPanes() {
    // 曾经只有 result/source 两格，result 显示哪个由「最近产出文本的运行」决定：
    // 先翻译再总结，译文就被挤掉，库里有内容却没有入口能点回去。
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")

    XCTAssertFalse(
      detail.contains("case result"),
      "总结与翻译不能再共用一个结果格，否则后跑的会挤掉先跑的"
    )
    XCTAssertTrue(detail.contains("case summary"))
    XCTAssertTrue(detail.contains("case translation"))

    // 两个格子各自按「自己那类产物存不存在」决定出现与否，而不是共享一个判据。
    XCTAssertTrue(detail.contains("if summaryArtifact != nil || liveRunReadingPane == .summary { panes.append(.summary) }"))
    XCTAssertTrue(detail.contains("if translationArtifact != nil || liveRunReadingPane == .translation { panes.append(.translation) }"))

    // 取产物必须按运行类型取最新一份，只取全局最新就等于回到老毛病。
    XCTAssertTrue(detail.contains("artifact(ofKind: .summarize)"))
    XCTAssertTrue(detail.contains("artifact(ofKind: .translate)"))

    // 选中的格子不可用时要退回默认；这个兜底原来只对抖音生效。
    XCTAssertTrue(
      detail.contains("if !availableReadingPanes.contains(readingPane) { return defaultReadingPane }"),
      "切到只总结过的条目时，选中的翻译格会消失，必须退回默认而不是停在空白面板"
    )
  }

  func testReadingPanePickerStaysVisibleWhenOneSideIsEmpty() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")
    // 钉条件本身，不钉整行写法：这一行后来加了笔记分支从单行变成多行，
    // 行为没变，而写死整行的断言会因此假失败。
    XCTAssertTrue(
      detail.contains("hasResultBody || hasSourceBody || hasLiveTranscription"),
      "The picker must not disappear just because there is no summary yet"
    )
    // 自己写的东西是例外：只有一份正文时，不该出现只有一个选项的分段控件。
    //
    // 钉的是「按真实可用面板数决定」这个行为,不是判据叫什么名字——
    // 三模块切开后这个判据从 isUserNote 扩成了 isOwnWriting(笔记/稿件/作品
    // 都算),行为完全没变,而钉住变量名的断言会因此假失败。
    XCTAssertTrue(
      detail.contains("return availableReadingPanes.count > 1"),
      "自己写的东西应按真实可用面板数决定，而不是跟着抓取记录的规则走"
    )
    XCTAssertFalse(
      detail.contains("hasResultBody && hasPresentableSourceBody"),
      "isRedundantDouyinBody must no longer be able to hide the picker"
    )
    // 断言「空面板会自我解释」这个不变量，而不是某个具体的实参写法——
    // 结果面板拆成总结/翻译后实参从 .result 变成了 effectiveReadingPane，
    // 行为没变，写死字面量只会假失败。
    XCTAssertTrue(detail.contains("missingPaneNotice(for:"))
    XCTAssertTrue(detail.contains("missingPaneNotice(for: .source)"))
    XCTAssertTrue(detail.contains("latestTranscriptionSnapshot"))
    XCTAssertTrue(detail.contains("availableReadingPanes"))
    XCTAssertTrue(detail.contains("ForEach(availableReadingPanes)"))
    XCTAssertTrue(detail.contains("尚未转写"))
    XCTAssertTrue(detail.contains("点击上方的『转写』开始"))
    XCTAssertTrue(detail.contains("history-reading-result-empty"))
    XCTAssertTrue(detail.contains("尚未生成总结"))
    XCTAssertTrue(detail.contains("点击上方「生成总结」开始"))
    XCTAssertTrue(detail.contains("本条没有抓取到正文"))
    XCTAssertTrue(detail.contains("readingPane = defaultReadingPane"))
    XCTAssertTrue(
      detail.contains("of: detail.task.id, initial: true"),
      "The first rendered item must also land on a non-empty pane"
    )
  }

  func testLiveModelRunReadsInTheSummaryOrTranslationPane() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")

    XCTAssertFalse(detail.contains("生成预览"), "生成中的字不该再单独挂一块预览卡")
    XCTAssertFalse(detail.contains("streamingResultCard"))
    XCTAssertTrue(detail.contains("liveRunReadingBody"))
    // 面板保活：content 不再用 switch 销毁重建，各面板按传入的 pane 参数
    // 渲染并折叠（见 mountedReadingPane）。
    XCTAssertTrue(detail.contains("liveRunReadingPane == pane"))
    XCTAssertTrue(detail.contains("mountedReadingPane(.translation)"))
    XCTAssertTrue(detail.contains("visitedReadingPanes"))
    XCTAssertTrue(detail.contains("engageReadingPane(.summary, started: started)"))
    XCTAssertTrue(detail.contains("engageReadingPane(.translation, started: started)"))
    // 流式正文挪进了文件尾部的 LiveRunReadingBody 叶子视图（观察
    // LiveRunTextModel，拍点只重绘那一块）；标识符与接线改为钉全文。
    XCTAssertTrue(source.contains("model-run-output"))
    XCTAssertTrue(detail.contains("live: appModel.liveRunText"))
  }

  /// 行宽只能有一个控制点。
  ///
  /// 原来阅读区卡在 590pt，而它所在的内容列有 680pt 且左对齐——右边固定空出
  /// 58pt，正文实际只有 558pt。那不是留白设计，是两层上限打架的残留，看着像
  /// 卡片右边缺了一块。这类问题不报错，只是常年少了 16% 的可读宽度。
  func testReadingWidthHasASingleConstraint() {
    let source = historyContentViewSource()
    XCTAssertFalse(
      source.contains(".frame(maxWidth: 590, alignment: .leading)"),
      "阅读区的第二层宽度上限回来了，正文又会缩窄并在右侧留下空白")
    XCTAssertFalse(
      source.contains(".frame(maxWidth: 680, alignment: .leading)"),
      "钉死的 680pt 上限应已被字号联动的可读上限取代")
    XCTAssertTrue(
      source.contains("maxWidth: DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: readingFont.bodySize)"),
      "行宽仍要有上限，只是应当唯一——没有上限会让宽屏下的行长到不可读")
  }

  func testLiveTranscriptionRendersOnlyInSourcePaneWithSharedBodyTypography() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    let localVideo = section(in: source, from: "struct HistoryVideoPlayerCard: View", to: "/// UI state changes")
    let remoteVideo = section(in: source, from: "struct CurrentCaptureMediaPreviewCard: View", to: "/// Top-of-detail video card")

    // 转写流式正文挪进了文件尾部的 LiveTranscriptionReadingBody 叶子视图
    // （观察 LiveRunTextModel）；标识符改为钉全文，接线与排版仍钉详情区。
    XCTAssertTrue(source.contains("history-reading-source-live-transcription"))
    XCTAssertTrue(detail.contains("LiveTranscriptionReadingBody("))
    XCTAssertTrue(detail.contains("live: model.liveTranscriptionText"))
    // 正文排版已改为跟随用户偏好；实时转写必须读同一个来源，不能写死回 16.5。
    // readingFont.body() 连字体族一起带上，而不是只借字号（那会丢掉宋体等家族设置）。
    XCTAssertTrue(detail.contains("readingFont.body()"))
    XCTAssertTrue(detail.contains("MarkdownPresentation.bodyLineSpacing"))
    XCTAssertFalse(localVideo.contains("history-video-transcription-text"))
    XCTAssertFalse(remoteVideo.contains("remote-transcribe-partial"))
  }

  func testHistoryListUsesNativeMultiSelectionAndShowsCountPlaceholder() {
    let source = historyContentViewSource()
    XCTAssertTrue(source.contains("List(selection: $model.selectedTaskIDs)"))
    XCTAssertTrue(source.contains("history-multi-selection-placeholder"))
    XCTAssertTrue(source.contains("Text(\"已选择 \\(model.selectedTaskCount) 项\")"))
    XCTAssertTrue(source.contains("delete-selected-history"))
  }

  func testAppBootstrapUsesOneShotLatchBeforeConfiguringHistory() {
    let source = linkDigestAppSource()
    let task = section(in: source, from: ".task {", to: ".defaultSize")
    XCTAssertTrue(source.contains("@State private var didBootstrap = false"))
    XCTAssertTrue(task.contains("guard !didBootstrap else { return }"))
    XCTAssertTrue(task.contains("didBootstrap = true"))
    XCTAssertLessThan(
      try! XCTUnwrap(task.range(of: "didBootstrap = true")).lowerBound,
      try! XCTUnwrap(task.range(of: "historyModel.configure(")).lowerBound
    )
  }

  func testCapturedVideoAutoSaveIsOptInAndReusesExistingIngestPath() {
    let source = linkDigestAppSource()
    let captureSink = section(in: source, from: "captureSink: { value in", to: "self.configurationService")
    XCTAssertTrue(captureSink.contains("mediaStoragePreference.autoSaveCapturedVideo"))
    XCTAssertTrue(captureSink.contains("CurrentCaptureMediaPreview.favoriteMedia(descriptor)"))
    XCTAssertTrue(captureSink.contains("historyModel.autoSaveCapturedMedia("))
    XCTAssertTrue(captureSink.contains("historyModel.ingestCapturedMedia("), "Legacy media keeps its accepted path")
    XCTAssertTrue(captureSink.contains("value.shouldAutomaticallyPersistLegacyMedia"))
  }

  func testLongTitleShrinksAndScrollsInsteadOfTruncating() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")
    XCTAssertTrue(detail.contains("titleFontSize: CGFloat = 22"), "28pt was too large for video captions")
    XCTAssertTrue(detail.contains("titleMaximumHeight: CGFloat { titleLineHeight * 3 }"))
    XCTAssertTrue(detail.contains("if titleNeedsScrolling"), "Short titles must stay plain Text views")
    XCTAssertTrue(detail.contains("private var measuredTitleText: some View"))
    XCTAssertTrue(detail.contains(".frame(height: Self.titleMaximumHeight)"))
    XCTAssertTrue(detail.contains("scrollBounceBehavior(.basedOnSize)"))
    XCTAssertTrue(detail.contains("history-detail-title"))
    XCTAssertFalse(
      detail.contains(".lineLimit(4)"),
      "Overflow is now reachable by scrolling rather than discarded"
    )
  }

  /// 这一版不提供工作台，就是谁都看不到——包括当初自己打开过开关的人。
  ///
  /// 0.2.0 时的语义是「只对新用户关」，于是开发机上工作台一直在，
  /// 连带每天的选题定时也照跑。0.2.1 收紧成版本闸门与用户开关同时成立。
  func testWorkbenchStaysHiddenForUsersWhoEnabledItWhenTheVersionDoesNotOfferIt() {
    XCTAssertFalse(
      ExperimentalFeatures.isWorkbenchVisible(userEnabled: false),
      "没打开过的人任何时候都不该看到")
    XCTAssertEqual(
      ExperimentalFeatures.isWorkbenchVisible(userEnabled: true),
      ExperimentalFeatures.isOfferedToUsers,
      "打开过的人能不能看到，完全由这一版提不提供决定")

    // 四处入口（中间列、侧边栏、详情列、右键「加入工作台」）必须都走这道闸门。
    // 漏掉一处的表现是「侧边栏没有工作台，右键却还能往里加素材」。
    let source = historyContentViewSource()
    let rawFlagUses = source.components(separatedBy: "isWorkbenchUserEnabled").count - 1
    XCTAssertEqual(
      rawFlagUses, 2,
      "原始开关只该出现两次：@AppStorage 声明 + isWorkbenchVisible 里那一次；多出来的是绕过闸门的判断")
    XCTAssertTrue(source.contains("ExperimentalFeatures.isWorkbenchVisible"))
    XCTAssertTrue(source.contains("if isWorkbenchVisible, !unfinished.isEmpty"))
  }

  /// 主题有令牌不等于行里用了它：状态点必须真的分两条路，
  /// 否则高对比主题下仍旧是那两个彩色圆点。
  func testRowStatusIndicatorBranchesOnThemeShapeEncoding() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    XCTAssertTrue(row.contains("theme.encodesStatusByShape"))
    XCTAssertTrue(row.contains("strokeBorder"), "空心圆是高对比主题下「未总结」的唯一标记")
    XCTAssertTrue(row.contains("theme.success"), "普通主题的已总结状态应使用主题成功色")
    XCTAssertTrue(row.contains("theme.warning"), "普通主题的未总结状态应使用主题警示色")
    XCTAssertFalse(row.contains("Color.green"))
    XCTAssertFalse(row.contains("Color.orange"))
    // 形状和颜色都要求用户看得见；读屏和悬停还得有话可说。
    // 状态走 accessibilityValue 而不是塞进 label：塞进 label 时 VoiceOver 只念
    // 「已总结」，听不出这是一个状态指示器；分开之后念的是「总结状态，已总结」。
    XCTAssertTrue(row.contains("accessibilityValue(isSummarized"))
  }

  func testHistoryRowExposesOneConciseVoiceOverElement() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    XCTAssertTrue(row.contains(".accessibilityElement(children: .ignore)"))
    XCTAssertTrue(row.contains(".accessibilityLabel(rowAccessibilityLabel)"))
    XCTAssertTrue(row.contains(".accessibilityValue(rowAccessibilityValue)"))
    XCTAssertTrue(row.contains("HistoryPlatformDisplay.name(forHost: row.host)"))
    let value = section(in: row, from: "private var rowAccessibilityValue", to: "var body: some View")
    XCTAssertFalse(value.contains("artifactPreview"), "读屏 value 不应复用可能很长的正文预览")
  }

  func testSidebarUsesSourceMetadataInsteadOfURLOrImportTime() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    // 图24 式排版：摘要优先，回退作者；发布时间仍来自来源元数据。
    // 列表主标题/副行走 HistoryReadingTitle（可把产物一级标题抬成主标题）。
    XCTAssertTrue(row.contains("HistoryReadingTitle.listPreview("))
    XCTAssertTrue(row.contains("rowPreviewLine"))
    // 一排时间，不是两排：发布时间优先（判断素材新不新鲜看的是它），抓不到
    // 才回落到入库时间。回落时必须带「存于」字样，否则会被读成原文的发布日期。
    XCTAssertTrue(row.contains("HistoryPublishedTimestampFormatter.text(published)"))
    XCTAssertTrue(row.contains("存于 \\(HistoryRelativeTime.text("))
    XCTAssertFalse(row.contains("更新 \\(historyUpdatedDate"), "行里显示发布或入库时间，不显示 updated")
    XCTAssertFalse(row.contains("Text(row.canonicalURL)"))
    XCTAssertFalse(row.contains("latestRunAtMilliseconds ?? row.updatedAtMilliseconds"))
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("latestSourceSnapshot"))
    // frontmatter 必须取自「抓取来源」，不能取任何派生层。
    //
    // 判据统一在 `LayeredSourceDocument.captionSnapshot`，这里只检查视图确实
    // 走了它、且没有自己另写一份。原来这条断言写死的是
    // `sourceKind != ...localTranscription.rawValue`——那把判据的**写法**钉死了：
    // 派生层后来多出画面字幕一种，判据必须改，而改对了反倒让断言失败。
    XCTAssertTrue(detail.contains("LayeredSourceDocument.captionSnapshot(in: detail.snapshots)"))
    XCTAssertFalse(
      detail.contains("sourceKind != CapturedDocument.Origin.localTranscription.rawValue"),
      "判据不该在视图里重写一份——漏掉新的派生层会静默丢掉 frontmatter"
    )
  }

  func testEffectiveTranscriptionBodyDoesNotReuseSourceFrontmatterBody() throws {
    let source = "---\nauthor: \"来源作者\"\n---\n\n来源正文"
    let transcription = "---\nauthor: \"不应作为属性\"\n---\n\n转写后的正文"
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(source).author, "来源作者")
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(transcription).body.trimmingCharacters(in: .whitespacesAndNewlines), "转写后的正文")
    XCTAssertNotEqual(MarkdownNoteFrontmatter.parse(transcription).body, MarkdownNoteFrontmatter.parse(source).body)

    let layered = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestCore/LayeredSourceDocument.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(layered.contains("MarkdownNoteFrontmatter.parse(snapshot.bodyText).body"))
    let detail = section(in: historyContentViewSource(), from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertFalse(detail.contains("source: sourceFrontmatter.body"))
  }

  func testSourcePaneKeepsCaptionAndTranscriptAsSeparateLayers() {
    let detail = section(
      in: historyContentViewSource(),
      from: "private struct HistoryDetailView: View",
      to: "private struct DataDestinationDisclosureView"
    )
    XCTAssertTrue(detail.contains("showsLayeredSource"))
    XCTAssertTrue(detail.contains("hasPresentableCaption"))
    XCTAssertTrue(detail.contains("LayeredSourceDocument.captionHeading"))
    XCTAssertTrue(detail.contains("LayeredSourceDocument.transcriptHeading"))
    XCTAssertTrue(detail.contains("展开全文"))
    XCTAssertTrue(detail.contains("collapsibleSourceSection"))
    XCTAssertFalse(detail.contains("history-reading-retranscribe"))
    XCTAssertTrue(detail.contains("translate(historyDetail: detail"))
    XCTAssertFalse(detail.contains("appModel.translate(preferences:"))
  }

  func testHistoryTimestampUsesTimeOnlyTodayAndLocalizedDateTimeEarlier() {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0)!
    calendar.timeZone = zone
    let locale = Locale(identifier: "en_US")
    let now = Date(timeIntervalSince1970: 1_784_957_400) // 2026-07-18 10:30 UTC
    let today = HistoryTimestampFormatter.text(1_784_957_400_000, now: now, calendar: calendar, locale: locale, timeZone: zone)
    let earlier = HistoryTimestampFormatter.text(1_784_871_000_000, now: now, calendar: calendar, locale: locale, timeZone: zone)
    XCTAssertFalse(today.contains("Jul"))
    XCTAssertTrue(earlier.contains("Jul") || earlier.contains("2026"))
    XCTAssertEqual(HistoryTimestampFormatter.text(nil, now: now, calendar: calendar, locale: locale, timeZone: zone), "—")
  }

  func testPublishedTimestampFormatterParsesStandardAndFractionalISOWithoutImportFallback() {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0)!
    calendar.timeZone = zone
    let locale = Locale(identifier: "en_US")
    let standard = HistoryPublishedTimestampFormatter.text("2026-07-20T00:00:00Z", calendar: calendar, locale: locale, timeZone: zone)
    let fractional = HistoryPublishedTimestampFormatter.text("2026-07-20T00:00:00.000Z", calendar: calendar, locale: locale, timeZone: zone)
    XCTAssertTrue(standard.contains("Jul") || standard.contains("2026"))
    XCTAssertEqual(fractional, standard)
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("5天前", calendar: calendar, locale: locale, timeZone: zone), "5天前")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text(nil, calendar: calendar, locale: locale, timeZone: zone), "发布时间未获取")
  }


  private func appSource(_ fileName: String) -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/\(fileName)")
    guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
      XCTFail("读不到 \(fileName)")
      return ""
    }
    return text
  }

  /// 历史界面的源码。
  ///
  /// 拆分后返回主文件 + 拆出去的那两个的拼接：这些断言关心的是「实现里有没有
  /// 这段」，不是「它住在哪个文件」。按单文件读会让每次拆分都连带改一批测试，
  /// 而那种改动纯属噪音——真正该守住的行为一点没变。
  /// 阅读区必须把三层都渲染出来。
  ///
  /// Core 的 `LayeredSourceDocument` 决定的是**喂给模型**的正文，阅读区另有
  /// 一套渲染。画面字幕刚上线时只改了前者：字幕落库 40582 字，界面上却一个字
  /// 都看不到，看上去和「没保存」完全一样。
  ///
  /// 两处的层次和顺序必须一致，否则读到的和送去总结/翻译的不是同一份东西。
  func testReadingPaneRendersAllThreeSourceLayersInOrder() {
    let source = historyContentViewSource()
    let pane = section(in: source, from: "private var sourcePaneBody: some View", to: "private func collapsibleSourceSection")
    for heading in ["captionHeading", "subtitleHeading", "transcriptHeading"] {
      XCTAssertTrue(
        pane.contains("LayeredSourceDocument.\(heading)"),
        "阅读区漏渲染 \(heading) 这一层——数据会静默不可见"
      )
    }
    // 这里**不**比较三个 heading 的先后：`sourcePaneBody` 有多个分支，实时转写
    // 那支里也出现 transcriptHeading，而 `range(of:)` 只找第一次出现，跨分支比
    // 位置得不出任何结论。层次顺序由 `LayeredSourceDocumentTests` 直接对
    // `orderedLayers` 断言，那里才是顺序的真相源。
    //
    // 字幕层要和其它层一样可折叠，否则一份四万字的字幕稿会把整页撑开。
    XCTAssertTrue(
      pane.contains("heading: LayeredSourceDocument.subtitleHeading"),
      "画面字幕应当和其它层一样走 collapsibleSourceSection"
    )

    // 只有字幕、没有听写的记录也必须走分层渲染，否则那一层会被整个藏起来。
    let gate = section(in: source, from: "private var showsLayeredSource: Bool", to: "private var isDouyinCapture")
    XCTAssertTrue(gate.contains("latestSubtitleSnapshot"), "分层判据必须把画面字幕算进去")
  }

  /// 没有配文的记录，字幕层也必须显示。
  ///
  /// 抖音视频帖的 caption 多半只是重复标题，`hasPresentableCaption` 是 false。
  /// 旧判据把配文当成分层的前提，于是「字幕 + 听写都有、但没配文」的记录退回
  /// 单层渲染，只画听写稿——实测一条已读出正确字幕的抖音记录，界面上只看得到
  /// 听错的听写稿，字幕层在库里却一个字都不显示。
  ///
  /// 这里断言的是**不变量**而非写法：判据里必须存在一条不依赖配文的通路，且
  /// 分层分支不能再拿配文的存在与否当分支条件。
  func testSubtitleLayerSurvivesMissingCaption() {
    let source = historyContentViewSource()
    let gate = section(in: source, from: "private var showsLayeredSource: Bool", to: "private var isDouyinCapture")

    // 去掉注释再判断，否则注释里出现的标识符会让断言假绿。
    let gateCode = gate
      .split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")

    let bypass = gateCode
      .split(separator: "\n")
      .filter { $0.contains("return true") }
      .joined(separator: "\n")
    XCTAssertFalse(
      bypass.isEmpty,
      "分层判据缺少「不看配文」的通路：没配文的记录会把字幕层整个藏掉"
    )
    XCTAssertTrue(
      bypass.contains("latestSubtitleSnapshot"),
      "那条通路必须由画面字幕触发，否则守不住这个回归"
    )
    XCTAssertFalse(
      bypass.contains("hasPresentableCaption"),
      "这条通路一旦再挂上配文条件，等于回到旧行为"
    )

    // 分层分支自己也不能把配文写进分支条件——那样配文一缺，另外两层全都画不出来。
    let pane = section(in: source, from: "private var sourcePaneBody: some View", to: "private func collapsibleSourceSection")
    XCTAssertFalse(
      pane.contains("showsLayeredSource, let caption"),
      "配文必须是分层分支里可选的一层，不能充当整支的进入条件"
    )
  }

  /// 画面字幕和视频转写不能同时铺在页面上。
  ///
  /// 它们是同一段话的两个版本，纵向叠着意味着要滚过整份字幕才够得着转写稿，
  /// 而没有人会顺着读完一个再读另一个。改成一次只显示一层、用分段控件切换。
  ///
  /// 断言的是**不变量**：分层分支里必须出现按层分发的 switch，且三层各自的
  /// 渲染要互斥；只要有人把它改回顺序罗列（三个 if 并排），这条就红。
  func testSourceLayersAreSwitchedNotStacked() {
    let source = historyContentViewSource()
    let pane = section(
      in: source,
      from: "private var sourcePaneBody: some View",
      to: "private func collapsibleSourceSection"
    )
    // 分层分支的入口
    guard let branch = pane.range(of: "} else if showsLayeredSource {") else {
      return XCTFail("分层分支不见了，这条测试盯错了地方")
    }
    let layered = String(pane[branch.lowerBound...])
    XCTAssertTrue(
      layered.contains("switch activeSourceLayer"),
      "分层分支应当按选中的层分发，而不是把几层顺序铺开"
    )
    XCTAssertTrue(
      layered.contains("sourceLayerPicker"),
      "多于一层时要给出切换控件，否则另一层没有入口"
    )
    // 切换控件本身：三层都要能选到，顺序与文档层次一致。
    let picker = section(
      in: source,
      from: "private var sourceLayerPicker: some View",
      to: "private var readingPanePicker"
    )
    XCTAssertTrue(picker.contains("availableSourceLayers"), "可选项应当来自实际存在的层")
    XCTAssertTrue(picker.contains("history-source-layer-picker"))
  }

  /// 只有一层时不该出现分段控件——没有选择余地的控件只是看起来像有。
  func testSourceLayerPickerHidesWhenOnlyOneLayer() {
    let source = historyContentViewSource()
    let gate = section(
      in: source,
      from: "private var showsSourceLayerPicker: Bool",
      to: "private var showsLayeredSource"
    )
    XCTAssertTrue(
      gate.contains("availableSourceLayers.count > 1"),
      "单层记录不该显示层切换控件"
    )
  }

  /// 翻译页必须和原文页一样按层切换，不能把各层纵向叠着。
  ///
  /// 翻译是整份文档一次翻完的，回来时只剩 `## 配文` 这样的文本。第一版
  /// 忘了把开头的标题行从层数里拿掉，于是控件一次都没出现过，译文照旧
  /// 叠着——不报错，只是功能像没做。这里钉住接线和那个判据。
  func testTranslationLayersAreSwitchedNotStacked() {
    let source = historyContentViewSource()
    let pane = section(
      in: source,
      from: "private func readingPaneBody",
      to: "private var sourcePaneBody"
    )
    XCTAssertTrue(
      pane.contains("showsTranslationLayerPicker"),
      "翻译页应当按层数决定要不要出切换控件"
    )
    XCTAssertTrue(
      pane.contains("translationLayerPicker"),
      "多于一层时要给出切换控件，否则另一层没有入口"
    )
    XCTAssertTrue(
      pane.contains("activeTranslationBody"),
      "分层时只该喂当前这一层，不能把整篇译文平铺上去"
    )

    let picker = section(
      in: source,
      from: "private var translationLayerPicker: some View",
      to: "private func layerPicker"
    )
    XCTAssertTrue(picker.contains("availableTranslationLayers"), "可选项应当来自拆出来的层")
    XCTAssertTrue(picker.contains("history-translation-layer-picker"))

    let available = section(
      in: source,
      from: "private var availableTranslationLayers",
      to: "private var activeTranslationLayer"
    )
    XCTAssertTrue(
      available.contains("translationPreamble"),
      "开头的标题行必须从层数里拿掉，否则控件永远出不来"
    )
    XCTAssertTrue(available.contains("dropFirst()"))
  }

  /// 有切换控件时，层名小标题和空的工具条行都要去掉。
  func testLayerHeadingIsOmittedWhenThePickerIsVisible() {
    let source = historyContentViewSource()
    let chrome = section(
      in: source,
      from: "private func collapsibleSourceSection",
      to: "private func sourceLayerHeading"
    )
    XCTAssertTrue(
      chrome.contains("let showsHeading = !showsSourceLayerPicker"),
      "有切换控件时不应再渲染一层同名小标题"
    )
    XCTAssertTrue(
      chrome.contains("if showsHeading || showsExpandControl"),
      "标题和展开按钮都没有时，整行工具条都要去掉，否则会留下空行"
    )
  }

  private func historyContentViewSource() -> String {
    [
      "HistoryContentView.swift",
      "HistoryMediaPlayback.swift",
      "VideoScrollWheelRouting.swift",
      "HistorySourceLinkPresentation.swift",
      "HistoryTimestampFormatters.swift",
      "CapturedSourceBodyPresentation.swift",
      "VideoDisplayGeometry.swift",
      "HistorySessionMediaPresentation.swift",
      "HistoryRowView.swift",
      "HistoryWindowChrome.swift",
    ]
      .map(appSource)
      .joined(separator: "\n\n")
  }

  @MainActor
  private func testWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
  }

  @MainActor
  private func testCandidate(
    window: NSWindow,
    bounds: NSRect,
    isVisible: Bool = true,
    visibleRect: NSRect? = nil,
    hasEnclosingScrollView: Bool = true,
    localPoint: NSPoint = .zero
  ) -> VideoScrollWheelAnchorCandidate {
    .init(
      id: UUID(),
      windowID: ObjectIdentifier(window),
      bounds: bounds,
      visibleRect: visibleRect ?? bounds,
      localPoint: localPoint,
      isVisible: isVisible,
      hasEnclosingScrollView: hasEnclosingScrollView
    )
  }

  /// Rebuilds candidates with the cursor expressed in each one's own space,
  /// which is what the production monitor does per anchor.
  private func withLocalPoint(
    _ candidate: VideoScrollWheelAnchorCandidate,
    windowPoint: NSPoint,
    anchorOriginInWindow: NSPoint
  ) -> VideoScrollWheelAnchorCandidate {
    .init(
      id: candidate.id,
      windowID: candidate.windowID,
      bounds: candidate.bounds,
      visibleRect: candidate.visibleRect,
      localPoint: NSPoint(
        x: windowPoint.x - anchorOriginInWindow.x,
        y: windowPoint.y - anchorOriginInWindow.y
      ),
      isVisible: candidate.isVisible,
      hasEnclosingScrollView: candidate.hasEnclosingScrollView
    )
  }

  @MainActor
  private func testSample(
    window: NSWindow,
    point: NSPoint,
    deltaX: CGFloat = 0,
    deltaY: CGFloat,
    phase: NSEvent.Phase,
    momentumPhase: NSEvent.Phase = [],
    candidates: [VideoScrollWheelAnchorCandidate],
    isForwarding: Bool = false
  ) -> VideoScrollWheelRouteSample {
    .init(
      windowID: ObjectIdentifier(window),
      point: point,
      deltaX: deltaX,
      deltaY: deltaY,
      phase: phase,
      momentumPhase: momentumPhase,
      isForwarding: isForwarding,
      candidates: candidates.map { candidate in
        withLocalPoint(candidate, windowPoint: point, anchorOriginInWindow: .zero)
      }
    )
  }

  private func linkDigestAppSource() -> String {
    let desktopDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = desktopDirectory.appendingPathComponent("Sources/LinkDigestApp/LinkDigestApp.swift")
    do {
      return try String(contentsOf: sourceURL, encoding: .utf8)
    } catch {
      XCTFail("Unable to read LinkDigestApp source: \(error)")
      return ""
    }
  }

  private func mediaDescriptor(
    kind: MediaKind,
    playbackURL: String? = nil,
    expiresAt: String? = nil,
    failureReason: MediaFailureReason? = nil
  ) -> MediaDescriptor {
    MediaDescriptor(
      kind: kind,
      pageURL: "https://example.test/watch",
      canonicalURL: "https://example.test/watch",
      platform: "fixture",
      ephemeralPlaybackURL: playbackURL,
      mimeType: kind == .hls ? "application/vnd.apple.mpegurl" : "video/mp4",
      expiresAt: expiresAt,
      transcriptionCapability: kind == .directFile || kind == .hls ? .supported : .unavailable,
      failureReason: failureReason
    )
  }

  private func desktopPackageSource() -> String {
    let desktopDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let packageURL = desktopDirectory.appendingPathComponent("Package.swift")
    do {
      return try String(contentsOf: packageURL, encoding: .utf8)
    } catch {
      XCTFail("Unable to read desktop Package.swift: \(error)")
      return ""
    }
  }

  /// 按起止标记切出一段源码。
  ///
  /// HistoryContentView 拆分后，很多切片的**结束锚点**留在了原文件而起始类型搬去
  /// 了新文件。这时候切不到不代表断言该失败——断言关心的是「实现里有没有这段」。
  /// 所以：起点找不到才算结构变了；只是结束锚点没了，就从起点切到文件末尾。
  /// 阅读区工具栏的「小／大」字号快捷键。
  ///
  /// 这个功能之所以成立，全靠它和外观设置页改的是**同一个** @AppStorage 键——两处因此
  /// 自动同步，不需要任何接线。断言守住这个前提，外加：调节走夹取、到边界各自禁用，
  /// 不会把值顶出 ReadingFontSize 的上下限。
  func testReadingToolbarFontSizeControlSharesStorageAndClamps() {
    let history = historyContentViewSource()
    let settings = appSource("ProviderSettingsView.swift")

    XCTAssertTrue(
      history.contains("@AppStorage(ReadingFontSize.storageKey)")
        && settings.contains("@AppStorage(ReadingFontSize.storageKey)"),
      "工具栏和设置滑块必须共用同一个存储键，否则改一处另一处不动，同步就是假的")

    XCTAssertTrue(
      history.contains(#"accessibilityIdentifier("reading-font-size-control")"#),
      "阅读工具栏要有字号快捷控件")

    // 夹取：两端都收在合法区间内，别越过 ReadingFontSize 的上下限。
    XCTAssertTrue(history.contains("max(next, Double(ReadingFontSize.minimum))"))
    XCTAssertTrue(history.contains("Double(ReadingFontSize.maximum))"))

    // 到边界各自禁用：值已经顶在边界还响应点击，是无效反馈。
    XCTAssertTrue(history.contains("readingFontSizeRaw <= Double(ReadingFontSize.minimum)"))
    XCTAssertTrue(history.contains("readingFontSizeRaw >= Double(ReadingFontSize.maximum)"))
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start) else {
      XCTFail("找不到起始标记「\(start)」，源码结构已变，这条断言需要同步更新。")
      return ""
    }
    let tail = startRange.upperBound..<source.endIndex
    guard let endRange = source.range(of: end, range: tail) else {
      return String(source[startRange.lowerBound...])
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }
}

/// 「模型校对」按钮不能点时，必须说明为什么；已存视频和当前远程视频都要有入口。
///
/// 这个按钮受五个条件约束，而灰掉的按钮在 SwiftUI 里颜色很淡，扫一眼注意不到——
/// 实际收到过「一直没看到这个功能」的反馈，功能却一直都在。
final class TranscriptTidyBlockedReasonTests: XCTestCase {
  func testDisabledButtonAlwaysCarriesAReason() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryMediaPlayback.swift"),
      encoding: .utf8
    )
    // 禁用状态与理由必须来自同一个来源，否则两者会各改各的、说法不一致。
    XCTAssertTrue(source.contains("let tidyBlockedReason = model.transcriptTidyUnavailableReason("))
    XCTAssertTrue(source.contains(".disabled(tidyBlockedReason != nil)"))
    // 理由要显示出来，不能只放在悬停提示里——鼠标不停上去就看不到。
    XCTAssertTrue(source.contains("history-transcript-tidy-blocked-reason"))

    let remote = section(
      in: source,
      from: "struct CurrentCaptureMediaPreviewCard: View",
      to: "/// Top-of-detail video card"
    )
    XCTAssertTrue(remote.contains("let blockedReason = model.transcriptTidyUnavailableReason("))
    XCTAssertTrue(remote.contains(".disabled(blockedReason != nil)"))
    XCTAssertTrue(remote.contains("remote-transcript-tidy-blocked-reason"))
  }

  func testCurrentRemoteVideoExposesManualTidyWithoutAutoTriggerOnTranscriptionComplete() throws {
    let playbackSource = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryMediaPlayback.swift"),
      encoding: .utf8
    )
    let remote = section(
      in: playbackSource,
      from: "struct CurrentCaptureMediaPreviewCard: View",
      to: "/// Top-of-detail video card"
    )
    XCTAssertTrue(remote.contains("let tidyModel: String?"))
    XCTAssertFalse(remote.contains("let autoTidyEnabled: Bool"))
    XCTAssertTrue(remote.contains("model.requestTranscriptTidy(taskID: taskID, model: tidyModel)"))
    XCTAssertFalse(
      remote.contains("model.startTranscriptTidyAuto(taskID: taskID, model: tidyModel)"),
      "视频卡不应在转写完成时自动校对，应交给设置里的自动管线或用户手动点按钮"
    )
    XCTAssertFalse(
      remote.contains("descriptor.author"),
      "详情头部已有作者行，当前视频卡不能再显示一份可能混入统计的 author"
    )
    XCTAssertTrue(
      remote.contains("if state != .idle || preview?.isEmpty == false || timings != nil || cleanupFailure != nil"),
      "空闲的转写状态不能留下一个会参与外层 spacing 的空 VStack"
    )
    XCTAssertTrue(
      remote.contains("if state != .idle || blockedReason != nil"),
      "空闲且可校对时不能留下一个会参与外层 spacing 的空 VStack"
    )

    let local = section(
      in: playbackSource,
      from: "struct HistoryVideoPlayerCard: View",
      to: "private struct HistoryStreamingMediaCard: View"
    )
    XCTAssertFalse(
      local.contains("startTranscriptTidyAuto"),
      "本机视频卡也不应在转写完成时自动校对"
    )
    XCTAssertFalse(
      local.contains("media?.author"),
      "已存视频卡同样不能重复显示详情头部已经呈现的作者"
    )

    let playable = section(
      in: remote,
      from: "private func playableContent",
      to: "/// 清晰度切换"
    )
    XCTAssertLessThan(
      try XCTUnwrap(playable.range(of: "remoteTranscriptTidyControl")).lowerBound,
      try XCTUnwrap(playable.range(of: "switch playback.preparePhase")).lowerBound,
      "转写与模型校对必须在视频上方，不能再被高视频推出首屏"
    )

    let contentSource = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8
    )
    XCTAssertEqual(
      contentSource.components(separatedBy: "tidyModel: providerSettings.effectiveTidyModelName").count - 1,
      3,
      "本机媒体与两种当前远程媒体入口都必须接入同一校对模型"
    )
    XCTAssertTrue(
      contentSource.contains("tidy: settings.autoTidyTranscription"),
      "自动校对只应通过新内容自动管线触发，不应在视频卡 onChange 里硬接"
    )
  }

  /// 判断与理由必须由同一个方法推导，不能是两套独立逻辑。
  func testCanTidyIsDerivedFromTheReason() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryViewModel.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("transcriptTidyUnavailableReason(taskID: taskID) == nil"))
    XCTAssertTrue(
      source.contains("mindMapUnavailableReason(taskID: taskID) == nil"),
      "生成脑图的判断必须从理由推导，不能再各写一套门禁"
    )
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start) else {
      XCTFail("找不到起始标记「\(start)」")
      return ""
    }
    let tail = startRange.upperBound..<source.endIndex
    guard let endRange = source.range(of: end, range: tail) else {
      XCTFail("找不到结束标记「\(end)」")
      return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }
}

/// 自动管线第 ② 步的前置提示，必须写明它只适用于自动进来的新内容。
final class AutoPipelineTidyHintTests: XCTestCase {
  func testTidyHintStatesItOnlyAppliesToAutoCapturedContent() throws {
    let settings = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(settings.contains("仅影响自动进来的新内容"))
    XCTAssertTrue(settings.contains("手动转写完成后请点「模型校对」"))
    XCTAssertFalse(settings.contains("你手动点「转写」时，本步照常生效"))
  }

  /// 钉住真实行为：自动校对只走新内容自动管线，不在视频卡转写完成时偷偷触发。
  func testAutoTidyIsOnlyWiredThroughAutoPipeline() throws {
    let playback = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryMediaPlayback.swift"),
      encoding: .utf8
    )
    XCTAssertFalse(playback.contains("guard autoTidyEnabled, oldState.isActive, newState == .completed"))
    let viewModel = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryViewModel.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(viewModel.contains("if request.tidy, Self.latestTranscriptText(in: storedDetail) != nil"))
  }
}
