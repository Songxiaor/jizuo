import Foundation
import LinkDigestShared
import XCTest

@testable import LinkDigestApp

final class CompanionSyncGateTests: XCTestCase {
  func testOfferedSwitchKeepsSynchronizeDisabledEvenIfUserEnabledIt() {
    XCTAssertFalse(ExperimentalFeatures.isCompanionSyncOffered)
    XCTAssertFalse(ExperimentalFeatures.isCompanionSyncEnabled(userEnabled: true))
    XCTAssertFalse(ExperimentalFeatures.isCompanionSyncEnabled(userEnabled: false))
  }

  func testLaunchPathGuardsSynchronizeWithTheOfferedSwitch() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/LinkDigestApp.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("ExperimentalFeatures.isCompanionSyncEnabled()"))
    XCTAssertTrue(source.contains("companionNoteSync.synchronize()"))
    let guardRange = try XCTUnwrap(source.range(of: "ExperimentalFeatures.isCompanionSyncEnabled()"))
    let syncRange = try XCTUnwrap(source.range(of: "companionNoteSync.synchronize()"))
    XCTAssertLessThan(guardRange.lowerBound, syncRange.lowerBound)
  }

  @MainActor
  func testSynchronizeDoesNotCallTransportWhenSwitchIsOff() async {
    let spy = RecordingNoteSync()
    let coordinator = CompanionNoteSyncCoordinator(sync: spy, enabled: false)
    await coordinator.synchronize()
    XCTAssertEqual(spy.callCount.value, 0, "开关关闭时不得调用 synchronize")
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private final class RecordingNoteSync: NoteCardSyncing, @unchecked Sendable {
  let callCount = Counter()

  func synchronize(local: NoteCardStore) async throws -> NoteSyncStatus {
    callCount.value += 1
    return NoteSyncStatus()
  }

  final class Counter: @unchecked Sendable {
    var value = 0
  }
}
