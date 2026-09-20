import Foundation

/// iOS 目前只走 OpenAI-compatible `/chat/completions`。
/// OpenCode Go 目录里还有 messages / responses 模型；拉取后需过滤或标灰，避免测连失败。
public enum IOSChatCompletionsCompatibility: String, Sendable, Equatable {
  /// 已知可用 chat/completions。
  case supported
  /// 已知走 messages / responses，当前 App 不能直接用。
  case unsupportedTransport
  /// 不在已知表里：允许勾选，但脚注提示可能失败。
  case unknown
}

public enum IOSModelCatalogSupport {
  /// OpenCode Go 文档中明确走 `/chat/completions` 的模型 ID。
  public static let openCodeGoChatCompletionsIDs: Set<String> = [
    "glm-5.3-flash",
    "glm-5.3",
    "glm-5.2",
    "glm-5.1",
    "glm-5",
    "kimi-k3",
    "kimi-k2.7-code",
    "kimi-k2.6",
    "kimi-k2.5",
    "longcat-2.0",
    "deepseek-v4-pro",
    "deepseek-v4-flash",
    "deepseek-v4-flash-vision-exp",
    "mimo-v2.5",
    "mimo-v2.5-pro",
    "mimo-v2-pro",
    "mimo-v2-omni",
    "hy4-preview",
    "hy3",
    "hy3-preview",
  ]

  /// OpenCode Go 文档中明确不走 chat/completions 的模型。
  public static let openCodeGoNonChatCompletionsIDs: Set<String> = [
    "minimax-m3",
    "minimax-m2.7",
    "minimax-m2.5",
    "qwen3.8-max",
    "qwen3.8-flash",
    "qwen3.7-max",
    "qwen3.7-plus",
    "qwen3.6-plus",
    "qwen3.5-plus",
    "grok-4.6",
    "grok-4.5",
    "gpt-5.6-luna",
    "muse-spark-1.2-contributor",
  ]

  public static func isOpenCodeGoBaseURL(_ baseURL: String) -> Bool {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.contains("opencode.ai") && trimmed.contains("/zen/go")
  }

  public static func compatibility(modelID: String, baseURL: String) -> IOSChatCompletionsCompatibility {
    let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isOpenCodeGoBaseURL(baseURL) else { return .unknown }
    if openCodeGoChatCompletionsIDs.contains(id) { return .supported }
    if openCodeGoNonChatCompletionsIDs.contains(id) { return .unsupportedTransport }
    // 前缀启发：qwen / minimax / grok / gpt-5 / muse 在 Go 上多半不是 chat。
    let lower = id.lowercased()
    if lower.hasPrefix("qwen") || lower.hasPrefix("minimax") || lower.hasPrefix("grok")
      || lower.hasPrefix("gpt-5") || lower.hasPrefix("muse-")
    {
      return .unsupportedTransport
    }
    return .unknown
  }

  /// 目录展示顺序：可用 → 未知 → 不可用；同组内按名称排序。
  public static func sortedForDisplay(_ models: [String], baseURL: String) -> [String] {
    models.sorted { lhs, rhs in
      let lc = compatibility(modelID: lhs, baseURL: baseURL)
      let rc = compatibility(modelID: rhs, baseURL: baseURL)
      if lc != rc {
        return rank(lc) < rank(rc)
      }
      return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
  }

  public static func badgeText(for compatibility: IOSChatCompletionsCompatibility) -> String? {
    switch compatibility {
    case .supported: return nil
    case .unsupportedTransport: return "不支持"
    case .unknown: return "未验证"
    }
  }

  private static func rank(_ value: IOSChatCompletionsCompatibility) -> Int {
    switch value {
    case .supported: return 0
    case .unknown: return 1
    case .unsupportedTransport: return 2
    }
  }
}
