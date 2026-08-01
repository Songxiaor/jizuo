import Foundation

public enum CanonicalURLFailure: Error, Sendable, Equatable { case unsupported }

public struct CanonicalURL: Codable, Sendable, Equatable, Hashable {
  public static let version = 1

  /// 用户自建笔记的 scheme。
  ///
  /// 笔记没有来源链接，但 `tasks.canonical_url` 是 `NOT NULL` 且要求唯一。给它编一个
  /// 假的 https 地址看似省事，实际会出事：**favicon 抓取会拿 canonical_url 的域名去
  /// 发真实网络请求**，等于每建一条笔记就对一个不存在的域名打一次网；导出、来源显示
  /// 等处也会把那个假地址当成真链接展示给用户。
  ///
  /// 用独立 scheme 才是诚实的表达——笔记本来就不是链接。所有按 http(s) 分支工作的
  /// 代码（抓取、favicon、打开链接）都会自然跳过它，无需逐处加判断。
  public static let noteScheme = "linkdigest-note"

  public let value: String

  /// 为一条新笔记生成 canonical URL。唯一性由 UUID 保证。
  public static func note(id: UUID = UUID()) throws -> CanonicalURL {
    try CanonicalURL("\(noteScheme):\(id.uuidString.lowercased())")
  }

  /// 是否是用户自建笔记，而非抓取来的网页。
  public var isNote: Bool { value.hasPrefix("\(Self.noteScheme):") }

  public init(_ rawValue: String) throws {
    // 笔记：只做最小规范化（scheme 小写 + 非空标识），不套用 host/path 那套规则——
    // 它没有 host，硬走下面的分支会直接失败。
    if let separator = rawValue.firstIndex(of: ":"),
       rawValue[rawValue.startIndex..<separator].lowercased() == Self.noteScheme {
      let identifier = String(rawValue[rawValue.index(after: separator)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard !identifier.isEmpty, identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      else { throw CanonicalURLFailure.unsupported }
      value = "\(Self.noteScheme):\(identifier)"
      return
    }

    guard var components = URLComponents(string: rawValue),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host?.lowercased(), !host.isEmpty
    else { throw CanonicalURLFailure.unsupported }

    components.scheme = scheme
    components.host = host
    components.fragment = nil
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
      components.port = nil
    }
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    guard let result = components.string else { throw CanonicalURLFailure.unsupported }
    value = result
  }
}
