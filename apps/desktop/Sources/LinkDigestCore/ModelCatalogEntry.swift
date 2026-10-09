import Foundation

/// 模型列表里的一项：模型名，加上服务商愿意多给的信息（2026-10-09 Syc：把模型的信息标出来）。
///
/// 只有 `id` 是必有的。其余字段各家叫法不一，能认的都认：Magpie 给得最全（来源、上下文、
/// 最大输出、思考档位、能不能看图、原生协议），OpenRouter 给上下文和输入类型，Anthropic 给显示名，
/// 大多数服务商只有 `id`。认不出、类型不对的字段一律当没有，不让整份列表读失败。
public struct ModelCatalogEntry: Sendable, Equatable, Hashable {
  public let id: String
  public var displayName: String?
  /// 原始的 `owned_by`（Magpie 里是它的服务商 ID：anthropic、cursor、workbuddy…），配图标用。
  public var ownedBy: String?
  /// 给人看的来源名：Magpie 的 `magpie_label` 里「 · 」后面那段（「Claude Code」「Cursor」）。
  public var sourceLabel: String?
  public var contextWindow: Int?
  public var maxOutputTokens: Int?
  public var acceptsImages: Bool?
  public var supportsReasoning: Bool?
  public var reasoningLevels: [String] = []
  /// 服务商原生说的接口（`/v1/messages`、`/v1/chat/completions`、`/v1/responses`）。
  public var nativeEndpoints: [String] = []

  public init(id: String) { self.id = id }

  /// 有没有可标的规格（名字和渠道另有位置）。只有一个 ID 的，列表里就不多占一行。
  public var hasDetails: Bool {
    contextWindow != nil || maxOutputTokens != nil
      || acceptsImages == true || supportsReasoning == true || !nativeEndpoints.isEmpty
  }

  /// 解析 `/models` 的响应。`data` 不是数组、或一个能用的 ID 都没有时返回 nil（调用方按协议不兼容处理）。
  public static func parseCatalog(_ data: Data) -> [ModelCatalogEntry]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = root["data"] as? [[String: Any]]
    else { return nil }
    return items.compactMap(entry(from:))
  }

  static func entry(from item: [String: Any]) -> ModelCatalogEntry? {
    guard let rawID = item["id"] as? String else { return nil }
    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return nil }
    var entry = ModelCatalogEntry(id: id)
    entry.displayName = text(item["display_name"]) ?? text(item["name"])
    // 显示名就是 ID（或「/」后那段）时不再标一遍：「cursor/grok-4.7-fast」旁边写「grok-4.7-fast」是重复。
    let leaf = id.split(separator: "/").last.map(String.init) ?? id
    if let name = entry.displayName, name.caseInsensitiveCompare(id) == .orderedSame || name.caseInsensitiveCompare(leaf) == .orderedSame {
      entry.displayName = nil
    }
    entry.ownedBy = text(item["owned_by"])
    if let label = text(item["magpie_label"]), let range = label.range(of: " · ", options: .backwards) {
      entry.sourceLabel = text(String(label[range.upperBound...]))
    }
    let topProvider = item["top_provider"] as? [String: Any]
    entry.contextWindow = positive(item["context_window"]) ?? positive(item["context_length"])
      ?? positive(item["max_input_tokens"]) ?? positive(topProvider?["context_length"])
    entry.maxOutputTokens = positive(item["max_output_tokens"]) ?? positive(item["max_completion_tokens"])
      ?? positive(topProvider?["max_completion_tokens"])
    let modalities = (item["modalities"] as? [String: Any])?["input"] as? [String]
      ?? (item["architecture"] as? [String: Any])?["input_modalities"] as? [String]
    if let modalities { entry.acceptsImages = modalities.contains("image") }
    if let levels = item["supported_reasoning_levels"] as? [[String: Any]] {
      entry.reasoningLevels = levels.compactMap { text($0["effort"]) }
    }
    entry.supportsReasoning = (item["reasoning"] as? Bool) ?? (entry.reasoningLevels.isEmpty ? nil : true)
    entry.nativeEndpoints = (item["native_endpoints"] as? [String]) ?? []
    return entry
  }

  private static func text(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func positive(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let int = number.intValue
    return int > 0 ? int : nil
  }
}
