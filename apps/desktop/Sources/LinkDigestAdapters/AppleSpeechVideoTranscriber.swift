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

  /// 探测只听开头这么久。实测 130 秒音频识别耗时 3.2 秒（约 40 倍实时），
  /// 60 秒足够判出语种，两个候选加起来也只要几秒。
  static let localeProbeDurationSeconds: Double = 60

  /// 听一小段，挑一个真的对得上音频的 locale。
  ///
  /// 判据见 `CapturedContentLanguage.isPlausibleTranscript`：指错 locale 时
  /// Apple 的输出有两种彻底的坏法（吐异种文字碎片、或直接吐空），两种都能判出来。
  ///
  /// 全程只读已安装的模型：探测阶段静默下载模型会把一次「点了转写」变成
  /// 几百 MB 的后台流量，安装必须留在用户明确确认的那条路径上。
  public func detectLocale(
    fileURL: URL,
    workspaceURL: URL,
    preferred: String,
    fallbacks: [String]
  ) async -> String {
    guard #available(macOS 26.0, *) else { return preferred }

    // 候选按「先信调用方的猜测」排序，猜对时第一次探测就命中，不多花时间。
    var candidates: [String] = []
    for candidate in [preferred] + fallbacks where !candidates.contains(candidate) {
      candidates.append(candidate)
    }

    let probeURL: URL
    do {
      probeURL = try await Self.extractProbeAudio(from: fileURL, workspaceURL: workspaceURL)
    } catch {
      // 探测取不到音频不该拦住正片；照旧用猜测值走原路径，由它去报真正的错。
      return preferred
    }
    defer { try? FileManager.default.removeItem(at: probeURL) }

    for candidate in candidates {
      if Task.isCancelled { return preferred }
      guard await Self.isModelInstalled(candidate) else { continue }
      guard let sample = try? await Self.recognizeProbe(audioURL: probeURL, localeIdentifier: candidate) else {
        continue
      }
      if CapturedContentLanguage.isPlausibleTranscript(sample, forLocaleIdentifier: candidate) {
        return candidate
      }
    }

    // 一个都说不通（可能是纯音乐、无人声、或候选之外的语种）。回到猜测值，
    // 结果不会比没有探测更差。
    return preferred
  }

  /// 开头一小段音频，只服务于探测。与正片的 `extracted-audio.m4a` 分开命名，
  /// 免得两者互相顶掉。
  static func extractProbeAudio(from fileURL: URL, workspaceURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
      throw LocalVideoTranscriptionError.noAudioTrack
    }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
    let outputURL = workspaceURL.appendingPathComponent("locale-probe.m4a", isDirectory: false)
    try? FileManager.default.removeItem(at: outputURL)

    let duration = try await asset.load(.duration)
    let probeSeconds = min(localeProbeDurationSeconds, CMTimeGetSeconds(duration))
    exporter.timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: max(1, probeSeconds), preferredTimescale: 600)
    )
    do {
      try await exporter.export(to: outputURL, as: .m4a)
      return outputURL
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
  }

  /// 这台机器上装了这个语言的模型没有。
  ///
  /// **不能用 `AssetInventory.status` 判断**：它答的是「**当前进程**有没有占用
  /// 这个 locale」，而不是「机器上装没装」。实测同一台装好 en_US 的机器上，
  /// 一个没占用过它的进程问 status 得到的是 `.supported` 而不是 `.installed`；
  /// 照它设闸会把所有候选全判成「要下载」而跳过，探测于是永远回落到猜测值——
  /// 也就是等于没探测。`installedLocales` 答的才是系统维度的事实。
  @available(macOS 26.0, *)
  static func isModelInstalled(_ localeIdentifier: String) async -> Bool {
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { return false }
    let installed = await SpeechTranscriber.installedLocales
    return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
  }

  /// 探测用的识别：只要最终文本，不报进度、不累计时间轴。
  @available(macOS 26.0, *)
  static func recognizeProbe(audioURL: URL, localeIdentifier: String) async throws -> String {
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { throw LocalVideoTranscriptionError.chineseLocaleUnavailable }
    let transcriber = Self.makeTranscriber(locale: locale)
    guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task { () throws -> String in
      var text = ""
      for try await result in transcriber.results where result.isFinal {
        text += String(result.text.characters)
      }
      return text
    }
    do {
      try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
      return try await collector.value
    } catch {
      collector.cancel()
      await analyzer.cancelAndFinishNow()
      throw LocalVideoTranscriptionError.recognitionFailed
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
