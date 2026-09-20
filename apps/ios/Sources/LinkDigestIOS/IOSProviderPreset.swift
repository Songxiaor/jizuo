import Foundation

/// iOS Companion 的服务商快捷预设（只填 Base URL / 推荐模型，不带 Key）。
public enum IOSProviderPreset: String, CaseIterable, Identifiable, Sendable {
  case openCodeGo
  case openCodeZen
  case openAI
  case deepSeek
  case openRouter
  case siliconFlow
  case custom

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .openCodeGo: "OpenCode Go（订阅）"
    case .openCodeZen: "OpenCode Zen（按量）"
    case .openAI: "OpenAI"
    case .deepSeek: "DeepSeek"
    case .openRouter: "OpenRouter"
    case .siliconFlow: "SiliconFlow"
    case .custom: "自定义"
    }
  }

  public var baseURL: String {
    switch self {
    case .openCodeGo: "https://opencode.ai/zen/go/v1"
    case .openCodeZen: "https://opencode.ai/zen/v1"
    case .openAI: "https://api.openai.com/v1"
    case .deepSeek: "https://api.deepseek.com/v1"
    case .openRouter: "https://openrouter.ai/api/v1"
    case .siliconFlow: "https://api.siliconflow.cn/v1"
    case .custom: ""
    }
  }

  /// 推荐聊天模型；用户仍可改。
  /// Go 必须填官方模型 ID（见 https://opencode.ai/zen/go/v1/models）；
  /// 且 iOS 目前只走 `/chat/completions`，不要填只支持 responses/messages 的模型。
  public var recommendedModel: String? {
    switch self {
    case .openCodeGo: "glm-5.3-flash"
    case .openCodeZen: "glm-5.3-flash"
    case .openAI: "gpt-4o-mini"
    case .deepSeek: "deepseek-chat"
    case .openRouter: "openai/gpt-4o-mini"
    case .siliconFlow: "Qwen/Qwen2.5-7B-Instruct"
    case .custom: nil
    }
  }

  public var footerHint: String {
    switch self {
    case .openCodeGo:
      return "Go 是订阅通道，端点必须是 /zen/go/v1。模型名填官方 ID（如 glm-5.3-flash、deepseek-v4-flash、kimi-k2.6），不要填 gpt-5。误用 /zen/v1 常会看到 401 CreditsError。"
    case .openCodeZen:
      return "Zen 是按量付费通道（/zen/v1），和 Go 订阅不是同一个地址。模型名同样要用 Zen 目录里的 ID。"
    case .custom:
      return "填写 OpenAI-compatible 根地址，不要带 /chat/completions。"
    default:
      return "API Key 只保存在本机钥匙串，不会同步。"
    }
  }

  public static func matching(baseURL: String) -> IOSProviderPreset {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return allCases.first { !$0.baseURL.isEmpty && $0.baseURL == trimmed } ?? .custom
  }
}
