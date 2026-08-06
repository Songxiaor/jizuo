import Foundation

/// 目标目录里已经存在的一个 `.md`。
///
/// `digestID` 来自文件 frontmatter 里的 `digest_id`。解析不出来就是 `nil`——
/// 那说明这个文件不是汲作写的（用户自己的笔记，或别的工具的产物），
/// 汲作只能绕开它，不能碰。
public struct KnowledgeVaultExistingFile: Sendable, Equatable {
  public let filename: String
  public let digestID: String?
  public let text: String

  public init(filename: String, digestID: String?, text: String) {
    self.filename = filename
    self.digestID = digestID
    self.text = text
  }
}

public enum KnowledgeVaultAction: Sendable, Equatable {
  case create(filename: String, text: String)
  case update(filename: String, text: String)
  /// 标题变了导致文件名变了。重命名而不是新建，否则同一条内容会在目录里
  /// 留下两份，半年后目录里全是名字相近的重复文件。
  case rename(from: String, to: String, text: String)
  /// 渲染结果和磁盘上完全一致。**不写盘**——写了会动 mtime，触发 Obsidian
  /// 全量重建索引，并在用户的 Git 仓库里制造一堆没有内容变化的改动。
  case skipUnchanged(filename: String)
  /// 目标文件已存在，但它不归这条历史管。跳过并上报，绝不覆盖。
  case conflict(filename: String, digestID: String, reason: KnowledgeVaultConflictReason)
}

public enum KnowledgeVaultConflictReason: Sendable, Equatable {
  /// 文件里没有 `digest_id`：不是汲作写的文件。
  case foreignFile
  /// 文件里的 `digest_id` 指向另一条历史。
  case otherDigest(String)
}

public struct KnowledgeVaultPlan: Sendable, Equatable {
  public let actions: [KnowledgeVaultAction]

  public init(actions: [KnowledgeVaultAction]) {
    self.actions = actions
  }

  public var creates: Int { actions.filter { if case .create = $0 { return true }; return false }.count }
  public var updates: Int { actions.filter { if case .update = $0 { return true }; return false }.count }
  public var renames: Int { actions.filter { if case .rename = $0 { return true }; return false }.count }
  public var skips: Int { actions.filter { if case .skipUnchanged = $0 { return true }; return false }.count }
  public var conflicts: [KnowledgeVaultAction] {
    actions.filter { if case .conflict = $0 { return true }; return false }
  }
}

public enum KnowledgeVaultSync {
  /// 纯函数：给定要导出的条目和目录里现有的文件，算出该做哪些动作。
  /// 不碰文件系统——落盘是调用方的事，这样这段逻辑可以完全用夹具测。
  public static func plan(
    documents: [KnowledgeVaultDocument],
    existing: [KnowledgeVaultExistingFile]
  ) -> KnowledgeVaultPlan {
    var byDigestID: [String: KnowledgeVaultExistingFile] = [:]
    var byFilename: [String: KnowledgeVaultExistingFile] = [:]
    for file in existing {
      byFilename[file.filename] = file
      // 同一个 digest_id 出现在多个文件里时，认第一个；剩下那些会以
      // otherDigest 冲突的形式被报出来，交给用户自己收拾。
      if let id = file.digestID, byDigestID[id] == nil { byDigestID[id] = file }
    }

    var actions: [KnowledgeVaultAction] = []
    // 本批次已经占用的文件名。两条不同的历史完全可能在同一天有同样的标题，
    // 不去重的话第二条会被误判成冲突，或者两条来回覆盖同一个文件。
    var claimed = Set<String>()

    for document in documents {
      let digestID = document.digestID.rawValue

      // 已经在目录里认过亲的条目：优先保住它现在这个文件名。
      // 只有当期望的名字确实空着时才改名，否则每次同步都可能因为别的条目
      // 占了名字而来回折腾同一个文件。
      if let known = byDigestID[digestID] {
        let preferred = document.filename
        let target: String
        if known.filename == preferred {
          target = preferred
        } else if isAvailable(preferred, digestID: digestID, claimed: claimed, byFilename: byFilename) {
          target = preferred
        } else {
          target = known.filename
        }
        claimed.insert(target)
        if target == known.filename {
          actions.append(
            known.text == document.text
              ? .skipUnchanged(filename: target)
              : .update(filename: target, text: document.text)
          )
        } else {
          actions.append(.rename(from: known.filename, to: target, text: document.text))
        }
        continue
      }

      // 新条目。这里要严格区分两种「名字被占」：
      //
      // 本批次里另一条历史占了 —— 自动让开。两条不同的内容同一天同标题是
      // 正常的，让它们互相覆盖才是错的。
      //
      // 磁盘上的文件占了 —— 报冲突，绝不覆盖。那个文件可能是用户自己的东西，
      // 自动改名绕开会让冲突报告永远是空的，用户根本不知道发生过什么。
      var target = document.filename
      if claimed.contains(target) {
        target = disambiguated(target, digestID: digestID, claimed: claimed)
      }
      if let occupant = byFilename[target], occupant.digestID != digestID {
        actions.append(
          .conflict(
            filename: target,
            digestID: digestID,
            reason: occupant.digestID.map(KnowledgeVaultConflictReason.otherDigest) ?? .foreignFile
          )
        )
        continue
      }
      claimed.insert(target)
      actions.append(.create(filename: target, text: document.text))
    }

    return .init(actions: actions)
  }

  private static func isAvailable(
    _ name: String,
    digestID: String,
    claimed: Set<String>,
    byFilename: [String: KnowledgeVaultExistingFile]
  ) -> Bool {
    if claimed.contains(name) { return false }
    guard let occupant = byFilename[name] else { return true }
    return occupant.digestID == digestID
  }

  /// 给本批次内撞名的条目找一个区分名。
  ///
  /// 用 digest id 的短码，不用序号：短码是稳定的，同一条内容每次同步都会算出
  /// 同一个名字；序号会随批次里条目的顺序变，那会让文件名每次同步都可能变。
  private static func disambiguated(
    _ preferred: String,
    digestID: String,
    claimed: Set<String>
  ) -> String {
    let short = String(digestID.replacingOccurrences(of: "-", with: "").prefix(8))
    let candidate = suffixed(preferred, with: "_\(short)")
    if !claimed.contains(candidate) { return candidate }
    return suffixed(preferred, with: "_\(digestID)")
  }

  /// 把后缀插在 `.md` 之前，并保证整体仍在 255 字节的文件名预算内。
  private static func suffixed(_ filename: String, with suffix: String) -> String {
    let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
    let budget = 255 - suffix.utf8.count - ".md".utf8.count
    let bounded = KnowledgeVaultRenderer.truncated(base, withinUTF8ByteCount: max(0, budget)).text
    return "\(bounded)\(suffix).md"
  }

  /// 从一份 md 全文里读出 `digest_id`。
  ///
  /// 只认最前面那个 `---` 块里的这一个键。故意写得比通用 YAML 解析器窄：
  /// 这里唯一的问题是「这个文件归不归汲作管」，答不上来就当成别人的文件绕开，
  /// 那正是安全的方向。
  public static func digestID(inMarkdown text: String) -> String? {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("---\n") else { return nil }
    let rest = normalized.dropFirst(4)
    guard let end = rest.range(of: "\n---") else { return nil }
    for rawLine in rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard key == "digest_id" else { continue }
      var value = String(line[line.index(after: colon)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
          .replacingOccurrences(of: "\\\"", with: "\"")
          .replacingOccurrences(of: "\\\\", with: "\\")
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }
}
