import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 「转写后清理视频」：会删用户已保存的视频，所以重点测**不该删的一个都不删**——
/// 默认保留、没转写的不删、自选文件夹不删、共享文件只要有一条没转写就不删、清单读不到不删。
final class TranscribedVideoCleanupTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private var nowMilliseconds: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }
  private let day: Int64 = 86_400_000

  private func name(_ seed: Int) -> String { String(format: "%064x", seed) + ".mp4" }

  private func entry(
    _ path: String,
    savedDaysAgo: Int64,
    transcribed: Bool = true,
    userSelected: Bool = false
  ) -> MediaStorageEntry {
    .init(
      mediaID: UUID().uuidString.lowercased(),
      taskID: TaskID(),
      relativePath: path,
      usesUserSelectedFile: userSelected,
      byteSize: 0,
      lastUsedMilliseconds: nowMilliseconds,
      createdAtMilliseconds: nowMilliseconds - savedDaysAgo * day,
      isTranscribed: transcribed
    )
  }

  private func plan(_ inventory: [MediaStorageEntry], _ policy: TranscribedVideoCleanupPolicy) -> [String] {
    let sizes = Dictionary(uniqueKeysWithValues: Set(inventory.map(\.relativePath)).map { ($0, Int64(10)) })
    return LocalMediaStore.transcribedCleanupPlan(inventory: inventory, fileSizes: sizes, policy: policy, now: now)
      .map(\.relativePath)
  }

  func testKeepDeletesNothing() {
    XCTAssertEqual(plan([entry(name(1), savedDaysAgo: 100)], .keep), [])
  }

  func testAfterTranscriptionDeletesOnlyTranscribedAppOwnedFiles() {
    let inventory = [
      entry(name(1), savedDaysAgo: 0),
      entry(name(2), savedDaysAgo: 0, transcribed: false),
      entry(name(3), savedDaysAgo: 0, userSelected: true),
    ]
    XCTAssertEqual(plan(inventory, .afterTranscription), [name(1)])
  }

  func testAfterDaysWaitsUntilTheVideoIsOldEnough() {
    let inventory = [
      entry(name(1), savedDaysAgo: 16),
      entry(name(2), savedDaysAgo: 14),
      entry(name(3), savedDaysAgo: 40, transcribed: false),
    ]
    XCTAssertEqual(plan(inventory, .afterDays(15)), [name(1)])
  }

  /// 内容寻址：两条记录指向同一个文件，一条还没转写，就不能删。
  func testSharedFileNeedsEveryReferenceTranscribed() {
    let shared = name(7)
    XCTAssertEqual(plan([entry(shared, savedDaysAgo: 5), entry(shared, savedDaysAgo: 5, transcribed: false)], .afterTranscription), [])
    XCTAssertEqual(plan([entry(shared, savedDaysAgo: 5), entry(shared, savedDaysAgo: 5)], .afterTranscription), [shared])
  }

  /// 转写之后才重新下载回来的视频：「转写完成后清理」不动它，按天数的规则从下载那天重新算。
  func testRedownloadedVideosSurviveAfterTranscriptionButNotAfterDays() {
    let redownloaded = MediaStorageEntry(
      mediaID: "m", taskID: TaskID(), relativePath: name(9), usesUserSelectedFile: false,
      byteSize: 0, lastUsedMilliseconds: nowMilliseconds,
      createdAtMilliseconds: nowMilliseconds - 20 * day,
      isTranscribed: true, transcribedAfterSaving: false
    )
    XCTAssertEqual(plan([redownloaded], .afterTranscription), [])
    XCTAssertEqual(plan([redownloaded], .afterDays(15)), [name(9)])
    XCTAssertEqual(plan([redownloaded], .afterDays(30)), [])
  }

  func testFilesMissingOnDiskAreSkipped() {
    let result = LocalMediaStore.transcribedCleanupPlan(
      inventory: [entry(name(1), savedDaysAgo: 0)], fileSizes: [:], policy: .afterTranscription, now: now
    )
    XCTAssertEqual(result, [])
  }

  func testDaysAreClampedToOneThroughThirty() {
    XCTAssertEqual(TranscribedVideoCleanupPolicy.clampedDays(0), 1)
    XCTAssertEqual(TranscribedVideoCleanupPolicy.clampedDays(99), 30)
    XCTAssertEqual(plan([entry(name(1), savedDaysAgo: 31)], .afterDays(500)), [name(1)])
    XCTAssertEqual(plan([entry(name(1), savedDaysAgo: 29)], .afterDays(500)), [])
  }

  // MARK: - 偏好

  func testPreferenceDefaultsToKeepAndRemembersDays() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-transcribed-cleanup-")
    let store = UserDefaultsMediaStoragePreferenceStore(defaults: defaults)
    XCTAssertEqual(store.transcribedVideoCleanup, .keep)
    XCTAssertEqual(store.transcribedCleanupDays, 30)
    store.transcribedVideoCleanup = .afterDays(15)
    XCTAssertEqual(store.transcribedVideoCleanup, .afterDays(15))
    store.transcribedVideoCleanup = .keep
    XCTAssertEqual(store.transcribedVideoCleanup, .keep)
    XCTAssertEqual(store.transcribedCleanupDays, 15, "切回保留后上次选的天数还在")
    store.transcribedVideoCleanup = .afterTranscription
    XCTAssertEqual(store.transcribedVideoCleanup, .afterTranscription)
  }

  // MARK: - 执行

  func testDeletingRemovesOnlyThePlannedFilesAndMissingInventoryDeletesNothing() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-transcribed-cleanup-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    let media = base.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    for seed in [1, 2] { try Data(repeating: 0x41, count: 64).write(to: media.appendingPathComponent(name(seed))) }

    let (_, defaults) = try ephemeralDefaults("linkdigest-transcribed-cleanup-run-")
    let preference = UserDefaultsMediaStoragePreferenceStore(defaults: defaults)
    preference.transcribedVideoCleanup = .afterTranscription
    let store = LocalMediaStore(applicationSupportRoot: base, storagePreference: preference)

    XCTAssertNil(store.transcribedCleanupCandidates(now: now), "清单读不到时返回 nil，不当成空")

    let inventory = [entry(name(1), savedDaysAgo: 0), entry(name(2), savedDaysAgo: 0, transcribed: false)]
    store.setInventoryProvider { inventory }
    let candidates = try XCTUnwrap(store.transcribedCleanupCandidates(now: now))
    XCTAssertEqual(candidates.map(\.relativePath), [name(1)])
    let report = store.deleteTranscribedVideos(candidates)
    XCTAssertEqual(report.deleted.map(\.relativePath), [name(1)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(name(1)).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(name(2)).path))
  }
}
