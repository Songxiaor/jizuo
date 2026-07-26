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
    let root = section(in: source, from: "struct HistoryContentView: View", to: "private struct ManualLinkSheet")

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

  func testRunActionsWaitForStartupPreferencesBeforeGenerating() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    // Action pills gate on preferences readiness before summarize/translate.
    XCTAssertTrue(detail.contains("!providerSettings.arePreferencesReady"))
    XCTAssertTrue(detail.contains("actionPill"))
    XCTAssertTrue(detail.contains("summarize-history-detail") || detail.contains("summarize-current-capture"))
  }

  func testThreeColumnNavigationKeepsSearchInTheContentList() {
    let source = historyContentViewSource()
    let sidebar = section(in: source, from: "private var sidebar: some View", to: "@ViewBuilder private var detail")

    XCTAssertTrue(source.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
    XCTAssertTrue(source.contains("content: {"))
    // Both side columns open at near-matching widths and keep hard caps so the
    // detail column receives the surplus width.
    XCTAssertTrue(source.contains("navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)"))
    XCTAssertTrue(source.contains("navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)"))
    XCTAssertTrue(source.contains(".modifier(HistoryWindowToolbarThemeModifier(theme: theme))"))
    XCTAssertTrue(source.contains(".toolbarBackground(theme.canvas, for: .windowToolbar)"))
    XCTAssertTrue(source.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
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
    // 普通点击=叠加（AND 缩小范围），⌘点击=只看此标签；Syc 2026-07-23 拍板翻转。
    XCTAssertTrue(source.contains("model.toggleTag(item.tag, additive: !NSEvent.modifierFlags.contains(.command))"))
    XCTAssertTrue(sidebar.contains(".frame(maxWidth: .infinity)"))
    XCTAssertFalse(sidebar.contains("history-tag-filters"), "The old horizontal tag rail must not coexist with navigation")
  }

  func testNavigationTagsAndDetailEditorBindToViewModelWithoutRemoteImages() {
    let source = historyContentViewSource()
    let sidebar = section(in: source, from: "private var sidebar: some View", to: "@ViewBuilder private var detail")
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")

    XCTAssertTrue(sidebar.contains("TextField(\"搜索历史\", text: $model.searchText)"))
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
  }

  func testDetailUsesCenteredReadingColumnAndShowsStandaloneEngagementStats() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains(".frame(maxWidth: 680, alignment: .leading)"))
    XCTAssertTrue(detail.contains(".frame(maxWidth: .infinity, alignment: .center)"))
    XCTAssertTrue(detail.contains(".padding(.horizontal, 40)"))
    XCTAssertFalse(detail.contains(".padding(.leading, 48)"))
    // Non-WeChat captures retain their independently extracted social stats;
    // WeChat deliberately never presents that row, including old imports.
    XCTAssertTrue(detail.contains("sourceFrontmatter.hasProperties || (!isWeChatCapture && sourceFrontmatter.hasEngagementStats)"))
    XCTAssertTrue(detail.contains("history-engagement-stats"))
  }

  func testWeChatPropertiesShowSourceFieldsWithoutInventingEngagementStats() {
    let source = historyContentViewSource()
    let strip = section(in: source, from: "private func notePropertiesStrip", to: "private func propertyRow")
    XCTAssertTrue(strip.contains("note.accountName"))
    // The cover thumbnail was removed on purpose: a WeChat cover is usually a
    // repeat of the first body image or a promotional card, and showing it above
    // the text displaced the article's real opening. The body carries its own
    // images in the author's order, which is the only ordering worth trusting.
    XCTAssertFalse(strip.contains("history-wechat-cover-image"))
    XCTAssertTrue(strip.contains("!isWeChatCapture && note.hasEngagementStats"))
    XCTAssertFalse(strip.contains("read_num"))
    XCTAssertFalse(strip.contains("like_num"))
    XCTAssertTrue(source.contains("(!isWeChatCapture && sourceFrontmatter.hasEngagementStats)"))
    XCTAssertTrue(source.contains("appendsUnusedLocalImages: !isWeChatCapture"))
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
          let videoFirstReading = detail.range(of: "readingSurface", range: videoFirstBranch.upperBound..<detail.endIndex)
    else { return XCTFail("WeChat/article and video-first ordering anchors are unavailable") }
    XCTAssertLessThan(articleReading.lowerBound, media.lowerBound)
    XCTAssertLessThan(media.lowerBound, videoFirstReading.lowerBound)
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
    XCTAssertTrue(detail.contains("showsStreamingResultCard || hasResultBody || hasSourceBody"))
    XCTAssertTrue(detail.contains("if !presentsArticleBeforeMedia, showsReadingSurface"))
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
    XCTAssertTrue(detail.contains("github-readme-local-images") || source.contains("history-content-inline-image"))
    XCTAssertTrue(source.contains("LocalMarkdownImageLayout") || source.contains("localImageURLs: localImageURLs"))
    XCTAssertFalse(detail.contains("AsyncImage"), "History must not load README images from the network at render time")
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
    let preview = section(in: source, from: "private struct CurrentCaptureMediaPreviewCard: View", to: "/// Top-of-detail video card")

    XCTAssertTrue(detail.contains("showsCurrentCapture"))
    XCTAssertTrue(detail.contains("let descriptor = capture.mediaDescriptor"))
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
    let video = section(in: source, from: "private struct HistoryVideoPlayerCard: View", to: "/// UI state changes")

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
    let source = historyContentViewSource()
    let video = section(in: source, from: "private struct HistoryVideoPlayerCard: View", to: "/// UI state changes")

    let local = video.range(of: "已保存到本机")
    let transcribe = video.range(of: "transcriptionControl")
    let save = video.range(of: "Button(\"另存一份\"")
    let player = video.range(of: "playerSurface")
    XCTAssertNotNil(local); XCTAssertNotNil(transcribe); XCTAssertNotNil(save); XCTAssertNotNil(player)
    XCTAssertLessThan(local!.lowerBound, player!.lowerBound)
    XCTAssertLessThan(transcribe!.lowerBound, player!.lowerBound)
    XCTAssertLessThan(save!.lowerBound, player!.lowerBound)
    XCTAssertTrue(video.contains("media?.byteSize"))
    XCTAssertTrue(video.contains("media?.author"))
    XCTAssertTrue(video.contains("media?.durationSeconds"))
    XCTAssertTrue(video.contains(".aspectRatio(VideoDisplayGeometry.aspectRatio"))
    XCTAssertTrue(video.contains("naturalSize"))
    XCTAssertTrue(video.contains("preferredTransform"))
    XCTAssertFalse(video.contains(".frame(minHeight: 220, maxHeight: 360)"))
    XCTAssertTrue(video.contains("history-video-geometry-placeholder"))
  }

  func testRemotePreviewTranscriptionIsExplicitDirectOnlyAndExposesRecoveryIdentifiers() {
    let source = historyContentViewSource()
    let preview = section(
      in: source,
      from: "private struct CurrentCaptureMediaPreviewCard: View",
      to: "/// Top-of-detail video card"
    )
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
    let properties = detail.range(of: "notePropertiesStrip(sourceFrontmatter)")
    let metadata = detail.range(of: "metadata\n")
    let actions = detail.range(of: "actionToolbar\n")
    let video = detail.range(of: "HistoryVideoPlayerCard(")
    XCTAssertNotNil(properties); XCTAssertNotNil(metadata); XCTAssertNotNil(actions); XCTAssertNotNil(video)
    XCTAssertLessThan(properties!.lowerBound, video!.lowerBound)
    XCTAssertLessThan(metadata!.lowerBound, video!.lowerBound)
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

  func testXPostsReadInPostOrderWithTextAboveTheVideo() {
    let source = historyContentViewSource()
    let rule = section(
      in: source,
      from: "private var presentsArticleBeforeMedia: Bool",
      to: "private var suppressesEmbeddedMedia"
    )
    // X 帖子的正文就是帖子本身，视频是附件；抖音那类视频帖仍旧视频在前。
    XCTAssertTrue(rule.contains("latestSnapshot.platform == \"x\""))
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

  func testCinemaButtonAlignsToTheVideoEdgeNotTheReadingColumnEdge() {
    let source = historyContentViewSource()
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
    XCTAssertTrue(source.contains("需要下载 Apple 中文离线模型"))
    XCTAssertTrue(source.contains("Button(\"下载并转写\")"))
    XCTAssertTrue(source.contains("model.confirmModelDownloadAndTranscribe()"))
    XCTAssertTrue(source.contains("视频音频只在这台 Mac 上处理，不会上传"))
    XCTAssertTrue(source.contains("只读模式不能保存转写结果"))
  }

  func testVideoSaveFeedbackDelayBelongsToLatestSaveAndCancelsOnDisappear() {
    let source = historyContentViewSource()
    let video = section(in: source, from: "private struct HistoryVideoPlayerCard: View", to: "/// UI state changes")

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
  }

  func testDetailBindsLatestRunMetadataAndTokenBreakdownWithoutCostEstimate() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("if let run = newestRun"))
    XCTAssertTrue(detail.contains("historyAction(run.run.kind)"))
    XCTAssertTrue(detail.contains("run.run.model?.trimmedNonEmpty"))
    XCTAssertTrue(detail.contains("historyStatus(run.run.status)"))
    // Token 行改为全文总账（Run + 整理/脑图台账），分项用量在各功能状态行显示。
    XCTAssertTrue(detail.contains("model.taskTokenGrandTotals"))
    XCTAssertFalse(detail.contains("title: \"费用\""), "BYOK prices are not reliable enough to display an estimate")
  }

  func testDetailExposesModelJumpAndTruncationLabel() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("openSettings: () -> Void"))
    XCTAssertTrue(detail.contains("settingsModelButton(providerSettings.modelName)"))
    XCTAssertTrue(detail.contains("history-open-model-settings") || detail.contains("openSettings()"))
    XCTAssertTrue(detail.contains("capture-truncated-notice"))
    XCTAssertTrue(detail.contains("appModel.canTranslate"))
  }

  func testListIconsUseBuiltInPlatformMapThenLocalFaviconFallbackWithoutRemoteLoading() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "private struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    XCTAssertTrue(row.contains("model.faviconImageURL(for: row)"))
    XCTAssertTrue(row.contains("HistoryFaviconImageMemoryCache.image"))
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
    XCTAssertNil(PlatformIconCatalog.assetName(for: "example.test"))
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

  func testReadingPanePickerStaysVisibleWhenOneSideIsEmpty() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct TitleHeightPreferenceKey")
    XCTAssertTrue(
      detail.contains("showsReadingPanePicker: Bool { hasResultBody || hasSourceBody || hasLiveTranscription }"),
      "The picker must not disappear just because there is no summary yet"
    )
    XCTAssertFalse(
      detail.contains("hasResultBody && hasPresentableSourceBody"),
      "isRedundantDouyinBody must no longer be able to hide the picker"
    )
    XCTAssertTrue(detail.contains("missingPaneNotice(for: .result)"))
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

  func testLiveTranscriptionRendersOnlyInSourcePaneWithSharedBodyTypography() {
    let source = historyContentViewSource()
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    let localVideo = section(in: source, from: "private struct HistoryVideoPlayerCard: View", to: "/// UI state changes")
    let remoteVideo = section(in: source, from: "private struct CurrentCaptureMediaPreviewCard: View", to: "/// Top-of-detail video card")

    XCTAssertTrue(detail.contains("history-reading-source-live-transcription"))
    XCTAssertTrue(detail.contains("MarkdownPresentation.bodyFontSize"))
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

  func testSidebarUsesSourceMetadataInsteadOfURLOrImportTime() {
    let source = historyContentViewSource()
    let row = section(in: source, from: "private struct HistoryRowView: View", to: "private struct HistoryDetailView: View")
    // 图24 式排版：摘要优先，回退作者；发布时间仍来自来源元数据。
    XCTAssertTrue(row.contains("row.artifactPreview?.trimmedNonEmpty ?? row.author?.trimmedNonEmpty"))
    // 两排时间：第一排发布（未抓取到则整排消失），第二排创建。
    XCTAssertTrue(row.contains("if row.published?.trimmedNonEmpty != nil {"))
    XCTAssertTrue(row.contains("发布 \\(historyPublishedDate(row.published))"))
    XCTAssertTrue(row.contains("创建 \\(historyCreatedDate(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))"))
    XCTAssertFalse(row.contains("更新 \\(historyUpdatedDate"), "The list row shows publish + created, not the updated timestamp")
    XCTAssertFalse(row.contains("Text(row.canonicalURL)"))
    XCTAssertFalse(row.contains("latestRunAtMilliseconds ?? row.updatedAtMilliseconds"))
    let detail = section(in: source, from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("latestSourceSnapshot"))
    XCTAssertTrue(detail.contains("sourceKind != CapturedDocument.Origin.localTranscription.rawValue"))
  }

  func testEffectiveTranscriptionBodyDoesNotReuseSourceFrontmatterBody() {
    let source = "---\nauthor: \"来源作者\"\n---\n\n来源正文"
    let transcription = "---\nauthor: \"不应作为属性\"\n---\n\n转写后的正文"
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(source).author, "来源作者")
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(transcription).body.trimmingCharacters(in: .whitespacesAndNewlines), "转写后的正文")
    XCTAssertNotEqual(MarkdownNoteFrontmatter.parse(transcription).body, MarkdownNoteFrontmatter.parse(source).body)

    let detail = section(in: historyContentViewSource(), from: "private struct HistoryDetailView: View", to: "private struct DataDestinationDisclosureView")
    XCTAssertTrue(detail.contains("source: MarkdownNoteFrontmatter.parse(snapshot.bodyText).body"))
    XCTAssertFalse(detail.contains("source: sourceFrontmatter.body"))
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

  private func historyContentViewSource() -> String {
    let desktopDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = desktopDirectory.appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift")
    do {
      return try String(contentsOf: sourceURL, encoding: .utf8)
    } catch {
      XCTFail("Unable to read HistoryContentView source: \(error)")
      return ""
    }
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

  private func section(in source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start), let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
      XCTFail("HistoryContentView source structure is unavailable for this assertion.")
      return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }
}
