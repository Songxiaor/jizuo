import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class TranscriptionTempStoreTests: XCTestCase {
  func testTemporaryTranscriptionLimitIsIndependentFromPermanentMediaLimit() {
    // The transient transcription path and the permanent "保存到本地" path now
    // carry independent ceilings: the temp one is a fixed 2 GB, the permanent
    // one is user-configurable and no longer the old fixed 200 MB.
    XCTAssertEqual(TranscriptionTempStore.maxBytes, 2 * 1024 * 1024 * 1024)
    XCTAssertNotEqual(LocalMediaStore.maxBytes, 200 * 1024 * 1024)
    // 传输层上限绑的是**用户能配置的最大值**，不是默认值。绑默认值时，配置高于
    // 默认值的那部分会被传输层先一步卡掉，用户调大等于没调。
    XCTAssertEqual(LocalMediaStore.maxBytes, LocalMediaStore.maximumDownloadLimitBytes)
    XCTAssertGreaterThanOrEqual(LocalMediaStore.maximumDownloadLimitBytes, LocalMediaStore.defaultDownloadLimitBytes)
    XCTAssertGreaterThan(LocalMediaStore.defaultDownloadLimitBytes, LocalMediaStore.minimumDownloadLimitBytes)
    XCTAssertTrue(TranscriptionTempStoreError.insufficientDiskSpace.userMessage.contains("磁盘空间不足"))
  }

  func testPrepareIsClickScopedUsesUniqueTempDirectoryAndCleanupRemovesIt() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = TempResourceFetcher(result: .success(response()))
    let store = TranscriptionTempStore(applicationSupportRoot: root, resources: fetcher)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.tempRoot.path))
    XCTAssertEqual(fetcher.callCount, 0)

    let prepared = try await store.prepare(descriptor: descriptor())
    XCTAssertEqual(fetcher.callCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    XCTAssertTrue(prepared.fileURL.path.hasPrefix(store.tempRoot.path + "/"))
    XCTAssertFalse(prepared.fileURL.path.contains("/Media/"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.tempRoot.path).count, 1)

    let audioURL = prepared.workspaceURL.appendingPathComponent("extracted-audio.m4a")
    try Data("attempt-only-audio".utf8).write(to: audioURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

    try store.cleanup(attemptID: prepared.attemptID)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.tempRoot.path).count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testKnownOverlongDurationFailsBeforeNetworkOrFilesystemCreation() async {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = TempResourceFetcher(result: .success(response()))
    let store = TranscriptionTempStore(applicationSupportRoot: root, resources: fetcher)
    do {
      _ = try await store.prepare(descriptor: descriptor(durationSeconds: 7_201))
      XCTFail("overlong media must fail")
    } catch {
      XCTAssertEqual(error as? LocalVideoTranscriptionError, .mediaTooLong)
    }
    XCTAssertEqual(fetcher.callCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.tempRoot.path))
  }

  func testPrepareForwardsInsufficientDiskSpaceAndCleansAttemptDirectory() async {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TranscriptionTempStore(
      applicationSupportRoot: root,
      resources: TempResourceFetcher(result: .success(response())),
      availableDiskBytes: { _ in 0 }
    )

    do {
      _ = try await store.prepare(descriptor: descriptor())
      XCTFail("disk-space failure must be visible to the UI")
    } catch {
      XCTAssertEqual(error as? TranscriptionTempStoreError, .insufficientDiskSpace)
    }
    XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.tempRoot.path).count) ?? 0, 0)
  }

  func testNetworkFailureAndCancellationDeleteAttemptDirectories() async {
    for failure in [TempFailure.network, .cancelled] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let fetcher = TempResourceFetcher(result: .failure(failure))
      let store = TranscriptionTempStore(applicationSupportRoot: root, resources: fetcher)
      do {
        _ = try await store.prepare(descriptor: descriptor())
        XCTFail("failure should propagate")
      } catch {}
      XCTAssertEqual(fetcher.callCount, 1)
      XCTAssertEqual(
        (try? FileManager.default.contentsOfDirectory(atPath: store.tempRoot.path).count) ?? 0,
        0
      )
    }
  }

  func testStartupCleanupAndExplicitRetryAfterCleanupFailure() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = CleanupGate()
    let store = TranscriptionTempStore(
      applicationSupportRoot: root,
      resources: TempResourceFetcher(result: .success(response())),
      removeItem: { url in try gate.remove(url) }
    )
    let prepared = try await store.prepare(descriptor: descriptor())
    gate.failNext = true
    XCTAssertThrowsError(try store.cleanup(attemptID: prepared.attemptID)) {
      XCTAssertEqual($0 as? TranscriptionTempStoreError, .cleanupFailed(prepared.attemptID))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    try store.cleanup(attemptID: prepared.attemptID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))

    let orphan = store.tempRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("orphan".utf8).write(to: orphan.appendingPathComponent("media.mp4"))
    try store.cleanupAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }

  private func makeRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp/linkdigest-transcription-temp-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func descriptor(durationSeconds: Double? = nil) -> MediaDescriptor {
    .init(
      kind: .directFile,
      pageURL: "https://example.test/video",
      canonicalURL: "https://example.test/video",
      platform: "generic",
      ephemeralPlaybackURL: "https://media.example.test/video.mp4?signature=never-persist",
      mimeType: "video/mp4",
      durationSeconds: durationSeconds,
      transcriptionCapability: .supported
    )
  }

  private func response() -> SafeResourceResponse {
    var body = Data([0, 0, 0, 24])
    body.append(contentsOf: Array("ftypisom".utf8))
    body.append(contentsOf: Array(repeating: 0, count: 12))
    return .init(
      url: URL(string: "https://media.example.test/video.mp4")!,
      statusCode: 200,
      contentType: "video/mp4",
      body: body
    )
  }
}

private enum TempFailure: Error { case network, cancelled }

private final class TempResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<SafeResourceResponse, TempFailure>
  private var calls = 0

  init(result: Result<SafeResourceResponse, TempFailure>) { self.result = result }
  var callCount: Int { lock.withLock { calls } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    _ = request
    lock.withLock { calls += 1 }
    switch result {
    case let .success(response): return response
    case .failure(.network): throw ManualLinkError.network
    case .failure(.cancelled): throw CancellationError()
    }
  }
}

private final class CleanupGate: @unchecked Sendable {
  private let lock = NSLock()
  private var fail = false
  var failNext: Bool {
    get { lock.withLock { fail } }
    set { lock.withLock { fail = newValue } }
  }

  func remove(_ url: URL) throws {
    let shouldFail = lock.withLock { () -> Bool in
      if fail { fail = false; return true }
      return false
    }
    if shouldFail { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.removeItem(at: url)
  }
}
