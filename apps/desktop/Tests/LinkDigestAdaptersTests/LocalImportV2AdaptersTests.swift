import AVFoundation
import Darwin
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 本地导入 v2：文件夹展开与自然排序、跳过规则。全部在临时目录里造文件，不碰用户的真实文件。
final class LocalImportScanTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-import-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func touch(_ relative: String, bytes: Int = 3) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: url)
    return url
  }

  func testNaturalOrderPutsTwoBeforeTen() {
    let names = ["10.mp4", "2.mp4", "01.mp4", "第3集.mp4", "第12集.mp4", "第1集.mp4"]
    XCTAssertEqual(
      names.sorted(by: LocalFileImportReader.naturallyPrecedes),
      ["01.mp4", "2.mp4", "10.mp4", "第1集.mp4", "第3集.mp4", "第12集.mp4"]
    )
  }

  func testFolderExpandsRecursivelyInNaturalOrder() throws {
    _ = try touch("课程/10 结尾.txt")
    _ = try touch("课程/2 中间.md")
    _ = try touch("课程/01 开头.txt")
    _ = try touch("课程/03 章节/2.md")
    _ = try touch("课程/03 章节/1.md")
    let scan = LocalFileImportReader.scanForImport([root.appendingPathComponent("课程")])
    XCTAssertEqual(scan.entries.map(\.displayName), [
      "课程/01 开头.txt",
      "课程/2 中间.md",
      "课程/03 章节/1.md",
      "课程/03 章节/2.md",
      "课程/10 结尾.txt",
    ])
    XCTAssertEqual(scan.folders.map(\.name), ["课程"])
    XCTAssertEqual(Set(scan.entries.map(\.folderIndex)), [0])
    XCTAssertTrue(scan.skipped.isEmpty)
    XCTAssertFalse(scan.truncated)
  }

  func testSkipsHiddenFilesAndPackagesAndExplainsUnsupportedOnes() throws {
    _ = try touch("资料/.DS_Store")
    _ = try touch("资料/.草稿.txt")
    _ = try touch("资料/工具.app/Contents/说明.txt")
    _ = try touch("资料/电影.mkv")
    _ = try touch("资料/片段.webm")
    _ = try touch("资料/压缩包.zip")
    _ = try touch("资料/笔记.txt")
    let scan = LocalFileImportReader.scanForImport([root.appendingPathComponent("资料")])
    XCTAssertEqual(scan.entries.map(\.displayName), ["资料/笔记.txt"], "隐藏文件不收、包不拆")
    let reasons = Dictionary(uniqueKeysWithValues: scan.skipped.map { ($0.displayName, $0.reason) })
    XCTAssertEqual(Set(reasons.keys), ["资料/工具.app", "资料/电影.mkv", "资料/片段.webm", "资料/压缩包.zip"])
    XCTAssertTrue(reasons["资料/电影.mkv"]?.contains("MP4") == true, "不支持的视频要说清楚能用哪些格式")
    XCTAssertTrue(reasons["资料/工具.app"]?.contains("不会拆开") == true)
    XCTAssertEqual(reasons["资料/压缩包.zip"], "暂不支持 .zip 文件。")
    XCTAssertEqual(scan.skippedCount, 4)
  }

  func testSymlinkLoopsAndDuplicatesAreVisitedOnce() throws {
    let a = try touch("循环/a.txt")
    let folder = root.appendingPathComponent("循环")
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("回到自己"), withDestinationURL: folder)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("b.txt"), withDestinationURL: a)
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("断了.txt"),
      withDestinationURL: root.appendingPathComponent("不存在.txt")
    )
    let scan = LocalFileImportReader.scanForImport([folder])
    XCTAssertEqual(scan.entries.count, 1, "链接成环不打转，同一个文件只收一次")
    XCTAssertEqual(scan.entries.first?.url.resolvingSymlinksInPath(), a.resolvingSymlinksInPath())
    XCTAssertEqual(scan.skipped.map(\.displayName), ["循环/断了.txt"])
  }

  func testCountsSizesAndLooseFilesForTheConfirmation() throws {
    _ = try touch("课/1.mp4", bytes: 10)
    _ = try touch("课/2.m4a", bytes: 20)
    _ = try touch("课/讲义.pdf", bytes: 30)
    _ = try touch("课/板书.png", bytes: 40)
    let loose = try touch("散的.mp3", bytes: 50)
    let scan = LocalFileImportReader.scanForImport([loose, root.appendingPathComponent("课")])
    XCTAssertEqual(scan.count(.video), 1)
    XCTAssertEqual(scan.count(.audio), 2)
    XCTAssertEqual(scan.count(.document), 1)
    XCTAssertEqual(scan.count(.image), 1)
    XCTAssertEqual(scan.mediaCount, 3)
    XCTAssertEqual(scan.totalBytes, 150)
    XCTAssertEqual(scan.entries.first(where: { $0.url.lastPathComponent == "散的.mp3" })?.folderIndex, nil)
    XCTAssertEqual(scan.entries.filter { $0.folderIndex == 0 }.count, 4)
  }

  func testFileLimitStopsTheScan() throws {
    for index in 1...3 { _ = try touch("多/\(index).txt") }
    let scan = LocalFileImportReader.scanForImport([root.appendingPathComponent("多")], fileLimit: 2)
    XCTAssertEqual(scan.entries.map(\.displayName), ["多/1.txt", "多/2.txt"])
    XCTAssertTrue(scan.truncated)
  }
}

/// 下载来源：quarantine / kMDItemWhereFroms 用 setxattr 造在临时文件上。
final class LocalFileProvenanceReaderTests: XCTestCase {
  private var file: URL!

  override func setUpWithError() throws {
    file = FileManager.default.temporaryDirectory.appendingPathComponent("provenance-\(UUID().uuidString).pdf")
    try Data("pdf".utf8).write(to: file)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: file)
  }

  private func set(_ name: String, _ data: Data) throws {
    let result = file.withUnsafeFileSystemRepresentation { path in
      data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
    }
    guard result == 0 else { throw XCTSkip("这个卷不支持扩展属性") }
  }

  func testQuarantinedDownloadCarriesAppAndPageURL() throws {
    try set("com.apple.quarantine", Data("0083;66f8a1b2;WeChat;9D5A1F3C-0000-4000-8000-000000000000".utf8))
    let whereFroms = try PropertyListSerialization.data(
      fromPropertyList: ["https://cdn.example.com/a.pdf?sign=secret", "https://example.com/article"],
      format: .binary, options: 0
    )
    try set("com.apple.metadata:kMDItemWhereFroms", whereFroms)
    let provenance = try XCTUnwrap(LocalFileImportReader.provenance(of: file))
    XCTAssertEqual(provenance.agentName, "WeChat")
    XCTAssertEqual(provenance.sourceURL, "https://example.com/article")
    XCTAssertEqual(provenance.summaryLabel, "微信下载")
    XCTAssertEqual(provenance.sourceLabel, "本地文件（下载自 WeChat：https://example.com/article）")
  }

  func testQuarantineWithoutWhereFromsStillCountsAsDownloaded() throws {
    try set("com.apple.quarantine", Data("0081;66f8a1b2;Google Chrome;".utf8))
    let provenance = try XCTUnwrap(LocalFileImportReader.provenance(of: file))
    XCTAssertEqual(provenance.agentName, "Google Chrome")
    XCTAssertNil(provenance.sourceURL)
  }

  func testFileWithoutQuarantineIsTreatedAsOwn() throws {
    XCTAssertNil(LocalFileImportReader.provenance(of: file))
    // 只有下载网址、没有 quarantine：按规则仍不算下载标记。
    try set("com.apple.metadata:kMDItemWhereFroms", try PropertyListSerialization.data(
      fromPropertyList: ["https://example.com/a.pdf"], format: .binary, options: 0
    ))
    XCTAssertNil(LocalFileImportReader.provenance(of: file))
  }

  func testGarbageQuarantineValueIsIgnored() throws {
    try set("com.apple.quarantine", Data("not-a-record".utf8))
    XCTAssertNil(LocalFileImportReader.provenance(of: file))
  }
}

/// 引用原文件：书签存法、移动后仍找得到、找不到时的说明、重新定位、删条目不删原文件。
final class ExternalMediaReferenceTests: XCTestCase {
  private var root: URL!
  private var originals: URL!
  private var store: LocalMediaStore!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("external-media-\(UUID().uuidString)", isDirectory: true)
    root = base.appendingPathComponent("AppSupport", isDirectory: true)
    originals = base.appendingPathComponent("用户的文件", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    store = LocalMediaStore(applicationSupportRoot: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  private func original(_ name: String, _ contents: String = "original-media-bytes") throws -> (URL, String) {
    let url = originals.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return (url, try LocalFileImportReader.contentSHA256(of: url))
  }

  private func asset(for url: URL, sha: String) throws -> MediaAsset {
    try store.externalReferenceAsset(
      fileURL: url, taskID: TaskID(), snapshotID: nil, contentSHA256: sha,
      byteSize: Int64(try Data(contentsOf: url).count), durationSeconds: 3,
      platform: LocalImportSource.files.rawValue, createdAtMilliseconds: 1
    )
  }

  private func same(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
  }

  func testReferenceUsesExistingColumnsAndNeverCopiesIntoMedia() throws {
    let (url, sha) = try original("讲座.mov")
    let asset = try asset(for: url, sha: sha)
    XCTAssertEqual(asset.relativePath, "\(sha).mov")
    XCTAssertNotNil(asset.relativePath.range(of: #"^[a-f0-9]{64}\.(mp4|mov)$"#, options: .regularExpression), "要过 attachMedia 的既有校验")
    XCTAssertTrue(ExternalMediaReference.isExternal(asset))
    XCTAssertEqual(ExternalMediaReference.placeholderRelativePath(contentSHA256: sha, fileExtension: "mp3"), "\(sha).mp4")
    XCTAssertTrue(same(try store.resolve(asset).url, url))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaRoot.path), "Media/ 里什么都不该有")

    let legacy = MediaAsset(taskID: TaskID(), relativePath: "\(sha).mp4", fileBookmark: Data("old-bookmark".utf8),
                            contentSHA256: sha, byteSize: 1, platform: "douyin", createdAtMilliseconds: 1)
    XCTAssertFalse(ExternalMediaReference.isExternal(legacy), "自选视频目录的旧书签不算引用原文件")
  }

  func testRenamedOriginalIsStillFound() throws {
    let (url, sha) = try original("第1集.mp4")
    let asset = try asset(for: url, sha: sha)
    let renamed = originals.appendingPathComponent("子文件夹", isDirectory: true)
    try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
    let moved = renamed.appendingPathComponent("改了名.mp4")
    try FileManager.default.moveItem(at: url, to: moved)
    XCTAssertTrue(same(try store.resolve(asset).url, moved), "同一块盘里移动、改名后书签照样找得到")
  }

  func testStaleBookmarkIsRefreshedThroughTheHook() throws {
    let (url, sha) = try original("a.mp3")
    let fake = LocalMediaStore(
      applicationSupportRoot: root,
      externalBookmarks: .init(
        create: { Data($0.path.utf8) },
        resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), true) }
      )
    )
    let asset = try fake.externalReferenceAsset(
      fileURL: url, taskID: TaskID(), snapshotID: nil, contentSHA256: sha, byteSize: 20,
      durationSeconds: nil, platform: LocalImportSource.files.rawValue, createdAtMilliseconds: 1
    )
    let refreshed = RefreshRecorder()
    fake.setExternalReferenceRefresher { refreshed.record($0) }
    _ = try fake.resolve(asset)
    let updated = try XCTUnwrap(refreshed.assets.first)
    XCTAssertEqual(updated.id, asset.id)
    XCTAssertEqual(updated.contentSHA256, asset.contentSHA256)
    XCTAssertTrue(ExternalMediaReference.isExternal(updated))
    XCTAssertEqual(updated.transcriptionStatus, .none)
  }

  func testMissingOriginalReportsWhereItUsedToBe() throws {
    let (url, sha) = try original("被删掉的.m4a")
    let asset = try asset(for: url, sha: sha)
    try FileManager.default.removeItem(at: url)
    XCTAssertThrowsError(try store.resolve(asset)) { error in
      guard case let .originalMissing(path)? = error as? ExternalMediaReferenceError else {
        return XCTFail("应当是「找不到原文件」，实际 \(error)")
      }
      XCTAssertEqual(path.map { ($0 as NSString).lastPathComponent }, "被删掉的.m4a")
    }
    XCTAssertEqual(ExternalMediaReference.lastKnownPath(of: asset).map { ($0 as NSString).lastPathComponent }, "被删掉的.m4a")
  }

  func testRelocateAcceptsOnlyTheSameContent() throws {
    let (url, sha) = try original("原片.mp4")
    let asset = try asset(for: url, sha: sha)
    let elsewhere = originals.appendingPathComponent("找回来的.mp4")
    try FileManager.default.copyItem(at: url, to: elsewhere)
    try FileManager.default.removeItem(at: url)

    let relocated = try store.relocatedExternalReference(asset, to: elsewhere)
    XCTAssertEqual(relocated.id, asset.id)
    XCTAssertEqual(relocated.relativePath, asset.relativePath)
    XCTAssertTrue(same(try store.resolve(relocated).url, elsewhere))

    let (other, _) = try original("别的.mp4", "different-media-bytes")
    XCTAssertThrowsError(try store.relocatedExternalReference(asset, to: other)) { error in
      XCTAssertEqual(error as? ExternalMediaReferenceError, .contentMismatch)
    }
  }

  func testDeletingTheTaskNeverDeletesTheOriginal() throws {
    let (url, sha) = try original("我的录音.wav")
    let asset = try asset(for: url, sha: sha)
    store.deleteFileIfUnreferenced(asset: asset, stillReferenced: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testTranscriberAcceptsReferencedAudioFormats() throws {
    for name in ["a.mp3", "b.wav", "c.m4v", "d.flac", "e.mp4", "f.m4a"] {
      let (url, _) = try original(name)
      XCTAssertNoThrow(try AppleSpeechVideoTranscriber.validateLocalMedia(url), name)
    }
    let (mkv, _) = try original("g.mkv")
    XCTAssertThrowsError(try AppleSpeechVideoTranscriber.validateLocalMedia(mkv))
  }
}

private final class RefreshRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [MediaAsset] = []
  func record(_ asset: MediaAsset) { lock.withLock { stored.append(asset) } }
  var assets: [MediaAsset] { lock.withLock { stored } }
}
