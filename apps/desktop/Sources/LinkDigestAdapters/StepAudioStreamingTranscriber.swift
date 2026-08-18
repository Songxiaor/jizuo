import AVFoundation
import Foundation
import LinkDigestCore

/// 阶跃星辰 Step Plan 的流式 ASR 适配器。
///
/// 与 `OpenAICompatibleAudioTranscriber` 走的是**两个不同的接口**，不是同一接口
/// 换参数：那边是 multipart 打到 `/v1/audio/transcriptions`，整片音频发完、服务端
/// 整片跑完才一次性返回；这边是 JSON + base64 打到 `/step_plan/v1/audio/asr/sse`，
/// 服务端边识别边用 SSE 推增量。实测同一段 13 分钟音频，批量端点稳定要 27.8s，
/// 这就是接口差异，调分片大小和并发都填不平。
///
/// 音频用 16kHz 单声道 s16le：这是服务端 ASR 的原生输入，省掉一次重编码，
/// 也省掉服务端的解码。代价是体积——PCM 比 128kbps AAC 大一倍，base64 后再涨
/// 三分之一，所以分片、并发和「边解边发」这三件事在这条路径上都是必需的，
/// 不是锦上添花。
public final class StepAudioStreamingTranscriber: StreamingOnlineAudioTranscribing, @unchecked Sendable {
  /// 服务端限制 `audio.data` 不超过 10MB，算的是 **base64 后的字符数**。
  /// 留一成余量，免得贴着上限被拒后整片重来。
  private static let base64BudgetPerChunk = 9 * 1_024 * 1_024
  private static let maximumDurationSeconds: Double = 7_200
  /// 分片之间没有依赖，并发主要是让上传与服务端识别重叠。
  /// 不敢开太大：Step Plan 有速率限制，被限流比串行更慢。
  private static let maximumConcurrentChunks = 4
  private static let defaultModel = "stepaudio-2.5-asr"
  private static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  private let configurationService: ProviderConfigurationService
  private let session: URLSession

  public init(configurationService: ProviderConfigurationService) {
    self.configurationService = configurationService
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 180
    configuration.timeoutIntervalForResource = 600
    session = URLSession(configuration: configuration)
  }

  /// 只有阶跃自家域名有 `step_plan` 这条路径，其它兼容端点必须回退到批量接口。
  public static func handles(baseURL: URL) -> Bool {
    guard let host = baseURL.host?.lowercased() else { return false }
    return host == "stepfun.com" || host.hasSuffix(".stepfun.com")
      || host == "stepfun.ai" || host.hasSuffix(".stepfun.ai")
  }

  /// SSE 端点不在 `/v1` 下，而是另一个路径根 `/step_plan/v1`，
  /// 所以只能取 baseURL 的 scheme + host 重建，不能在它后面接后缀。
  public static func endpointURL(baseURL: URL) -> URL? {
    var components = URLComponents()
    components.scheme = baseURL.scheme
    components.host = baseURL.host
    components.port = baseURL.port
    components.path = "/step_plan/v1/audio/asr/sse"
    return components.url
  }

  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> String {
    try await transcribe(
      remoteMediaURL: remoteMediaURL,
      model: model,
      language: language,
      progress: progress,
      partialTranscript: nil
    )
  }

  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?,
    partialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String {
    guard remoteMediaURL.scheme?.lowercased() == "https" || remoteMediaURL.isFileURL else {
      throw OnlineAudioTranscriptionError.mediaURLInvalid
    }
    let credentials: (profile: ProviderProfile, apiKey: String)
    do {
      guard let loaded = try await configurationService.loadTranscriptionCredentials() else {
        throw OnlineAudioTranscriptionError.modelNotConfigured
      }
      credentials = loaded
    } catch let error as OnlineAudioTranscriptionError {
      throw error
    } catch {
      throw OnlineAudioTranscriptionError.modelNotConfigured
    }
    guard let endpoint = Self.endpointURL(baseURL: credentials.profile.baseURL) else {
      throw OnlineAudioTranscriptionError.modelNotConfigured
    }
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel

    do {
      let makeAsset: @Sendable () -> AVAsset = { Self.remoteAsset(url: remoteMediaURL) }
      let duration = CMTimeGetSeconds(try await makeAsset().load(.duration))
      guard duration.isFinite, duration > 0, duration <= Self.maximumDurationSeconds else {
        throw OnlineAudioTranscriptionError.audioExtractionFailed(
          detail: String(format: "时长非法或超限（%.0fs / 上限 %.0fs）", duration, Self.maximumDurationSeconds)
        )
      }
      let rawBytesPerChunk = PCMChunkExtractor.rawBytesPerChunk(
        base64Budget: Self.base64BudgetPerChunk
      )
      let estimatedTotal = PCMChunkExtractor.estimatedChunkCount(
        durationSeconds: duration,
        rawBytesPerChunk: rawBytesPerChunk
      )

      let collector = PartialTranscriptCollector(onAdvance: partialTranscript)
      let stream = PCMChunkExtractor.chunks(
        makeAsset: makeAsset,
        rawBytesPerChunk: rawBytesPerChunk
      )

      let ordered = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [Int: String] in
        var results: [Int: String] = [:]
        var inFlight = 0
        var completed = 0
        var produced = 0
        var announcedStart = false

        for try await chunk in stream {
          // 第一片一解出来就算进入上传段：流水线之后不存在「全部切完」
          // 这个时刻了，而调用方的分段计时要靠这一声来划界。
          if !announcedStart {
            progress?(0, estimatedTotal)
            announcedStart = true
          }
          if inFlight >= Self.maximumConcurrentChunks, let (index, text) = try await group.next() {
            results[index] = text
            completed += 1
            inFlight -= 1
            progress?(completed, max(estimatedTotal, produced))
            await collector.commit(index: index, text: text)
          }
          let index = chunk.index
          let data = chunk.data
          group.addTask {
            let text = try await self.transcribeChunk(
              pcm: data,
              endpoint: endpoint,
              apiKey: credentials.apiKey,
              model: resolvedModel,
              language: language,
              onDelta: { await collector.append(index: index, delta: $0) }
            )
            return (index, text)
          }
          inFlight += 1
          produced += 1
        }
        if !announcedStart { progress?(0, estimatedTotal) }

        while let (index, text) = try await group.next() {
          results[index] = text
          completed += 1
          progress?(completed, max(produced, completed))
          await collector.commit(index: index, text: text)
        }
        return results
      }

      // 按分片序号还原，绝不能用完成顺序——那会把文稿打乱。
      let combined = ordered.keys.sorted()
        .compactMap { ordered[$0] }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !combined.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
      await collector.flush()
      return combined
    } catch is CancellationError {
      throw OnlineAudioTranscriptionError.cancelled
    } catch let error as OnlineAudioTranscriptionError {
      throw error
    } catch let error as URLError {
      _ = error
      throw OnlineAudioTranscriptionError.networkInterrupted
    } catch {
      let ns = error as NSError
      throw OnlineAudioTranscriptionError.audioExtractionFailed(detail: "\(ns.domain) \(ns.code)")
    }
  }

  private func transcribeChunk(
    pcm: Data,
    endpoint: URL,
    apiKey: String,
    model: String,
    language: String?,
    onDelta: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let encoded = pcm.base64EncodedString()
    guard !encoded.isEmpty else { throw OnlineAudioTranscriptionError.responseRejected }
    guard encoded.utf8.count <= 10 * 1_024 * 1_024 else {
      throw OnlineAudioTranscriptionError.providerRejected(
        detail: "音频分片超过服务端 10MB 上限（\(encoded.utf8.count) 字符）"
      )
    }
    let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
    let body: [String: Any] = [
      "audio": [
        "data": encoded,
        "input": [
          "transcription": [
            "language": (trimmedLanguage?.isEmpty == false ? trimmedLanguage! : "zh"),
            "model": model,
            "enable_itn": true,
            // 时间戳我们不用，关掉能少传一截，也少一份服务端开销。
            "enable_timestamp": false,
          ],
          "format": [
            "type": "pcm",
            "codec": "pcm_s16le",
            "rate": PCMChunkExtractor.sampleRate,
            "bits": 16,
            "channel": 1,
          ],
        ],
      ],
    ]

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OnlineAudioTranscriptionError.networkInterrupted
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw OnlineAudioTranscriptionError.authInvalid
    }
    if http.statusCode == 404 {
      throw OnlineAudioTranscriptionError.providerNotSupported
    }
    guard (200...299).contains(http.statusCode) else {
      throw OnlineAudioTranscriptionError.providerRejected(
        detail: await Self.errorDetail(status: http.statusCode, bytes: bytes)
      )
    }

    var accumulated = ""
    var finalText: String?
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard !payload.isEmpty, payload != "[DONE]" else { continue }
      guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
      else { continue }
      switch object["type"] as? String {
      case "transcript.text.delta":
        guard let delta = object["delta"] as? String, !delta.isEmpty else { continue }
        accumulated += delta
        await onDelta(delta)
      case "transcript.text.done":
        finalText = (object["text"] as? String) ?? accumulated
      case "error":
        throw OnlineAudioTranscriptionError.providerRejected(
          detail: Self.truncated((object["message"] as? String) ?? "服务端返回识别错误")
        )
      default:
        continue
      }
    }
    let text = (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
    return text
  }

  /// 错误体也是从字节流读的：请求已经用 `bytes(for:)` 发出去了，
  /// 这时没有现成的 `Data` 可用。只读前若干行，避免服务端吐超长内容。
  private static func errorDetail(status: Int, bytes: URLSession.AsyncBytes) async -> String {
    let collected = (try? await collectLines(bytes, limit: 8)) ?? ""
    let message = parseErrorMessage(collected) ?? collected
    let trimmed = truncated(message.trimmingCharacters(in: .whitespacesAndNewlines))
    return trimmed.isEmpty ? "HTTP \(status)" : "HTTP \(status)：\(trimmed)"
  }

  private static func collectLines(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
    var lines: [String] = []
    for try await line in bytes.lines {
      lines.append(line)
      if lines.count >= limit { break }
    }
    return lines.joined(separator: " ")
  }

  private static func parseErrorMessage(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let error = object["error"] as? [String: Any] {
      return error["message"] as? String
    }
    return object["message"] as? String
  }

  private static func truncated(_ text: String, limit: Int = 200) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…"
  }

  private static func remoteAsset(url: URL) -> AVURLAsset {
    guard !url.isFileURL else { return AVURLAsset(url: url) }
    var headers = ["User-Agent": browserUserAgent]
    if let host = url.host?.lowercased(),
       host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
       || host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
      headers["Referer"] = "https://www.bilibili.com/"
    }
    return StreamingComposition.urlAsset(
      url: url,
      role: .audio,
      httpHeaders: headers,
      applyOutOfBandMIME: true
    )
  }
}

/// 把并发到达的增量整理成「从头开始连续可用的前缀」。
///
/// 分片是并发跑的，第 2 片可能先出字。直接把增量按到达顺序拼给用户，
/// 读到的就是错乱的文稿。这里只推进 0..k 这段连续可用的部分，
/// 第 0 片没完成前，后面片的文字一个字都不往外放。
actor PartialTranscriptCollector {
  private var deltas: [Int: String] = [:]
  private var finished: [Int: String] = [:]
  private let onAdvance: (@Sendable (String) -> Void)?
  private let publishInterval: Duration
  private var lastPublished: String?
  private var pendingPublish: Task<Void, Never>?

  init(
    onAdvance: (@Sendable (String) -> Void)?,
    publishInterval: Duration = .milliseconds(250)
  ) {
    self.onAdvance = onAdvance
    self.publishInterval = publishInterval
  }

  func append(index: Int, delta: String) {
    guard onAdvance != nil else { return }
    deltas[index, default: ""] += delta
    schedulePublish()
  }

  func commit(index: Int, text: String) {
    guard onAdvance != nil else { return }
    finished[index] = text
    deltas[index] = text
    schedulePublish()
  }

  /// 完成时不等节流时钟，确保 UI 能收到最后一段连续前缀。
  func flush() {
    pendingPublish?.cancel()
    pendingPublish = nil
    publishNow()
  }

  private func schedulePublish() {
    // 第一行立即出现；后面的 token 合并到固定刷新拍点。测试可传 .zero
    // 验证每一步的分片顺序，而生产默认不会逐 token 重绘窗口。
    if lastPublished == nil || publishInterval == .zero {
      publishNow()
      return
    }
    guard pendingPublish == nil else { return }
    let delay = publishInterval
    pendingPublish = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.publishScheduled()
    }
  }

  private func publishScheduled() {
    pendingPublish = nil
    publishNow()
  }

  private func publishNow() {
    guard let onAdvance else { return }
    var parts: [String] = []
    var index = 0
    while let piece = deltas[index] {
      parts.append(piece)
      // 停在第一个「还没完成」的分片：它后面的分片即使已经有字，
      // 位置也还不确定，放出去就是乱序。
      if finished[index] == nil { break }
      index += 1
    }
    guard !parts.isEmpty else { return }
    let value = parts.joined(separator: "\n")
    guard value != lastPublished else { return }
    lastPublished = value
    onAdvance(value)
  }
}
