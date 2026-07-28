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
final class VideoScrollWheelBroker {
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
final class VideoScrollWheelAnchorView: NSView {
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

/// 拆出独立文件后不再是 file-private —— 使用方 HistoryContentView 已不同文件。
@MainActor
struct VideoScrollWheelAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> VideoScrollWheelAnchorView {
    VideoScrollWheelAnchorView(frame: .zero)
  }

  func updateNSView(_ nsView: VideoScrollWheelAnchorView, context: Context) {}

  static func dismantleNSView(_ nsView: VideoScrollWheelAnchorView, coordinator: ()) {
    VideoScrollWheelBroker.shared.unregister(nsView)
  }
}
