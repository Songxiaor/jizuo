import AVFoundation
import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore
import Speech

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

  // MARK: - 分段并行识别

  func testShortAudioStaysSinglePassAndLongAudioSplitsIntoAtMostFourChunks() {
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: 30), 1)
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: 149), 1)
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: 150), 2)
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: 551), 4)
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: 4 * 3600), 4)
    XCTAssertEqual(AppleSpeechVideoTranscriber.parallelChunkCount(durationSeconds: .nan), 1)
  }

  /// 切点要落在停顿里：名义切点附近放一段 1 秒的静音，切点应当落进这段静音。
  func testChunkBoundaryLandsInTheNearbySilence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-chunk-boundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tone.caf")
    let rate = 16_000.0
    let seconds = 200.0
    // 名义切点在 100 秒；静音放在 103.0–104.0 秒（落在前后 8 秒的搜索范围里）。
    let silence = 103.0..<104.0
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let chunkFrames = AVAudioFrameCount(rate)
      var written = 0.0
      while written < seconds {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames))
        buffer.frameLength = chunkFrames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(chunkFrames) {
          let time = written + Double(index) / rate
          samples[index] = silence.contains(time) ? 0 : Float(0.3 * sin(2 * .pi * 220 * time))
        }
        try file.write(from: buffer)
        written += 1
      }
    }
    let file = try AVAudioFile(forReading: url)
    let bounds = AppleSpeechVideoTranscriber.chunkBoundaries(file: file, count: 2)
    XCTAssertEqual(bounds.count, 3)
    XCTAssertEqual(bounds[0], 0)
    XCTAssertEqual(bounds[2], seconds, accuracy: 0.01)
    XCTAssertTrue(silence.contains(bounds[1]), "切点 \(bounds[1]) 应落在静音 \(silence) 里")
  }

  /// 自己按块喂识别器：48k 双声道转成 16k 单声道，整段一帧不少地喂完，之后不再出块。
  func testAnalyzerInputConvertsTheWholeFileAndThenEnds() async throws {
    guard #available(macOS 26.0, *) else { throw XCTSkip("本机语音识别需要 macOS 26") }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-analyzer-input-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tone.caf")
    let sourceRate = 48_000.0
    let sourceFrames = AVAudioFrameCount(sourceRate * 2.5)
    let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2))
    do {
      let file = try AVAudioFile(forWriting: url, settings: sourceFormat.settings)
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrames))
      buffer.frameLength = sourceFrames
      for channel in 0..<2 {
        let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
        for index in 0..<Int(sourceFrames) { samples[index] = Float(0.3 * sin(2 * .pi * 220 * Double(index) / sourceRate)) }
      }
      try file.write(from: buffer)
    }

    let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let input = try AudioFileAnalyzerInput(file: try AVAudioFile(forReading: url), targetFormat: target)
    var frames = 0
    while let chunk = try await input.next() {
      XCTAssertEqual(chunk.buffer.format, target)
      frames += Int(chunk.buffer.frameLength)
    }
    XCTAssertEqual(frames, 40_000, accuracy: 64)
    let afterEnd = try await input.next()
    XCTAssertNil(afterEnd)

    // 识别器没给建议格式时，也转成单声道再喂，不把双声道浮点原样交出去。
    let fallback = try AudioFileAnalyzerInput(file: try AVAudioFile(forReading: url), targetFormat: nil)
    var fallbackFrames = 0
    while let chunk = try await fallback.next() {
      XCTAssertEqual(chunk.buffer.format.channelCount, 1)
      fallbackFrames += Int(chunk.buffer.frameLength)
    }
    XCTAssertEqual(fallbackFrames, 40_000, accuracy: 64)
  }

  /// 真音频上跑一遍完整转写，确认分段并行的结果能用、时间轴是整段的。
  ///   LINKDIGEST_SPEECH_PARALLEL_SAMPLE=/path/to/speech.mp4 \
  ///   LINKDIGEST_SPEECH_PARALLEL_LOCALE=zh_CN swift test --filter AppleSpeechVideoTranscriberTests
  func testParallelTranscriptionOnRealAudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let samplePath = env["LINKDIGEST_SPEECH_PARALLEL_SAMPLE"], !samplePath.isEmpty else {
      throw XCTSkip("未指定 LINKDIGEST_SPEECH_PARALLEL_SAMPLE，跳过真机并行转写")
    }
    guard #available(macOS 26.0, *) else { throw XCTSkip("本机语音识别需要 macOS 26") }
    let localeIdentifier = env["LINKDIGEST_SPEECH_PARALLEL_LOCALE"] ?? "zh_CN"
    // 模型在机器上装着，但「已安装」是按进程登记的：测试进程要先占用这个语言，
    // 否则识别前的检查会当成没装（见 `isModelInstalled` 的注释）。
    let locale = Locale(identifier: localeIdentifier)
    let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
    defer { if reserved { Task { await AssetInventory.release(reservedLocale: locale) } } }
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-parallel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let started = Date()
    var finalText = ""
    var paragraphs: [TranscriptParagraph] = []
    var partials = 0
    for try await event in AppleSpeechVideoTranscriber().transcribe(
      fileURL: URL(fileURLWithPath: samplePath),
      workspaceURL: workspace,
      localeIdentifier: localeIdentifier
    ) {
      switch event {
      case .partial: partials += 1
      case let .final(text): finalText = text
      case let .finalParagraphs(value): paragraphs = value
      default: break
      }
    }
    let elapsed = Date().timeIntervalSince(started)
    print("parallel transcription: \(String(format: "%.2f", elapsed))s chars=\(finalText.count) paragraphs=\(paragraphs.count) partials=\(partials)")
    XCTAssertGreaterThan(finalText.count, 100)
    XCTAssertFalse(paragraphs.isEmpty)
    // 段落时间单调，且覆盖到音频后段（证明各段时间已换算回整段时间轴）。
    XCTAssertEqual(paragraphs.map(\.startMilliseconds), paragraphs.map(\.startMilliseconds).sorted())
    XCTAssertGreaterThan(paragraphs.last?.startMilliseconds ?? 0, 60_000)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.path).filter { $0.hasPrefix("parallel-chunk-") }
    XCTAssertTrue(leftovers.isEmpty, "分段临时文件必须清理：\(leftovers)")
  }
}
