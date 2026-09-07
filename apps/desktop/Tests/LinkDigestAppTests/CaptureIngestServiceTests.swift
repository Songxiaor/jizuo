import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore
@testable import LinkDigestPersistence

private actor CaptureIngestSinkRecorder {
  private(set) var values: [CurrentCapture] = []
  func receive(_ value: CurrentCapture) { values.append(value) }
}

final class CaptureIngestServiceTests: XCTestCase {
  func testLocalCaptureDefaultsToRevealAndCanExplicitlyKeepCurrentNavigation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("capture-ingest-navigation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let recorder = CaptureIngestSinkRecorder()
    let service = CaptureIngestService(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await recorder.receive($0) }
    )

    let ordinary = try await service.ingest(document(path: "ordinary"))
    let background = try await service.ingest(
      document(path: "profile-batch"),
      requestedAction: .save,
      suppressesAutomaticEnrichment: true,
      navigationIntent: .keepCurrent
    )

    XCTAssertEqual(ordinary.navigationIntent, .reveal, "普通单链接保持原有自动打开行为")
    XCTAssertEqual(background.navigationIntent, .keepCurrent, "批量抓取只刷新资料，不抢当前阅读")
    let published = await recorder.values
    XCTAssertEqual(published.map(\.navigationIntent), [.reveal, .keepCurrent])
  }

  private func document(path: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-09-07T00:00:00Z",
      origin: .manualLink,
      url: "https://example.test/\(path)",
      title: path,
      platform: "fixture",
      method: "fixture",
      text: "fixture body",
      completeness: "complete",
      capturedAt: "2026-09-07T00:00:00Z",
      sourceLabel: "fixture"
    )
  }
}
