import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// `Media/` 目录治理：孤儿扫描与总容量上限。
///
/// 这两件事都会**删用户的文件**，所以测的重点不是「删得干不干净」，而是
/// **删得够不够少**：库里有的不能被当成孤儿，传进来的清单之外的一个文件都不能动，
/// 上限默认关着的时候一个文件都不许删。
final class LocalMediaStoreGovernanceTests: XCTestCase {
  private func makeRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-governance-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("LinkDigest/Media", isDirectory: true),
      withIntermediateDirectories: true
    )
    return base
  }

  private func hashedName(_ seed: Int, ext: String = "mp4") -> String {
    String(format: "%064x", seed) + "." + ext
  }

  @discardableResult
  private func writeFile(_ root: URL, name: String, bytes: Int) throws -> URL {
    let url = root.appendingPathComponent("LinkDigest/Media/\(name)", isDirectory: false)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
  }

  private func entry(
    _ relativePath: String,
    lastUsed: Int64,
    bytes: Int64 = 0,
    userSelected: Bool = false,
    mediaID: String = UUID().uuidString.lowercased()
  ) -> MediaStorageEntry {
    .init(
      mediaID: mediaID,
      taskID: TaskID(),
      relativePath: relativePath,
      usesUserSelectedFile: userSelected,
      byteSize: bytes,
      lastUsedMilliseconds: lastUsed
    )
  }

  // MARK: - 孤儿识别

  func testKnownFilesAreNeverListedAsOrphans() throws {
    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root)
    let known = hashedName(1)
    let orphan = hashedName(2)
    try writeFile(root, name: known, bytes: 100)
    try writeFile(root, name: orphan, bytes: 250)

    let scan = try store.scanOrphans(knownRelativePaths: [known])
    XCTAssertEqual(scan.files.map(\.relativePath), [orphan])
    XCTAssertEqual(scan.totalBytes, 250)
    XCTAssertEqual(scan.count, 1)
  }

  /// 不认识的东西不该由我们来处置：没下完的临时文件、用户自己拖进来的、
  /// 子目录，一律不进清单。
  func testUnrecognisedEntriesAreNotOffered() throws {
    let root = try makeRoot()
    let media = root.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    let store = LocalMediaStore(applicationSupportRoot: root)
    try writeFile(root, name: hashedName(3), bytes: 10)
    try writeFile(root, name: "用户自己的片子.mp4", bytes: 10)
    try writeFile(root, name: ".linkdigest-abc.tmp", bytes: 10)
    try writeFile(root, name: "\(String(format: "%064x", 4)).txt", bytes: 10)
    try FileManager.default.createDirectory(
      at: media.appendingPathComponent("subdir", isDirectory: true), withIntermediateDirectories: true
    )

    let scan = try store.scanOrphans(knownRelativePaths: [])
    XCTAssertEqual(scan.files.map(\.relativePath), [hashedName(3)])
  }

  func testMissingMediaDirectoryScansToEmpty() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-missing-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    let store = LocalMediaStore(applicationSupportRoot: base)
    XCTAssertEqual(try store.scanOrphans(knownRelativePaths: []).count, 0)
  }

  // MARK: - 删除只限清单

  func testDeleteOrphansTouchesOnlyTheGivenList() throws {
    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root)
    let keep = hashedName(5)
    let remove = hashedName(6)
    let alsoKeep = hashedName(7)
    try writeFile(root, name: keep, bytes: 10)
    try writeFile(root, name: remove, bytes: 20)
    try writeFile(root, name: alsoKeep, bytes: 30)

    let report = store.deleteOrphans([.init(relativePath: remove, byteSize: 20)])
    XCTAssertEqual(report.deleted.map(\.relativePath), [remove])
    XCTAssertEqual(report.deletedBytes, 20)
    XCTAssertTrue(report.refused.isEmpty)

    let media = root.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(keep).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(alsoKeep).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(remove).path))
  }

  /// 逃出 `Media/` 的路径必须被拒绝，而且要**报出来**——
  /// 「什么都没发生」在删文件这件事上不能是静默的。
  func testDeleteOrphansRefusesPathsOutsideTheMediaRoot() throws {
    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root)
    let outside = root.appendingPathComponent("LinkDigest/outside.mp4", isDirectory: false)
    try Data(repeating: 0x41, count: 5).write(to: outside)

    let report = store.deleteOrphans([
      .init(relativePath: "../outside.mp4", byteSize: 5),
      .init(relativePath: "/etc/hosts", byteSize: 5),
      .init(relativePath: "用户的片子.mp4", byteSize: 5),
    ])
    XCTAssertTrue(report.deleted.isEmpty)
    XCTAssertEqual(report.refused.count, 3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  // MARK: - 容量淘汰顺序

  func testEvictionPlanRemovesTheOldestFirstAndStopsWhenItFits() {
    let sizes = [hashedName(11): Int64(100), hashedName(12): 100, hashedName(13): 100]
    let plan = LocalMediaStore.evictionPlan(
      inventory: [
        entry(hashedName(12), lastUsed: 200),
        entry(hashedName(11), lastUsed: 100),
        entry(hashedName(13), lastUsed: 300),
      ],
      fileSizes: sizes,
      currentBytes: 300,
      incomingBytes: 100,
      limitBytes: 250
    )
    // 需要腾出 150：最旧的两条正好够，第三条不能跟着删。
    XCTAssertEqual(plan.map(\.relativePath), [hashedName(11), hashedName(12)])
  }

  func testEvictionPlanIsEmptyWhenItAlreadyFitsOrTheLimitIsOff() {
    let sizes = [hashedName(21): Int64(50)]
    let inventory = [entry(hashedName(21), lastUsed: 1)]
    XCTAssertTrue(LocalMediaStore.evictionPlan(
      inventory: inventory, fileSizes: sizes, currentBytes: 50, incomingBytes: 10, limitBytes: 1_000
    ).isEmpty)
    XCTAssertTrue(LocalMediaStore.evictionPlan(
      inventory: inventory, fileSizes: sizes, currentBytes: 50, incomingBytes: 10, limitBytes: 0
    ).isEmpty, "上限为 0 = 不限制，一个文件都不能删")
  }

  /// 用户自己选的文件夹里的文件是用户的，容量治理不碰。
  /// 内容寻址下同一个文件可能被多条记录引用，只能算一次、删一次。
  func testEvictionPlanSkipsUserFilesAndCountsSharedFilesOnce() {
    let shared = hashedName(31)
    let userOwned = hashedName(32)
    let other = hashedName(33)
    let plan = LocalMediaStore.evictionPlan(
      inventory: [
        entry(userOwned, lastUsed: 1, userSelected: true),
        entry(shared, lastUsed: 2, mediaID: "a"),
        entry(shared, lastUsed: 3, mediaID: "b"),
        entry(other, lastUsed: 4),
      ],
      fileSizes: [shared: 100, userOwned: 999, other: 100],
      currentBytes: 200,
      incomingBytes: 100,
      limitBytes: 150
    )
    XCTAssertEqual(plan.map(\.relativePath), [shared, other])
    XCTAssertFalse(plan.contains { $0.relativePath == userOwned })
  }

  // MARK: - 写入前的执行

  func testCapacityLimitIsOffByDefaultSoNothingGetsDeleted() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-media-cap-off-")
    let preference = fixturePreference(defaults: defaults)
    XCTAssertEqual(preference.totalCapacityLimitBytes, LocalMediaStore.totalCapacityDisabled)

    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)
    let existing = hashedName(41)
    try writeFile(root, name: existing, bytes: 4_096)
    let inventory = [entry(existing, lastUsed: 1, bytes: 4_096)]
    store.setInventoryProvider { inventory }

    let outcome = store.enforceTotalCapacity(incomingByteCount: 1_000_000)
    XCTAssertTrue(outcome.evicted.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent("LinkDigest/Media/\(existing)").path
    ))
  }

  func testStoringANewFileEvictsTheOldestOnceTheLimitIsOn() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-media-cap-on-")
    let preference = fixturePreference(defaults: defaults)
    preference.totalCapacityLimitBytes = LocalMediaStore.minimumTotalCapacityBytes

    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)
    // 上限 1 GB，这里放两个各 600 MB 的稀疏文件，再写一个新的就必须腾地方。
    let oldest = hashedName(51)
    let newer = hashedName(52)
    try writeSparseFile(root, name: oldest, bytes: 600 * 1024 * 1024)
    try writeSparseFile(root, name: newer, bytes: 600 * 1024 * 1024)
    let inventory = [
      entry(oldest, lastUsed: 100, bytes: 600 * 1024 * 1024),
      entry(newer, lastUsed: 200, bytes: 600 * 1024 * 1024),
    ]
    store.setInventoryProvider { inventory }

    _ = try store.storeDetailed(data: mp4Fixture(), preferredExtension: "mp4")

    let media = root.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: media.appendingPathComponent(oldest).path),
      "最久没碰过的那个应当先被淘汰"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: media.appendingPathComponent(newer).path),
      "腾够了就该停手，不该顺手把第二个也删了"
    )
  }

  /// 用户自己选的文件夹是用户的地盘：即使开了上限，也一步都不进去。
  func testCustomDirectoryIsNeverTouchedByTheCapacityLimit() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-media-cap-custom-")
    let preference = fixturePreference(defaults: defaults)
    preference.totalCapacityLimitBytes = LocalMediaStore.minimumTotalCapacityBytes

    let root = try makeRoot()
    let selected = root.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try preference.saveDirectory(selected)

    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)
    let existing = hashedName(61)
    try writeSparseFile(root, name: existing, bytes: 2 * 1024 * 1024 * 1024)
    let inventory = [entry(existing, lastUsed: 1, bytes: 2 * 1024 * 1024 * 1024)]
    store.setInventoryProvider { inventory }

    let outcome = store.enforceTotalCapacity(incomingByteCount: 1_000)
    XCTAssertTrue(outcome.evicted.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent("LinkDigest/Media/\(existing)").path
    ))
  }

  /// 接不上仓库清单时什么都不做。「查不到」不能被当成「一条都没有」——
  /// 后者会把整个目录判成可淘汰。
  func testMissingInventoryProviderDeletesNothing() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-media-cap-noinv-")
    let preference = fixturePreference(defaults: defaults)
    preference.totalCapacityLimitBytes = LocalMediaStore.minimumTotalCapacityBytes

    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)
    let existing = hashedName(71)
    try writeSparseFile(root, name: existing, bytes: 2 * 1024 * 1024 * 1024)

    let outcome = store.enforceTotalCapacity(incomingByteCount: 1_000)
    XCTAssertTrue(outcome.evicted.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent("LinkDigest/Media/\(existing)").path
    ))
  }

  func testTotalStoredBytesOnlyCountsThisStoresOwnFiles() throws {
    let root = try makeRoot()
    let store = LocalMediaStore(applicationSupportRoot: root)
    try writeFile(root, name: hashedName(81), bytes: 100)
    try writeFile(root, name: "别人的东西.mp4", bytes: 9_999)
    XCTAssertEqual(try store.totalStoredBytes(), 100)
  }

  // MARK: - 夹具

  /// 稀疏文件：逻辑大小按上限算，实际不占盘，跑测试不写几个 GB 出去。
  private func writeSparseFile(_ root: URL, name: String, bytes: Int) throws {
    let url = root.appendingPathComponent("LinkDigest/Media/\(name)", isDirectory: false)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
  }

  private func fixturePreference(defaults: UserDefaults) -> UserDefaultsMediaStoragePreferenceStore {
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
