import AppKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

@MainActor
final class SnapshotRenderingTests: XCTestCase {
  func testIdenticalSimpleViewsProduceTheSamePNG() {
    _ = NSApplication.shared
    let view = Text("汲作").frame(width: 200, height: 80)
    let first = SnapshotTestSupport.pngData(from: view, size: CGSize(width: 200, height: 80))
    let second = SnapshotTestSupport.pngData(from: view, size: CGSize(width: 200, height: 80))
    SnapshotTestSupport.assertPNG(first)
    XCTAssertEqual(first, second)
  }

  func testGalleryFixtureRendersANonEmptyPNG() {
    _ = NSApplication.shared
    let data = SnapshotTestSupport.pngData(
      from: GallerySnapshotFixture(),
      size: CGSize(width: 640, height: 360)
    )
    SnapshotTestSupport.assertPNG(data)
  }

  func testTwoGalleryFixtureRendersMatch() {
    _ = NSApplication.shared
    let size = CGSize(width: 640, height: 360)
    let first = SnapshotTestSupport.pngData(from: GallerySnapshotFixture(), size: size)
    let second = SnapshotTestSupport.pngData(from: GallerySnapshotFixture(), size: size)
    SnapshotTestSupport.assertPNG(first)
    XCTAssertEqual(first, second)
  }
}

private struct GallerySnapshotFixture: View {
  var body: some View {
    HistoryGallerySplitView {
      List { Text("全部"); Text("X") }
    } detail: {
      Text("图库").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
