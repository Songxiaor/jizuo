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

  /// 真机端到端：拿一段真实音频，确认探测能推翻错误的猜测。
  ///
  /// 为什么要跑真音频：这条链路的价值全在「Apple 对错 locale 的反应」上，
  /// 而那个反应是模型行为，假替身造不出来——`zh_CN` 听英文吐的是成段的拉丁
  /// 碎片（不是空、也不短），只有真模型会这么坏。
  ///
  /// 样本走环境变量，不进仓库：媒体是用户的私人内容，路径也因机器而异。
  /// 没给样本就跳过，换机跑测试不会红。
  ///   LINKDIGEST_SPEECH_PROBE_SAMPLE=/path/to/english-speech.mp4 \
  ///   LINKDIGEST_SPEECH_PROBE_EXPECTED=en_US swift test --filter AppleSpeechVideoTranscriberTests
  func testLocaleProbeOverridesAWrongGuessOnRealAudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let samplePath = env["LINKDIGEST_SPEECH_PROBE_SAMPLE"], !samplePath.isEmpty else {
      throw XCTSkip("未指定 LINKDIGEST_SPEECH_PROBE_SAMPLE，跳过真机语种探测")
    }
    guard FileManager.default.fileExists(atPath: samplePath) else {
      throw XCTSkip("样本文件不存在：\(samplePath)")
    }
    guard #available(macOS 26.0, *) else { throw XCTSkip("本机语音识别需要 macOS 26") }
    let expected = env["LINKDIGEST_SPEECH_PROBE_EXPECTED"] ?? "en_US"
    // 猜测值刻意取样本语言之外的那个，逼探测去推翻它。
    let wrongGuess = expected == "zh_CN" ? "en_US" : "zh_CN"

    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-locale-probe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let resolved = await AppleSpeechVideoTranscriber().detectLocale(
      fileURL: URL(fileURLWithPath: samplePath),
      workspaceURL: workspace,
      preferred: wrongGuess,
      fallbacks: ["en_US", "zh_CN"]
    )

    XCTAssertEqual(resolved, expected, "探测应当推翻错误的猜测 \(wrongGuess)")
    // 探测的临时切片不能留在 workspace 里跟正片抢名字。
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: workspace.appendingPathComponent("locale-probe.m4a").path),
      "探测切片必须清理掉"
    )
  }
}
