import AppKit
import SwiftUI
import XCTest

/// NSHostingView → PNG，不引入第三方依赖。
@MainActor
enum SnapshotTestSupport {
  static func pngData<V: View>(from view: V, size: CGSize) -> Data? {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }

  static func assertPNG(_ data: Data?, file: StaticString = #filePath, line: UInt = #line) {
    let png = data ?? Data()
    XCTAssertGreaterThan(png.count, 32, "PNG should not be empty", file: file, line: line)
    XCTAssertEqual(
      Array(png.prefix(8)),
      [137, 80, 78, 71, 13, 10, 26, 10],
      "PNG signature",
      file: file,
      line: line
    )
  }
}
