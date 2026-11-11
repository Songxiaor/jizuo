import AppKit
import SwiftUI
import XCTest
import LinkDigestCore
@testable import LinkDigestApp

@MainActor
final class RelatedContentServiceTests: XCTestCase {
  func testNotReadyShowsNothingAndNeverSearches() async {
    let search = FakeRelatedSearch()
    search.isRelatedContentReady = false
    let service = RelatedContentService()
    let request = RelatedContentRequest(taskID: TaskID(UUID()), query: "标题\n总结")

    await service.load(request: request, search: search, rows: FakeRelatedRows(byID: [:]))

    XCTAssertTrue(service.items.isEmpty)
    XCTAssertEqual(search.queries, [], "「按意思搜」没就绪时不能触发检索，更不能顺手下载模型")
  }

  func testSameItemIsNotComputedTwice() async {
    let current = TaskID(UUID())
    let memo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    search.results["标题\n总结"] = [(memo, 0.9)]
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [memo: row(memo, host: LocalImportSource.appleNotes.rawValue)])

    await service.load(request: request, search: search, rows: rows)
    await service.load(request: request, search: search, rows: rows)

    XCTAssertEqual(search.queries.count, 1, "相同资料、同一版索引只算一次")
    XCTAssertEqual(service.items.map(\.taskID), [memo])
  }

  func testIndexChangeInvalidatesTheCache() async {
    let current = TaskID(UUID())
    let oldMemo = TaskID(UUID())
    let newMemo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    search.results["标题\n总结"] = [(oldMemo, 0.9)]
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [
      oldMemo: row(oldMemo, host: LocalImportSource.appleNotes.rawValue),
      newMemo: row(newMemo, host: LocalImportSource.voiceMemos.rawValue),
    ])

    await service.load(request: request, search: search, rows: rows)
    XCTAssertEqual(service.items.map(\.taskID), [oldMemo])

    // 索引补了一遍：版本变了，旧缓存不能再用。
    search.relatedContentIndexFingerprint = "v2"
    search.results["标题\n总结"] = [(oldMemo, 0.9), (newMemo, 0.8)]
    await service.load(request: request, search: search, rows: rows)

    XCTAssertEqual(search.queries.count, 2, "索引变了要重算")
    XCTAssertEqual(service.items.map(\.taskID), [oldMemo, newMemo])
  }

  func testEmptyResultsAreNotCached() async {
    let current = TaskID(UUID())
    let memo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [memo: row(memo, host: LocalImportSource.appleNotes.rawValue)])

    await service.load(request: request, search: search, rows: rows)
    XCTAssertTrue(service.items.isEmpty)

    // 索引没变，但上次没结果：下次还要能算出来，不能把「空」缓存住。
    search.results["标题\n总结"] = [(memo, 0.9)]
    await service.load(request: request, search: search, rows: rows)

    XCTAssertEqual(search.queries.count, 2)
    XCTAssertEqual(service.items.map(\.taskID), [memo])
  }

  func testKeepsExistingItemsWhileIndexIsNotReady() async {
    let current = TaskID(UUID())
    let memo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    search.results["标题\n总结"] = [(memo, 0.9)]
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [memo: row(memo, host: LocalImportSource.appleNotes.rawValue)])

    await service.load(request: request, search: search, rows: rows)
    XCTAssertEqual(service.items.map(\.taskID), [memo])

    // 索引正在补算（状态暂时不是 ready）：已有结果不能整块消失。
    search.isRelatedContentReady = false
    await service.load(request: request, search: search, rows: rows)
    XCTAssertEqual(service.items.map(\.taskID), [memo])

    // 换到另一条资料时才应该撤掉。
    let other = RelatedContentRequest(taskID: TaskID(UUID()), query: "另一条")
    await service.load(request: other, search: search, rows: rows)
    XCTAssertTrue(service.items.isEmpty)
  }

  func testKeepsOldResultsVisibleWhileRecomputing() async throws {
    let current = TaskID(UUID())
    let oldMemo = TaskID(UUID())
    let newMemo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    search.results["标题\n总结"] = [(oldMemo, 0.9)]
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [
      oldMemo: row(oldMemo, host: LocalImportSource.appleNotes.rawValue),
      newMemo: row(newMemo, host: LocalImportSource.voiceMemos.rawValue),
    ])

    await service.load(request: request, search: search, rows: rows)

    search.relatedContentIndexFingerprint = "v2"
    search.results["标题\n总结"] = [(newMemo, 0.9)]
    search.delays["标题\n总结"] = .milliseconds(120)
    let task = Task { await service.load(request: request, search: search, rows: rows) }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(service.items.map(\.taskID), [oldMemo], "重算期间旧结果先留在屏幕上，不能闪空")

    await task.value
    XCTAssertEqual(service.items.map(\.taskID), [newMemo])
  }

  func testSwitchingItemsDropsLateResultsFromThePreviousItem() async throws {
    let currentA = TaskID(UUID())
    let currentB = TaskID(UUID())
    let memoA = TaskID(UUID())
    let memoB = TaskID(UUID())
    let rowA = row(memoA, host: LocalImportSource.appleNotes.rawValue, title: "A")
    let rowB = row(memoB, host: LocalImportSource.voiceMemos.rawValue, title: "B")
    let search = FakeRelatedSearch()
    search.results["A 的查询"] = [(memoA, 0.9)]
    search.results["B 的查询"] = [(memoB, 0.9)]
    search.delays["A 的查询"] = .milliseconds(80)
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [memoA: rowA, memoB: rowB])

    let requestA = RelatedContentRequest(taskID: currentA, query: "A 的查询")
    let requestB = RelatedContentRequest(taskID: currentB, query: "B 的查询")
    let taskA = Task { await service.load(request: requestA, search: search, rows: rows) }
    try await Task.sleep(for: .milliseconds(10))
    let taskB = Task { await service.load(request: requestB, search: search, rows: rows) }

    await taskB.value
    XCTAssertEqual(service.items.map(\.taskID), [memoB])
    try await Task.sleep(for: .milliseconds(150))
    await taskA.value
    XCTAssertEqual(service.items.map(\.taskID), [memoB], "迟到的 A 结果不能盖到 B 上")
  }

  func testBecomingReadyLaterStillLoadsTheSameItem() async {
    let current = TaskID(UUID())
    let memo = TaskID(UUID())
    let request = RelatedContentRequest(taskID: current, query: "标题\n总结")
    let search = FakeRelatedSearch()
    search.isRelatedContentReady = false
    search.results["标题\n总结"] = [(memo, 0.9)]
    let service = RelatedContentService()
    let rows = FakeRelatedRows(byID: [memo: row(memo, host: LocalImportSource.appleNotes.rawValue)])

    await service.load(request: request, search: search, rows: rows)
    XCTAssertTrue(service.items.isEmpty)

    // 模型装好、索引进度完成后，同一个请求要能重新算，不能被上一次的「空」缓存住。
    search.isRelatedContentReady = true
    await service.load(request: request, search: search, rows: rows)
    XCTAssertEqual(service.items.map(\.taskID), [memo])
  }

  /// 隔离数据离屏渲染：只看这一块长什么样，不连详情页、不碰真实历史库。
  /// 想亲眼看图时设 `LINKDIGEST_WRITE_RELATED_SNAPSHOT=1`，会写到 /tmp/related-content.png。
  func testRelatedContentListRendersOffscreen() throws {
    _ = NSApplication.shared
    let items = [
      RelatedContentSelection.Item(
        taskID: TaskID(UUID()),
        title: "关于定价的三个想法",
        preview: "收费不是把价格标上去，而是让愿意付的人先付。",
        host: LocalImportSource.appleNotes.rawValue
      ),
      RelatedContentSelection.Item(
        taskID: TaskID(UUID()),
        title: "和客户聊定价",
        preview: "今天这段录音里我讲了为什么先谈价值再谈价格。",
        host: LocalImportSource.voiceMemos.rawValue
      ),
      RelatedContentSelection.Item(
        taskID: TaskID(UUID()),
        title: "无标题笔记",
        preview: "",
        host: LocalImportSource.appleNotes.rawValue
      ),
    ]
    let view = RelatedContentList(items: items, onOpen: { _ in })
      .padding(24)
      .frame(width: 640, alignment: .leading)
      .background(Color.white)
    let data = SnapshotTestSupport.pngData(from: view, size: CGSize(width: 640, height: 300))
    SnapshotTestSupport.assertPNG(data)
    if ProcessInfo.processInfo.environment["LINKDIGEST_WRITE_RELATED_SNAPSHOT"] != nil {
      try XCTUnwrap(data).write(to: URL(fileURLWithPath: "/tmp/related-content.png"))
    }
  }

  // MARK: - 替身

  @MainActor
  private final class FakeRelatedSearch: RelatedContentSearching {
    var isRelatedContentReady = true
    var relatedContentIndexFingerprint = "v1"
    var results: [String: [(taskID: TaskID, score: Float)]] = [:]
    var delays: [String: Duration] = [:]
    private(set) var queries: [String] = []

    func relatedCandidates(_ query: String) async -> RelatedContentCandidates {
      queries.append(query)
      if let delay = delays[query] { try? await Task.sleep(for: delay) }
      return RelatedContentCandidates(
        indexFingerprint: relatedContentIndexFingerprint,
        ranked: results[query] ?? []
      )
    }
  }

  private struct FakeRelatedRows: RelatedContentRowLoading {
    let byID: [TaskID: HistoryRowProjection]

    func rows(for taskIDs: [TaskID]) -> [HistoryRowProjection] {
      taskIDs.compactMap { byID[$0] }
    }
  }

  private func row(_ id: TaskID, host: String, title: String = "一条记录") -> HistoryRowProjection {
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
      sourcePreview: "正文预览",
      tagNames: nil
    )
  }
}
