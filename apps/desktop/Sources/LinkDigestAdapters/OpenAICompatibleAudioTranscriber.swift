import AVFoundation
import Foundation
import LinkDigestCore

/// Online fallback for large direct-file captures. AVFoundation reads the
/// remote audio track with the source site's public Referer, exports short M4A
/// chunks locally, and uploads those chunks to `/audio/transcriptions`. The
/// full video and its signed URL are never sent to the model provider.
public final class OpenAICompatibleAudioTranscriber: OnlineAudioTranscribing, @unchecked Sendable {
  private static let chunkDurationSeconds: Double = 300
  private static let maximumDurationSeconds: Double = 7_200
  private static let maximumChunkBytes = 24 * 1_024 * 1_024
  /// 同时在飞的分片上传数。分片之间无依赖，但服务端普遍有速率限制，
  /// 无节制并发会被拒或更慢。
  private static let maximumConcurrentChunkUploads = 3
  /// 单个分片最多尝试 3 次（首次 + 2 次重试）。429 与 5xx 是服务端的临时状态，
  /// 以前一撞上整条转写就失败，用户只能整段重来。
  private static let maximumUploadAttempts = 3
  /// multipart 落盘时的拷贝块大小：音频不再整片进内存。
  private static let uploadCopyBufferBytes = 1 << 20
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
    let delegate = SameOriginAudioRedirectDelegate()
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> String {
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else { throw OnlineAudioTranscriptionError.modelNotConfigured }
    // 已存任务的本机视频文件同样可用：分片提取与上传逻辑完全一致，
    // 只是音频源从远程流换成本地文件。
    guard remoteMediaURL.scheme?.lowercased() == "https" || remoteMediaURL.isFileURL else {
      throw OnlineAudioTranscriptionError.mediaURLInvalid
    }
    let credentials: (profile: ProviderProfile, apiKey: String)
    do {
      // The transcription assignment is independent from the summary model;
      // nil means the user kept the local default and online must not run.
      guard let loaded = try await configurationService.loadTranscriptionCredentials() else {
        throw OnlineAudioTranscriptionError.modelNotConfigured
      }
      credentials = loaded
    } catch let error as OnlineAudioTranscriptionError {
      throw error
    } catch {
      throw OnlineAudioTranscriptionError.modelNotConfigured
    }
    let endpoint: URL
    do { endpoint = try OpenAICompatibleEndpoint.audioTranscriptionsURL(baseURL: credentials.profile.baseURL) }
    catch { throw OnlineAudioTranscriptionError.modelNotConfigured }

    do {
      let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("linkdigest-online-transcription-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: workspace) }
      let asset = Self.remoteAsset(url: remoteMediaURL)
      guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
        // 拆轨源拿错 URL（纯画面轨）就会走到这。绝不能报成"服务拒绝"。
        throw OnlineAudioTranscriptionError.audioExtractionFailed(
          detail: "媒体没有音频轨（host \(remoteMediaURL.host ?? "?")）"
        )
      }
      let duration = CMTimeGetSeconds(try await asset.load(.duration))
      guard duration.isFinite, duration > 0, duration <= Self.maximumDurationSeconds else {
        throw OnlineAudioTranscriptionError.audioExtractionFailed(
          detail: String(format: "时长非法或超限（%.0fs / 上限 %.0fs）", duration, Self.maximumDurationSeconds)
        )
      }
      // 导出一片就上传一片，导出与上传重叠进行。
      //
      // 原来是「所有分片先全部串行导出完，才进 TaskGroup 上传」：导出阶段
      // 进度条一动不动，第一片明明已经就绪却干等最后一片切完。分片总数可以
      // 直接由时长算出，所以进度条的分母从一开始就是准的，不必等导出结束。
      let total = max(1, Int((duration / Self.chunkDurationSeconds).rounded(.up)))
      let apiKey = credentials.apiKey
      let ordered = try await AudioChunkPipeline.run(
        total: total,
        concurrencyLimit: Self.maximumConcurrentChunkUploads,
        progress: progress,
        export: { index in
          let start = Double(index) * Self.chunkDurationSeconds
          let seconds = max(0, min(Self.chunkDurationSeconds, duration - start))
          let chunkURL = workspace.appendingPathComponent("audio-\(index).m4a")
          try await Self.exportAudioChunk(
            asset: asset,
            startSeconds: start,
            durationSeconds: seconds,
            outputURL: chunkURL
          )
          return chunkURL
        },
        upload: { _, chunkURL in
          defer { try? FileManager.default.removeItem(at: chunkURL) }
          do {
            return try await AudioChunkPipeline.retrying(
              maximumAttempts: Self.maximumUploadAttempts,
              isRetryable: { $0 is AudioChunkPipeline.RetryableFailure },
              sleep: { seconds in
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
              }
            ) {
              try await self.uploadChunk(
                chunkURL,
                endpoint: endpoint,
                apiKey: apiKey,
                model: trimmedModel,
                language: language
              )
            }
          } catch is AudioChunkPipeline.RetryableFailure {
            // 重试耗尽后对外语义与以前完全一致，不新增对外可见的错误类型。
            throw OnlineAudioTranscriptionError.responseRejected
          }
        }
      )
      // 结果按分片序号还原，绝不能用完成顺序——那会把文稿打乱。
      let texts = ordered.keys.sorted().compactMap { ordered[$0] }
      let combined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !combined.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
      return combined
    } catch is CancellationError {
      throw OnlineAudioTranscriptionError.cancelled
    } catch let error as OnlineAudioTranscriptionError {
      throw error
    } catch let error as URLError {
      // 只有真正的传输错误才配叫"连接中断"。
      _ = error
      throw OnlineAudioTranscriptionError.networkInterrupted
    } catch {
      // 其余都发生在本机提取阶段（loadTracks / duration 等 AVFoundation 错误），
      // 之前被折叠成"连接中断"，连续掩盖了取错轨和缺 MIME 两个真实缺陷。
      let ns = error as NSError
      throw OnlineAudioTranscriptionError.audioExtractionFailed(
        detail: "\(ns.domain) \(ns.code)"
      )
    }
  }

  private func uploadChunk(
    _ fileURL: URL,
    endpoint: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> String {
    // 只读文件大小属性，不再把整片音频读进内存（24MB × 并发 3 曾经翻倍占用）。
    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let audioBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard audioBytes > 0, audioBytes <= Self.maximumChunkBytes else {
      throw OnlineAudioTranscriptionError.responseRejected
    }
    let boundary = "LinkDigest-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var fields = [
      "model": model,
      "response_format": "json",
    ]
    if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
      fields["language"] = language
    }
    // multipart 前缀 + 音频 + 后缀流式写到临时文件，再从磁盘上传。
    let bodyURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("upload-\(UUID().uuidString).multipart")
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    do {
      try Self.writeMultipartBody(
        boundary: boundary,
        fields: fields,
        audioURL: fileURL,
        outputURL: bodyURL
      )
    } catch {
      // 落盘失败发生在本机，绝不能报成"服务拒绝"或"连接中断"。
      let ns = error as NSError
      throw OnlineAudioTranscriptionError.audioExtractionFailed(
        detail: "上传体落盘失败 \(ns.domain) \(ns.code)"
      )
    }
    let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw OnlineAudioTranscriptionError.networkInterrupted
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw OnlineAudioTranscriptionError.authInvalid
    }
    if http.statusCode == 404 {
      throw OnlineAudioTranscriptionError.providerNotSupported
    }
    // 429 限流和 5xx 是服务端的临时状态，交给重试；其余非 2xx 语义不变。
    if http.statusCode == 429 || (500...599).contains(http.statusCode) {
      throw AudioChunkPipeline.RetryableFailure(statusCode: http.statusCode)
    }
    guard (200...299).contains(http.statusCode), data.count <= 10 * 1_024 * 1_024 else {
      throw OnlineAudioTranscriptionError.responseRejected
    }
    let payload = try JSONDecoder().decode(Response.self, from: data)
    let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
    return text
  }

  /// 把 multipart 请求体流式写到磁盘：前缀、分块拷贝的音频、后缀。
  /// 字节序列与原来的内存拼装完全一致，只是不再让整片音频驻留内存。
  static func writeMultipartBody(
    boundary: String,
    fields: [String: String],
    audioURL: URL,
    outputURL: URL
  ) throws {
    var prefix = Data()
    for key in fields.keys.sorted() {
      guard let value = fields[key], !value.isEmpty else { continue }
      prefix.append(Data("--\(boundary)\r\n".utf8))
      prefix.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
      prefix.append(Data("\(value)\r\n".utf8))
    }
    prefix.append(Data("--\(boundary)\r\n".utf8))
    prefix.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8))
    prefix.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
    let suffix = Data("\r\n--\(boundary)--\r\n".utf8)

    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let writer = try FileHandle(forWritingTo: outputURL)
    defer { try? writer.close() }
    let reader = try FileHandle(forReadingFrom: audioURL)
    defer { try? reader.close() }
    try writer.write(contentsOf: prefix)
    while true {
      guard let block = try reader.read(upToCount: Self.uploadCopyBufferBytes), !block.isEmpty else {
        break
      }
      try writer.write(contentsOf: block)
    }
    try writer.write(contentsOf: suffix)
  }

  private static func remoteAsset(url: URL) -> AVURLAsset {
    guard !url.isFileURL else { return AVURLAsset(url: url) }
    var headers = ["User-Agent": browserUserAgent]
    if let referer = referer(forHost: url.host) { headers["Referer"] = referer }
    // 与播放层同一处理：B 站音轨 `.m4s` 返回 octet-stream，无 MIME 提示时
    // AVFoundation 报 -11828 打不开——提取不到音频，最后被误报成网络中断。
    return StreamingComposition.urlAsset(
      url: url,
      role: .audio,
      httpHeaders: headers,
      applyOutOfBandMIME: true
    )
  }

  private static func referer(forHost host: String?) -> String? {
    guard let host = host?.lowercased() else { return nil }
    if host == "douyin.com" || host.hasSuffix(".douyin.com")
      || host.hasSuffix("douyinvod.com") || host.hasSuffix("douyincdn.com") {
      return "https://www.douyin.com/"
    }
    if host.hasSuffix("qpic.cn") || host.hasSuffix("qlogo.cn") || host.hasSuffix("qq.com") {
      return "https://mp.weixin.qq.com/"
    }
    // 实测 `*.bilivideo.com` 无 Referer 一律 403，带站点根 Referer 即 206。
    if host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
      || host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
      return "https://www.bilibili.com/"
    }
    return nil
  }

  private static func exportAudioChunk(
    asset: AVAsset,
    startSeconds: Double,
    durationSeconds: Double,
    outputURL: URL
  ) async throws {
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw OnlineAudioTranscriptionError.audioExtractionFailed(detail: "无法创建 AppleM4A 导出会话")
    }
    exporter.timeRange = CMTimeRange(
      start: CMTime(seconds: startSeconds, preferredTimescale: 600),
      duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
    )
    do {
      try await exporter.export(to: outputURL, as: .m4a)
      try Task.checkCancellation()
    } catch is CancellationError {
      exporter.cancelExport()
      throw OnlineAudioTranscriptionError.cancelled
    } catch {
      // 本地导出失败曾被映射成"网络中断"——错误域和码必须原样带出来。
      let ns = error as NSError
      throw OnlineAudioTranscriptionError.audioExtractionFailed(
        detail: "export 失败 \(ns.domain) \(ns.code)"
      )
    }
  }

  private struct Response: Decodable { let text: String }
}

/// 分片流水线与上传重试的纯逻辑接缝。
///
/// 真实的 `transcribe()` 调用的就是这两个函数，测试通过注入假的
/// export / upload / sleep 覆盖它们——不要在测试里另写一份等价逻辑，
/// 那样测的是副本，改坏了生产代码测试照样绿。
enum AudioChunkPipeline {
  /// 服务端的临时状态（429 / 5xx）。只在模块内部流动，重试耗尽后由调用方
  /// 翻译成对外的 `responseRejected`，不新增对外可见的错误类型。
  struct RetryableFailure: Error, Sendable {
    let statusCode: Int
  }

  /// 导出一片就上传一片：export 串行（同一个 AVAsset 并行导出没有收益），
  /// upload 并发且在飞数不超过 `concurrencyLimit`，两者重叠进行。
  /// 返回值以分片序号为键，调用方按序号还原，绝不能用完成顺序。
  static func run(
    total: Int,
    concurrencyLimit: Int,
    progress: (@Sendable (Int, Int) -> Void)?,
    export: (Int) async throws -> URL,
    upload: @escaping @Sendable (Int, URL) async throws -> String
  ) async throws -> [Int: String] {
    guard total > 0 else { return [:] }
    let limit = max(1, min(concurrencyLimit, total))
    // 分母一开始就是准的，第一片导出完进度条就能动。
    progress?(0, total)
    return try await withThrowingTaskGroup(of: (Int, String).self) { group in
      var results: [Int: String] = [:]
      var nextIndex = 0
      var inFlight = 0
      var completed = 0
      while nextIndex < total || inFlight > 0 {
        if nextIndex < total, inFlight < limit {
          try Task.checkCancellation()
          let index = nextIndex
          let chunkURL = try await export(index)
          group.addTask {
            let text = try await upload(index, chunkURL)
            return (index, text)
          }
          inFlight += 1
          nextIndex += 1
          continue
        }
        // 在飞数已满或全部导出完毕，先收一片再继续，天然形成背压。
        guard let (finishedIndex, text) = try await group.next() else { break }
        results[finishedIndex] = text
        inFlight -= 1
        completed += 1
        progress?(completed, total)
      }
      return results
    }
  }

  /// 指数退避 + 随机抖动的重试。`sleep` 可注入，测试传一个立即返回的实现，
  /// 不要让测试真的等几秒。取消永远不重试。
  static func retrying<Value>(
    maximumAttempts: Int,
    baseDelaySeconds: Double = 0.8,
    isRetryable: (Error) -> Bool,
    sleep: (Double) async throws -> Void,
    operation: () async throws -> Value
  ) async throws -> Value {
    let attemptLimit = max(1, maximumAttempts)
    var attempt = 1
    while true {
      do {
        return try await operation()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard attempt < attemptLimit, isRetryable(error) else { throw error }
        try Task.checkCancellation()
        // 抖动很关键：限流时几片同时醒来会再撞一次同样的墙。
        let backoff = baseDelaySeconds * pow(2, Double(attempt - 1))
        try await sleep(backoff + Double.random(in: 0...(backoff * 0.5)))
        attempt += 1
      }
    }
  }
}

private final class SameOriginAudioRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let source = response.url, let destination = request.url,
          source.scheme?.lowercased() == destination.scheme?.lowercased(),
          source.host?.lowercased() == destination.host?.lowercased(),
          source.port == destination.port else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
