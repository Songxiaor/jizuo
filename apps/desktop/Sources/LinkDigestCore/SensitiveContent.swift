import Foundation

/// 识别「不该进素材库、更不该交给 AI 工具」的内容：密钥、令牌、私钥、账号密码。
///
/// 2026-09-23 备忘录同步把「🔑 API 密钥」「👤 账号密码」等文件夹原样导入了汲作，
/// 而 MCP 会把素材交给外部 AI 工具检索。这里宁可漏判少数，也不对普通文章误判：
/// 只认有明确形态的密钥串，以及「密码：xxx」这类显式标注。
public enum SensitiveContent {
  /// 文件夹名里带这些词的备忘录，整个文件夹默认不同步。
  public static let excludedFolderKeywords = [
    "密钥", "密码", "账号", "证件", "财务", "卡密", "服务器", "口令",
    "password", "credential", "secret", "token", "api key",
  ]

  /// 用户在偏好里额外指定的「永不同步」文件夹（完整名字，一行一个）。
  public static let excludedFoldersDefaultsKey = "localImport.appleNotes.excludedFolders"

  public static func isExcludedNotesFolder(_ folder: String?, extra: [String] = []) -> Bool {
    guard let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else { return false }
    if extra.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == folder }) { return true }
    let lowered = folder.lowercased()
    return excludedFolderKeywords.contains { lowered.contains($0) }
  }

  private static let patterns: [String] = [
    #"sk-(proj-|ant-)?[A-Za-z0-9_\-]{20,}"#,              // OpenAI / Anthropic 风格
    #"AIza[0-9A-Za-z_\-]{30,}"#,                          // Google API key
    #"gh[pousr]_[A-Za-z0-9]{30,}"#,                       // GitHub token
    #"xox[abpr]-[A-Za-z0-9\-]{10,}"#,                     // Slack token
    #"AKIA[0-9A-Z]{16}"#,                                 // AWS access key
    #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,               // 私钥
    #"ssh-(rsa|ed25519|dss) AAAA[0-9A-Za-z+/]{40,}"#,     // SSH 公私钥
    #"(?i)bearer\s+[A-Za-z0-9._\-]{24,}"#,                // Authorization 头
    #"(?i)[?&#](token|access_token|api_key|apikey|key)=[A-Za-z0-9._\-]{16,}"#,
    #"(?i)(api[_ ]?key|secret|token|password|passwd)\s*[:=：]\s*\S{8,}"#,
    #"(密码|口令|密钥|恢复码|助记词)\s*[:：]\s*\S{4,}"#,
  ]

  private static let expressions: [NSRegularExpression] = patterns.compactMap {
    try? NSRegularExpression(pattern: $0)
  }

  /// 文本里是否出现了疑似密钥 / 令牌 / 账号密码。
  public static func looksSensitive(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
  }
}
