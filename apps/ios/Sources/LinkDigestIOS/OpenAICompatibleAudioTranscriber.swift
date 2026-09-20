import Foundation
import LinkDigestShared

public enum AudioTranscriberError: Error, LocalizedError, Sendable, Equatable {
  case invalidBaseURL
  case invalidMediaURL
  case unsupportedMediaType(String)
  case downloadFailed(String)
  case httpStatus(Int)
  case emptyTranscript
  case decodingFailed
  case providerMessage(String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Base URL 无效，无法调用音频转写接口。"
    case .invalidMediaURL:
      return "媒体地址无效。"
    case .unsupportedMediaType(let type):
      return "暂不支持该媒体类型（\(type)）。请用 mp3 / m4a / wav / aac，或到 Mac 做完整视频转写。"
    case .downloadFailed(let message):
      return "下载媒体失败：\(message)"
    case .httpStatus(let code):
      return OpenAICompatibleAPI.publicHTTPMessage(status: code)
    case .emptyTranscript:
      return "模型没有返回转写文字。"
    case .decodingFailed:
      return "无法解析转写接口返回的 JSON。"
    case .providerMessage:
      return "模型服务拒绝了这次请求。"
    }
  }
}

/// OpenAI-compatible `/audio/transcriptions`（在线转写）。不含 yt-dlp/ffmpeg。
public struct OpenAICompatibleAudioTranscriber: Sendable {
  public static let supportedExtensions: Set<String> = [
    "mp3", "m4a", "wav", "aac", "ogg", "flac", "webm", "mp4", "mpeg", "mpga",
  ]

  private let session: URLSession
  private let maxBytes: Int

  public init(session: URLSession = .shared, maxBytes: Int = 24 * 1024 * 1024) {
    self.session = session
    self.maxBytes = max(256 * 1024, maxBytes)
  }

  public static func looksLikeDirectMediaURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let ext = url.pathExtension.lowercased().nilIfEmpty
    else {
      return false
    }
    return supportedExtensions.contains(ext)
  }

  public func transcribeRemoteMedia(
    mediaURLString: String,
    baseURL: String,
    model: String,
    apiKey: String,
    languageHint: String? = "zh"
  ) async throws -> String {
    let trimmedMedia = mediaURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let mediaURL = URL(string: trimmedMedia),
          mediaURL.scheme == "http" || mediaURL.scheme == "https"
    else {
      throw AudioTranscriberError.invalidMediaURL
    }
    let ext = mediaURL.pathExtension.lowercased()
    guard Self.supportedExtensions.contains(ext) else {
      throw AudioTranscriberError.unsupportedMediaType(ext.isEmpty ? "未知" : ext)
    }

    let (data, response) = try await session.data(from: mediaURL)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw AudioTranscriberError.downloadFailed("HTTP \(http.statusCode)")
    }
    guard !data.isEmpty else { throw AudioTranscriberError.downloadFailed("空文件") }
    if data.count > maxBytes {
      throw AudioTranscriberError.downloadFailed("文件超过 \(maxBytes / 1024 / 1024)MB 上限")
    }

    let endpoint = try Self.transcriptionsURL(baseURL: baseURL)
    let boundary = "LinkDigestBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var body = Data()
    func append(_ string: String) {
      if let chunk = string.data(using: .utf8) { body.append(chunk) }
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
    append("Content-Type: application/octet-stream\r\n\r\n")
    body.append(data)
    append("\r\n")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    append("\(model.trimmingCharacters(in: .whitespacesAndNewlines))\r\n")
    if let languageHint, !languageHint.isEmpty {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
      append("\(languageHint)\r\n")
    }
    append("--\(boundary)--\r\n")

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 120

    let (respData, resp) = try await session.data(for: request)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    if !(200...299).contains(status) {
      throw AudioTranscriberError.httpStatus(status)
    }

    guard let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
      throw AudioTranscriberError.decodingFailed
    }
    if root["error"] is [String: Any] {
      throw AudioTranscriberError.providerMessage("rejected")
    }
    guard let text = root["text"] as? String else {
      throw AudioTranscriberError.decodingFailed
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AudioTranscriberError.emptyTranscript }
    return trimmed
  }

  public static func transcriptionsURL(baseURL: String) throws -> URL {
    do {
      return try OpenAICompatibleAPI.endpointURL(baseURL: baseURL, kind: .audioTranscriptions)
    } catch {
      throw AudioTranscriberError.invalidBaseURL
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
