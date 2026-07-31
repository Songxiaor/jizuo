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

  func testSessionMediaRestoreModeDefaultsToManualAndPersists() throws {
    let suite = "linkdigest-media-settings-restore-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
      }
    )
    let model = MediaStorageSettingsViewModel(store: store)
    XCTAssertEqual(model.sessionMediaRestoreMode, .manual)
    model.sessionMediaRestoreMode = .automatic
    XCTAssertEqual(store.sessionMediaRestoreMode, .automatic)
    let reloaded = MediaStorageSettingsViewModel(store: store)
    XCTAssertEqual(reloaded.sessionMediaRestoreMode, .automatic)
  }

  func testBilibiliStreamQualityDefaultsToHighestAndPersists() throws {
    let suite = "linkdigest-media-settings-bili-q-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
      }
    )
    let model = MediaStorageSettingsViewModel(store: store)
    XCTAssertEqual(model.bilibiliStreamQuality, .highest)
    model.bilibiliStreamQuality = .dataSaver
    XCTAssertEqual(store.bilibiliStreamQuality, .dataSaver)
    let reloaded = MediaStorageSettingsViewModel(store: store)
    XCTAssertEqual(reloaded.bilibiliStreamQuality, .dataSaver)
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

    // 默认关闭；用户显式打开后应持久化，且不影响下载上限。
    XCTAssertFalse(model.autoSaveCapturedVideo)
    model.autoSaveCapturedVideo = true

    XCTAssertTrue(store.autoSaveCapturedVideo)
    XCTAssertEqual(store.downloadLimitBytes, originalLimit)
    let reloaded = MediaStorageSettingsViewModel(store: store)
    XCTAssertTrue(reloaded.autoSaveCapturedVideo)
  }
}

/// 单个视频上限的可选区间与显示。
///
/// 原来是 1–128 GB：起点太高（想只留几百兆的短视频做不到），上界又高到等于没有
/// 上限。现在收成 200 MB – 2 GB。
@MainActor
final class MediaStorageDownloadLimitRangeTests: XCTestCase {
  func testRangeIsTwoHundredMegabytesToTwoGigabytes() {
    XCTAssertEqual(MediaStorageSettingsViewModel.minimumLimitMegabytes, 200)
    XCTAssertEqual(MediaStorageSettingsViewModel.maximumLimitMegabytes, 2048)
    // 默认值必须落在区间内，否则打开设置页看到的就是个非法值。
    XCTAssertGreaterThanOrEqual(
      LocalMediaStore.defaultDownloadLimitBytes / (1024 * 1024),
      MediaStorageSettingsViewModel.minimumLimitMegabytes
    )
    XCTAssertLessThanOrEqual(
      LocalMediaStore.defaultDownloadLimitBytes / (1024 * 1024),
      MediaStorageSettingsViewModel.maximumLimitMegabytes
    )
  }

  /// 步进要能从起点走到终点，不能卡在半路。
  func testSteppingCoversTheWholeRange() {
    let step = MediaStorageSettingsViewModel.limitStepMegabytes
    XCTAssertGreaterThan(step, 0)
    var value = MediaStorageSettingsViewModel.minimumLimitMegabytes
    var hops = 0
    while value < MediaStorageSettingsViewModel.maximumLimitMegabytes, hops < 100 {
      value += step
      hops += 1
    }
    XCTAssertGreaterThanOrEqual(value, MediaStorageSettingsViewModel.maximumLimitMegabytes)
    XCTAssertLessThan(hops, 20, "档位太多，用户得一直点")
  }

  /// 顶档和它下面一档不能显示成同一个字样，否则看起来像点了没反应。
  func testTopTwoStepsReadDifferently() {
    let top = MediaStorageSettingsViewModel.maximumLimitMegabytes
    let below = top - MediaStorageSettingsViewModel.limitStepMegabytes
    XCTAssertNotEqual(
      MediaStorageSettingsViewModel.formattedLimit(megabytes: top),
      MediaStorageSettingsViewModel.formattedLimit(megabytes: below)
    )
  }

  func testFormattingSwitchesToGigabytesOnlyAboveOneGigabyte() {
    XCTAssertEqual(MediaStorageSettingsViewModel.formattedLimit(megabytes: 200), "200 MB")
    XCTAssertEqual(MediaStorageSettingsViewModel.formattedLimit(megabytes: 1000), "1000 MB")
    XCTAssertEqual(MediaStorageSettingsViewModel.formattedLimit(megabytes: 1024), "1 GB")
    XCTAssertEqual(MediaStorageSettingsViewModel.formattedLimit(megabytes: 2048), "2 GB")
    // 向下取整：2000 MB 是 1.95 GB，不能显示成 2 GB。
    XCTAssertEqual(MediaStorageSettingsViewModel.formattedLimit(megabytes: 2000), "1.9 GB")
  }
}
