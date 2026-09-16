import Foundation
import os

/// 汲作的统一日志出口。
///
/// 存在的理由是「用户报故障时我们能查」。之前抓取失败、模型请求失败、媒体下载失败
/// 都只在界面上留一句话，进程一退什么都不剩；要复现只能靠用户复述。
///
/// 这里有一条铁律：**日志里永远不出现正文、完整 URL、密钥、Cookie**。
/// 诊断导出会把这些行原样交给用户、再由用户转给我们，所以脱敏必须发生在写入之前，
/// 而不是导出的时候——导出时再洗一遍等于承认曾经写进过系统日志。
///
/// 具体做法：
/// - URL 只记 host（`AppLog.host(_:)`），path / query / fragment 一律不进日志；
/// - 每个字段值都过 `AppLog.redact(_:)`，密钥形状、`Bearer`、`key=value` 形式的
///   敏感键、以及任何看起来像不透明凭据的长串都被替换成 `[redacted]`；
/// - 错误一律带错误码（`code=`），因为这是唯一能跨版本对齐的东西。
public enum AppLog {
  public enum Category: String, Sendable, CaseIterable {
    case capture
    case provider
    case media
    case storage
    case browserExtension = "extension"
  }

  public static let subsystem = "com.syc.linkdigest"

  /// 单个字段值的长度上限。日志不是内容存储，超长只会是正文泄漏的征兆。
  public static let maxFieldLength = 120

  // MARK: - 写入

  public static func info(
    _ category: Category,
    _ event: String,
    _ fields: [String: String] = [:]
  ) {
    logger(for: category).info("\(message(event, fields), privacy: .public)")
  }

  public static func notice(
    _ category: Category,
    _ event: String,
    _ fields: [String: String] = [:]
  ) {
    logger(for: category).notice("\(message(event, fields), privacy: .public)")
  }

  /// 错误必须带错误码：界面上的中文说明会改、会翻译，错误码不会。
  public static func error(
    _ category: Category,
    _ event: String,
    code: String,
    _ fields: [String: String] = [:]
  ) {
    var merged = fields
    merged["code"] = code
    logger(for: category).error("\(message(event, merged), privacy: .public)")
  }

  // MARK: - 组装与脱敏（公开，便于测试直接断言）

  /// 组装成一行 `event key=value …`。键按字典序，保证同一事件的行可直接比对。
  public static func message(_ event: String, _ fields: [String: String] = [:]) -> String {
    let safeEvent = redact(event)
    guard !fields.isEmpty else { return safeEvent }
    let rendered = fields.keys.sorted().map { key in
      "\(sanitizeKey(key))=\(redact(fields[key] ?? ""))"
    }
    return ([safeEvent] + rendered).joined(separator: " ")
  }

  /// 只留 host。传入的字符串可能是完整 URL，也可能已经是 host。
  public static func host(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "none" }
    if let components = URLComponents(string: raw), let host = components.host, !host.isEmpty {
      return host.lowercased()
    }
    // 不是可解析的 URL：只有在它本身长得像裸 host 时才放行，否则整串丢掉。
    let candidate = raw.lowercased()
    let isBareHost = candidate.count <= 253
      && !candidate.contains("/")
      && !candidate.contains("@")
      && !candidate.contains(" ")
      && candidate.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
    return isBareHost ? candidate : "unparseable"
  }

  public static func host(_ url: URL?) -> String {
    guard let url else { return "none" }
    return host(url.absoluteString)
  }

  /// 把一段自由文本洗成可以进日志的形态。
  ///
  /// 宁可洗过头：这里丢掉的信息最多让一条日志少一点上下文，漏掉的信息会变成
  /// 用户主动发给我们的密钥。
  public static func redact(_ raw: String) -> String {
    guard !raw.isEmpty else { return "" }
    var value = raw

    // 1) 完整 URL → 只留 scheme://host。必须最先做：URL 里常带 token 参数。
    value = replace(value, pattern: "[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s\"']+") { match in
      guard let components = URLComponents(string: match), let host = components.host else {
        return "[redacted-url]"
      }
      return "\(components.scheme ?? "url")://\(host.lowercased())"
    }

    // 2) Authorization 头形态。
    value = replace(value, pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+") { _ in "Bearer [redacted]" }
    value = replace(value, pattern: "(?i)basic\\s+[A-Za-z0-9+/=]{8,}") { _ in "Basic [redacted]" }

    // 3) `敏感键=值` / `敏感键: 值`。
    let sensitiveKey =
      "(?i)\\b(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|passwd|pwd|authorization|auth|cookie|set-cookie|session|sessionid|signature|sign)\\b\\s*[:=]\\s*[^\\s,;&]+"
    value = replace(value, pattern: sensitiveKey) { match in
      guard let separatorIndex = match.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
        return "[redacted]"
      }
      let key = match[match.startIndex..<separatorIndex].trimmingCharacters(in: .whitespaces)
      return "\(key)\(match[separatorIndex])[redacted]"
    }

    // 4) 已知的密钥前缀形状（OpenAI / xAI / Groq / GitHub / GitLab / Slack…）。
    value = replace(
      value,
      pattern: "(?i)\\b(sk|rk|pk|xai|gsk|ghp|gho|ghu|ghs|ghr|glpat|xox[abprs]|pat|ak|sn)[-_][A-Za-z0-9_-]{8,}"
    ) { _ in "[redacted]" }

    // 5) 兜底：任何足够长、同时含字母与数字的不透明串。密钥即使换了前缀也逃不过
    //    这一条；正常中文/英文句子不会命中（要求 28 位以上且无空格）。
    value = replace(value, pattern: "[A-Za-z0-9_\\-+/=]{28,}") { match in
      let hasLetter = match.rangeOfCharacter(from: .letters) != nil
      let hasDigit = match.rangeOfCharacter(from: .decimalDigits) != nil
      return (hasLetter && hasDigit) ? "[redacted]" : match
    }

    // 6) 控制字符与换行会把一行日志撑成多行，直接压平。
    value = value.components(separatedBy: .newlines).joined(separator: " ")
    value = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })

    if value.count > maxFieldLength {
      value = String(value.prefix(maxFieldLength)) + "…"
    }
    return value
  }

  // MARK: - 内部

  private static let loggers: [Category: Logger] = Dictionary(
    Category.allCases.map {
      ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    },
    uniquingKeysWith: { _, new in new }
  )

  private static func logger(for category: Category) -> Logger {
    loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
  }

  private static func sanitizeKey(_ key: String) -> String {
    let filtered = key.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "."
    }
    let result = String(String.UnicodeScalarView(filtered))
    return result.isEmpty ? "field" : result
  }

  private static func replace(
    _ value: String,
    pattern: String,
    transform: (String) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let full = NSRange(value.startIndex..<value.endIndex, in: value)
    var result = ""
    var cursor = value.startIndex
    for match in regex.matches(in: value, range: full) {
      guard let range = Range(match.range, in: value) else { continue }
      result += value[cursor..<range.lowerBound]
      result += transform(String(value[range]))
      cursor = range.upperBound
    }
    result += value[cursor...]
    return result
  }
}
