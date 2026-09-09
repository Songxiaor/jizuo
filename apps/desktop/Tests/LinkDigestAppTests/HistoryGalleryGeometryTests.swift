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
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1288, height: 672),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: SidebarAlignmentFixture(native: true))
    window.contentView = host
    for width in [CGFloat(1288), 940, 1512] {
      window.setContentSize(NSSize(width: width, height: 672))
      var bounds: [CGRect] = []
      for native in [true, false] {
        host.rootView = SidebarAlignmentFixture(native: native)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let marker = try XCTUnwrap(findMarker(in: host))
        bounds.append(marker.convert(marker.bounds, to: host))
      }
      XCTAssertEqual(bounds[1].minX, bounds[0].minX, accuracy: 0.5, "navigation origin at width \(width)")
      XCTAssertEqual(bounds[1].width, bounds[0].width, accuracy: 0.5, "navigation width at width \(width)")
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

  func testGallerySplitUsesFixedSidebarIdealWidth() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp")
    let split = try String(contentsOf: root.appendingPathComponent("CreatorDirectoryViews.swift"), encoding: .utf8)
    let history = try String(contentsOf: root.appendingPathComponent("HistoryContentView.swift"), encoding: .utf8)
    XCTAssertTrue(split.contains("minWidth: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(split.contains("idealWidth: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(split.contains("maxWidth: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(split.contains("minHeight: 0"), "gallery rail must accept a height below its ideal content size")
    XCTAssertFalse(split.contains("history.navigation.sidebarWidth"))
    XCTAssertFalse(split.contains("HistoryGallerySidebarWidthKey"))
    XCTAssertTrue(history.contains("min: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(history.contains("ideal: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertTrue(history.contains("max: DesignTokens.Layout.sidebarIdeal"))
    XCTAssertFalse(history.contains("history.navigation.sidebarWidth"))
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
