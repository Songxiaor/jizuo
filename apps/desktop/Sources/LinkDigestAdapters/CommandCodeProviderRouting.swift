import Foundation
import LinkDigestCore

/// Command Code Provider API 的窄路由：只有官方 host + `/provider/v1` 上的 Claude
/// 模型才改走 Anthropic Messages。其它商家、其它模型一律保持 Chat Completions。
enum CommandCodeProviderRouting {
  static let host = "api.commandcode.ai"
  static let apiRootPath = "/provider/v1"

  static func usesAnthropicMessages(baseURL: URL, model: String) -> Bool {
    isCommandCodeProviderRoot(baseURL) && isClaudeModel(model)
  }

  static func isCommandCodeProviderRoot(_ baseURL: URL) -> Bool {
    guard baseURL.host?.lowercased() == host else { return false }
    return normalizedPath(baseURL) == apiRootPath
  }

  /// 官方 Claude ID 为裸 `claude-*`；也容忍 `vendor/claude-…` 末段。
  static func isClaudeModel(_ model: String) -> Bool {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return false }
    let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    return leaf.hasPrefix("claude")
  }

  static func messagesURL(baseURL: URL) throws -> URL {
    try endpointURL(baseURL: baseURL, suffix: "/messages")
  }

  private static func normalizedPath(_ url: URL) -> String {
    var path = url.path
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    return path.isEmpty ? "/" : path
  }

  private static func endpointURL(baseURL: URL, suffix: String) throws -> URL {
    guard
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw ModelProviderFailure(
        code: .baseURLInvalid,
        retryable: false,
        hadOutput: false
      )
    }

    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    if path == "/" { path = "" }
    components.percentEncodedPath = path + suffix

    guard let url = components.url else {
      throw ModelProviderFailure(
        code: .baseURLInvalid,
        retryable: false,
        hadOutput: false
      )
    }
    return url
  }
}
