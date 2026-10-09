import Foundation
import LinkDigestCore

/// 模型规格的一行小字：「上下文 100万 · 输出 12.8万 · 看图 · 思考 low–max · 原生 Anthropic」。
extension ModelCatalogEntry {
  var detailLine: String {
    // 名字和渠道已经在标题、小节标题里了（「模型名 · 厂商」按渠道分组），这一行只写规格。
    var parts: [String] = []
    if let contextWindow { parts.append("上下文 \(Self.tokenCount(contextWindow))") }
    if let maxOutputTokens { parts.append("输出 \(Self.tokenCount(maxOutputTokens))") }
    if acceptsImages == true { parts.append("看图") }
    if supportsReasoning == true {
      if let first = reasoningLevels.first, let last = reasoningLevels.last, reasoningLevels.count > 1 {
        parts.append("思考 \(first)–\(last)")
      } else {
        parts.append("可思考")
      }
    }
    if let native = nativeProtocolLabel { parts.append("原生 \(native)") }
    return parts.joined(separator: " · ")
  }

  /// 服务商原生说的协议：选「协议」时参考，原生的那种最省转换。
  var nativeProtocolLabel: String? {
    if nativeEndpoints.contains(where: { $0.hasSuffix("/messages") }) { return "Anthropic" }
    if nativeEndpoints.contains(where: { $0.hasSuffix("/chat/completions") }) { return "OpenAI" }
    if nativeEndpoints.contains(where: { $0.hasSuffix("/responses") }) { return "Responses" }
    return nil
  }

  /// 1000000 → 100万，128000 → 12.8万，8192 → 8192。
  static func tokenCount(_ value: Int) -> String {
    guard value >= 10_000 else { return "\(value)" }
    let wan = Double(value) / 10_000
    let rounded = (wan * 10).rounded() / 10
    return rounded == rounded.rounded() ? "\(Int(rounded))万" : String(format: "%.1f万", rounded)
  }
}
