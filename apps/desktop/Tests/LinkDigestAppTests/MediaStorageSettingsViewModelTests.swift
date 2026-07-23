import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp

@MainActor
final class MediaStorageSettingsViewModelTests: XCTestCase {
  func testCancelKeepsExistingSelectionAndRestoreDefaultClearsIt() throws {
    let suite = "linkdigest-media-settings-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let selected = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: selected) }
    let store = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
      }
    )
    let model = MediaStorageSettingsViewModel(store: store)

    model.applySelection(selected)
    XCTAssertTrue(model.usesCustomDirectory)
    XCTAssertEqual(model.directoryPath, selected.path)

    model.applySelection(nil)
    XCTAssertEqual(model.directoryPath, selected.path)
    XCTAssertTrue(store.hasCustomDirectory)

    model.restoreDefault()
    XCTAssertFalse(model.usesCustomDirectory)
    XCTAssertFalse(store.hasCustomDirectory)
    XCTAssertTrue(model.directoryPath.contains("默认"))
  }

  func testStaleDirectoryBookmarkHasExplainableRecoveryState() throws {
    let suite = "linkdigest-media-settings-stale-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("stale".utf8), forKey: "media-storage.directory-bookmark")
    let store = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { _ in
        (FileManager.default.temporaryDirectory, true)
      }
    )

    let model = MediaStorageSettingsViewModel(store: store)

    XCTAssertTrue(model.usesCustomDirectory)
    XCTAssertTrue(model.directoryPath.contains("不可用"))
    guard case let .failed(message) = model.state else { return XCTFail("expected stale recovery state") }
    XCTAssertTrue(message.contains("失效"))
  }

  func testAutoSaveToggleLoadsAndPersistsWithoutChangingDownloadLimit() throws {
    let suite = "linkdigest-media-settings-auto-save-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
      }
    )
    let originalLimit = store.downloadLimitBytes
    let model = MediaStorageSettingsViewModel(store: store)

    XCTAssertTrue(model.autoSaveCapturedVideo)
    model.autoSaveCapturedVideo = false

    XCTAssertFalse(store.autoSaveCapturedVideo)
    XCTAssertEqual(store.downloadLimitBytes, originalLimit)
    let reloaded = MediaStorageSettingsViewModel(store: store)
    XCTAssertFalse(reloaded.autoSaveCapturedVideo)
  }
}
