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

  /// 工作台里的稿件。
  ///
  /// 和笔记分开一个 scheme,是为了让三个模块在**列表层面**互不打扰:
  /// 找素材时不该翻到半成品,写稿时也不该被自己的随手记打断。
  /// 底层仍共用同一张表,所以编辑器、搜索、导出、双链全部零改动可用。
  public static let draftScheme = "linkdigest-draft"

  /// 不指向网络的本机内容,它们都不该被当成链接处理。
  ///
  /// 抓 favicon、打开链接、导出来源这些按 http(s) 工作的代码,
  /// 只要认这一组就能整体跳过,不必为每加一种内容再补一处判断。
  static let localSchemes = [noteScheme, draftScheme]

  public let value: String

  /// 为一条新笔记生成 canonical URL。唯一性由 UUID 保证。
  public static func note(id: UUID = UUID()) throws -> CanonicalURL {
    try CanonicalURL("\(noteScheme):\(id.uuidString.lowercased())")
  }

  /// 为工作台的一份稿件生成 canonical URL。
  public static func draft(id: UUID = UUID()) throws -> CanonicalURL {
    try CanonicalURL("\(draftScheme):\(id.uuidString.lowercased())")
  }

  /// 是否是用户自建笔记，而非抓取来的网页。
  public var isNote: Bool { value.hasPrefix("\(Self.noteScheme):") }

  /// 是否是工作台的稿件。
  public var isDraft: Bool { value.hasPrefix("\(Self.draftScheme):") }

  /// 是否是本机自有内容(笔记或稿件),而不是抓来的网页。
  public var isLocalContent: Bool { isNote || isDraft }

  public init(_ rawValue: String) throws {
    // 本机内容（笔记、稿件）：只做最小规范化（scheme 小写 + 非空标识），
    // 不套用 host/path 那套规则——它们没有 host，硬走下面的分支会直接失败。
    if let separator = rawValue.firstIndex(of: ":"),
       case let scheme = rawValue[rawValue.startIndex..<separator].lowercased(),
       Self.localSchemes.contains(scheme) {
      let identifier = String(rawValue[rawValue.index(after: separator)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard !identifier.isEmpty, identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      else { throw CanonicalURLFailure.unsupported }
      value = "\(scheme):\(identifier)"
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
