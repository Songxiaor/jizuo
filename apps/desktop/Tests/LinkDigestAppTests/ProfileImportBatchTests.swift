import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

final class ProfileImportBatchTests: XCTestCase {
  func testJournalRestoresUnfinishedItemsAsInterruptedWithoutSignedURLs() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("profile-import-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = ProfileImportBatchJournal(applicationSupportRoot: root)
    let creatorID = CreatorID()
    let completedID = TaskID()
    let batch = ProfileImportBatch(
      id: UUID(),
      createdAtMilliseconds: 123,
      downloadsVideo: false,
      creatorID: creatorID,
      isCollapsed: false,
      items: [
        item(id: "7000000000000000001", phase: .queued),
        item(id: "7000000000000000002", phase: .fetching),
        item(id: "7000000000000000003", phase: .saving),
        item(id: "7000000000000000004", phase: .completed(completedID)),
        item(id: "7000000000000000005", phase: .failed("需要验证")),
      ]
    )

    try journal.save([batch])

    let data = try Data(contentsOf: root.appendingPathComponent(ProfileImportBatchJournal.fileName))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("signed-capture-secret"), "journal 不得保存带签名的 captureURL")
    XCTAssertFalse(json.contains("temporary-cover-secret"), "journal 不保存可能短时有效的封面 URL")

    let restored = try XCTUnwrap(journal.load().first)
    XCTAssertEqual(restored.creatorID, creatorID)
    XCTAssertEqual(restored.items[0].phase, .interrupted)
    XCTAssertEqual(restored.items[1].phase, .interrupted)
    XCTAssertEqual(restored.items[2].phase, .interrupted)
    XCTAssertEqual(restored.items[3].phase, .completed(completedID))
    XCTAssertEqual(restored.items[4].phase, .failed("需要验证"))
    XCTAssertTrue(restored.items.allSatisfy { $0.seed.captureURL == nil && $0.seed.coverURL == nil })
  }

  func testCreatorGridColumnCountStaysBetweenOneAndFour() {
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 400), 1)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 760), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 1_200), 4)
  }


  func testQueueCompletionNoticeDoesNotHideUnfinishedOrFailedWork() {
    var batch = ProfileImportBatch(id: UUID(), createdAtMilliseconds: 1, downloadsVideo: false,
      creatorID: nil, isCollapsed: false, items: [item(id: "1", phase: .completed(TaskID()))])
    XCTAssertTrue(ProfileImportQueuePresentation.succeeded(batch))
    XCTAssertTrue(ProfileImportQueuePresentation.visible(batch, dismissed: ""))
    XCTAssertFalse(ProfileImportQueuePresentation.visible(batch, dismissed: batch.id.uuidString))
    for phase: ProfileImportBatchItemPhase in [.queued, .fetching, .saving, .failed("失败"), .interrupted, .cancelled] {
      batch.items.append(item(id: "2", phase: phase))
      XCTAssertFalse(ProfileImportQueuePresentation.succeeded(batch))
      XCTAssertTrue(ProfileImportQueuePresentation.visible(batch, dismissed: batch.id.uuidString))
      batch.items.removeLast()
    }
    XCTAssertEqual(batch.completedCount, 1)
  }

  private func item(id: String, phase: ProfileImportBatchItemPhase) -> ProfileImportBatchItem {
    .init(
      id: UUID(),
      seed: .init(
        workID: id,
        authorID: "creator-fixture",
        canonicalURL: "https://www.douyin.com/video/\(id)",
        captureURL: "https://www.douyin.com/video/\(id)?signature=signed-capture-secret",
        previewText: "预览 \(id)",
        coverURL: "https://p3.douyinpic.com/temporary-cover-secret",
        publishedText: "2026-09-07",
        likes: "0",
        comments: nil,
        collects: "1"
      ),
      phase: phase
    )
  }
}
