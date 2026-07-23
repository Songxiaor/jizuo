import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class AppleSpeechVideoTranscriberTests: XCTestCase {
  func testAudioExtractionFailureFallsBackToOriginalVideoAndRemovesPartialM4A() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-apple-speech-fallback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let source = workspace.appendingPathComponent("source.mp4")
    try Data("video".utf8).write(to: source)

    let selected = try await AppleSpeechVideoTranscriber.recognitionInputURL(
      from: source,
      workspaceURL: workspace,
      extractAudio: { _, destination in
        try Data("partial".utf8).write(to: destination.appendingPathComponent("extracted-audio.m4a"))
        throw LocalVideoTranscriptionError.audioExtractionFailed
      }
    )

    XCTAssertEqual(selected, source)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("extracted-audio.m4a").path))
  }

  func testRemoteAndMissingFilesFailBeforeAudioExtraction() async {
    let transcriber = AppleSpeechVideoTranscriber()
    for url in [
      URL(string: "https://example.invalid/video.mp4")!,
      FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mp4"),
      FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).webm"),
    ] {
      do {
        let workspace = FileManager.default.temporaryDirectory
          .appendingPathComponent("linkdigest-apple-speech-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        for try await _ in transcriber.transcribe(
          fileURL: url,
          workspaceURL: workspace,
          localeIdentifier: "zh_CN"
        ) {}
        XCTFail("invalid source should fail")
      } catch {
        XCTAssertEqual(error as? LocalVideoTranscriptionError, .invalidLocalFile)
      }
    }
  }

  func testHumanReadableFailuresCoverAvailabilityMediaModelAndEmptyText() {
    let errors: [LocalVideoTranscriptionError] = [
      .unsupportedOS, .speechUnavailable, .chineseLocaleUnavailable,
      .modelDownloadFailed, .noAudioTrack, .audioExtractionFailed,
      .recognitionFailed, .emptyTranscript, .cancelled,
    ]
    let messages = errors.map(\.userMessage)
    XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    XCTAssertTrue(LocalVideoTranscriptionError.recognitionFailed.userMessage.contains("没有上传"))
    XCTAssertTrue(LocalVideoTranscriptionError.unsupportedOS.userMessage.contains("macOS 26"))
    XCTAssertTrue(LocalVideoTranscriptionError.noAudioTrack.userMessage.contains("音轨"))
  }
}
