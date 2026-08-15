import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

@MainActor
final class KnowledgeVaultSettingsViewModelTests: XCTestCase {
  func testBrowserAndManualCapturesBothScheduleAutomaticSync() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/LinkDigestApp.swift"),
      encoding: .utf8
    )
    XCTAssertEqual(
      source.components(separatedBy: "scheduleAutoSync()").count - 1,
      2,
      "浏览器接收与手动链接入库都必须安排知识库同步"
    )
  }

  func testAutomaticSyncFailureIsVisibleAndClearsAfterSuccessfulRetry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-vault-settings-\(UUID().uuidString)", isDirectory: true)
    let vault = root.appendingPathComponent("vault", isDirectory: true)
    let database = root.appendingPathComponent("database", isDirectory: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let suite = "KnowledgeVaultSettingsViewModelTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsKnowledgeVaultStore(
      defaults: defaults,
      createBookmark: { _ in Data("fixture-bookmark".utf8) },
      resolveBookmark: { _ in (vault, false) }
    )
    try store.saveDirectory(vault)

    let originalDelay = KnowledgeVaultSettingsViewModel.autoSyncDelaySeconds
    KnowledgeVaultSettingsViewModel.autoSyncDelaySeconds = 0
    defer { KnowledgeVaultSettingsViewModel.autoSyncDelaySeconds = originalDelay }

    let model = KnowledgeVaultSettingsViewModel(store: store)
    model.scheduleAutoSync()
    await waitUntil { model.lastAutoSyncFailureMessage != nil }
    XCTAssertTrue(model.lastAutoSyncFailureMessage?.contains("历史还没准备好") == true)
    XCTAssertEqual(model.state, .idle, "后台失败不应伪装成一次手动同步结果")

    let repository = try GRDBHistoryRepository.open(
      at: .init(applicationSupportRoot: database)
    )
    defer { try? repository.database.close() }
    model.configure(history: HistoryApplicationService(repository: repository))
    model.scheduleAutoSync()
    await waitUntil { model.lastAutoSyncFailureMessage == nil }
    XCTAssertNil(model.lastAutoSyncFailureMessage)
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      if clock.now >= deadline {
        XCTFail("等待条件超时", file: file, line: line)
        return
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
