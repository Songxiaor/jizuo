import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

final class CaptureOutcomeStoreTests: XCTestCase {
  func testRoundTripsSuccessAndFailureCountsWithoutWritingSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureOutcomeStore(applicationSupportRoot: root)

    store.recordSuccess(platform: "x")
    store.recordSuccess(platform: "x")
    store.recordFailure(platform: "x", code: "CAPTURE_CONTENT_EMPTY")
    store.recordFailure(platform: "https://example.com/item?token=abcd", code: "CAPTURE_SCHEMA_INVALID")

    let snap = store.snapshot()
    XCTAssertEqual(snap.platforms["x"]?.succeeded, 2)
    XCTAssertEqual(snap.platforms["x"]?.failed["CAPTURE_CONTENT_EMPTY"], 1)
    XCTAssertNil(snap.platforms["https://example.com/item?token=abcd"])

    let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
    XCTAssertFalse(text.contains("https://"))
    XCTAssertFalse(text.contains("token=abcd"))
    XCTAssertTrue(text.contains("CAPTURE_CONTENT_EMPTY"))
  }

  func testSharedStoreIsDisabledUnderXCTest() {
    XCTAssertNil(CaptureOutcomeStore.shared)
  }

  func testPlatformTokenMapsHostsToFixedNamesWithoutLeakingURL() {
    XCTAssertEqual(CaptureOutcomeStore.platformToken(forURLString: "https://www.xiaohongshu.com/explore/abc?xsec_token=SECRET"), "xiaohongshu")
    XCTAssertEqual(CaptureOutcomeStore.platformToken(forURLString: "https://xhslink.com/a/xyz"), "xiaohongshu")
    XCTAssertEqual(CaptureOutcomeStore.platformToken(forURLString: "https://www.douyin.com/video/1"), "douyin")
    XCTAssertEqual(CaptureOutcomeStore.platformToken(forURLString: "https://example.org/private/path"), "generic")
    // 和成功统计同一个桶名：成功写的是 CapturePlatformDetection，失败不能另起一套。
    for raw in ["https://example.org/a", "https://mp.weixin.qq.com/s/x", "https://www.zhihu.com/q/1", "https://medium.com/p", "https://www.youtube.com/watch?v=1", "https://xhslink.cn/a"] {
      let expected = URL(string: raw).map(CapturePlatformDetection.platform(from:))
      let token = CaptureOutcomeStore.platformToken(forURLString: raw)
      XCTAssertTrue(token == expected || (raw.contains("xhslink.cn") && token == "xiaohongshu"), raw)
    }
    XCTAssertEqual(CaptureOutcomeStore.platformToken(forURLString: "not a url"), "unknown")
  }
}

final class AutoTranscriptionJournalTests: XCTestCase {
  private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func testPersistsAcrossLaunchAndCapsAutomaticAttempts() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = TaskID(), b = TaskID()
    let first = AutoTranscriptionJournal(applicationSupportRoot: root)
    first.register(a)
    first.register(b)
    first.noteAttempt(a)

    // 重启后还在，且尝试次数保留。
    let second = AutoTranscriptionJournal(applicationSupportRoot: root)
    XCTAssertEqual(Set(second.resumableTaskIDs()), [a, b])
    second.noteAttempt(a) // a 达到上限
    let third = AutoTranscriptionJournal(applicationSupportRoot: root)
    XCTAssertEqual(third.resumableTaskIDs(), [b], "达到次数上限的不再自动重试")
    third.remove(b)
    XCTAssertEqual(AutoTranscriptionJournal(applicationSupportRoot: root).pendingCount, 0)
  }

  func testJournalFileStoresOnlyTaskIDsAndCounts() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let id = TaskID()
    journal.register(id)
    let text = String(decoding: try Data(contentsOf: root.appendingPathComponent(AutoTranscriptionJournal.fileName)), as: UTF8.self)
    XCTAssertTrue(text.contains(id.rawValue))
    XCTAssertFalse(text.contains("http"))
  }
}
