import Foundation

/// The portable, local-only formats offered by the History detail screen.
public enum HistoryExportFormat: String, CaseIterable, Sendable, Equatable {
  case markdown
  case plainText
  case json

  public var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .plainText: "txt"
    case .json: "json"
    }
  }
}

/// A fully rendered export. Core deliberately returns bytes rather than a URL:
/// selecting a directory and writing remain macOS UI responsibilities.
public struct HistoryExportFile: Sendable, Equatable {
  public let format: HistoryExportFormat
  public let suggestedFilename: String
  public let data: Data

  public init(format: HistoryExportFormat, suggestedFilename: String, data: Data) {
    self.format = format
    self.suggestedFilename = suggestedFilename
    self.data = data
  }
}

public enum HistoryExportRenderer {
  /// APFS/HFS+ expose the POSIX NAME_MAX budget as 255 UTF-8 bytes for one
  /// filename component. Reserve the version/extension before trimming title.
  private static let maximumSuggestedFilenameUTF8ByteCount = 255

  public static func render(_ projection: HistoryExportProjection, as format: HistoryExportFormat) throws -> HistoryExportFile {
    let data: Data
    switch format {
    case .markdown:
      data = Data(markdown(projection).utf8)
    case .plainText:
      data = Data(plainText(projection).utf8)
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(projection)
    }
    return .init(format: format, suggestedFilename: suggestedFilename(for: projection, as: format), data: data)
  }

  public static func suggestedFilename(for projection: HistoryExportProjection, as format: HistoryExportFormat) -> String {
    let rawTitle = projection.snapshots.last?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    // 版本号只写在导出内容里（JSON 的 formatVersion 字段、md/txt 的「导出版本」行），
    // 不进文件名：`<标题>.1.json` 会被误认成系统重名计数或重复文件。
    let suffix = ".\(format.fileExtension)"
    let maximumBaseUTF8ByteCount = maximumSuggestedFilenameUTF8ByteCount - suffix.utf8.count
    let base = safeFilenameComponent(
      rawTitle?.isEmpty == false ? rawTitle! : "LinkDigest 历史",
      maximumUTF8ByteCount: maximumBaseUTF8ByteCount
    )
    return "\(base)\(suffix)"
  }

  public static func safeFilenameComponent(_ value: String, maximumUTF8ByteCount: Int = 255) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:")
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\u{0000}"))
    var result = String(value.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined())
    result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.hasPrefix(".") {
      result.removeFirst()
      result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let bounded = prefix(result, withinUTF8ByteCount: maximumUTF8ByteCount)
    if !bounded.isEmpty { return bounded }
    return prefix("LinkDigest 历史", withinUTF8ByteCount: maximumUTF8ByteCount)
  }

  /// Iterate Swift Characters so an extended grapheme cluster is either kept
  /// whole or omitted. If the first Character alone exceeds the budget, skip
  /// it so a later safe Character (or the fallback) can still be used.
  private static func prefix(_ value: String, withinUTF8ByteCount maximumByteCount: Int) -> String {
    guard maximumByteCount > 0 else { return "" }
    var result = ""
    var usedByteCount = 0
    for character in value {
      let characterByteCount = String(character).utf8.count
      if characterByteCount > maximumByteCount - usedByteCount {
        if result.isEmpty { continue }
        break
      }
      result.append(character)
      usedByteCount += characterByteCount
    }
    return result
  }

  private static func markdown(_ projection: HistoryExportProjection) -> String {
    let title = displayTitle(projection)
    let sourceURL = projection.task.canonicalURL
    let snapshot = projection.snapshots.last
    let note = MarkdownNoteFrontmatter.parse(snapshot?.bodyText ?? "")
    // 用户自己写的笔记没有来源。`linkdigest-note:<uuid>` 是本机的行标识，
    // 导进 Obsidian 后它既打不开也没有意义，只是一行噪音。
    let isUserNote = sourceURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
    // Tolaria/Obsidian-compatible header when exporting .md
    var lines: [String] = ["---", "title: \(yamlString(title))"]
    if !isUserNote { lines.append("source: \(yamlString(sourceURL))") }
    if let author = note.author?.nonBlank { lines.append("author: \(yamlString(author))") }
    if let published = note.published?.nonBlank { lines.append("published: \(yamlString(published))") }
    let tags = projection.tags.map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !tags.isEmpty {
      lines.append("tags:")
      for tag in tags { lines.append("  - \(yamlString(tag))") }
    }
    lines += [
      "created: \(yamlString(timestamp(projection.task.createdAtMilliseconds)))",
      "---",
      "",
      "# \(title)",
      "",
    ]
    if !isUserNote { lines.append("- 来源：\(sourceURL)") }
    lines += [
      "- 标签：\(tagLine(projection.tags))",
      "- 导出版本：\(projection.formatVersion)",
      "- 创建时间（UTC）：\(timestamp(projection.task.createdAtMilliseconds))",
      "- 最近更新时间（UTC）：\(timestamp(projection.task.updatedAtMilliseconds))",
      "",
      // 笔记的正文不是「原文」——那个词的意思是「抓回来的那一份」。
      isUserNote ? "## 正文" : "## 最近原文",
      "",
    ]
    if let snapshot {
      let body = note.body.isEmpty ? snapshot.bodyText : note.body
      // 抓取的捕获时间、来源标签、完整性对笔记都不成立：它没有被捕获过。
      if !isUserNote {
        lines += [
          "- 捕获时间（UTC）：\(timestamp(snapshot.capturedAtMilliseconds))",
          "- 来源标签：\(snapshot.sourceLabel)",
          "- 完整性：\(snapshot.completeness)",
          "",
        ]
      }
      lines.append(body.isEmpty ? (isUserNote ? "（笔记为空）" : "（原文为空）") : body)
    } else {
      lines.append(isUserNote ? "（笔记为空）" : "（没有保存的原文）")
    }
    lines += ["", "## 运行记录"]
    if projection.runs.isEmpty { lines += ["", "（没有运行记录）"] }
    for (index, detail) in projection.runs.enumerated() {
      let run = detail.run
      lines += ["", "### \(index + 1). \(action(run.kind)) · \(status(run.status))", "", "- 动作：\(action(run.kind))", "- 状态：\(status(run.status))", "- 时间（UTC）：\(runTime(run))", "- 模型：\(run.model?.nonBlank ?? "—")", "- Token：\(tokens(run.usageCost))", "- 费用：\(cost(run.usageCost))"]
      if let artifact = detail.artifact {
        let resultBody = MarkdownNoteFrontmatter.parse(artifact.bodyText).body
        lines += ["- 结果完整性：\(artifact.completeness == .complete ? "完整" : "部分结果")", "- 结果格式：\(artifact.contentFormat == .markdown ? "Markdown" : "纯文本")", "", "#### 结果", "", resultBody.isEmpty ? "（结果为空）" : resultBody]
      } else {
        lines += ["- 结果：无可导出的结果"]
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func yamlString(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  private static func plainText(_ projection: HistoryExportProjection) -> String {
    let isUserNote = projection.task.canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
    var lines = ["标题: \(displayTitle(projection))"]
    if !isUserNote { lines.append("来源: \(projection.task.canonicalURL)") }
    lines += ["标签: \(tagLine(projection.tags))", "导出版本: \(projection.formatVersion)", "创建时间（UTC）: \(timestamp(projection.task.createdAtMilliseconds))", "最近更新时间（UTC）: \(timestamp(projection.task.updatedAtMilliseconds))", "", isUserNote ? "正文:" : "最近原文:"]
    if let snapshot = projection.snapshots.last {
      if !isUserNote {
        lines += ["捕获时间（UTC）: \(timestamp(snapshot.capturedAtMilliseconds))", "来源标签: \(snapshot.sourceLabel)", "完整性: \(snapshot.completeness)"]
      }
      lines.append(snapshot.bodyText.isEmpty ? (isUserNote ? "（笔记为空）" : "（原文为空）") : snapshot.bodyText)
    } else { lines.append(isUserNote ? "（笔记为空）" : "（没有保存的原文）") }
    lines += ["", "运行记录:"]
    if projection.runs.isEmpty { lines.append("（没有运行记录）") }
    for (index, detail) in projection.runs.enumerated() {
      let run = detail.run
      lines += ["", "[\(index + 1)] 动作: \(action(run.kind))", "状态: \(status(run.status))", "时间（UTC）: \(runTime(run))", "模型: \(run.model?.nonBlank ?? "—")", "Token: \(tokens(run.usageCost))", "费用: \(cost(run.usageCost))"]
      if let artifact = detail.artifact {
        lines += ["结果完整性: \(artifact.completeness == .complete ? "完整" : "部分结果")", "结果格式: \(artifact.contentFormat == .markdown ? "Markdown" : "纯文本")", "结果:", artifact.bodyText.isEmpty ? "（结果为空）" : artifact.bodyText]
      } else { lines.append("结果: 无可导出的结果") }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func displayTitle(_ projection: HistoryExportProjection) -> String {
    CapturedDocumentTitle.display(
      projection.snapshots.last?.title,
      for: projection.task.canonicalURL
    )
  }
  private static func tagLine(_ tags: [HistoryTag]) -> String {
    let value = tags.map(\.name).joined(separator: ", ")
    return value.isEmpty ? "—" : value
  }

  private static func timestamp(_ milliseconds: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }

  private static func runTime(_ run: HistoryRun) -> String {
    timestamp(run.finishedAtMilliseconds ?? run.startedAtMilliseconds ?? run.createdAtMilliseconds)
  }
  private static func action(_ kind: RunKind) -> String { kind == .summarize ? "总结" : "翻译" }
  private static func status(_ value: RunStatus) -> String {
    switch value {
    case .queued: "等待中"; case .running: "处理中"; case .completed: "已完成"
    case .stopped: "已停止"; case .failed: "未完成"; case .interrupted: "已中断"
    }
  }
  private static func tokens(_ usage: RunUsageCost) -> String {
    var total = usage.totalTokens
    if total == nil, let input = usage.inputTokens, let output = usage.outputTokens {
      let sum = input.addingReportingOverflow(output)
      if !sum.overflow { total = sum.partialValue }
    }
    return "输入 \(usage.inputTokens.map(String.init) ?? "—") / 输出 \(usage.outputTokens.map(String.init) ?? "—") / 总计 \(total.map(String.init) ?? "—")"
  }
  private static func cost(_ usage: RunUsageCost) -> String {
    guard let amount = usage.costAmountMicros, let currency = usage.costCurrencyCode else { return "—" }
    return "\(currency) \(Decimal(amount) / 1_000_000)"
  }
}

private extension String {
  var nonBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
