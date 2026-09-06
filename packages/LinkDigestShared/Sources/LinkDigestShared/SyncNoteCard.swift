import Foundation

/// 跨 Mac / iOS 同步的「笔记卡」。
///
/// 这是 Companion 同步合同，不是桌面 SQLite 的完整 History 模型。
/// 桌面侧以后再把 HistoryTask / 用户笔记映射进此投影；同步载荷里
/// **不得**出现 API Key、Cookie 或本机绝对路径。
public struct SyncNoteCard: Codable, Sendable, Equatable, Identifiable, Hashable {
  public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
    /// 用户手写文字笔记。
    case text
    /// 口述转写后的文字笔记（正文即转写结果）。
    case voice
    /// 链接抓取 + 可选总结。
    case link
  }

  /// 合同版本。字段增减时递增，旧端必须能拒绝或忽略未知版本。
  public static let currentSchemaVersion = 1

  public let id: UUID
  public var kind: Kind
  public var title: String
  /// 手写正文、口述转写，或链接抓到的原文。
  public var body: String
  /// 链接笔记的 AI 总结；文字/口述笔记可空。
  public var summary: String?
  /// AI 翻译结果（与总结并列；可对链接或任意有正文的笔记生成）。
  public var translation: String?
  /// 音视频 / 口述之外的在线转写结果（与 Mac 转写语义对齐的 Companion 投影）。
  public var transcript: String?
  /// 非 nil 表示手机请求 Mac 做完整音视频转写；Mac 处理后应清空并写回 `transcript`。
  public var transcriptionRequestedAtMilliseconds: Int64?
  /// 仅 `kind == .link` 使用；其它类型必须为 nil。
  public var sourceURL: String?
  public var createdAtMilliseconds: Int64
  public var updatedAtMilliseconds: Int64
  /// 软删除时间；非 nil 表示对各端都应视为已删除。
  public var deletedAtMilliseconds: Int64?
  public var schemaVersion: Int

  public init(
    id: UUID = UUID(),
    kind: Kind,
    title: String,
    body: String,
    summary: String? = nil,
    translation: String? = nil,
    transcript: String? = nil,
    transcriptionRequestedAtMilliseconds: Int64? = nil,
    sourceURL: String? = nil,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64,
    deletedAtMilliseconds: Int64? = nil,
    schemaVersion: Int = SyncNoteCard.currentSchemaVersion
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.body = body
    self.summary = summary
    self.translation = translation
    self.transcript = transcript
    self.transcriptionRequestedAtMilliseconds = transcriptionRequestedAtMilliseconds
    self.sourceURL = sourceURL
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.deletedAtMilliseconds = deletedAtMilliseconds
    self.schemaVersion = schemaVersion
  }

  public var isDeleted: Bool { deletedAtMilliseconds != nil }

  /// 列表预览用的一行摘要。
  public var previewLine: String {
    let source = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
    let primary = (source?.isEmpty == false ? source! : body)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if primary.isEmpty { return title }
    return primary
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init) ?? primary
  }
}

public enum SyncNoteCardFactory {
  public static let untitledTitle = "无标题笔记"
  public static let placeholderBody = "在这里写下你的想法…"

  public static func nowMilliseconds(_ date: Date = Date()) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
  }

  public static func makeText(
    id: UUID = UUID(),
    title: String? = nil,
    body: String? = nil,
    now: Date = Date()
  ) -> SyncNoteCard {
    let ms = nowMilliseconds(now)
    let resolvedBody = normalizedBody(body) ?? placeholderBody
    let resolvedTitle = normalizedTitle(title) ?? untitledTitle
    return SyncNoteCard(
      id: id,
      kind: .text,
      title: resolvedTitle,
      body: resolvedBody,
      summary: nil,
      translation: nil,
      transcript: nil,
      sourceURL: nil,
      createdAtMilliseconds: ms,
      updatedAtMilliseconds: ms
    )
  }

  public static func makeVoice(
    id: UUID = UUID(),
    title: String? = nil,
    transcript: String,
    now: Date = Date()
  ) -> SyncNoteCard {
    let ms = nowMilliseconds(now)
    let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = normalizedTitle(title)
      ?? derivedTitle(fromBody: body)
      ?? "口述笔记"
    return SyncNoteCard(
      id: id,
      kind: .voice,
      title: resolvedTitle,
      body: body.isEmpty ? "（空的口述）" : body,
      summary: nil,
      translation: nil,
      transcript: nil,
      sourceURL: nil,
      createdAtMilliseconds: ms,
      updatedAtMilliseconds: ms
    )
  }

  public static func makeLink(
    id: UUID? = nil,
    sourceURL: String,
    title: String? = nil,
    body: String,
    summary: String? = nil,
    translation: String? = nil,
    transcript: String? = nil,
    now: Date = Date()
  ) -> SyncNoteCard {
    let ms = nowMilliseconds(now)
    let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = normalizedTitle(title) ?? url
    let resolvedID = id ?? SyncNoteCardIdentity.fromLinkCanonicalURL(url)
    return SyncNoteCard(
      id: resolvedID,
      kind: .link,
      title: resolvedTitle.isEmpty ? url : resolvedTitle,
      body: body,
      summary: normalizedOptional(summary),
      translation: normalizedOptional(translation),
      transcript: normalizedOptional(transcript),
      sourceURL: url,
      createdAtMilliseconds: ms,
      updatedAtMilliseconds: ms
    )
  }

  public static func softDelete(_ card: SyncNoteCard, at date: Date = Date()) -> SyncNoteCard {
    var next = card
    let ms = nowMilliseconds(date)
    next.deletedAtMilliseconds = ms
    // 墓碑必须严格新于原文时间戳，避免同毫秒合并丢掉删除。
    next.updatedAtMilliseconds = max(card.updatedAtMilliseconds + 1, ms)
    return next
  }

  /// 合并两端版本：较新的 `updatedAtMilliseconds` 获胜；同戳时墓碑优先，便于删除跨端传播。
  public static func merge(local: SyncNoteCard, remote: SyncNoteCard) -> SyncNoteCard {
    precondition(local.id == remote.id)
    if local.updatedAtMilliseconds > remote.updatedAtMilliseconds { return local }
    if remote.updatedAtMilliseconds > local.updatedAtMilliseconds { return remote }
    if local.isDeleted != remote.isDeleted {
      return local.isDeleted ? local : remote
    }
    return remote
  }

  public static func derivedTitle(fromBody body: String) -> String? {
    for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      guard line.hasPrefix("# ") else { return nil }
      let title = sanitizedTitle(String(line.dropFirst(2)))
      guard !title.isEmpty else { return nil }
      return title.count > 120 ? String(title.prefix(120)) + "…" : title
    }
    return nil
  }

  public static func sanitizedTitle(_ raw: String) -> String {
    let disallowed = CharacterSet.controlCharacters
      .union(.illegalCharacters)
      .union(CharacterSet(charactersIn: "\u{FFF9}\u{FFFA}\u{FFFB}\u{FFFC}"))
    let mapped = raw.unicodeScalars.map { disallowed.contains($0) ? " " : Character($0) }
    return String(mapped)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }

  private static func normalizedTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let cleaned = sanitizedTitle(title)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func normalizedBody(_ body: String?) -> String? {
    guard let body else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : body
  }

  private static func normalizedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
  }
}

public enum SyncNoteCardValidationError: Error, Sendable, Equatable {
  case unsupportedSchemaVersion(Int)
  case linkMissingSourceURL
  case nonLinkHasSourceURL
  case emptyIdentifier
}

public enum SyncNoteCardValidator {
  public static func validate(_ card: SyncNoteCard) throws {
    guard card.schemaVersion > 0, card.schemaVersion <= SyncNoteCard.currentSchemaVersion else {
      throw SyncNoteCardValidationError.unsupportedSchemaVersion(card.schemaVersion)
    }
    switch card.kind {
    case .link:
      guard let url = card.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
        throw SyncNoteCardValidationError.linkMissingSourceURL
      }
    case .text, .voice:
      if card.sourceURL != nil {
        throw SyncNoteCardValidationError.nonLinkHasSourceURL
      }
    }
  }
}
