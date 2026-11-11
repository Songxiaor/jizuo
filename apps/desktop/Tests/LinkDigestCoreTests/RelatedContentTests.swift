import XCTest
@testable import LinkDigestCore

final class RelatedContentTests: XCTestCase {
  // MARK: - 查询文本

  func testQueryPrefersSummaryOverBodyAndIsBounded() {
    let title = "为什么定价比功能重要"
    let summary = "## 摘要\n\n这篇讲的是定价、收费和用户愿意付多少钱。"
    let body = "正文开头：先讲一个和主题关系不大的故事。"

    let text = RelatedContentQuery.text(title: title, summary: summary, body: body)
    XCTAssertTrue(text.hasPrefix("\(title)\n"))
    XCTAssertTrue(text.contains("定价"))
    XCTAssertFalse(text.contains("和主题关系不大的故事"), "有总结时不该再拿正文开头凑")
    XCTAssertLessThanOrEqual(text.count, RelatedContentQuery.limit)

    let long = RelatedContentQuery.text(
      title: String(repeating: "题", count: 100),
      summary: String(repeating: "字", count: 2_000),
      body: nil
    )
    XCTAssertEqual(long.count, RelatedContentQuery.limit, "定长截断")
  }

  func testQueryFallsBackToBodyOpeningWhenSummaryIsMissing() {
    let text = RelatedContentQuery.text(
      title: "一条视频",
      summary: nil,
      body: "这是一句很短的配文，讲了 AI 视频工作流和它为什么省时间。"
    )
    XCTAssertTrue(text.hasPrefix("一条视频\n"))
    XCTAssertTrue(text.contains("AI 视频工作流"))

    let emptySummary = RelatedContentQuery.text(title: "标题", summary: "   ", body: "正文开头这一段。")
    XCTAssertTrue(emptySummary.contains("正文开头这一段"), "空白总结要当成没有总结")
  }

  func testBodyIsNotReadWhenSummaryExists() {
    var bodyReads = 0
    let text = RelatedContentQuery.text(title: "标题", summary: "总结内容", body: { bodyReads += 1; return "很长的正文" }())
    XCTAssertTrue(text.contains("总结内容"))
    XCTAssertEqual(bodyReads, 0, "有总结就不该为了拼查询去拆正文")

    let withoutSummary = RelatedContentQuery.text(title: "标题", summary: nil, body: { bodyReads += 1; return "正文开头" }())
    XCTAssertTrue(withoutSummary.contains("正文开头"))
    XCTAssertEqual(bodyReads, 1, "没有总结才读一次正文")
  }

  // MARK: - 结果筛选

  func testSelectionKeepsOnlyOwnAppleNotesAndVoiceMemos() {
    let current = TaskID(UUID())
    let external = TaskID(UUID())
    let ownNote = TaskID(UUID())
    let memo = TaskID(UUID())
    let voice = TaskID(UUID())
    let file = TaskID(UUID())
    let ranked: [(taskID: TaskID, score: Float)] = [
      (current, 0.95),
      (external, 0.90),
      (ownNote, 0.85),
      (memo, 0.80),
      (file, 0.78),
      (voice, 0.70),
    ]
    let rows = [
      row(current, host: LocalImportSource.appleNotes.rawValue),
      row(external, host: "x.com"),
      row(ownNote, host: HistoryPlatformDisplay.noteHost),
      row(memo, host: LocalImportSource.appleNotes.rawValue),
      row(file, host: LocalImportSource.files.rawValue),
      row(voice, host: LocalImportSource.voiceMemos.rawValue),
    ]

    let items = RelatedContentSelection.select(
      ranked: ranked, currentTaskID: current, rows: rows, minimumScore: 0.48
    )
    XCTAssertEqual(items.map(\.taskID), [memo, voice])
    XCTAssertEqual(items.map(\.host), [LocalImportSource.appleNotes.rawValue, LocalImportSource.voiceMemos.rawValue])
  }

  func testSelectionHonoursManualOwnershipTag() {
    let memo = TaskID(UUID())
    let markedExternal = TaskID(UUID())
    let ranked: [(taskID: TaskID, score: Float)] = [(memo, 0.9), (markedExternal, 0.8)]
    let rows = [
      row(memo, host: LocalImportSource.appleNotes.rawValue),
      row(markedExternal, host: LocalImportSource.appleNotes.rawValue, tags: [ContentOwnership.externalTagName]),
    ]

    let items = RelatedContentSelection.select(
      ranked: ranked, currentTaskID: TaskID(UUID()), rows: rows, minimumScore: 0.48
    )
    XCTAssertEqual(items.map(\.taskID), [memo], "手动改成「外部」的备忘录不出现")
  }

  func testSelectionDropsScoresBelowTheThreshold() {
    let low = TaskID(UUID())
    let atFloor = TaskID(UUID())
    let ranked: [(taskID: TaskID, score: Float)] = [(low, 0.479), (atFloor, 0.48)]
    let rows = [
      row(low, host: LocalImportSource.appleNotes.rawValue),
      row(atFloor, host: LocalImportSource.voiceMemos.rawValue),
    ]

    let items = RelatedContentSelection.select(
      ranked: ranked, currentTaskID: TaskID(UUID()), rows: rows, minimumScore: 0.48
    )
    XCTAssertEqual(items.map(\.taskID), [atFloor], "低于门槛的不硬凑")
  }

  func testSelectionExcludesSelfKeepsOrderAndStopsAtFive() {
    let current = TaskID(UUID())
    let others = (0..<7).map { _ in TaskID(UUID()) }
    let ranked: [(taskID: TaskID, score: Float)] = ([current] + others).enumerated().map {
      ($0.element, Float(0.9) - Float($0.offset) * 0.05)
    }
    let rows = ([current] + others).map { row($0, host: LocalImportSource.appleNotes.rawValue) }

    let items = RelatedContentSelection.select(
      ranked: ranked, currentTaskID: current, rows: rows, minimumScore: 0.48
    )
    XCTAssertEqual(items.count, RelatedContentSelection.limit)
    XCTAssertFalse(items.contains { $0.taskID == current })
    XCTAssertEqual(items.map(\.taskID), Array(others.prefix(5)), "按相似度从高到低")
  }

  func testSelectionFillsTitleAndPreviewFallbacks() {
    let voice = TaskID(UUID())
    let raw = TaskID(UUID())
    let ranked: [(taskID: TaskID, score: Float)] = [(voice, 0.9), (raw, 0.8)]
    let rows = [
      row(voice, host: LocalImportSource.voiceMemos.rawValue, title: nil, preview: nil),
      row(
        raw,
        host: LocalImportSource.appleNotes.rawValue,
        title: "   ",
        preview: "---\nauthor: \"我\"\n---\n\n# 小标题\n\n![](https://example.test/a.jpg)这是正文开头的一段话，后面还有很多。"
      ),
    ]

    let items = RelatedContentSelection.select(
      ranked: ranked, currentTaskID: TaskID(UUID()), rows: rows, minimumScore: 0.48
    )
    XCTAssertEqual(items.map(\.title), ["语音备忘录", "备忘录"])
    XCTAssertEqual(items[0].preview, "", "没有正文就留空，不在列表里硬写一句")
    XCTAssertTrue(items[1].preview.contains("这是正文开头的一段话"))
    XCTAssertFalse(items[1].preview.contains("example.test"))
    XCTAssertFalse(items[1].preview.contains("author"))
    XCTAssertLessThanOrEqual(items[1].preview.count, RelatedContentSelection.previewLimit)
  }

  // MARK: - 夹具

  private func row(
    _ id: TaskID,
    host: String,
    title: String? = "一条记录",
    preview: String? = "正文预览",
    tags: [String]? = nil
  ) -> HistoryRowProjection {
    HistoryRowProjection(
      taskID: id,
      title: title,
      canonicalURL: "linkdigest://\(host)/\(id.rawValue)",
      host: host,
      sourceLabel: host,
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      sourcePreview: preview,
      tagNames: tags
    )
  }
}
