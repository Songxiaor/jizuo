import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 转写临时媒体：有伴随音轨时必须下音频轨，而不是只有画面的主播放地址。
final class TranscriptionTempStoreCompanionTrackTests: XCTestCase {
  func testPreferredSourceUsesCompanionAudioWhenPresent() {
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://www.bilibili.com/video/BV1test",
      canonicalURL: "https://www.bilibili.com/video/BV1test",
      platform: "bilibili",
      ephemeralPlaybackURL: "https://upos.bilivideo.com/video-only.m4s",
      companionAudioURL: "https://upos.bilivideo.com/audio-only.m4s",
      transcriptionCapability: .supported
    )
    XCTAssertEqual(
      TranscriptionTempStore.preferredTranscriptionSourceURL(descriptor),
      "https://upos.bilivideo.com/audio-only.m4s"
    )
  }

  func testPreferredSourceFallsBackToPlaybackURLWithoutCompanion() {
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/video",
      canonicalURL: "https://example.test/video",
      platform: "douyin",
      ephemeralPlaybackURL: "https://media.example.test/muxed.mp4",
      companionAudioURL: nil,
      transcriptionCapability: .supported
    )
    XCTAssertEqual(
      TranscriptionTempStore.preferredTranscriptionSourceURL(descriptor),
      "https://media.example.test/muxed.mp4"
    )
  }

  func testPrepareDownloadsCompanionAudioTrackWhenPresent() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-transcription-companion-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let audioURL = "https://upos.bilivideo.com/audio-only.m4s?token=audio"
    let videoURL = "https://upos.bilivideo.com/video-only.m4s?token=video"
    let fetcher = RecordingTempFetcher(result: .success(isoMediaResponse(url: audioURL)))
    let store = TranscriptionTempStore(applicationSupportRoot: root, resources: fetcher)

    let prepared = try await store.prepare(descriptor: MediaDescriptor(
      kind: .directFile,
      pageURL: "https://www.bilibili.com/video/BV1test",
      canonicalURL: "https://www.bilibili.com/video/BV1test",
      platform: "bilibili",
      ephemeralPlaybackURL: videoURL,
      companionAudioURL: audioURL,
      mimeType: "application/octet-stream",
      transcriptionCapability: .supported
    ))

    XCTAssertEqual(fetcher.callCount, 1)
    XCTAssertEqual(fetcher.lastRequestedURL?.absoluteString, audioURL)
    XCTAssertEqual(fetcher.lastReferer, "https://www.bilibili.com/")
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    try store.cleanup(attemptID: prepared.attemptID)
  }

  func testPrepareDownloadsPlaybackURLWhenNoCompanion() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-transcription-no-companion-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let videoURL = "https://media.example.test/video.mp4?signature=never-persist"
    let fetcher = RecordingTempFetcher(result: .success(isoMediaResponse(url: videoURL)))
    let store = TranscriptionTempStore(applicationSupportRoot: root, resources: fetcher)

    _ = try await store.prepare(descriptor: MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/video",
      canonicalURL: "https://example.test/video",
      platform: "generic",
      ephemeralPlaybackURL: videoURL,
      companionAudioURL: nil,
      mimeType: "video/mp4",
      transcriptionCapability: .supported
    ))

    XCTAssertEqual(fetcher.lastRequestedURL?.absoluteString, videoURL)
  }

  private func isoMediaResponse(url: String) -> SafeResourceResponse {
    var body = Data([0, 0, 0, 24])
    body.append(contentsOf: Array("ftypisom".utf8))
    body.append(contentsOf: Array(repeating: 0, count: 12))
    return .init(
      url: URL(string: url)!,
      statusCode: 200,
      contentType: "application/octet-stream",
      body: body
    )
  }
}

private final class RecordingTempFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<SafeResourceResponse, Error>
  private var calls = 0
  private var lastURL: URL?
  private var lastHeaders: [String: String] = [:]

  init(result: Result<SafeResourceResponse, Error>) { self.result = result }

  var callCount: Int { lock.withLock { calls } }
  var lastRequestedURL: URL? { lock.withLock { lastURL } }
  var lastReferer: String? { lock.withLock { lastHeaders["Referer"] } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock {
      calls += 1
      lastURL = request.url
      lastHeaders = request.headers
    }
    switch result {
    case let .success(response): return response
    case let .failure(error): throw error
    }
  }
}
