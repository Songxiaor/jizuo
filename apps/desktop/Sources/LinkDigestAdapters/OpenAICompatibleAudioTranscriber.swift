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

  public func transcribe(remoteMediaURL: URL, model: String, language: String?) async throws -> String {
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
        throw OnlineAudioTranscriptionError.responseRejected
      }
      let duration = CMTimeGetSeconds(try await asset.load(.duration))
      guard duration.isFinite, duration > 0, duration <= Self.maximumDurationSeconds else {
        throw OnlineAudioTranscriptionError.responseRejected
      }
      var texts: [String] = []
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
        let text = try await uploadChunk(
          chunkURL,
          endpoint: endpoint,
          apiKey: credentials.apiKey,
          model: trimmedModel,
          language: language
        )
        texts.append(text)
        try? FileManager.default.removeItem(at: chunkURL)
        start += seconds
        index += 1
      }
      let combined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !combined.isEmpty else { throw OnlineAudioTranscriptionError.emptyTranscript }
      return combined
    } catch is CancellationError {
      throw OnlineAudioTranscriptionError.cancelled
    } catch let error as OnlineAudioTranscriptionError {
      throw error
    } catch {
      throw OnlineAudioTranscriptionError.networkInterrupted
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
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
    return nil
  }

  private static func exportAudioChunk(
    asset: AVAsset,
    startSeconds: Double,
    durationSeconds: Double,
    outputURL: URL
  ) async throws {
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw OnlineAudioTranscriptionError.responseRejected
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
      throw OnlineAudioTranscriptionError.networkInterrupted
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
