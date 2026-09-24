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
          let recognized = try await Self.recognize(
            audioURL: audioURL,
            workspaceURL: workspaceURL,
            localeIdentifier: localeIdentifier,
            continuation: continuation
          )
          try Task.checkCancellation()
          let trimmed = recognized.text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { throw LocalVideoTranscriptionError.emptyTranscript }
          continuation.yield(.final(trimmed))
          // 紧跟在 .final 之后：接收方先拿到正文（落库要用），再拿到时间。
          if !recognized.paragraphs.isEmpty {
            continuation.yield(.finalParagraphs(recognized.paragraphs))
          }
          if !recognized.phrases.isEmpty {
            continuation.yield(.finalPhrases(recognized.phrases))
          }
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
  /// 本机分说话人用：重新识别一遍，返回带时间的短语（每个定稿结果按 `audioTimeRange`
  /// 拆成若干片）。存下来的转写分段太粗（常常一整段对话只有一个时间码），换人的位置
  /// 落在段落中间就分不开；短语级的时间才能按说话人切开（2026-09-23）。
  public func recognizeTimedPhrases(
    fileURL: URL,
    workspaceURL: URL,
    localeIdentifier: String
  ) async throws -> [SpeakerSegment] {
    guard #available(macOS 26.0, *) else { throw LocalVideoTranscriptionError.unsupportedOS }
    guard SpeechTranscriber.isAvailable else { throw LocalVideoTranscriptionError.speechUnavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { throw LocalVideoTranscriptionError.chineseLocaleUnavailable }
    let audioURL = fileURL.pathExtension.lowercased() == "m4a"
      ? fileURL
      : try await Self.extractAudio(from: fileURL, workspaceURL: workspaceURL)
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
    )
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw LocalVideoTranscriptionError.modelDownloadFailed
    }
    let audioFile: AVAudioFile
    do { audioFile = try AVAudioFile(forReading: audioURL) }
    catch { throw LocalVideoTranscriptionError.audioExtractionFailed }
    // 分说话人要把整段再听一遍，同样分段并行；失败退回整段。
    let chunkCount = Self.parallelChunkCount(durationSeconds: Self.durationSeconds(of: audioFile))
    if chunkCount > 1 {
      do {
        var phrases: [SpeakerSegment] = []
        let stream = Self.parallelTimedResults(
          audioURL: audioURL, audioFile: audioFile, workspaceURL: workspaceURL,
          locale: locale, chunkCount: chunkCount
        )
        for try await result in stream where result.isFinal { phrases += result.phrases }
        return phrases.sorted { $0.startSeconds < $1.startSeconds }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
      }
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task { () throws -> [SpeakerSegment] in
      var phrases: [SpeakerSegment] = []
      for try await result in transcriber.results where result.isFinal {
        phrases += Self.timedPhrases(in: result)
      }
      return phrases
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

  // MARK: - 分段并行识别

  /// 分段并行识别（2026-09-24）。
  ///
  /// 实测：同一段 9 分钟中文音频，整段识别 12.0 秒；在停顿处切成 4 段同时识别 4.1 秒，
  /// 切成 8 段也还是 4 秒——系统语音引擎单路远没吃满这台机器，四路左右到顶。
  /// 切点选在名义切点前后最安静的地方，逐字比对切口前后与整段识别一致、没有丢字；
  /// 全文差异是标点和个别同音字，两边各有对错，质量相当。
  ///
  /// 短音频不切：两分半以内整段识别本来就只要几秒，切段的准备成本不划算。
  static let parallelMinimumSeconds: Double = 150
  static let maximumParallelChunks = 4
  /// 每段大约多长。9 分钟切 4 段，3 分钟切 2 段。
  static let targetChunkSeconds: Double = 90
  /// 在名义切点前后多远的范围里找停顿。
  static let boundarySearchSeconds: Double = 8

  static func parallelChunkCount(durationSeconds: Double) -> Int {
    guard durationSeconds.isFinite, durationSeconds >= parallelMinimumSeconds else { return 1 }
    let wanted = Int((durationSeconds / targetChunkSeconds).rounded(.up))
    return min(maximumParallelChunks, max(2, wanted))
  }

  static func durationSeconds(of file: AVAudioFile) -> Double {
    let rate = file.processingFormat.sampleRate
    guard rate > 0 else { return 0 }
    return Double(file.length) / rate
  }

  /// 切点：每个名义切点前后 `boundarySearchSeconds` 内，能量最低的 100ms 的中点。
  /// 读不出样本时退回名义切点（切在句中只是多错一两个字，不影响能用）。
  static func chunkBoundaries(file: AVAudioFile, count: Int) -> [Double] {
    let total = durationSeconds(of: file)
    guard count > 1, total > 0 else { return [0, total] }
    let rate = file.processingFormat.sampleRate
    var bounds: [Double] = [0]
    for index in 1..<count {
      let nominal = total * Double(index) / Double(count)
      bounds.append(quietestPoint(in: file, around: nominal, total: total, rate: rate) ?? nominal)
    }
    bounds.append(total)
    return bounds
  }

  private static func quietestPoint(in file: AVAudioFile, around nominal: Double, total: Double, rate: Double) -> Double? {
    let lower = max(0, nominal - boundarySearchSeconds)
    let upper = min(total, nominal + boundarySearchSeconds)
    let frames = AVAudioFrameCount(max(0, (upper - lower) * rate))
    guard frames > 0,
          file.processingFormat.commonFormat == .pcmFormatFloat32,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
    else { return nil }
    do {
      file.framePosition = AVAudioFramePosition(lower * rate)
      try file.read(into: buffer, frameCount: frames)
    } catch { return nil }
    guard let samples = buffer.floatChannelData?[0] else { return nil }
    let window = max(1, Int(0.1 * rate))
    let length = Int(buffer.frameLength)
    guard length >= window else { return nil }
    var best: Double?
    var bestEnergy = Float.greatestFiniteMagnitude
    var start = 0
    while start + window <= length {
      var energy: Float = 0
      for offset in start..<(start + window) { energy += samples[offset] * samples[offset] }
      if energy < bestEnergy {
        bestEnergy = energy
        best = lower + (Double(start) + Double(window) / 2) / rate
      }
      start += window / 2
    }
    return best
  }

  /// 一条识别结果，时间已经换算回整段音频的时间轴。
  struct TimedResult: Sendable {
    let range: CMTimeRange
    let text: String
    let isFinal: Bool
    let phrases: [SpeakerSegment]
  }

  @available(macOS 26.0, *)
  private static func recognizeInParallel(
    audioURL: URL,
    audioFile: AVAudioFile,
    workspaceURL: URL,
    locale: Locale,
    chunkCount: Int,
    continuation: AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>.Continuation
  ) async throws -> (text: String, paragraphs: [TranscriptParagraph], phrases: [SpeakerSegment]) {
    var accumulator = TimedTranscriptionAccumulator()
    var phrases: [SpeakerSegment] = []
    // 四路同时出结果，界面刷新统一节流到约 3 次/秒。
    var lastPartialYield = ContinuousClock.now - .seconds(1)
    let stream = parallelTimedResults(
      audioURL: audioURL, audioFile: audioFile, workspaceURL: workspaceURL,
      locale: locale, chunkCount: chunkCount
    )
    for try await result in stream {
      try Task.checkCancellation()
      accumulator.merge(range: result.range, text: result.text, isFinal: result.isFinal)
      if result.isFinal { phrases += result.phrases }
      let now = ContinuousClock.now
      if now - lastPartialYield >= .milliseconds(300) {
        lastPartialYield = now
        continuation.yield(.partial(accumulator.displayText))
      }
    }
    phrases.sort { $0.startSeconds < $1.startSeconds }
    return (accumulator.finalText, accumulator.finalParagraphs, phrases)
  }

  /// 切段、并行识别，把各段结果（已换算到整段时间轴）汇成一个流。
  ///
  /// 分段识别只要定稿结果：各段都很快跑完，草稿结果只会把事件量放大上百倍
  /// （实测 9 分钟音频 3225 条对 30 条），最终文本完全一样。
  @available(macOS 26.0, *)
  static func parallelTimedResults(
    audioURL: URL,
    audioFile: AVAudioFile,
    workspaceURL: URL,
    locale: Locale,
    chunkCount: Int
  ) -> AsyncThrowingStream<TimedResult, Error> {
    let bounds = chunkBoundaries(file: audioFile, count: chunkCount)
    let (stream, output) = AsyncThrowingStream<TimedResult, Error>.makeStream()
    let producer = Task {
      var chunkURLs: [URL] = []
      defer { for url in chunkURLs { try? FileManager.default.removeItem(at: url) } }
      do {
        for index in 0..<(bounds.count - 1) {
          chunkURLs.append(workspaceURL.appendingPathComponent("parallel-chunk-\(index).m4a", isDirectory: false))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
          for index in chunkURLs.indices {
            let start = bounds[index], end = bounds[index + 1]
            let url = chunkURLs[index]
            group.addTask {
              try await exportChunk(from: audioURL, start: start, duration: end - start, to: url)
              try await recognizeChunk(url: url, offsetSeconds: start, locale: locale) { output.yield($0) }
            }
          }
          try await group.waitForAll()
        }
        output.finish()
      } catch {
        output.finish(throwing: error)
      }
    }
    output.onTermination = { @Sendable _ in producer.cancel() }
    return stream
  }

  private static func exportChunk(from audioURL: URL, start: Double, duration: Double, to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: audioURL), presetName: AVAssetExportPresetAppleM4A) else {
      throw LocalVideoTranscriptionError.audioExtractionFailed
    }
    exporter.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 44_100),
      duration: CMTime(seconds: max(0.1, duration), preferredTimescale: 44_100)
    )
    try await exporter.export(to: url, as: .m4a)
  }

  @available(macOS 26.0, *)
  private static func recognizeChunk(
    url: URL,
    offsetSeconds: Double,
    locale: Locale,
    emit: @escaping @Sendable (TimedResult) -> Void
  ) async throws {
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
    )
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let offset = CMTime(seconds: offsetSeconds, preferredTimescale: 600)
    let collector = Task { () throws in
      for try await result in transcriber.results {
        try Task.checkCancellation()
        let range = CMTimeRange(start: CMTimeAdd(result.range.start, offset), duration: result.range.duration)
        let phrases = result.isFinal
          ? timedPhrases(in: result).map {
            SpeakerSegment(
              startSeconds: $0.startSeconds + offsetSeconds,
              endSeconds: $0.endSeconds + offsetSeconds,
              speaker: $0.speaker,
              text: $0.text
            )
          }
          : []
        emit(TimedResult(range: range, text: String(result.text.characters), isFinal: result.isFinal, phrases: phrases))
      }
    }
    do {
      try await withTaskCancellationHandler {
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await collector.value
      } onCancel: {
        collector.cancel()
        Task { await analyzer.cancelAndFinishNow() }
      }
    } catch {
      collector.cancel()
      await analyzer.cancelAndFinishNow()
      throw error
    }
  }

  /// 一条定稿结果按 `audioTimeRange` 拆成若干带时间的短语。
  @available(macOS 26.0, *)
  private static func timedPhrases(in result: SpeechTranscriber.Result) -> [SpeakerSegment] {
    var phrases: [SpeakerSegment] = []
    for run in result.text.runs {
      let piece = String(result.text[run.range].characters)
      guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let range = run.audioTimeRange ?? result.range
      let start = CMTimeGetSeconds(range.start)
      let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
      guard start.isFinite, end.isFinite else { continue }
      phrases.append(SpeakerSegment(startSeconds: start, endSeconds: end, speaker: "", text: piece))
    }
    return phrases
  }

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

    var rejectedSamples: [String] = []
    for candidate in candidates {
      if Task.isCancelled { return preferred }
      guard await Self.isModelInstalled(candidate) else { continue }
      guard let sample = try? await Self.recognizeProbe(audioURL: probeURL, localeIdentifier: candidate) else {
        continue
      }
      if CapturedContentLanguage.isPlausibleTranscript(sample, forLocaleIdentifier: candidate) {
        return candidate
      }
      rejectedSamples.append(sample)
    }

    // 听过的都对不上，但某次听写**本身**已经露出了真实语种（例：中文模型听英文讲座，
    // 吐的是一串拉丁字母碎片），而那个语种的模型还没装——就选它，交给调用方现成的
    // 「需要下载模型」确认。原来这里悄悄退回猜测值：没装英文模型的机器上，英文视频
    // 一律按中文转写，整篇乱码一路流到翻译（2026-09-24 实库 9 月 1 日的记录即此）。
    // 下载仍由用户确认，这里不触发任何下载。
    if let hinted = Self.installableHint(from: rejectedSamples, candidates: candidates),
       !(await Self.isModelInstalled(hinted)) {
      return hinted
    }

    // 一个都说不通（可能是纯音乐、无人声、或候选之外的语种）。回到猜测值，
    // 结果不会比没有探测更差。
    return preferred
  }

  /// 被判「对不上」的听写里，若主体文字清楚指向某个候选语种，返回它。
  /// 空输出、判不出主体文字的，不作数——纯音乐不该把人引去下载模型。
  static func installableHint(from rejectedSamples: [String], candidates: [String]) -> String? {
    for sample in rejectedSamples {
      guard CapturedContentLanguage.detect(in: sample) != nil else { continue }
      let hinted = CapturedContentLanguage.speechLocaleIdentifier(in: sample)
      if candidates.contains(hinted) { return hinted }
    }
    return nil
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
    workspaceURL: URL,
    localeIdentifier: String,
    continuation: AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>.Continuation
  ) async throws -> (text: String, paragraphs: [TranscriptParagraph], phrases: [SpeakerSegment]) {
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

    // 长音频分段并行识别；任何一段出问题都退回下面的整段识别，不让提速变成失败。
    let chunkCount = Self.parallelChunkCount(durationSeconds: Self.durationSeconds(of: audioFile))
    if chunkCount > 1 {
      do {
        return try await Self.recognizeInParallel(
          audioURL: audioURL,
          audioFile: audioFile,
          workspaceURL: workspaceURL,
          locale: locale,
          chunkCount: chunkCount,
          continuation: continuation
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
      }
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let resultsTask = Task { () throws -> (text: String, paragraphs: [TranscriptParagraph], phrases: [SpeakerSegment]) in
      var accumulator = TimedTranscriptionAccumulator()
      var phrases: [SpeakerSegment] = []
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
        if result.isFinal { phrases += Self.timedPhrases(in: result) }
        let now = ContinuousClock.now
        if result.isFinal || now - lastPartialYield >= .milliseconds(300) {
          lastPartialYield = now
          continuation.yield(.partial(accumulator.displayText))
        }
      }
      return (accumulator.finalText, accumulator.finalParagraphs, phrases)
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
