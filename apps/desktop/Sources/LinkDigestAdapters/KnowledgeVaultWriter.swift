import Foundation
import LinkDigestCore

public struct KnowledgeVaultConflictEntry: Sendable, Equatable {
  public let filename: String
  public let reason: String

  public init(filename: String, reason: String) {
    self.filename = filename
    self.reason = reason
  }
}

public struct KnowledgeVaultFailureEntry: Sendable, Equatable {
  public let filename: String
  public let message: String

  public init(filename: String, message: String) {
    self.filename = filename
    self.message = message
  }
}

public struct KnowledgeVaultSyncReport: Sendable, Equatable {
  public var created = 0
  public var updated = 0
  public var renamed = 0
  public var skipped = 0
  public var conflicts: [KnowledgeVaultConflictEntry] = []
  public var failures: [KnowledgeVaultFailureEntry] = []

  public init() {}

  public var touched: Int { created + updated + renamed }

  /// 给设置页那一行汇总用。
  public var summaryLine: String {
    var parts = ["新增 \(created)", "更新 \(updated)"]
    if renamed > 0 { parts.append("重命名 \(renamed)") }
    parts.append("跳过 \(skipped)")
    if !conflicts.isEmpty { parts.append("冲突 \(conflicts.count)") }
    if !failures.isEmpty { parts.append("失败 \(failures.count)") }
    return parts.joined(separator: " · ")
  }
}

public enum KnowledgeVaultWriter {
  /// 读出目录里现有的 `.md`。
  ///
  /// 只看顶层，不递归：汲作只管自己那一个目录，用户知识库里别的层级不该被扫，
  /// 也不该被这个功能知道。
  public static func scan(directory: URL) throws -> [KnowledgeVaultExistingFile] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    var files: [KnowledgeVaultExistingFile] = []
    for name in names.sorted() where name.hasSuffix(".md") && !name.hasPrefix(".") {
      let url = directory.appendingPathComponent(name)
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      // 符号链接不读也不写：跟着它走就可能写到目录外面去。
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      files.append(
        .init(filename: name, digestID: KnowledgeVaultSync.digestID(inMarkdown: text), text: text)
      )
    }
    return files
  }

  /// 执行计划。单个文件出错不中断整批——同步 42 条不该因为第 3 条权限不对就
  /// 全盘停下，失败的那些进报告。
  public static func apply(_ plan: KnowledgeVaultPlan, in directory: URL) -> KnowledgeVaultSyncReport {
    var report = KnowledgeVaultSyncReport()
    for action in plan.actions {
      switch action {
      case let .skipUnchanged(filename):
        _ = filename
        report.skipped += 1

      case let .conflict(filename, digestID, reason):
        let detail: String
        switch reason {
        case .foreignFile:
          detail = "已存在同名文件，且不是汲作写的"
        case let .otherDigest(other):
          detail = "已存在同名文件，属于另一条记录（\(String(other.prefix(8)))）"
        }
        _ = digestID
        report.conflicts.append(.init(filename: filename, reason: detail))

      case let .create(filename, text):
        switch write(text, named: filename, in: directory) {
        case .success: report.created += 1
        case let .failure(message): report.failures.append(.init(filename: filename, message: message))
        }

      case let .update(filename, text):
        switch write(text, named: filename, in: directory) {
        case .success: report.updated += 1
        case let .failure(message): report.failures.append(.init(filename: filename, message: message))
        }

      case let .rename(from, to, text):
        // 先把新文件写出来，成功之后再删旧的。反过来做的话，中途失败会把
        // 用户那条内容整个弄丢；这个顺序最坏也只是留下一份多余的旧文件。
        switch write(text, named: to, in: directory) {
        case .success:
          report.renamed += 1
          if let old = safeURL(named: from, in: directory) {
            try? FileManager.default.removeItem(at: old)
          }
        case let .failure(message):
          report.failures.append(.init(filename: to, message: message))
        }
      }
    }
    return report
  }

  private enum WriteOutcome {
    case success
    case failure(String)
  }

  private static func write(_ text: String, named filename: String, in directory: URL) -> WriteOutcome {
    guard let url = safeURL(named: filename, in: directory) else {
      return .failure("文件名不合法，已跳过")
    }
    // 已存在的符号链接不覆盖：写过去会顺着链接改到目录外面的文件。
    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values?.isSymbolicLink == true { return .failure("目标是符号链接，已跳过") }
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
      return .success
    } catch {
      return .failure((error as NSError).localizedDescription)
    }
  }

  /// 文件名必须是单个普通分量，且拼出来的路径确实落在目标目录里。
  ///
  /// 名字是汲作自己生成的，理论上已经洗过；这里再挡一道，是因为这个功能唯一
  /// 不可接受的失败就是写到用户知识库的其它地方去。
  private static func safeURL(named filename: String, in directory: URL) -> URL? {
    guard !filename.isEmpty,
          !filename.hasPrefix("."),
          !filename.contains("/"),
          !filename.contains("\\"),
          !filename.contains("\0"),
          filename != "..",
          filename.hasSuffix(".md")
    else { return nil }
    let url = directory.appendingPathComponent(filename)
    let parent = url.deletingLastPathComponent().standardizedFileURL.path
    guard parent == directory.standardizedFileURL.path else { return nil }
    return url
  }
}
