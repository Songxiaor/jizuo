import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class MediaStoragePreferenceStoreTests: XCTestCase {
  func testDirectoryPreferenceRoundTripsAndClearRestoresDefault() throws {
    let suite = "linkdigest-media-storage-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-pref-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(defaults: defaults)

    XCTAssertNil(try store.resolvedDirectoryURL())
    try store.saveDirectory(root)
    XCTAssertEqual(try store.resolvedDirectoryURL()?.standardizedFileURL, root.standardizedFileURL)
    XCTAssertTrue(store.hasCustomDirectory)

    store.clearDirectory()
    XCTAssertNil(try store.resolvedDirectoryURL())
    XCTAssertFalse(store.hasCustomDirectory)
  }

  func testCustomDirectoryStoresFileBookmarkAndReusesSameHash() throws {
    let suite = "linkdigest-media-store-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-custom-\(UUID().uuidString)", isDirectory: true)
    let internalRoot = base.appendingPathComponent("internal", isDirectory: true)
    let selectedRoot = base.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let preference = fixtureStore(defaults: defaults)
    try preference.saveDirectory(selectedRoot)
    let store = LocalMediaStore(applicationSupportRoot: internalRoot, storagePreference: preference)
    let body = mp4Fixture()

    let first = try store.storeDetailed(data: body, preferredExtension: "mp4")
    XCTAssertTrue(first.didCreateFile)
    XCTAssertNotNil(first.fileBookmark)
    XCTAssertEqual(first.fileURL.deletingLastPathComponent().standardizedFileURL, selectedRoot.standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))

    let replay = try store.storeDetailed(data: body, preferredExtension: "mp4")
    XCTAssertFalse(replay.didCreateFile)
    XCTAssertEqual(replay.fileURL, first.fileURL)

    let asset = MediaAsset(
      taskID: TaskID(),
      relativePath: first.relativePath,
      fileBookmark: first.fileBookmark,
      contentSHA256: first.sha256,
      byteSize: Int64(body.count),
      platform: "fixture",
      createdAtMilliseconds: 1
    )
    let lease = try store.resolve(asset)
    XCTAssertEqual(lease.url.standardizedFileURL, first.fileURL.standardizedFileURL)
  }

  func testCustomDirectoryNeverOverwritesDirectoryAtHashDestination() throws {
    let suite = "linkdigest-media-conflict-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-conflict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let preference = fixtureStore(defaults: defaults)
    try preference.saveDirectory(base)
    let store = LocalMediaStore(applicationSupportRoot: base.appendingPathComponent("internal"), storagePreference: preference)
    let body = mp4Fixture()
    let hash = LocalMediaStore.contentSHA256(body)
    let conflict = base.appendingPathComponent("\(hash).mp4", isDirectory: true)
    try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: false)

    XCTAssertThrowsError(try store.storeDetailed(data: body, preferredExtension: "mp4")) {
      XCTAssertEqual($0 as? MediaDownloadError, .unsafeDestination)
    }
    XCTAssertTrue((try? conflict.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
  }

  func testDownloadLimitDefaultsHighAndClampsHandEditedValues() throws {
    let suite = "linkdigest-download-limit-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = fixtureStore(defaults: defaults)

    // A fixed 200 MB used to refuse videos the user explicitly asked to keep.
    XCTAssertEqual(store.downloadLimitBytes, LocalMediaStore.defaultDownloadLimitBytes)
    XCTAssertGreaterThan(store.downloadLimitBytes, 200 * 1024 * 1024)

    // 区间内的值原样保留。
    store.downloadLimitBytes = 512 * 1024 * 1024
    XCTAssertEqual(store.downloadLimitBytes, 512 * 1024 * 1024)

    // 区间收窄到 200 MB – 2 GB 之后，旧安装里存着的 16 GB 会在读取时被收进新
    // 上界——迁移就是靠这一步完成的，没有单独的迁移代码。
    store.downloadLimitBytes = 16 * 1024 * 1024 * 1024
    XCTAssertEqual(store.downloadLimitBytes, LocalMediaStore.maximumDownloadLimitBytes)

    // The transport bound must stay finite and inside the supported range even
    // if the defaults entry is edited by hand.
    store.downloadLimitBytes = Int.max
    XCTAssertEqual(store.downloadLimitBytes, LocalMediaStore.maximumDownloadLimitBytes)
    store.downloadLimitBytes = 1
    XCTAssertEqual(store.downloadLimitBytes, LocalMediaStore.minimumDownloadLimitBytes)

    store.resetDownloadLimit()
    XCTAssertEqual(store.downloadLimitBytes, LocalMediaStore.defaultDownloadLimitBytes)
  }

  func testCapturedVideoAutoSaveDefaultsOffWhenKeyWasNeverSet() throws {
    let suite = "linkdigest-auto-save-video-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = fixtureStore(defaults: defaults)

    // 新装机默认不自动落盘；从未写过 key 时解析为 false。
    XCTAssertFalse(store.autoSaveCapturedVideo)
  }

  func testCapturedVideoAutoSaveKeepsExplicitFalseForExistingUser() throws {
    let suite = "linkdigest-auto-save-video-off-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = fixtureStore(defaults: defaults)

    store.autoSaveCapturedVideo = false

    XCTAssertFalse(fixtureStore(defaults: defaults).autoSaveCapturedVideo)
  }

  func testCapturedVideoAutoSaveKeepsExplicitTrue() throws {
    let suite = "linkdigest-auto-save-video-on-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = fixtureStore(defaults: defaults)

    store.autoSaveCapturedVideo = true

    XCTAssertTrue(fixtureStore(defaults: defaults).autoSaveCapturedVideo)
  }

  func testEffectiveDownloadLimitNeverExceedsWhatTheVolumeCanSpare() throws {
    let suite = "linkdigest-effective-limit-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preference = fixtureStore(defaults: defaults)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-effective-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)

    preference.downloadLimitBytes = LocalMediaStore.minimumDownloadLimitBytes
    XCTAssertLessThanOrEqual(store.effectiveDownloadLimitBytes(), LocalMediaStore.minimumDownloadLimitBytes)

    preference.downloadLimitBytes = LocalMediaStore.maximumDownloadLimitBytes
    let effective = store.effectiveDownloadLimitBytes()
    XCTAssertLessThanOrEqual(effective, LocalMediaStore.maximumDownloadLimitBytes)
    XCTAssertGreaterThanOrEqual(effective, 0, "A full volume yields 0, never a negative byteLimit")
  }

  private func fixtureStore(defaults: UserDefaults) -> UserDefaultsMediaStoragePreferenceStore {
    UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        guard let path = String(data: data, encoding: .utf8) else {
          throw MediaStoragePreferenceError.missingResource
        }
        return (URL(fileURLWithPath: path), false)
      }
    )
  }

  private func mp4Fixture() -> Data {
    Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0, 0, 0, 0, 0])
  }
}
