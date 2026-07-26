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
      // 先切好所有分片，再并发上传。
      //
      // 原来是「导出一片 → 上传一片 → 等返回 → 再导出下一片」全串行：
      // 13 分钟音频切 3 片，每片 ASR 几十秒，串起来就是几分钟，而分片之间
      // 本来毫无依赖。导出针对的是已落地的本地文件，很快；真正的耗时在
      // 逐片等服务端返回，所以并发这一段收益最大。
      var plan: [(index: Int, url: URL)] = []
      var start = 0.0
      var index = 0
      while start < duration {
        try Task.checkCancellation()
        let seconds = min(Self.chunkDurationSeconds, duration - start)
        let chunkURL = workspace.appendingPathComponent("audio-\(index).m4a")
        try await Self.exportAudioChunk(
          asset: asset,
          startSeconds: start,
          durationSeconds: seconds,
          outputURL: chunkURL
        )
        plan.append((index, chunkURL))
        start += seconds
        index += 1
      }
      let total = plan.count
      progress?(0, total)

      let ordered = try await withThrowingTaskGroup(
        of: (Int, String).self
      ) { group -> [Int: String] in
        var results: [Int: String] = [:]
        var next = 0
        var completed = 0
        // 限制在飞请求数：服务端普遍有速率限制，无节制并发反而更慢或被拒。
        let limit = min(Self.maximumConcurrentChunkUploads, total)
        func addTask(_ item: (index: Int, url: URL)) {
          group.addTask {
            let text = try await self.uploadChunk(
              item.url,
              endpoint: endpoint,
              apiKey: credentials.apiKey,
              model: trimmedModel,
              language: language
            )
            try? FileManager.default.removeItem(at: item.url)
            return (item.index, text)
          }
        }
        while next < limit {
          addTask(plan[next])
          next += 1
        }
        while let (finishedIndex, text) = try await group.next() {
          results[finishedIndex] = text
          completed += 1
          progress?(completed, total)
          if next < total {
            addTask(plan[next])
            next += 1
          }
        }
        return results
      }
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
    let audio = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard !audio.isEmpty, audio.count <= Self.maximumChunkBytes else {
      throw OnlineAudioTranscriptionError.responseRejected
    }
    let boundary = "LinkDigest-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Self.multipartBody(
      boundary: boundary,
      fields: [
        "model": model,
        "response_format": "json",
        "language": language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      ],
      audio: audio
    )
    let (data, response) = try await session.data(for: request)
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
    guard (200...299).contains(http.statusCode), data.count <= 10 * 1_024 * 1_024 else {
      throw OnlineAudioTranscriptionError.responseRejected
    }
    let payload = try JSONDecoder().decode(Response.self, from: data)
    let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
    return text
  }

  private static func multipartBody(boundary: String, fields: [String: String], audio: Data) -> Data {
    var body = Data()
    for key in fields.keys.sorted() {
      guard let value = fields[key], !value.isEmpty else { continue }
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
      body.append(Data("\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8))
    body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
    body.append(audio)
    body.append(Data("\r\n".utf8))
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
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
