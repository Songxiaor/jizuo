import AppKit
import XCTest
@testable import LinkDigestApp

/// 阅读渲染缓存的 LRU 行为。缓存是 @MainActor 静态枚举，测试也钉在主线程。
@MainActor
final class ReadingRenderCacheTests: XCTestCase {
  private func prepareCache() {
    // attributed / plain 的键含 NSApp.effectiveAppearance；测试进程默认没有应用实例。
    _ = NSApplication.shared
    ReadingRenderCache.resetForTests()
  }

  private let palette = ReadingTextComposer.Palette(
    primary: .black,
    secondary: .darkGray,
    accent: .blue
  )

  private var capacity: Int { ReadingRenderCache.lruCapacityForTests }

  private func attributed(_ i: Int) -> NSAttributedString {
    ReadingRenderCache.attributed(
      blocks: ReadingRenderCache.blocks(from: "lru-attributed-\(i)"),
      readingFont: .sans,
      palette: palette
    )
  }

  private func plain(_ i: Int) -> NSAttributedString {
    ReadingRenderCache.plainAttributed(
      source: "lru-plain-\(i)",
      readingFont: .sans,
      color: .black
    )
  }

  func testSameInputReturnsSameAttributedInstance() {
    prepareCache()
    let first = attributed(0)
    let second = attributed(0)
    XCTAssertTrue(first === second)
  }

  func testEvictsOldestNeverHitEntryWhenOverCapacity() {
    prepareCache()
    var cached: [NSAttributedString] = []
    cached.reserveCapacity(capacity)
    for i in 0..<capacity {
      cached.append(attributed(i))
    }

    _ = attributed(capacity)

    XCTAssertFalse(
      attributed(0) === cached[0],
      "写满后最早写入且从未被命中的条目应被淘汰"
    )
    XCTAssertTrue(
      attributed(capacity - 1) === cached[capacity - 1],
      "最近写入的条目仍应命中同一实例"
    )
  }

  func testLookupRecencyProtectsOldestFromEviction() {
    prepareCache()
    var cached: [NSAttributedString] = []
    cached.reserveCapacity(capacity)
    for i in 0..<capacity {
      cached.append(attributed(i))
    }

    XCTAssertTrue(attributed(0) === cached[0], "续命前最老条目必须仍在缓存里")
    _ = attributed(capacity)

    XCTAssertTrue(
      attributed(0) === cached[0],
      "刚被命中的最老条目应续命，不应被下一条新写入淘汰"
    )
    XCTAssertFalse(
      attributed(1) === cached[1],
      "次老且未再命中的条目才应被淘汰"
    )
  }

  func testFiveCachesDoNotShareEviction() {
    prepareCache()
    var attributedCached: [NSAttributedString] = []
    var plainCached: [NSAttributedString] = []
    attributedCached.reserveCapacity(capacity)
    plainCached.reserveCapacity(capacity)

    for i in 0..<capacity {
      attributedCached.append(attributed(i))
    }
    for i in 0..<capacity {
      plainCached.append(plain(i))
      _ = ReadingRenderCache.paneBody(
        source: "lru-pane-\(i)",
        strippingEchoedMetadata: false
      )
      _ = ReadingRenderCache.summaryCitations(
        summary: "lru-summary-\(i)",
        source: "lru-source-\(i)"
      )
      _ = ReadingRenderCache.gallerySegments(
        markdown: "lru-markdown-\(i)",
        localImageURLs: [],
        appendsUnusedLocalImages: false
      )
    }

    for i in 0..<capacity {
      XCTAssertTrue(
        attributed(i) === attributedCached[i],
        "其它四个缓存写满不应淘汰 attributed 条目 \(i)"
      )
      XCTAssertTrue(
        plain(i) === plainCached[i],
        "其它缓存写入不应淘汰 plain 条目 \(i)"
      )
    }

    XCTAssertTrue(attributed(0) === attributedCached[0])
    _ = attributed(capacity)
    XCTAssertTrue(
      attributed(0) === attributedCached[0],
      "attributed 自己的 LRU 续命不应被其它缓存打乱"
    )
    XCTAssertFalse(
      attributed(1) === attributedCached[1],
      "attributed 淘汰应只发生在本缓存内"
    )
    for i in 0..<capacity {
      XCTAssertTrue(
        plain(i) === plainCached[i],
        "attributed 淘汰一条不应带走 plain 条目 \(i)"
      )
    }
  }
}
