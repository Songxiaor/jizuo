import XCTest
import LinkDigestCore
@testable import LinkDigestAdapters

final class SessionMediaDescriptorCacheTests: XCTestCase {
  func testLRUEvictsOldestWhenCapacityExceeded() {
    let cache = SessionMediaDescriptorCache(capacity: 3)
    let ids = (0..<4).map { _ in TaskID() }
    for id in ids {
      cache.insert(descriptor(url: "https://media.example.test/\(id.rawValue).mp4"), for: id)
    }
    XCTAssertEqual(cache.count, 3)
    XCTAssertNil(cache.descriptor(for: ids[0]), "first insert should be evicted")
    XCTAssertNotNil(cache.descriptor(for: ids[1]))
    XCTAssertNotNil(cache.descriptor(for: ids[2]))
    XCTAssertNotNil(cache.descriptor(for: ids[3]))
    XCTAssertEqual(cache.orderedTaskIDs(), [ids[1], ids[2], ids[3]])
  }

  func testTouchOnReadKeepsRecentlyUsed() {
    let cache = SessionMediaDescriptorCache(capacity: 2)
    let a = TaskID()
    let b = TaskID()
    let c = TaskID()
    cache.insert(descriptor(url: "https://media.example.test/a.mp4"), for: a)
    cache.insert(descriptor(url: "https://media.example.test/b.mp4"), for: b)
    // Reading a makes it most-recent; inserting c should evict b.
    XCTAssertNotNil(cache.descriptor(for: a))
    cache.insert(descriptor(url: "https://media.example.test/c.mp4"), for: c)
    XCTAssertNotNil(cache.descriptor(for: a))
    XCTAssertNil(cache.descriptor(for: b))
    XCTAssertNotNil(cache.descriptor(for: c))
  }

  func testExpiredDescriptorIsDropped() {
    let cache = SessionMediaDescriptorCache(capacity: 2)
    let id = TaskID()
    let expired = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/watch",
      canonicalURL: "https://example.test/watch",
      platform: "fixture",
      ephemeralPlaybackURL: "https://media.example.test/expired.mp4",
      expiresAt: "2020-01-01T00:00:00Z",
      transcriptionCapability: .supported
    )
    cache.insert(expired, for: id)
    XCTAssertNil(cache.descriptor(for: id, now: Date(timeIntervalSince1970: 1_800_000_000)))
    XCTAssertEqual(cache.count, 0)
  }

  private func descriptor(url: String) -> MediaDescriptor {
    MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/watch",
      canonicalURL: "https://example.test/watch",
      platform: "fixture",
      ephemeralPlaybackURL: url,
      mimeType: "video/mp4",
      transcriptionCapability: .supported
    )
  }
}
