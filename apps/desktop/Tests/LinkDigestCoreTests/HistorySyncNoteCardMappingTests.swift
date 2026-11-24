import XCTest
import LinkDigestShared
@testable import LinkDigestCore

final class HistorySyncNoteCardMappingTests: XCTestCase {
  func testMapsUserNoteToTextCardUsingNoteURLIdentity() throws {
    let noteID = UUID()
    let url = try CanonicalURL.note(id: noteID).value
    let task = HistoryTask(
      id: TaskID(),
      canonicalURL: url,
      canonicalizationVersion: 1,
      createdAtMilliseconds: 100,
      updatedAtMilliseconds: 200
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: task.id,
      sequence: 1,
      envelopeCreatedAtMilliseconds: 100,
      capturedAtMilliseconds: 100,
      sourceKind: CapturedDocument.Origin.userNote.rawValue,
      sourceURL: url,
      title: "灵感",
      platform: HistoryPlatformDisplay.noteHost,
      captureMethod: "user_note",
      completeness: "complete",
      bodyText: "正文",
      characterCount: 2,
      bodySHA256: "abc",
      sourceLabel: "我的笔记",
      usedCookie: false
    )
    let detail = HistoryDetailProjection(task: task, snapshots: [snapshot], runs: [])
    let card = try XCTUnwrap(HistorySyncNoteCardMapping.card(from: detail))
    XCTAssertEqual(card.id, noteID)
    XCTAssertEqual(card.kind, .text)
    XCTAssertEqual(card.title, "灵感")
    XCTAssertEqual(card.body, "正文")
    XCTAssertNil(card.sourceURL)
  }

  func testMapsLinkWithStableURLIdentityAndSummary() throws {
    let canonical = "https://example.com/a"
    let task = HistoryTask(
      id: TaskID(),
      canonicalURL: canonical,
      canonicalizationVersion: 1,
      createdAtMilliseconds: 10,
      updatedAtMilliseconds: 20
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: task.id,
      sequence: 1,
      envelopeCreatedAtMilliseconds: 10,
      capturedAtMilliseconds: 10,
      sourceKind: CapturedDocument.Origin.manualLink.rawValue,
      sourceURL: canonical,
      title: "例",
      platform: "manual",
      captureMethod: "manual_link",
      completeness: "complete",
      bodyText: "原文很长",
      characterCount: 4,
      bodySHA256: "def",
      sourceLabel: "手动",
      usedCookie: false
    )
    let run = HistoryRun(
      id: RunID(),
      taskID: task.id,
      snapshotID: snapshot.id,
      idempotencyKey: "k",
      rerunOfRunID: nil,
      kind: .summarize,
      targetLanguage: nil,
      status: .completed,
      providerProfileID: nil,
      providerKind: nil,
      providerBaseURL: nil,
      providerAPIMode: nil,
      model: "m",
      createdAtMilliseconds: 15,
      startedAtMilliseconds: 15,
      finishedAtMilliseconds: 16,
      failureCode: nil,
      failureRetryable: nil,
      usageCost: RunUsageCost()
    )
    let artifact = HistoryArtifact(
      id: ArtifactID(),
      runID: run.id,
      contentFormat: .markdown,
      completeness: .complete,
      bodyText: "摘要一句",
      createdAtMilliseconds: 16,
      updatedAtMilliseconds: 16
    )
    let detail = HistoryDetailProjection(
      task: task,
      snapshots: [snapshot],
      runs: [.init(run: run, artifact: artifact)]
    )
    let card = try XCTUnwrap(HistorySyncNoteCardMapping.card(from: detail))
    XCTAssertEqual(card.kind, .link)
    XCTAssertEqual(card.id, SyncNoteCardIdentity.fromLinkCanonicalURL(canonical))
    XCTAssertEqual(card.summary, "摘要一句")
    XCTAssertEqual(card.sourceURL, canonical)
  }

  func testSkipsDraftAndWork() throws {
    let draftURL = try CanonicalURL.draft().value
    let task = HistoryTask(
      id: TaskID(),
      canonicalURL: draftURL,
      canonicalizationVersion: 1,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: task.id,
      sequence: 1,
      envelopeCreatedAtMilliseconds: 1,
      capturedAtMilliseconds: 1,
      sourceKind: CapturedDocument.Origin.pieceDraft.rawValue,
      sourceURL: draftURL,
      title: "稿",
      platform: HistoryPlatformDisplay.draftHost,
      captureMethod: "piece_draft",
      completeness: "complete",
      bodyText: "x",
      characterCount: 1,
      bodySHA256: "x",
      sourceLabel: "稿件",
      usedCookie: false
    )
    let detail = HistoryDetailProjection(task: task, snapshots: [snapshot], runs: [])
    XCTAssertNil(HistorySyncNoteCardMapping.card(from: detail))
  }

  func testDailyTitleRoundTripsToDailyURL() throws {
    let card = SyncNoteCardFactory.makeText(title: "2026-09-01", body: "今天")
    let url = try HistorySyncNoteCardMapping.canonicalURL(for: card)
    XCTAssertEqual(url.value, "linkdigest-note:daily-2026-09-01")
  }

  func testLinkSummaryBodyIgnoresNotesAndBlank() throws {
    let link = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/s",
      body: "原文",
      summary: "  摘要  "
    )
    XCTAssertEqual(HistorySyncNoteCardMapping.linkSummaryBody(from: link), "  摘要  ")

    // Factory 会把空白 summary 归一成 nil；这里直接构造验证桥接层对空白的防护。
    let blank = SyncNoteCard(
      id: UUID(),
      kind: .link,
      title: "t",
      body: "原文",
      summary: "   ",
      sourceURL: "https://example.com/s",
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    XCTAssertNil(HistorySyncNoteCardMapping.linkSummaryBody(from: blank))
    XCTAssertNil(HistorySyncNoteCardMapping.linkSummaryBody(from: SyncNoteCardFactory.makeText()))
  }

  func testNeedsRemoteSummaryWriteSkipsIdenticalCompletedSummary() throws {
    let canonical = "https://example.com/need"
    let task = HistoryTask(
      id: TaskID(),
      canonicalURL: canonical,
      canonicalizationVersion: 1,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 2
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: task.id,
      sequence: 1,
      envelopeCreatedAtMilliseconds: 1,
      capturedAtMilliseconds: 1,
      sourceKind: CapturedDocument.Origin.manualLink.rawValue,
      sourceURL: canonical,
      title: "t",
      platform: "manual",
      captureMethod: "manual_link",
      completeness: "complete",
      bodyText: "body",
      characterCount: 4,
      bodySHA256: "h",
      sourceLabel: "手动",
      usedCookie: false
    )
    let run = HistoryRun(
      id: RunID(),
      taskID: task.id,
      snapshotID: snapshot.id,
      idempotencyKey: "k",
      rerunOfRunID: nil,
      kind: .summarize,
      targetLanguage: nil,
      status: .completed,
      providerProfileID: nil,
      providerKind: nil,
      providerBaseURL: nil,
      providerAPIMode: nil,
      model: "m",
      createdAtMilliseconds: 2,
      startedAtMilliseconds: 2,
      finishedAtMilliseconds: 3,
      failureCode: nil,
      failureRetryable: nil,
      usageCost: RunUsageCost()
    )
    let artifact = HistoryArtifact(
      id: ArtifactID(),
      runID: run.id,
      contentFormat: .markdown,
      completeness: .complete,
      bodyText: "同一摘要",
      createdAtMilliseconds: 3,
      updatedAtMilliseconds: 3
    )
    let detail = HistoryDetailProjection(
      task: task,
      snapshots: [snapshot],
      runs: [.init(run: run, artifact: artifact)]
    )
    XCTAssertFalse(
      HistorySyncNoteCardMapping.needsRemoteSummaryWrite(detail: detail, remoteSummary: "  同一摘要  ")
    )
    XCTAssertTrue(
      HistorySyncNoteCardMapping.needsRemoteSummaryWrite(detail: detail, remoteSummary: "新摘要")
    )
    let empty = HistoryDetailProjection(task: task, snapshots: [snapshot], runs: [])
    XCTAssertTrue(
      HistorySyncNoteCardMapping.needsRemoteSummaryWrite(detail: empty, remoteSummary: "任意")
    )
  }

  /// 手机同步回读的 `transcript` 只给当前视频；作者换过视频时旧稿不能冒充当前内容。
  func testLatestTranscriptIgnoresTheOldVideosTranscript() {
    let canonical = "https://www.xiaohongshu.com/explore/1"
    let task = HistoryTask(
      id: TaskID(), canonicalURL: canonical, canonicalizationVersion: 1,
      createdAtMilliseconds: 1, updatedAtMilliseconds: 2
    )
    func snapshot(_ sequence: Int, kind: String, text: String) -> ContentSnapshot {
      ContentSnapshot(
        id: ContentSnapshotID(), taskID: task.id, sequence: sequence,
        envelopeCreatedAtMilliseconds: Int64(sequence), capturedAtMilliseconds: Int64(sequence),
        sourceKind: kind, sourceURL: canonical, title: "t", platform: "xiaohongshu",
        captureMethod: "manual_link", completeness: "complete", bodyText: text,
        characterCount: text.count, bodySHA256: String(repeating: "a", count: 64),
        sourceLabel: "小红书", usedCookie: false
      )
    }
    func media(_ snapshotID: ContentSnapshotID, character: Character, createdAt: Int64) -> MediaAsset {
      MediaAsset(
        taskID: task.id, snapshotID: snapshotID,
        relativePath: "\(String(repeating: String(character), count: 64)).mp4",
        contentSHA256: String(repeating: String(character), count: 64), byteSize: 1,
        durationSeconds: 150, platform: "xiaohongshu", transcriptionStatus: .none,
        createdAtMilliseconds: createdAt
      )
    }
    let oldCapture = snapshot(2, kind: CapturedDocument.Origin.manualLink.rawValue, text: "旧文案")
    let oldTranscript = snapshot(3, kind: CapturedDocument.Origin.localTranscription.rawValue, text: "旧视频转写")
    let newCapture = snapshot(7, kind: CapturedDocument.Origin.manualLink.rawValue, text: "新文案")
    let oldMedia = media(oldCapture.id, character: "a", createdAt: 100)
    let newMedia = media(newCapture.id, character: "b", createdAt: 700)

    let staleOnly = HistoryDetailProjection(
      task: task, snapshots: [oldCapture, oldTranscript, newCapture], runs: [],
      media: newMedia, mediaAssets: [newMedia, oldMedia]
    )
    XCTAssertNil(HistorySyncNoteCardMapping.latestTranscript(in: staleOnly))

    let newTranscript = snapshot(8, kind: CapturedDocument.Origin.localTranscription.rawValue, text: "新视频转写")
    let current = HistoryDetailProjection(
      task: task, snapshots: [oldCapture, oldTranscript, newCapture, newTranscript], runs: [],
      media: newMedia, mediaAssets: [newMedia, oldMedia]
    )
    XCTAssertEqual(HistorySyncNoteCardMapping.latestTranscript(in: current), "新视频转写")
  }
}
