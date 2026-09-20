import Foundation

/// Shared OpenAI-compatible URL and error mapping for Mac and iOS.
/// Provider response bodies never become user-visible strings.
public enum OpenAICompatibleAPI {
  public static let lowReasoningEffort = "low"

  public enum EndpointKind: Sendable {
    case chatCompletions
    case models
    case audioTranscriptions
  }

  public static func endpointURL(baseURL: URL, kind: EndpointKind) throws -> URL {
    let suffix: String
    let rejectCompletedChat: Bool
    switch kind {
    case .chatCompletions:
      suffix = "/chat/completions"
      rejectCompletedChat = true
    case .models:
      suffix = "/models"
      rejectCompletedChat = false
    case .audioTranscriptions:
      suffix = "/audio/transcriptions"
      rejectCompletedChat = false
    }
    let normalizedPath = baseURL.path.split(separator: "/").map(String.init)
    if rejectCompletedChat, normalizedPath.suffix(2) == ["chat", "completions"] {
      throw OpenAICompatiblePublicError.invalidBaseURL
    }
    guard
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw OpenAICompatiblePublicError.invalidBaseURL
    }
    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    if path == "/" { path = "" }
    components.percentEncodedPath = path + suffix
    guard let url = components.url else { throw OpenAICompatiblePublicError.invalidBaseURL }
    return url
  }

  public static func endpointURL(baseURL: String, kind: EndpointKind) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      throw OpenAICompatiblePublicError.invalidBaseURL
    }
    return try endpointURL(baseURL: url, kind: kind)
  }

  /// Fixed Chinese copy. Never interpolates provider JSON, HTML, or API keys.
  public static func publicHTTPMessage(status: Int) -> String {
    switch status {
    case 401, 403:
      return "认证失败，请检查 API Key。"
    case 404:
      return "接口不存在，请检查 Base URL。"
    case 429:
      return "请求过于频繁，请稍后再试。"
    case 500...599:
      return "模型服务暂时不可用。"
    default:
      return "模型接口返回 HTTP \(status)。"
    }
  }
}

public enum OpenAICompatiblePublicError: Error, Sendable, Equatable {
  case invalidBaseURL
}
