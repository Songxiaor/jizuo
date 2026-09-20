import Foundation
import LinkDigestShared

/// 把桌面 History 投影成 Companion `SyncNoteCard`，以及反向落回 History 所需的纯映射。
public enum HistorySyncNoteCardMapping {
  public static let voiceCaptureMethod = "user_note_voice"

  /// 是否进入 Companion 同步（笔记 + http(s) 链接；稿件/作品不同步）。
  public static func isSyncable(canonicalURL raw: String) -> Bool {
    guard let url = try? CanonicalURL(raw) else { return false }
    if url.isNote { return true }
    if url.isDraft || url.isWork { return false }
    return raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")
  }

  public static func card(from detail: HistoryDetailProjection) -> SyncNoteCard? {
    guard isSyncable(canonicalURL: detail.task.canonicalURL) else { return nil }
    guard let snapshot = primaryContentSnapshot(in: detail) else { return nil }

    if snapshot.sourceKind == CapturedDocument.Origin.userNote.rawValue {
      guard let id = SyncNoteCardIdentity.fromNoteCanonicalURL(detail.task.canonicalURL) else {
        return nil
      }
      let kind: SyncNoteCard.Kind =
        snapshot.captureMethod == voiceCaptureMethod ? .voice : .text
      return SyncNoteCard(
        id: id,
        kind: kind,
        title: snapshot.title ?? UserNoteDocument.untitledTitle,
        body: snapshot.bodyText,
        summary: nil,
        sourceURL: nil,
        createdAtMilliseconds: detail.task.createdAtMilliseconds,
        updatedAtMilliseconds: detail.task.updatedAtMilliseconds
      )
    }

    guard
      snapshot.sourceKind == CapturedDocument.Origin.browserCapture.rawValue
        || snapshot.sourceKind == CapturedDocument.Origin.manualLink.rawValue
    else {
      return nil
    }

    let id = SyncNoteCardIdentity.fromLinkCanonicalURL(detail.task.canonicalURL)
    return SyncNoteCard(
      id: id,
      kind: .link,
      title: snapshot.title ?? detail.task.canonicalURL,
      body: snapshot.bodyText,
      summary: latestSummary(in: detail),
      transcript: latestTranscript(in: detail),
      sourceURL: detail.task.canonicalURL,
      createdAtMilliseconds: detail.task.createdAtMilliseconds,
      updatedAtMilliseconds: detail.task.updatedAtMilliseconds
    )
  }

  /// 远端笔记卡对应的本机 canonical URL。
  public static func canonicalURL(for card: SyncNoteCard) throws -> CanonicalURL {
    switch card.kind {
    case .text, .voice:
      if looksLikeDailyTitle(card.title) {
        return try CanonicalURL("\(CanonicalURL.noteScheme):daily-\(card.title.lowercased())")
      }
      return try CanonicalURL.note(id: card.id)
    case .link:
      guard let raw = card.sourceURL else { throw SyncNoteCardValidationError.linkMissingSourceURL }
      return try CanonicalURL(raw)
    }
  }

  public static func document(forApplying card: SyncNoteCard) throws -> CapturedDocument {
    try SyncNoteCardValidator.validate(card)
    let url = try canonicalURL(for: card)
    let timestamp = iso8601(fromMilliseconds: card.updatedAtMilliseconds)
    switch card.kind {
    case .text:
      return CapturedDocument(
        createdAt: timestamp,
        origin: .userNote,
        url: url.value,
        title: card.title,
        platform: HistoryPlatformDisplay.noteHost,
        method: "user_note",
        text: card.body,
        completeness: "complete",
        capturedAt: timestamp,
        sourceLabel: "我的笔记"
      )
    case .voice:
      return CapturedDocument(
        createdAt: timestamp,
        origin: .userNote,
        url: url.value,
        title: card.title,
        platform: HistoryPlatformDisplay.noteHost,
        method: voiceCaptureMethod,
        text: card.body,
        completeness: "complete",
        capturedAt: timestamp,
        sourceLabel: "口述笔记"
      )
    case .link:
      return CapturedDocument(
        createdAt: timestamp,
        origin: .manualLink,
        url: url.value,
        title: card.title,
        platform: "manual",
        method: "manual_link_sync",
        text: card.body,
        completeness: "complete",
        capturedAt: timestamp,
        sourceLabel: "手机同步"
      )
    }
  }

  public static func primaryContentSnapshot(in detail: HistoryDetailProjection) -> ContentSnapshot? {
    let preferred = detail.snapshots.reversed().first {
      $0.sourceKind != CapturedDocument.Origin.localTranscription.rawValue
    }
    return preferred ?? detail.snapshots.last
  }

  public static func latestSummary(in detail: HistoryDetailProjection) -> String? {
    let completed = detail.runs
      .filter { $0.run.kind == .summarize && $0.run.status == .completed }
      .sorted { $0.run.createdAtMilliseconds > $1.run.createdAtMilliseconds }
    guard let body = completed.first?.artifact?.bodyText else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : body
  }

  /// 本机转写快照 → Companion `transcript`，供手机同步回读。
  public static func latestTranscript(in detail: HistoryDetailProjection) -> String? {
    let snapshot = detail.snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    }
    guard let body = snapshot?.bodyText else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : body
  }

  /// 链接卡上可写回 History 的 summary 正文；笔记卡或空白则 nil。
  public static func linkSummaryBody(from card: SyncNoteCard) -> String? {
    guard card.kind == .link, !card.isDeleted else { return nil }
    guard let summary = card.summary else { return nil }
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : summary
  }

  /// 远端 summary 是否需要落成一条新的 completed summarize artifact。
  ///
  /// 已有相同（按 trim 比较）正文的最新 completed 摘要则跳过，避免重复 run。
  public static func needsRemoteSummaryWrite(
    detail: HistoryDetailProjection,
    remoteSummary: String
  ) -> Bool {
    let remoteTrimmed = remoteSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remoteTrimmed.isEmpty else { return false }
    guard let existing = latestSummary(in: detail) else { return true }
    return existing.trimmingCharacters(in: .whitespacesAndNewlines) != remoteTrimmed
  }

  public static func looksLikeDailyTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 10 else { return false }
    let parts = trimmed.split(separator: "-")
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else { return false }
    return true
  }

  private static func iso8601(fromMilliseconds ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    return ISO8601DateFormatter().string(from: date)
  }
}
