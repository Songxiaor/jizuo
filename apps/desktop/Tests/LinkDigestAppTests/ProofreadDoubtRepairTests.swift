import Foundation
import GRDB
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

/// 「录音校对」复核后的 10 条修正里，要经过 HistoryViewModel 才能验证的几条：
/// 提示跟着记录走、删除后清存疑、连点采纳不丢改动、名字表写失败的说法。
@MainActor
final class ProofreadDoubtRepairTests: XCTestCase {
  override func setUp() {
    super.setUp()
    CapabilityConsent.revokeAll()
  }

  private func waitUntil(timeout: Duration = .seconds(3), _ condition: @escaping @MainActor () -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition())
  }

  private struct Fixture {
    let root: URL
    let repository: GRDBHistoryRepository
    func cleanup() {
      try? repository.database.close()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("doubt-fix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Fixture(root: root, repository: try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root)))
  }

  /// 一条已经转写好的记录。
  private func addTranscribedTask(_ repository: GRDBHistoryRepository, url: String, raw: String, at ms: Int64) throws -> TaskID {
    let accepted = try repository.acceptCapture(.init(document: CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink, url: url, title: "访谈",
      platform: "douyin", method: "fixture", text: "占位", completeness: "complete",
      capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    ), receivedAtMilliseconds: ms))
    let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: ms + 1)
    _ = try repository.completeTaskTranscription(.init(
      taskID: accepted.taskID, attempt: attempt,
      document: CapturedDocument(
        createdAt: "2026-07-20T00:01:00Z", origin: .localTranscription, url: url, title: "访谈",
        platform: "douyin", method: "speech_analyzer_local", text: raw, completeness: "complete",
        capturedAt: "2026-07-20T00:01:00Z", sourceLabel: "本机视频转写"
      ),
      evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: ms + 2),
      receivedAtMilliseconds: ms + 2
    ))
    return accepted.taskID
  }

  // MARK: 1. 「记住这个名字」跟着记录走

  func testNameSuggestionShowsOnUnproofreadTranscriptAndDoesNotLeakToOtherTask() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let first = try addTranscribedTask(fixture.repository, url: "https://example.test/a", raw: "**说话人1**：你好呀", at: 10)
    let second = try addTranscribedTask(fixture.repository, url: "https://example.test/b", raw: "另一条没有改名的转写", at: 100)
    let model = HistoryViewModel()
    model.knownNameStore = KnownNameStore(directoryURL: fixture.root)
    model.transcriptDoubtStore = TranscriptDoubtStore(directoryURL: fixture.root)
    model.configure(history: .init(repository: fixture.repository), isReadOnly: false, unavailableCode: nil)

    model.selectedTaskID = first
    await waitUntil { model.detailState == .loaded && model.detail?.task.id == first }
    // 这条记录没有校对稿：提示照样出来。
    XCTAssertNil(model.doubtEntry(taskID: first))
    model.renameSpeaker(detail: try XCTUnwrap(model.detail), from: "说话人1", to: "张总")
    XCTAssertEqual(model.nameToRemember(for: first), "张总")
    XCTAssertNil(model.nameToRemember(for: second), "别的记录上不显示")

    // 切到另一条：提示不出现，也不会带回来。
    model.selectedTaskID = second
    await waitUntil { model.detailState == .loaded && model.detail?.task.id == second }
    XCTAssertNil(model.nameToRemember(for: second))
    XCTAssertNil(model.nameToRemember(for: first))
    model.selectedTaskID = first
    await waitUntil { model.detailState == .loaded && model.detail?.task.id == first }
    XCTAssertNil(model.nameToRemember(for: first), "切走时已经清空")

    // 关掉详情（取消选中）同样清空。
    model.renameSpeaker(detail: try XCTUnwrap(model.detail), from: "张总", to: "李总")
    XCTAssertEqual(model.nameToRemember(for: first), "李总")
    model.selectedTaskIDs = []
    XCTAssertNil(model.nameToRemember(for: first))
  }

  // MARK: 2. 删除资料、清空回收站后清存疑

  func testEmptyingTrashPrunesDoubtsOfPurgedTasksOnly() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let gone = try addTranscribedTask(fixture.repository, url: "https://example.test/a", raw: "今天张葱来了", at: 10)
    let kept = try addTranscribedTask(fixture.repository, url: "https://example.test/b", raw: "今天奥利克来了", at: 100)
    let store = TranscriptDoubtStore(directoryURL: fixture.root)
    store.replace(taskID: gone.rawValue, doubts: [.init(id: "g", original: "张葱", suggestion: "张聪", reason: "")], changeCount: 1)
    store.replace(taskID: kept.rawValue, doubts: [.init(id: "k", original: "奥利克", suggestion: "欧立克", reason: "")], changeCount: 1)
    let model = HistoryViewModel()
    model.transcriptDoubtStore = store
    model.configure(history: .init(repository: fixture.repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    // 移到回收站：可以恢复，存疑项还在。
    model.moveToTrash(taskIDs: [gone])
    await waitUntil { !model.isDeleting }
    XCTAssertNotNil(store.entry(taskID: gone.rawValue))

    // 清空回收站：对应条目消失，另一条不动。
    model.purgeTrash(olderThanDays: 0)
    await waitUntil { store.entry(taskID: gone.rawValue) == nil }
    XCTAssertNotNil(store.entry(taskID: kept.rawValue))
    XCTAssertNotNil(TranscriptDoubtStore(directoryURL: fixture.root).entry(taskID: kept.rawValue), "写进了文件")
    XCTAssertNil(TranscriptDoubtStore(directoryURL: fixture.root).entry(taskID: gone.rawValue))
  }

  func testRemoveDoubtsDropsEntriesByTaskID() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = TranscriptDoubtStore(directoryURL: fixture.root)
    let a = TaskID(UUID()), b = TaskID(UUID())
    store.replace(taskID: a.rawValue, doubts: [.init(id: "1", original: "张葱", suggestion: "张聪", reason: "")], changeCount: 1)
    store.replace(taskID: b.rawValue, doubts: [.init(id: "2", original: "奥利克", suggestion: "欧立克", reason: "")], changeCount: 1)
    let model = HistoryViewModel()
    model.transcriptDoubtStore = store
    model.removeDoubts(taskIDs: [a])
    XCTAssertNil(store.entry(taskID: a.rawValue))
    XCTAssertNotNil(store.entry(taskID: b.rawValue))
  }

  func testPruneUsingHistoryKeepsEntriesWhenLookupFails() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = TranscriptDoubtStore(directoryURL: fixture.root)
    store.replace(taskID: "ghost", doubts: [.init(id: "1", original: "张葱", suggestion: "张聪", reason: "")], changeCount: 1)
    let live = HistoryApplicationService(repository: fixture.repository)
    XCTAssertEqual(store.prune(using: live), 1, "库里没有这条：清掉")
    XCTAssertNil(store.entry(taskID: "ghost"))
  }

  // MARK: 4. 连点两次「采纳」两处都生效

  func testTwoAdoptsInARowBothTakeEffect() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let raw = "今天张葱讲了奥利克的新方案大家觉得很有意思"
    let taskID = try addTranscribedTask(fixture.repository, url: "https://example.test/v", raw: raw, at: 10)
    let doubts = [
      TranscriptDoubt(id: "d1", original: "张葱", suggestion: "张聪", reason: "像人名"),
      TranscriptDoubt(id: "d2", original: "奥利克", suggestion: "欧立克", reason: "像品牌"),
    ]
    let tidier = RepairDoubtTidier(text: "今天张葱讲了奥利克的新方案，大家觉得很有意思。", doubts: doubts)
    let model = HistoryViewModel(transcriptTidier: tidier)
    model.transcriptDoubtStore = TranscriptDoubtStore(directoryURL: fixture.root)
    model.configure(history: .init(repository: fixture.repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == taskID }
    model.requestTranscriptTidy(taskID: taskID, model: "m")
    model.confirmTranscriptTidy()
    await waitUntil { model.transcriptTidyState(for: taskID) == .completed }
    await waitUntil { model.doubtEntry(taskID: taskID)?.doubts.count == 2 }
    await waitUntil { model.detail?.snapshots.last?.captureMethod == "openai_compatible_chat_tidy" }

    // 不等界面刷新，紧接着连点两次。
    XCTAssertTrue(model.adoptDoubt(taskID: taskID, doubtID: "d1"))
    XCTAssertTrue(model.isSavingDoubts(for: taskID), "保存到详情刷新之间，界面禁用采纳按钮")
    XCTAssertTrue(model.adoptDoubt(taskID: taskID, doubtID: "d2"))

    let body = try fixture.repository.detail(taskID: taskID).snapshots.last?.bodyText
    XCTAssertEqual(body, "今天张聪讲了欧立克的新方案，大家觉得很有意思。", "两处都生效，前一次没被盖掉")
    XCTAssertEqual(model.doubtEntry(taskID: taskID)?.doubts.map(\.status), [.adopted, .adopted])
    await waitUntil { !model.isSavingDoubts(for: taskID) }
  }

  // MARK: 10. 名字表保存失败有自己的说法

  func testKnownNameWriteFailureIsReportedAsWriteFailedNotEmptyName() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    // 数据目录的位置上放了一个普通文件：目录建不出来，写必然失败。
    let blocker = fixture.root.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: blocker)
    let model = HistoryViewModel()
    model.knownNameStore = KnownNameStore(directoryURL: blocker)
    let result = model.addKnownName("张总", source: .manual)
    XCTAssertEqual(result, .writeFailed)
    let message = try XCTUnwrap(KnownNameMessage.message(for: result))
    XCTAssertFalse(message.contains("不能为空"))
    XCTAssertTrue(message.contains("没能保存"))
    XCTAssertEqual(KnownNameMessage.message(for: .invalid)?.contains("不能为空"), true)
    XCTAssertFalse(model.isKnownName("张总"), "没写进去的名字不算记住了")
  }
}

private actor RepairDoubtTidier: TranscriptTidying {
  let text: String
  let doubts: [TranscriptDoubt]
  init(text: String, doubts: [TranscriptDoubt]) { self.text = text; self.doubts = doubts }

  func tidy(
    text _: String, model _: String?, style _: TidyStyle, context _: TranscriptTidyContext,
    progress _: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    TranscriptTidyOutcome(text: text, promptTokens: 10, completionTokens: 5, totalTokens: 15, doubts: doubts)
  }
}
