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

  /// 这次请求走不走 Anthropic Messages：服务商协议选了 Anthropic，或者是 Command Code 上的 Claude。
  static func usesAnthropicMessages(profile: ProviderProfile, model: String) -> Bool {
    profile.apiMode == .anthropicMessages || usesAnthropicMessages(baseURL: profile.baseURL, model: model)
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

  /// 各家文档给的 Anthropic 地址多半不带 `/v1`（`https://api.deepseek.com/anthropic`，Claude Code
  /// 自己补 `/v1/messages`）；Anthropic 官方、Magpie、Command Code 给的带 `/v1`。两种都认。
  static func messagesURL(baseURL: URL) throws -> URL {
    try endpointURL(baseURL: baseURL, suffix: versionedSuffix(baseURL, "/messages"))
  }

  /// Anthropic 的模型列表。默认一页只有 20 个，要一次拿全。
  static func modelsURL(baseURL: URL) throws -> URL {
    let url = try endpointURL(baseURL: baseURL, suffix: versionedSuffix(baseURL, "/models"))
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
    return components.url ?? url
  }

  private static func versionedSuffix(_ baseURL: URL, _ suffix: String) -> String {
    normalizedPath(baseURL).split(separator: "/").last == "v1" ? suffix : "/v1" + suffix
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
