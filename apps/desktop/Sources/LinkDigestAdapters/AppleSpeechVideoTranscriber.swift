import AVFoundation
import Foundation
import LinkDigestCore
import Speech

/// macOS 26 adapter for fully local video transcription. The only network-capable
/// operation is Apple's model installation, exposed as a separate explicit method.
public struct AppleSpeechVideoTranscriber: LocalVideoTranscribing {
  public init() {}

  /// 不用 `.progressiveTranscription` preset：它含 `.fastResults`（快速通道
  /// 牺牲质量），实测最终文本几乎丢光句内标点、只在停顿分段处补句号。
  /// 这里保留 `.volatileResults` 维持进度展示，显式要 `.audioTimeRange`
  /// 供 TimedTranscriptionAccumulator 按时间排序分段。
  @available(macOS 26.0, *)
  private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: [.audioTimeRange]
    )
  }

  public func modelState(localeIdentifier: String) async -> LocalSpeechModelState {
    guard #available(macOS 26.0, *) else { return .unavailable(.unsupportedOS) }
    guard SpeechTranscriber.isAvailable else { return .unavailable(.speechUnavailable) }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { return .unavailable(.chineseLocaleUnavailable) }

    let transcriber = Self.makeTranscriber(locale: locale)
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed:
      return .ready
    case .supported, .downloading:
      return .requiresDownload
    case .unsupported:
      return .unavailable(.chineseLocaleUnavailable)
    @unknown default:
      return .unavailable(.speechUnavailable)
    }
  }

  public func downloadModel(localeIdentifier: String) async throws {
    guard #available(macOS 26.0, *) else { throw LocalVideoTranscriptionError.unsupportedOS }
    guard SpeechTranscriber.isAvailable else { throw LocalVideoTranscriptionError.speechUnavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { throw LocalVideoTranscriptionError.chineseLocaleUnavailable }

    let transcriber = Self.makeTranscriber(locale: locale)
    if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
    do {
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
        throw LocalVideoTranscriptionError.modelDownloadFailed
      }
      try await request.downloadAndInstall()
      guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
        throw LocalVideoTranscriptionError.modelDownloadFailed
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as LocalVideoTranscriptionError {
      throw error
    } catch {
      throw LocalVideoTranscriptionError.modelDownloadFailed
    }
  }

  public func transcribe(
    fileURL: URL,
    workspaceURL: URL,
    localeIdentifier: String
  ) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard #available(macOS 26.0, *) else {
            throw LocalVideoTranscriptionError.unsupportedOS
          }
          try Self.validateLocalMedia(fileURL)
          try Task.checkCancellation()
          let audioURL: URL
          if fileURL.pathExtension.lowercased() == "m4a" {
            // Remote-transcription attempts already extracted this transient
            // audio track. Reusing it avoids a second export and stays local.
            audioURL = fileURL
          } else {
            continuation.yield(.extractingAudio)
            audioURL = try await Self.recognitionInputURL(
              from: fileURL,
              workspaceURL: workspaceURL,
              extractAudio: { sourceURL, destinationURL in
                try await Self.extractAudio(from: sourceURL, workspaceURL: destinationURL)
              }
            )
          }

          try Task.checkCancellation()
          continuation.yield(.transcribing)
          let text = try await Self.recognize(
            audioURL: audioURL,
            localeIdentifier: localeIdentifier,
            continuation: continuation
          )
          try Task.checkCancellation()
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { throw LocalVideoTranscriptionError.emptyTranscript }
          continuation.yield(.final(trimmed))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as LocalVideoTranscriptionError {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(throwing: LocalVideoTranscriptionError.recognitionFailed)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private static func validateLocalMedia(_ fileURL: URL) throws {
    guard fileURL.isFileURL,
          ["mp4", "mov", "m4a"].contains(fileURL.pathExtension.lowercased()),
          FileManager.default.fileExists(atPath: fileURL.path)
    else { throw LocalVideoTranscriptionError.invalidLocalFile }
  }

  static func extractedAudioURL(workspaceURL: URL) throws -> URL {
    var isDirectory: ObjCBool = false
    guard workspaceURL.isFileURL,
          FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else { throw LocalVideoTranscriptionError.audioExtractionFailed }
    let outputURL = workspaceURL.appendingPathComponent("extracted-audio.m4a", isDirectory: false)
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
    return outputURL
  }

  /// Failing to export an M4A must not turn a readable video into a dead end.
  /// Speech can open many MP4/MOV containers directly; use that local fallback
  /// and remove any partially written attempt-scoped M4A before continuing.
  static func recognitionInputURL(
    from fileURL: URL,
    workspaceURL: URL,
    extractAudio: @escaping @Sendable (URL, URL) async throws -> URL
  ) async throws -> URL {
    do {
      return try await extractAudio(fileURL, workspaceURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let partial = workspaceURL.appendingPathComponent("extracted-audio.m4a", isDirectory: false)
      try? FileManager.default.removeItem(at: partial)
      return fileURL
    }
  }

  /// Produces attempt-scoped M4A audio for local speech recognition. The
  /// caller owns `workspaceURL` and removes it on every terminal outcome.
  public static func extractAudio(from fileURL: URL, workspaceURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
      throw LocalVideoTranscriptionError.noAudioTrack
    }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
    let outputURL = try extractedAudioURL(workspaceURL: workspaceURL)

    do {
      try await exporter.export(to: outputURL, as: .m4a)
      try Task.checkCancellation()
      return outputURL
    } catch is CancellationError {
      exporter.cancelExport()
      try? FileManager.default.removeItem(at: outputURL)
      throw LocalVideoTranscriptionError.cancelled
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
  }

  @available(macOS 26.0, *)
  private static func recognize(
    audioURL: URL,
    localeIdentifier: String,
    continuation: AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>.Continuation
  ) async throws -> String {
    guard SpeechTranscriber.isAvailable else { throw LocalVideoTranscriptionError.speechUnavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { throw LocalVideoTranscriptionError.chineseLocaleUnavailable }
    let transcriber = Self.makeTranscriber(locale: locale)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw LocalVideoTranscriptionError.modelDownloadFailed
    }

    let audioFile: AVAudioFile
    do { audioFile = try AVAudioFile(forReading: audioURL) }
    catch { throw LocalVideoTranscriptionError.audioExtractionFailed }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let resultsTask = Task { () throws -> String in
      var accumulator = TimedTranscriptionAccumulator()
      // 文件分析比实时播放快得多，volatile 结果每秒可达几十条；逐条重算
      // 全文并推给 UI 会让长转写滚动卡顿。定稿必推，草稿节流到约 3 次/秒。
      var lastPartialYield = ContinuousClock.now - .seconds(1)
      for try await result in transcriber.results {
        try Task.checkCancellation()
        accumulator.merge(
          range: result.range,
          text: String(result.text.characters),
          isFinal: result.isFinal
        )
        let now = ContinuousClock.now
        if result.isFinal || now - lastPartialYield >= .milliseconds(300) {
          lastPartialYield = now
          continuation.yield(.partial(accumulator.displayText))
        }
      }
      return accumulator.finalText
    }

    do {
      try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
      return try await withTaskCancellationHandler {
        try await resultsTask.value
      } onCancel: {
        resultsTask.cancel()
        Task { await analyzer.cancelAndFinishNow() }
      }
    } catch is CancellationError {
      resultsTask.cancel()
      await analyzer.cancelAndFinishNow()
      throw CancellationError()
    } catch {
      resultsTask.cancel()
      await analyzer.cancelAndFinishNow()
      throw LocalVideoTranscriptionError.recognitionFailed
    }
  }
}
