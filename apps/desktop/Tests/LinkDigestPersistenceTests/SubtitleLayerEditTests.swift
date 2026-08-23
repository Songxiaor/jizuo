import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

final class SubtitleLayerEditTests: XCTestCase {
  /// 画面字幕层必须真能校对保存。
  ///
  /// 它和听写稿一样是机器识别的结果，会有错字。既然界面上给了编辑入口，
  /// 保存就必须落库——否则那是个假功能，点进去改完还弹「无法保存」。
  func testSubtitleSnapshotBodyCanBeEdited() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-subedit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let url = "https://example.test/subtitle-edit"
    _ = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z", origin: .manualLink, url: url,
        title: "视频", platform: "x", method: "fixture", text: "配文正文。",
        completeness: "complete", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "X"
      ),
      receivedAtMilliseconds: 1
    ))
    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-07-20T00:05:00Z", origin: .burnedInSubtitles, url: url,
        title: "视频", platform: "x", method: "vision_ocr", text: "00:00 有多复杂，後置的标准",
        completeness: "complete", capturedAt: "2026-07-20T00:05:00Z", sourceLabel: "画面字幕"
      ),
      receivedAtMilliseconds: 2
    ))

    let detail = try repository.detail(taskID: accepted.taskID)
    let subtitle = try XCTUnwrap(LayeredSourceDocument.subtitleSnapshot(in: detail.snapshots))

    XCTAssertNoThrow(
      try repository.updateSnapshotBodyText(
        taskID: accepted.taskID,
        snapshotID: subtitle.id,
        bodyText: "00:00 有多复杂，衡量的标准",
        updatedAtMilliseconds: 3
      ),
      "画面字幕层的校对必须能保存"
    )
    let after = try repository.detail(taskID: accepted.taskID)
    let edited = try XCTUnwrap(LayeredSourceDocument.subtitleSnapshot(in: after.snapshots))
    XCTAssertTrue(edited.bodyText.contains("衡量的标准"), "改动没落库")
  }
}
