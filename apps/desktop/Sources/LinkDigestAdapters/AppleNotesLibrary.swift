import Foundation

/// 系统「备忘录」里的一条笔记。
public struct AppleNote: Sendable, Equatable, Decodable {
  public let id: String
  public let name: String?
  public let folder: String?
  /// 备忘录给的是 HTML；加密的备忘录读不到正文，这里为 nil。
  public let body: String?
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let locked: Bool

  public init(id: String, name: String?, folder: String?, body: String?, createdAt: Date?, modifiedAt: Date?, locked: Bool) {
    self.id = id
    self.name = name
    self.folder = folder
    self.body = body
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.locked = locked
  }
}

public enum AppleNotesLibraryError: Error, Sendable, Equatable {
  /// 用户没有允许汲作控制「备忘录」（系统设置 → 隐私与安全性 → 自动化）。
  case permissionDenied
  /// 「备忘录」没有及时响应。最常见的原因是首次授权弹窗还没被点，或被其它窗口挡住。
  case timedOut
  /// 脚本执行失败，原因不是权限。
  case failed(String)

  public var userMessage: String {
    switch self {
    case .permissionDenied:
      return "汲作还没有读取备忘录的权限。请在「系统设置 → 隐私与安全性 → 自动化」里找到汲作，打开其中的「备忘录」，然后回来再同步一次。"
    case .timedOut:
      return "「备忘录」没有及时响应。第一次同步时，系统会弹窗询问是否允许汲作访问备忘录——弹窗可能被其它窗口挡住，请找到它并点「好」，再同步一次。如果之前点过「不允许」，请在「系统设置 → 隐私与安全性 → 自动化」里打开汲作下面的「备忘录」。"
    case let .failed(detail):
      return "读取备忘录失败：\(detail)。请确认「备忘录」App 能正常打开后重试。"
    }
  }
}

/// 只读访问系统备忘录。
///
/// 走 Apple 官方支持的脚本接口（JavaScript for Automation），而不是直接读备忘录的
/// 私有数据库：数据库结构和正文编码随系统版本变化，脚本接口是 Apple 承诺维护的那一层。
/// 代价是第一次使用时系统会弹窗征求「自动化」授权。
///
/// 脚本只读取，不创建、修改或删除任何备忘录。
public struct AppleNotesLibrary: Sendable {
  public static let recentlyDeletedFolderNames: Set<String> = ["Recently Deleted", "最近删除", "最近刪除"]

  private let timeout: TimeInterval

  public init(timeout: TimeInterval = 180) {
    self.timeout = timeout
  }

  /// 逐个文件夹批量读取，一个文件夹出错不拖垮其余的：批量读失败时退回逐条读。
  static let script = #"""
  const Notes = Application('Notes');
  const deleted = new Set(["Recently Deleted", "最近删除", "最近刪除"]);
  const out = [];
  function iso(d) { try { return d ? d.toISOString() : null; } catch (e) { return null; } }
  function readOne(n, folderName) {
    let locked = false;
    try { locked = n.passwordProtected(); } catch (e) {}
    let body = null;
    if (!locked) { try { body = n.body(); } catch (e) { body = null; } }
    out.push({ id: n.id(), name: n.name(), folder: folderName, body: body,
               createdAt: iso(n.creationDate()), modifiedAt: iso(n.modificationDate()), locked: locked });
  }
  for (const account of Notes.accounts()) {
    for (const folder of account.folders()) {
      let folderName = null;
      try { folderName = folder.name(); } catch (e) {}
      if (folderName && deleted.has(folderName)) continue;
      const notes = folder.notes;
      try {
        const ids = notes.id(), names = notes.name(), created = notes.creationDate(),
              modified = notes.modificationDate(), locked = notes.passwordProtected();
        for (let i = 0; i < ids.length; i++) {
          let body = null;
          if (!locked[i]) { try { body = notes[i].body(); } catch (e) { body = null; } }
          out.push({ id: ids[i], name: names[i], folder: folderName, body: body,
                     createdAt: iso(created[i]), modifiedAt: iso(modified[i]), locked: !!locked[i] });
        }
      } catch (e) {
        for (const n of folder.notes()) { try { readOne(n, folderName); } catch (e2) {} }
      }
    }
  }
  JSON.stringify(out);
  """#

  public func notes() async throws -> [AppleNote] {
    let output = try await runScript()
    return try Self.decode(output)
  }

  static func decode(_ output: Data) throws -> [AppleNote] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date"))
    }
    do {
      return try decoder.decode([AppleNote].self, from: output)
    } catch {
      throw AppleNotesLibraryError.failed("备忘录返回的内容无法解析")
    }
  }

  /// `osascript` 在子进程里跑，不占主线程；系统把它的「自动化」请求记在汲作名下。
  private func runScript() async throws -> Data {
    let timeout = timeout
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let run = ScriptRun()
        run.process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        run.process.arguments = ["-l", "JavaScript", "-e", Self.script]
        let stdout = Pipe(), stderr = Pipe()
        run.process.standardOutput = stdout
        run.process.standardError = stderr
        do { try run.process.run() } catch {
          continuation.resume(throwing: AppleNotesLibraryError.failed("无法启动系统脚本"))
          return
        }
        // 首次使用时系统会弹授权窗，脚本在用户点选之前一直等着；给足时间后再放弃。
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { run.terminateIfRunning() }
        // 先读完输出再等退出：备忘录多时输出很大，不读的话管道写满，子进程会一直挂着。
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.process.waitUntilExit()
        if run.didTimeOut {
          continuation.resume(throwing: AppleNotesLibraryError.timedOut)
        } else if run.process.terminationStatus != 0 {
          continuation.resume(throwing: Self.error(fromStderr: errorText))
        } else {
          continuation.resume(returning: output)
        }
      }
    }
  }

  static func error(fromStderr text: String) -> AppleNotesLibraryError {
    // -1743：用户拒绝或尚未允许发送 Apple 事件；-1744：需要用户同意但无法弹窗。
    if text.contains("-1743") || text.contains("-1744") || text.localizedCaseInsensitiveContains("not authorized") {
      return .permissionDenied
    }
    // -1712：Apple 事件超时。首次使用时它几乎总是意味着授权弹窗还在等用户。
    if text.contains("-1712") { return .timedOut }
    let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    return .failed(line.isEmpty ? "未知错误" : String(line.prefix(120)))
  }
}

/// 子进程与超时标记。只在这一个文件里跨线程使用，访问都经过锁。
private final class ScriptRun: @unchecked Sendable {
  let process = Process()
  private let lock = NSLock()
  private var timedOut = false

  var didTimeOut: Bool { lock.withLock { timedOut } }

  func terminateIfRunning() {
    lock.withLock {
      guard process.isRunning else { return }
      timedOut = true
      process.terminate()
    }
  }
}

/// 备忘录正文是一小撮固定的 HTML（div、br、标题、列表、粗体、表格、内嵌图片）。
/// 转成 Markdown 文字，保留段落、标题和列表结构，丢掉样式与内嵌图片数据。
///
/// 不用 `NSAttributedString` 的 HTML 导入：它必须在主线程、依赖 WebKit，几百条
/// 备忘录会把界面卡住，而这里只需要结构，不需要排版。
public enum AppleNoteHTML {
  public static func markdown(from html: String) -> String {
    var text = html
    // 内嵌图片是 base64，动辄几百 KB，既不是文字也不该进正文。
    text = replace(#"<img\b[^>]*>"#, in: text, with: "\n[图片]\n")
    text = replace(#"<h1\b[^>]*>"#, in: text, with: "\n# ")
    text = replace(#"<h2\b[^>]*>"#, in: text, with: "\n## ")
    text = replace(#"<h3\b[^>]*>"#, in: text, with: "\n### ")
    text = replace(#"<li\b[^>]*>"#, in: text, with: "\n- ")
    text = replace(#"<(b|strong)\b[^>]*>"#, in: text, with: "**")
    text = replace(#"</(b|strong)>"#, in: text, with: "**")
    text = replace(#"</t[dh]>"#, in: text, with: " | ")
    text = replace(#"<br\s*/?>"#, in: text, with: "\n")
    // `</li>` 不换行：下一个 `<li>` 已经从新行开始，再换一次会在列表项之间多出空行。
    text = replace(#"</(div|p|h[1-6]|tr|ul|ol|table)>"#, in: text, with: "\n")
    text = replace(#"<[^>]+>"#, in: text, with: "")
    text = decodeEntities(text)
    // 空粗体（`****`）来自只加粗了换行的段落。
    text = text.replacingOccurrences(of: "****", with: "")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var result: [String] = []
    for line in lines {
      if line.isEmpty, result.last?.isEmpty ?? true { continue }
      result.append(line)
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replace(_ pattern: String, in text: String, with template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    return expression.stringByReplacingMatches(
      in: text,
      range: NSRange(text.startIndex..., in: text),
      withTemplate: NSRegularExpression.escapedTemplate(for: template)
    )
  }

  private static func decodeEntities(_ text: String) -> String {
    var value = text
    for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
      value = value.replacingOccurrences(of: entity, with: character)
    }
    if let expression = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
      let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
      for match in matches {
        guard let whole = Range(match.range, in: value),
              let hexMarker = Range(match.range(at: 1), in: value),
              let digits = Range(match.range(at: 2), in: value),
              let code = UInt32(value[digits], radix: value[hexMarker].isEmpty ? 10 : 16),
              let scalar = Unicode.Scalar(code)
        else { continue }
        value.replaceSubrange(whole, with: String(Character(scalar)))
      }
    }
    return value.replacingOccurrences(of: "&amp;", with: "&")
  }
}
