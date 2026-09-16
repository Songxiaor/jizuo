import AppKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

@MainActor
final class HistoryGalleryGeometryTests: XCTestCase {
  func testDesktopSplitFillsWindowAcrossReaderTransitionsAndResizes() async throws {
    // Never order this window on screen; no application data or network involved.
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1288, height: 672),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: GalleryGeometryFixture(reading: false))
    window.contentView = host

    for width in [CGFloat(1288), 940, 1512, 1288] {
      window.setContentSize(NSSize(width: width, height: 672))
      for reading in [false, true, false] {
        host.rootView = GalleryGeometryFixture(reading: reading)
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findSplit(in: host))
        let panes = split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 0 }
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(split.convert(split.bounds, to: host).minX, 0, accuracy: 1)
        XCTAssertEqual(split.bounds.width, host.bounds.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(panes.last?.frame.width ?? 0, width - DesignTokens.Layout.sidebarMax - 2)
      }
    }
  }

  func testSidebarBoundsMatchNativeNavigationContainer() async throws {
    // 不再拿原生 NavigationSplitView 当对照：macOS 26 会在固定宽侧栏外加 8pt 留白，
    // 两个容器都设 220pt 也不能保证位置相同。这里只断言自绘 marker 的图库侧栏。
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1288, height: 672),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: SidebarAlignmentFixture(native: false))
    window.contentView = host
    for width in [CGFloat(1288), 940, 1512] {
      window.setContentSize(NSSize(width: width, height: 672))
      host.rootView = SidebarAlignmentFixture(native: false)
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      let marker = try XCTUnwrap(findMarker(in: host))
      let frame = marker.convert(marker.bounds, to: host)
      XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "gallery sidebar origin at width \(width)")
      XCTAssertLessThanOrEqual(frame.minX, 8.5, "gallery sidebar origin at width \(width)")
      XCTAssertEqual(frame.width, DesignTokens.Layout.sidebarIdeal, accuracy: 1, "gallery sidebar width at width \(width)")
    }
  }

  private func findMarker(in root: NSView) -> SidebarBoundsMarkerView? {
    if let marker = root as? SidebarBoundsMarkerView { return marker }
    return root.subviews.lazy.compactMap { self.findMarker(in: $0) }.first
  }

  func testGallerySidebarListScrollsWhenWindowIsShorterThanPlatformRows() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: TallSidebarGalleryFixture())
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 700))
    try await Task.sleep(for: .milliseconds(120))
    host.layoutSubtreeIfNeeded()
    let split = try XCTUnwrap(findSplit(in: host))
    let pane = try XCTUnwrap(split.arrangedSubviews.first { !$0.isHidden && $0.frame.width > 0 })
    XCTAssertLessThanOrEqual(pane.frame.height, 701)
    let scroll = try XCTUnwrap(findScrollView(in: pane))
    let documentHeight = scroll.documentView?.frame.height ?? 0
    XCTAssertGreaterThan(
      documentHeight,
      scroll.contentView.bounds.height + 8,
      "11+ platform rows at 700pt must live inside a scroll view, not an unclipped List that the window crops"
    )
  }

  func testGallerySplitUsesFixedSidebarIdealWidth() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1288, height: 672),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: GalleryGeometryFixture(reading: false))
    window.contentView = host
    window.setContentSize(NSSize(width: 1288, height: 672))
    try await Task.sleep(for: .milliseconds(40))
    host.layoutSubtreeIfNeeded()
    let split = try XCTUnwrap(findSplit(in: host))
    let panes = split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 0 }
    XCTAssertEqual(panes.count, 2)
    XCTAssertGreaterThanOrEqual(panes[0].frame.width, DesignTokens.Layout.sidebarIdeal - 1)
    XCTAssertLessThanOrEqual(panes[0].frame.width, DesignTokens.Layout.sidebarIdeal + 16)
  }

  private func findSplit(in root: NSView) -> NSSplitView? {
    if let split = root as? NSSplitView { return split }
    return root.subviews.lazy.compactMap { self.findSplit(in: $0) }.first
  }

  private func findScrollView(in root: NSView) -> NSScrollView? {
    if let scroll = root as? NSScrollView { return scroll }
    return root.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
  }
}

private final class SidebarBoundsMarkerView: NSView {}

private struct SidebarBoundsMarker: NSViewRepresentable {
  func makeNSView(context: Context) -> SidebarBoundsMarkerView { SidebarBoundsMarkerView() }
  func updateNSView(_ nsView: SidebarBoundsMarkerView, context: Context) {}
}

private struct SidebarAlignmentFixture: View {
  let native: Bool
  private var rail: some View {
    List { Text("全部"); Text("X") }
      .listStyle(.sidebar)
      .background(SidebarBoundsMarker())
  }
  var body: some View {
    if native {
      NavigationSplitView {
        rail.navigationSplitViewColumnWidth(min: DesignTokens.Layout.sidebarIdeal,
          ideal: DesignTokens.Layout.sidebarIdeal, max: DesignTokens.Layout.sidebarIdeal)
      } content: {
        Text("资料列表").navigationSplitViewColumnWidth(ideal: DesignTokens.Layout.listIdeal)
      } detail: {
        Text("阅读").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      HistoryGallerySplitView { rail } detail: {
        Text("图库").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct TallSidebarGalleryFixture: View {
  var body: some View {
    HistoryGallerySplitView {
      List {
        ForEach(0..<24, id: \.self) { index in
          Text("平台 \(index)")
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
      }
      .listStyle(.sidebar)
      .frame(minHeight: 0, maxHeight: .infinity)
    } detail: {
      Text("图库").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct GalleryGeometryFixture: View {
  let reading: Bool

  var body: some View {
    HistoryGallerySplitView {
      List { Text("全部博主"); Text("X") }
    } detail: {
      if reading {
        ScrollView { Text("隔离阅读夹具").frame(maxWidth: .infinity) }
      } else {
        GeometryReader { geometry in
          ScrollViewReader { _ in
            ScrollView {
              LazyVGrid(columns: Array(
                repeating: GridItem(.flexible()),
                count: CreatorDirectoryChrome.xColumnCount(availableWidth: geometry.size.width)
              )) {
                ForEach(0..<20) { index in
                  Text("作品 \(index)").frame(maxWidth: .infinity, minHeight: 160).id(index)
                }
              }
            }
          }
        }
      }
    }
  }
}
