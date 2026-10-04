import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 下载超限才改试较低档。网络和状态错误保持失败，不把备用地址当成重试清单。
final class VideoMediaDownloaderFallbackTests: XCTestCase {
  func testOversizedVariantsFallThroughUntilOneFits() async throws {
    let root = try makeRoot()
    let high = "https://video.twimg.com/high.mp4"
    let mid = "https://video.twimg.com/mid.mp4"
    let low = "https://video.twimg.com/low.mp4"
    let skipped = "http://video.twimg.com/insecure.mp4"
    let fetcher = VariantFetcher(script: [
      high: .tooLarge,
      mid: .tooLarge,
      low: .body(Self.mp4Fixture()),
    ])
    let downloader = VideoMediaDownloader(resources: fetcher, store: LocalMediaStore(applicationSupportRoot: root))
    let media = CaptureMedia(
      platform: "x",
      videoURL: high,
      fallbackVideoURLs: [high, skipped, mid, low]
    )

    let result = try await downloader.downloadAndStoreResult(
      media: media,
      taskID: TaskID(),
      snapshotID: nil
    )

    XCTAssertEqual(fetcher.requested, [high, mid, low])
    XCTAssertEqual(result.asset.byteSize, Int64(Self.mp4Fixture().count))
    XCTAssertEqual(result.asset.platform, "x")
  }

  func testNetworkErrorDoesNotTryLowerVariants() async throws {
    let root = try makeRoot()
    let high = "https://video.twimg.com/high.mp4"
    let low = "https://video.twimg.com/low.mp4"
    let fetcher = VariantFetcher(script: [
      high: .failure(.network),
      low: .body(Self.mp4Fixture()),
    ])
    let downloader = VideoMediaDownloader(resources: fetcher, store: LocalMediaStore(applicationSupportRoot: root))
    let media = CaptureMedia(
      platform: "x",
      videoURL: high,
      fallbackVideoURLs: [low]
    )

    do {
      _ = try await downloader.downloadAndStoreResult(media: media, taskID: TaskID(), snapshotID: nil)
      XCTFail("network errors must not be retried on a lower variant")
    } catch let error as MediaDownloadError {
      XCTAssertEqual(error, .network)
    }
    XCTAssertEqual(fetcher.requested, [high])
  }

  func testStatusErrorOnAFallbackStopsTheChain() async throws {
    let root = try makeRoot()
    let high = "https://video.twimg.com/high.mp4"
    let mid = "https://video.twimg.com/mid.mp4"
    let low = "https://video.twimg.com/low.mp4"
    let fetcher = VariantFetcher(script: [
      high: .tooLarge,
      mid: .failure(.responseStatus),
      low: .body(Self.mp4Fixture()),
    ])
    let downloader = VideoMediaDownloader(resources: fetcher, store: LocalMediaStore(applicationSupportRoot: root))
    let media = CaptureMedia(
      platform: "x",
      videoURL: high,
      fallbackVideoURLs: [mid, low]
    )

    do {
      _ = try await downloader.downloadAndStoreResult(media: media, taskID: TaskID(), snapshotID: nil)
      XCTFail("a non-size failure must stop the fallback chain")
    } catch let error as MediaDownloadError {
      XCTAssertEqual(error, .responseStatus)
    }
    XCTAssertEqual(fetcher.requested, [high, mid])
  }

  func testInvalidPrimaryDoesNotUseFallbacks() async throws {
    let root = try makeRoot()
    let fetcher = VariantFetcher(script: [
      "https://video.twimg.com/low.mp4": .body(Self.mp4Fixture()),
    ])
    let downloader = VideoMediaDownloader(resources: fetcher, store: LocalMediaStore(applicationSupportRoot: root))
    let media = CaptureMedia(
      platform: "x",
      videoURL: "http://video.twimg.com/high.mp4",
      fallbackVideoURLs: ["https://video.twimg.com/low.mp4"]
    )

    do {
      _ = try await downloader.downloadAndStoreResult(media: media, taskID: TaskID(), snapshotID: nil)
      XCTFail("an invalid primary URL must fail before any fallback")
    } catch let error as MediaDownloadError {
      XCTAssertEqual(error, .invalidURL)
    }
    XCTAssertTrue(fetcher.requested.isEmpty)
  }

  func testMediaDescriptorWithoutFallbackKeyStillDecodes() throws {
    let json = """
    {"kind":"directFile","pageURL":"https://x.com/a/status/1","canonicalURL":"https://x.com/a/status/1","platform":"x","ephemeralPlaybackURL":"https://video.twimg.com/a.mp4","transcriptionCapability":"supported"}
    """
    let descriptor = try JSONDecoder().decode(MediaDescriptor.self, from: Data(json.utf8))
    XCTAssertNil(descriptor.fallbackVideoURLs)
    let encoded = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
    XCTAssertFalse(encoded.contains("fallbackVideoURLs"))
    XCTAssertTrue(encoded.contains("ephemeralPlaybackURL"))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-fallback-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func mp4Fixture() -> Data {
    var body = Data([0x00, 0x00, 0x00, 0x18])
    body.append(contentsOf: Array("ftyp".utf8))
    body.append(contentsOf: Array("isom".utf8))
    body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    body.append(contentsOf: Array("isom".utf8))
    return body
  }
}

private final class VariantFetcher: SafeResourceFetching, @unchecked Sendable {
  enum Script {
    case tooLarge
    case failure(ManualLinkError)
    case body(Data)
  }

  private let lock = NSLock()
  private let script: [String: Script]
  private var urls: [String] = []

  init(script: [String: Script]) {
    self.script = script
  }

  var requested: [String] { lock.withLock { urls } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    let raw = request.url.absoluteString
    lock.withLock { urls.append(raw) }
    switch script[raw] {
    case .tooLarge:
      throw ManualLinkError.responseTooLarge
    case let .failure(error):
      throw error
    case let .body(body):
      return .init(url: request.url, statusCode: 200, contentType: "video/mp4", body: body)
    case nil:
      throw ManualLinkError.network
    }
  }
}
