import CryptoKit
import Foundation

/// 跨端稳定身份：同一条笔记 / 同一 URL 在 Mac 与 iOS 上映射到同一个 `SyncNoteCard.id`。
public enum SyncNoteCardIdentity {
  /// RFC 4122 URL 命名空间；仅用于派生稳定 UUID，不是密钥。
  private static let urlNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!

  /// 从 `linkdigest-note:` canonical URL 取出或派生笔记卡 id。
  public static func fromNoteCanonicalURL(_ rawURL: String) -> UUID? {
    let lowered = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let prefix = "linkdigest-note:"
    guard lowered.hasPrefix(prefix) else { return nil }
    let rest = String(lowered.dropFirst(prefix.count))
    guard !rest.isEmpty else { return nil }
    if let uuid = UUID(uuidString: rest) { return uuid }
    return stable(from: lowered)
  }

  /// 链接笔记：用规范化 URL 派生稳定 id，避免两端各建一张卡。
  public static func fromLinkCanonicalURL(_ rawURL: String) -> UUID {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return stable(from: trimmed)
  }

  /// 基于命名空间 + 字符串的 SHA-256 截断 UUID（variant/version 位置按 UUID 习惯打标）。
  public static func stable(from string: String) -> UUID {
    var hasher = SHA256()
    hasher.update(data: Data(urlNamespace.uuidString.lowercased().utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(string.utf8))
    let digest = hasher.finalize()
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}
