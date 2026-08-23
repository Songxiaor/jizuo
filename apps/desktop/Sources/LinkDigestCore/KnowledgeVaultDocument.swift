import Foundation

/// 一条历史渲染成的知识库快照：文件名 + 全文。
///
/// 和 `HistoryExportFile` 的区别不是格式细节，而是**读者不同**。那一份是导给
/// 用户自己看的存档，把运行记录（模型、token、费用、每次运行的状态）也写进去；
/// 这一份是导给外部全文检索当素材用的，那些字段在检索里一个都用不上，只会
/// 变成分母——下游按「命中次数 / 正文长度」排序，废话越多，真正相关的条目
/// 排得越靠后。所以这里只留 frontmatter、摘要和原文。
public struct KnowledgeVaultDocument: Sendable, Equatable {
  public let digestID: TaskID
  public let filename: String
  public let text: String

  public init(digestID: TaskID, filename: String, text: String) {
    self.digestID = digestID
    self.filename = filename
    self.text = text
  }
}

public enum KnowledgeVaultRenderer {
  /// 单文件硬上限。
  ///
  /// 这个数字来自下游检索器（内容看板 `vault/search` 的 `SEARCH_MAX_BYTES`）：
  /// **超过它的文件被整个跳过**，不是内容读不全，是这条内容彻底搜不到。所以
  /// 它是硬上限而不是软目标，宁可截断也不能超。
  ///
  /// 它同时也是一处跨项目的隐式耦合：下游改了那个常量，这里就失配了。
  public static let maximumFileUTF8ByteCount = 512 * 1_024

  /// 原文自身的上限，给 frontmatter 和摘要留出余量。
  public static let maximumBodyUTF8ByteCount = 200 * 1_024

  /// 摘要上限。摘要理论上不会这么长，但它和原文共享同一个文件预算，
  /// 不设上限的话一次异常的超长输出会把原文挤没。
  public static let maximumSummaryUTF8ByteCount = 64 * 1_024

  public static let truncationNotice = "（已截断，完整原文见汲作）"

  /// 文件名里日期之后、`.md` 之前的部分能占的字节数。
  /// 255 是 APFS 单个文件名分量的 UTF-8 预算，减去 `YYYY-MM-DD_` 和 `.md`。
  private static let maximumTitleUTF8ByteCount = 255 - "YYYY-MM-DD_".utf8.count - ".md".utf8.count

  /// 只有真正从网上抓回来的内容才进知识库。
  ///
  /// 历史里还躺着用户自建笔记、工作台稿件和成品（`linkdigest-note:` /
  /// `linkdigest-draft:` / `linkdigest-work:`）。那些是用户自己写的东西，
  /// 不是采集来的素材；把稿件同步进知识库，下次检索素材时会搜到自己上一稿，
  /// 那是噪音，不是材料。
  public static func isSyncable(_ projection: HistoryExportProjection) -> Bool {
    let url = projection.task.canonicalURL
    return !url.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
      && !url.hasPrefix(HistoryPlatformDisplay.draftURLPrefix)
      && !url.hasPrefix(HistoryPlatformDisplay.workURLPrefix)
  }

  public static func render(
    _ projection: HistoryExportProjection,
    timeZone: TimeZone = .current
  ) -> KnowledgeVaultDocument {
    // 元数据取「抓取来源」那一层，不能取 `snapshots.last`。
    //
    // last 是最新追加的派生层——听写稿，或画面字幕。它们既没有 author/published，
    // sourceLabel 还分别是「本机转写」「画面字幕」，直接拿来当 platform 会把
    // 平台名写成一个动作名。派生层每多一种，这个错就多一种表现。
    let snapshot = LayeredSourceDocument.captionSnapshot(in: projection.snapshots)
      ?? projection.snapshots.last
    let note = MarkdownNoteFrontmatter.parse(snapshot?.bodyText ?? "")
    let title = CapturedDocumentTitle.display(snapshot?.title, for: projection.task.canonicalURL)
    let digestID = projection.task.id

    let summary = latestSummary(projection)
    // 只看听写层，**不**把画面字幕算进来：这个字段是导出契约的一部分，下游
    // 检索按它筛选，语义扩大会悄悄改变别处的结果。要不要让它涵盖字幕层，是
    // 契约层面的决定，不该在这里顺手改掉。
    let hasTranscript = projection.snapshots.contains {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    }

    var lines: [String] = ["---", "type: digest"]
    lines.append("digest_id: \(yamlScalar(digestID.rawValue))")
    lines.append("title: \(yamlScalar(title))")
    lines.append("url: \(yamlScalar(projection.task.canonicalURL))")
    if let platform = snapshot?.sourceLabel.nonBlank {
      lines.append("platform: \(yamlScalar(platform))")
    }
    if let author = note.author?.nonBlank { lines.append("author: \(yamlScalar(author))") }
    if let published = note.published?.nonBlank { lines.append("published: \(yamlScalar(published))") }
    lines.append("captured: \(yamlScalar(timestamp(capturedMilliseconds(projection))))")
    lines.append("has_transcript: \(hasTranscript)")
    lines.append("has_summary: \(summary != nil)")
    lines.append("tags: \(yamlFlowSequence(projection.tags.map(\.name)))")
    lines.append("---")
    lines.append("")
    lines.append("# \(title)")
    lines.append("")
    // 回链是这份导出的全部意义所在：检索命中之后要能回到汲作看全文、看视频、
    // 看转写。找得到却回不去，等于没找到。
    lines.append("> 回链：\(digestURL(digestID))")
    lines.append("> 原文：\(projection.task.canonicalURL)")

    var head = lines.joined(separator: "\n") + "\n"

    if let summary {
      let bounded = truncated(summary, withinUTF8ByteCount: maximumSummaryUTF8ByteCount)
      head += "\n## 摘要\n\n" + bounded.text + (bounded.didTruncate ? "\n\n\(truncationNotice)" : "") + "\n"
    }

    // 正文要带上**所有**层。原来只导出 `snapshots.last`：有听写稿时配文就丢了，
    // 有画面字幕时听写稿也跟着丢——导出的「原文」只剩最后追加的那一层。
    // `modelInput` 是分层正文的唯一真相源，导出、总结、翻译都该走它。
    let layered = LayeredSourceDocument.modelInput(from: projection.snapshots)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let bodyText = layered.isEmpty
      ? (note.body.isEmpty ? (snapshot?.bodyText ?? "") : note.body)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      : layered
    let bodyHeader = "\n## 原文\n\n"
    // 原文预算 = 文件硬上限扣掉已经确定的部分，再和原文自身上限取小。
    // 截断按最终文件的字节数算，不是只按正文算——frontmatter 和摘要也占预算。
    let overhead = head.utf8.count + bodyHeader.utf8.count + truncationNotice.utf8.count + 8
    let bodyBudget = max(0, min(maximumBodyUTF8ByteCount, maximumFileUTF8ByteCount - overhead))
    let body = truncated(bodyText.isEmpty ? "（原文为空）" : bodyText, withinUTF8ByteCount: bodyBudget)

    var text = head + bodyHeader + body.text + "\n"
    if body.didTruncate { text += "\n\(truncationNotice)\n" }

    return .init(digestID: digestID, filename: filename(projection, timeZone: timeZone), text: text)
  }

  /// 同步专用文件名：`<YYYY-MM-DD>_<安全标题>.md`。
  ///
  /// 不复用 `HistoryExportRenderer.suggestedFilename`：同步文件名需要日期前缀
  /// 做稳定去重键，与一次性导出的命名职责不同。
  ///
  /// 日期前缀用本地时区：它是给人看的「我哪天存的」，UTC 会让晚上存的东西
  /// 显示成前一天。
  public static func filename(
    _ projection: HistoryExportProjection,
    timeZone: TimeZone = .current
  ) -> String {
    let title = CapturedDocumentTitle.display(
      projection.snapshots.last?.title,
      for: projection.task.canonicalURL
    )
    let safeTitle = HistoryExportRenderer.safeFilenameComponent(
      title,
      maximumUTF8ByteCount: maximumTitleUTF8ByteCount
    )
    return "\(dayStamp(capturedMilliseconds(projection), timeZone: timeZone))_\(safeTitle).md"
  }

  public static func digestURL(_ taskID: TaskID) -> String {
    "\(KnowledgeVaultLink.scheme)://\(KnowledgeVaultLink.digestHost)/\(taskID.rawValue)"
  }

  private static func capturedMilliseconds(_ projection: HistoryExportProjection) -> Int64 {
    projection.snapshots.last?.capturedAtMilliseconds ?? projection.task.createdAtMilliseconds
  }

  /// 最近一次成功产出的总结。翻译不是摘要，不进这一节。
  private static func latestSummary(_ projection: HistoryExportProjection) -> String? {
    let candidates = projection.runs.filter {
      $0.run.kind == .summarize && $0.run.status == .completed && $0.artifact != nil
    }
    guard let latest = candidates.max(by: { lhs, rhs in
      runTime(lhs.run) < runTime(rhs.run)
    }), let artifact = latest.artifact else { return nil }
    let body = MarkdownNoteFrontmatter.parse(artifact.bodyText).body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? nil : body
  }

  private static func runTime(_ run: HistoryRun) -> Int64 {
    run.finishedAtMilliseconds ?? run.startedAtMilliseconds ?? run.createdAtMilliseconds
  }

  // MARK: - YAML

  /// 一律加双引号。
  ///
  /// 中文标题里有太多东西会让裸标量失效：`: ` 会被读成键值对，开头的 `-`
  /// 会被读成列表项，纯数字标题会被读成数字，`yes`/`no`/`null` 会被读成布尔和空值。
  /// 逐一判断哪些需要引号既容易漏，也没有收益——标准 YAML 解析器读双引号标量
  /// 从来不出错。
  static func yamlScalar(_ value: String) -> String {
    var escaped = ""
    for character in value.unicodeScalars {
      switch character {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      default:
        // 其余控制字符按 YAML 的 \xNN 转义，否则解析器会拒绝整份文档。
        if character.value < 0x20 {
          escaped += String(format: "\\x%02x", character.value)
        } else {
          escaped.unicodeScalars.append(character)
        }
      }
    }
    return "\"\(escaped)\""
  }

  static func yamlFlowSequence(_ values: [String]) -> String {
    let items = values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(yamlScalar)
    return "[\(items.joined(separator: ", "))]"
  }

  // MARK: - 截断

  struct TruncationResult: Equatable {
    let text: String
    let didTruncate: Bool
  }

  /// 按 UTF-8 字节数截断，但以 Character 为单位取舍，避免把一个字或 emoji
  /// 从中间劈开变成乱码。
  static func truncated(_ value: String, withinUTF8ByteCount maximumByteCount: Int) -> TruncationResult {
    guard maximumByteCount > 0 else { return .init(text: "", didTruncate: !value.isEmpty) }
    if value.utf8.count <= maximumByteCount { return .init(text: value, didTruncate: false) }
    var result = ""
    var used = 0
    for character in value {
      let size = String(character).utf8.count
      if used + size > maximumByteCount { break }
      result.append(character)
      used += size
    }
    return .init(text: result, didTruncate: true)
  }

  // MARK: - 时间

  private static func timestamp(_ milliseconds: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }

  private static func dayStamp(_ milliseconds: Int64, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents(
      [.year, .month, .day],
      from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    )
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 1970,
      components.month ?? 1,
      components.day ?? 1
    )
  }
}

/// `linkdigest://` 的形状。渲染器和 App 的 URL 处理各读一份常量会漂移，
/// 所以两边都从这里取。
public enum KnowledgeVaultLink {
  public static let scheme = "linkdigest"
  public static let digestHost = "digest"

  /// 从 `linkdigest://digest/<taskID>` 取出条目 id。
  ///
  /// scheme 注册之后，任何网页都能构造这样一个链接扔给 App，所以这里只认
  /// 规范 UUID，其余一律返回 nil。调用方拿到的是一个「定位到某条历史」的
  /// 请求，不带任何副作用。
  public static func digestID(from url: URL) -> TaskID? {
    guard url.scheme?.lowercased() == scheme else { return nil }
    guard url.host?.lowercased() == digestHost else { return nil }
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count == 1, let raw = components.first else { return nil }
    return TaskID(raw)
  }
}

private extension String {
  var nonBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
