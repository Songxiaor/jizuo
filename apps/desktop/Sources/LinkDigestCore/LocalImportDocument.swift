import CryptoKit
import Foundation

/// 本机导入素材的来源。rawValue 就是 `linkdigest-local://<source>/…` 里的 source 段，
/// 也是侧栏平台分组用的 host——改名等于把已导入的条目挪出原来的分组。
public enum LocalImportSource: String, Sendable, CaseIterable {
  case voiceMemos = "voicememos"
  case files = "localfiles"
  case appleNotes = "applenotes"
}

/// 本机导入素材的条目组装。
///
/// 和笔记一样走 `tasks` + `content_snapshots`，于是标签、搜索、总结、导出、MCP
/// 全部零改动可用。区别是它们算「资料」而不是「笔记」：出现在全部资料和平台分组里。
public enum LocalImportDocument {
  /// 录音在转写之前没有文字，但条目不能没有正文（校验器拒绝空内容）。
  /// 这段占位既让列表行有内容可看，也告诉用户下一步该做什么。
  public static func voiceMemoPlaceholder(durationSeconds: Double?) -> String {
    var lines = ["这是一条语音备忘录，还没有转写。"]
    if let durationSeconds, durationSeconds > 0 {
      lines.append("时长：\(formattedDuration(durationSeconds))")
    }
    lines.append("点「转写」即可在本机把录音转成文字。")
    return lines.joined(separator: "\n\n")
  }

  public static func mediaPlaceholder(fileName: String, durationSeconds: Double?, hasVideo: Bool) -> String {
    var lines = ["从本机导入的\(hasVideo ? "视频" : "音频")：\(fileName)"]
    if let durationSeconds, durationSeconds > 0 {
      lines.append("时长：\(formattedDuration(durationSeconds))")
    }
    lines.append("点「转写」即可在本机把声音转成文字。")
    return lines.joined(separator: "\n\n")
  }

  public static func voiceMemo(
    recordingID: String,
    title: String?,
    recordedAt: Date?,
    durationSeconds: Double?,
    now: Date = Date()
  ) throws -> CapturedDocument {
    let url = try CanonicalURL.localImport(
      source: LocalImportSource.voiceMemos.rawValue,
      identifier: stableIdentifier(recordingID)
    )
    let resolvedTitle = cleanedTitle(title)
      ?? recordedAt.map { "语音备忘录 \(dateTitle($0))" }
      ?? "语音备忘录"
    return make(
      url: url,
      title: resolvedTitle,
      source: .voiceMemos,
      method: "voice_memos_import",
      // 录制时间写进属性头：列表与阅读页显示「什么时候录的」，而不是「什么时候导入的」。
      text: withProperties(voiceMemoPlaceholder(durationSeconds: durationSeconds), author: nil, published: recordedAt),
      completeness: "partial",
      capturedAt: recordedAt ?? now,
      sourceLabel: "语音备忘录",
      now: now
    )
  }

  /// `contentSHA256` 既是 URL 身份也是去重键：同一份文件拖两次只会有一条。
  public static func file(
    contentSHA256: String,
    fileName: String,
    text: String,
    completeness: String,
    method: String,
    fileDate: Date?,
    now: Date = Date()
  ) throws -> CapturedDocument {
    let url = try CanonicalURL.localImport(
      source: LocalImportSource.files.rawValue,
      identifier: contentSHA256.lowercased()
    )
    let base = (fileName as NSString).deletingPathExtension
    return make(
      url: url,
      title: cleanedTitle(base) ?? fileName,
      source: .files,
      method: method,
      text: text,
      completeness: completeness,
      capturedAt: fileDate ?? now,
      sourceLabel: "本地文件",
      now: now
    )
  }

  /// 导入图片的正文：原图在前，识别出的文字单独成节。
  ///
  /// 识图结果是一行一个文字块。阅读页把相邻的单换行并成同一段，截图里的几十个
  /// 按钮、数字会挤成一整坨；这里给每行补上 Markdown 硬换行（行尾两个空格），
  /// 并丢掉「•••.....。」这种没有任何字母、数字、汉字的杂点行。
  public static func imageBody(fileName: String, reference: String, recognizedText: String?) -> String {
    let image = "![\(fileName)](\(reference))"
    let lines = (recognizedText ?? "")
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in line.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
    guard !lines.isEmpty else { return image + "\n\n（图片里没有识别到文字。）" }
    return image + "\n\n" + imageTextHeading + "\n\n" + lines.joined(separator: "  \n")
  }

  static let imageTextHeading = "## 图片里的文字"

  /// 把 `imageBody` 拆回「图」和「识别出的文字」。阅读页只把图放在正文里，文字收进
  /// 一条可展开的小节——整段大字紧跟在同样内容的图片下面，读起来是重复的。
  /// 库里存的仍是完整正文，搜索、总结、导出都照常用得到这些文字。
  public static func splitImageBody(_ body: String) -> (image: String, recognizedText: String?) {
    guard let range = body.range(of: "\n\n" + imageTextHeading + "\n\n") else {
      return (body, nil)
    }
    let text = body[range.upperBound...]
      .replacingOccurrences(of: "  \n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (String(body[..<range.lowerBound]), text.isEmpty ? nil : text)
  }

  /// TXT 和 PDF 抽出的是纯文字，不是 Markdown：一行就是一行。阅读页会把相邻的单换行
  /// 并成一段（「第一行第二行」连成一串），所以给每行补上硬换行，空行仍分段。
  public static func preservingLineBreaks(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n").map { line in
      String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
    }
    var output: [String] = []
    for (index, line) in lines.enumerated() {
      let next = index + 1 < lines.count ? lines[index + 1] : ""
      output.append(!line.isEmpty && !next.isEmpty ? line + "  " : line)
    }
    return output.joined(separator: "\n")
  }

  /// Word / RTF 读出来每个换行就是一个段落；拉开成空行分隔，阅读页才会分段显示。
  public static func documentParagraphs(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2028}", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  /// 系统「备忘录」里的一条笔记。
  ///
  /// 文件夹写进 `author`：列表行和卡片本来就显示作者，于是不用新增任何界面就能
  /// 看出这条来自哪个文件夹，搜索也能按文件夹名命中。
  public static func appleNote(
    noteID: String,
    title: String?,
    folder: String?,
    createdAt: Date?,
    text: String,
    now: Date = Date()
  ) throws -> CapturedDocument {
    let url = try CanonicalURL.localImport(
      source: LocalImportSource.appleNotes.rawValue,
      identifier: noteIdentifier(noteID)
    )
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（这条备忘录没有文字内容。）" : text
    return make(
      url: url,
      title: cleanedTitle(title) ?? "无标题备忘录",
      source: .appleNotes,
      method: "apple_notes_import",
      text: withProperties(body, author: folder, published: createdAt),
      completeness: "complete",
      capturedAt: createdAt ?? now,
      sourceLabel: "备忘录",
      now: now
    )
  }

  /// 备忘录 ID 形如 `x-coredata://<库>/ICNote/p123`，含 `/` 与 `:`，不能直接当 URL 段；
  /// 取稳定哈希，同一条备忘录每次同步都落回同一个条目。
  public static func noteIdentifier(_ raw: String) -> String {
    "n" + SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  static func withProperties(_ body: String, author: String?, published: Date?) -> String {
    let trimmedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)
    return MarkdownNoteFrontmatter(
      author: trimmedAuthor?.isEmpty == false ? trimmedAuthor : nil,
      published: published.map { ISO8601DateFormatter().string(from: $0) },
      body: body
    ).render()
  }

  /// 系统录音 ID 通常是 UUID，但不保证；只留 URL 身份段允许的字符，
  /// 其余一律换成 `-`，再兜底成原文的哈希，保证不同录音不会撞成同一条。
  public static func stableIdentifier(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    if !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(allowed.contains) { return trimmed }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return "h" + String(hash, radix: 16)
  }

  private static func make(
    url: CanonicalURL,
    title: String,
    source: LocalImportSource,
    method: String,
    text: String,
    completeness: String,
    capturedAt: Date,
    sourceLabel: String,
    now: Date
  ) -> CapturedDocument {
    let formatter = ISO8601DateFormatter()
    return CapturedDocument(
      createdAt: formatter.string(from: now),
      origin: .localImport,
      url: url.value,
      title: title,
      platform: source.rawValue,
      method: method,
      text: text,
      completeness: completeness,
      capturedAt: formatter.string(from: capturedAt),
      sourceLabel: sourceLabel
    )
  }

  private static func cleanedTitle(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let title = UserNoteDocument.sanitizedTitle(raw)
    guard !title.isEmpty else { return nil }
    return title.count > 120 ? String(title.prefix(120)) + "…" : title
  }

  private static func dateTitle(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  public static func formattedDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }
}
