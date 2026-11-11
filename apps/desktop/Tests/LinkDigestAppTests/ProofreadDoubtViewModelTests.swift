import Foundation
import GRDB
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

@MainActor
final class ProofreadDoubtViewModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    CapabilityConsent.revokeAll()
  }

  private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition())
  }

  func testAdoptAndKeepEditOnlyTheProofreadSnapshotAndKeepTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("doubt-vm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let accepted = try repository.acceptCapture(.init(document: CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink, url: "https://example.test/v", title: "访谈",
      platform: "douyin", method: "fixture", text: "占位", completeness: "complete",
      capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    ), receivedAtMilliseconds: 1))
    let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
    let raw = "今天张葱讲了奥利克的新方案大家觉得很有意思"
    _ = try repository.completeTaskTranscription(.init(
      taskID: accepted.taskID, attempt: attempt,
      document: CapturedDocument(
        createdAt: "2026-07-20T00:01:00Z", origin: .localTranscription, url: "https://example.test/v", title: "访谈",
        platform: "douyin", method: "speech_analyzer_local", text: raw, completeness: "complete",
        capturedAt: "2026-07-20T00:01:00Z", sourceLabel: "本机视频转写"
      ),
      evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
      receivedAtMilliseconds: 3
    ))

    let tidied = "今天张葱讲了奥利克的新方案，大家觉得很有意思。"
    let doubts = [
      TranscriptDoubt(id: "d1", original: "张葱", suggestion: "张聪", reason: "像人名"),
      TranscriptDoubt(id: "d2", original: "奥利克", suggestion: "欧立克", reason: "像品牌"),
    ]
    let tidier = DoubtTidier(text: tidied, doubts: doubts)
    let model = HistoryViewModel(transcriptTidier: tidier)
    let store = TranscriptDoubtStore(directoryURL: root)
    let names = KnownNameStore(directoryURL: root)
    model.transcriptDoubtStore = store
    model.knownNameStore = names
    _ = names.add("张总", source: .manual)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    model.requestTranscriptTidy(taskID: accepted.taskID, model: "m")
    XCTAssertEqual(model.pendingTidyKnownNameCount, 1, "确认框要能说出多发了几个名字")
    model.confirmTranscriptTidy()
    await waitUntil { model.transcriptTidyState(for: accepted.taskID) == .completed }

    let sent = await tidier.receivedContext
    XCTAssertEqual(sent?.knownNames, ["张总"], "校对请求带名字表")
    await waitUntil { model.doubtEntry(taskID: accepted.taskID)?.doubts.count == 2 }
    XCTAssertNotNil(model.doubtEntry(taskID: accepted.taskID)?.changeCount)
    await waitUntil { (model.detail?.snapshots.last?.captureMethod) == "openai_compatible_chat_tidy" }

    XCTAssertTrue(model.adoptDoubt(taskID: accepted.taskID, doubtID: "d1"))
    model.keepDoubt(taskID: accepted.taskID, doubtID: "d2")
    await waitUntil { model.detail?.snapshots.last?.bodyText.contains("张聪") == true }

    let after = try repository.detail(taskID: accepted.taskID)
    let transcripts = after.snapshots.filter { $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue }
    XCTAssertTrue(transcripts.contains { $0.bodyText == raw }, "机器原稿一个字没动")
    XCTAssertEqual(transcripts.last?.bodyText, "今天张聪讲了奥利克的新方案，大家觉得很有意思。")
    XCTAssertEqual(model.doubtEntry(taskID: accepted.taskID)?.doubts.map(\.status), [.adopted, .kept])

    // 重启后还在
    XCTAssertEqual(TranscriptDoubtStore(directoryURL: root).entry(taskID: accepted.taskID.rawValue)?.doubts.map(\.status), [.adopted, .kept])
  }

  func testRenameOffersToRememberNameWithoutChangingRenaming() {
    let model = HistoryViewModel()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    model.knownNameStore = KnownNameStore(directoryURL: dir)
    XCTAssertEqual(model.addKnownName("张总", source: .manual), .added)
    XCTAssertTrue(model.isKnownName("张总"))
    model.removeKnownName("张总")
    XCTAssertFalse(model.isKnownName("张总"))
    XCTAssertEqual(model.knownNameList.count, 0)
  }
}

private actor DoubtTidier: TranscriptTidying {
  let text: String
  let doubts: [TranscriptDoubt]
  private(set) var receivedContext: TranscriptTidyContext?
  init(text: String, doubts: [TranscriptDoubt]) { self.text = text; self.doubts = doubts }

  func tidy(
    text _: String, model _: String?, style _: TidyStyle, context: TranscriptTidyContext,
    progress _: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    receivedContext = context
    return TranscriptTidyOutcome(text: text, promptTokens: 10, completionTokens: 5, totalTokens: 15, doubts: doubts)
  }
}
