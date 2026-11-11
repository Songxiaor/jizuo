import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 素材卡流程：开关默认关；批量/队列/MCP 永不触发；数据去向没确认不调模型；只读不调模型；
/// 批量先估算、确认后串行、可停、失败不重试。全程假模型、内存存储，不联网、不碰真实库。
@MainActor
final class MaterialCardControllerTests: XCTestCase {
  private let transcript = String(repeating: "把复杂的事情讲清楚，比把简单的事情讲复杂难得多。", count: 8)

  private final class FakeStore: MaterialCardStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TaskID: TaskMaterialCardRecord] = [:]
    var candidates: [MaterialCardCandidate] = []
    func saveMaterialCard(_ record: TaskMaterialCardRecord) throws { lock.lock(); records[record.taskID] = record; lock.unlock() }
    func loadMaterialCard(taskID: TaskID) throws -> TaskMaterialCardRecord? { lock.lock(); defer { lock.unlock() }; return records[taskID] }
    func deleteMaterialCard(taskID: TaskID) throws { lock.lock(); records[taskID] = nil; lock.unlock() }
    func materialCardTaskIDs() throws -> Set<TaskID> { lock.lock(); defer { lock.unlock() }; return Set(records.keys) }
    func materialCardCandidates() throws -> [MaterialCardCandidate] { candidates }
  }

  private final class Extractor: MaterialCardExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var script: [Result<MaterialCardOutcome, Error>] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func extractCard(transcript: String, title: String?) async throws -> MaterialCardOutcome {
      let index = nextIndex()
      return try (script.indices.contains(index) ? script[index] : script.last ?? .success(Self.ok(live: true))).get()
    }
    private func nextIndex() -> Int { lock.lock(); defer { lock.unlock() }; let i = _calls; _calls += 1; return i }
    static func ok(live: Bool) -> MaterialCardOutcome {
      MaterialCardOutcome(
        card: MaterialCard(speaker: "开发者", viewpoints: ["观点"], hook: "钩子", quotes: [], isLiveSpeaker: live, liveSpeakerReason: "r"),
        promptTokens: 900, completionTokens: 120, totalTokens: 1020
      )
    }
  }

  private final class Effects: @unchecked Sendable {
    private let lock = NSLock()
    private var _attached: [TaskID] = [], _tokens: [TaskID] = [], _confirms = 0
    var tags: Set<String> = []
    var attached: [TaskID] { lock.lock(); defer { lock.unlock() }; return _attached }
    var tokens: [TaskID] { lock.lock(); defer { lock.unlock() }; return _tokens }
    var confirms: Int { lock.lock(); defer { lock.unlock() }; return _confirms }
    func attach(_ id: TaskID) { lock.lock(); _attached.append(id); lock.unlock() }
    func token(_ id: TaskID) { lock.lock(); _tokens.append(id); lock.unlock() }
    func confirm() { lock.lock(); _confirms += 1; lock.unlock() }
  }

  private struct Harness {
    let controller: MaterialCardController
    let store: FakeStore
    let extractor: Extractor
    let effects: Effects
    let defaults: UserDefaults
    let suite: String
  }

  private func make(
    auto: Bool = false, readOnly: Bool = false,
    gate: ((Effects) -> ModelCallGate)? = nil, source: String? = nil
  ) -> Harness {
    let suite = "material-card-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = FakeStore(), extractor = Extractor(), effects = Effects()
    let text = source ?? transcript
    let service = MaterialCardService(
      store: store, extractor: extractor,
      loadSource: { _ in .init(text: text, title: "标题") },
      currentTagNames: { _ in effects.tags },
      attachLiveSpeakerTag: { id in effects.attach(id); return true },
      recordTokens: { id, _ in effects.token(id) },
      now: { 1_000 }
    )
    let controller = MaterialCardController(
      service: service,
      gate: gate?(effects) ?? .alwaysAllowed,
      isReadOnly: { readOnly },
      preferences: MaterialCardPreferences(defaults: defaults)
    )
    controller.autoAfterTranscript = auto
    return Harness(controller: controller, store: store, extractor: extractor, effects: effects, defaults: defaults, suite: suite)
  }

  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0 ..< 400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

  private func gateNeedingConsent(_ effects: Effects) -> ModelCallGate {
    ModelCallGate(status: { .needsConfirmation(host: "api.example.test", model: "m") }, confirm: { _, _ in effects.confirm(); return true })
  }

  // MARK: 自动触发

  func testAutoSwitchIsOffByDefault() {
    let suite = "material-card-default-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(MaterialCardPreferences(defaults: defaults).autoAfterTranscript)
  }

  func testSwitchOffMeansTranscriptionNeverCallsModel() async {
    let h = make(auto: false)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.controller.transcriptionCompleted(taskID: TaskID(UUID()), origin: .manualSingle)
    await settle()
    XCTAssertEqual(h.extractor.calls, 0)
    XCTAssertEqual(h.controller.generationAttempts, 0)
  }

  func testBatchQueueAndAgentTranscriptionsNeverTriggerEvenWhenSwitchIsOn() async {
    let h = make(auto: true)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.controller.transcriptionCompleted(taskID: TaskID(UUID()), origin: .batchOrQueue)
    h.controller.transcriptionCompleted(taskID: TaskID(UUID()), origin: .agent)
    await settle()
    XCTAssertEqual(h.extractor.calls, 0)
    XCTAssertEqual(h.controller.generationAttempts, 0)
  }

  func testManualSingleTranscriptionWithSwitchOnMakesOneCardAndAttachesTag() async throws {
    let h = make(auto: true)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.transcriptionCompleted(taskID: id, origin: .manualSingle)
    await waitUntil { h.controller.record(for: id) != nil }
    XCTAssertEqual(h.extractor.calls, 1)
    XCTAssertEqual(h.effects.attached, [id], "判真人口播就挂「真人口播」标签")
    XCTAssertEqual(h.effects.tokens, [id], "记 token 账")
    XCTAssertEqual(try h.store.loadMaterialCard(taskID: id)?.totalTokens, 1020)
  }

  func testAutoPathNeverAsksConsentAndSkipsModelUntilConfirmed() async {
    let h = make(auto: true, gate: gateNeedingConsent)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.controller.transcriptionCompleted(taskID: TaskID(UUID()), origin: .manualSingle)
    await settle()
    XCTAssertEqual(h.extractor.calls, 0)
    XCTAssertEqual(h.effects.confirms, 0, "自动路径不替用户确认数据去向")
  }

  func testAutoPathSkipsWhenCardAlreadyExists() async throws {
    let h = make(auto: true)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    try h.store.saveMaterialCard(.init(taskID: id, card: Extractor.ok(live: false).card, createdAtMilliseconds: 1, updatedAtMilliseconds: 1))
    h.controller.transcriptionCompleted(taskID: id, origin: .manualSingle)
    await settle()
    XCTAssertEqual(h.extractor.calls, 0)
  }

  func testReadOnlyNeverCallsModel() async {
    let h = make(auto: true, readOnly: true)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.transcriptionCompleted(taskID: id, origin: .manualSingle)
    h.controller.generate(taskID: id)
    h.controller.prepareBatch()
    await settle()
    XCTAssertEqual(h.extractor.calls, 0)
    XCTAssertNotNil(h.controller.unavailableReason(taskID: id, hasTranscript: true))
  }

  // MARK: 手动

  func testManualGenerateAsksForConsentFirstAndOnlyCallsAfterConfirm() async {
    let h = make(gate: gateNeedingConsent)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.generate(taskID: id)
    await waitUntil { if case .needsConsent = h.controller.state(for: id) { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 0, "没确认前不调模型")
    h.controller.confirmConsent(taskID: id)
    await waitUntil { h.controller.record(for: id) != nil }
    XCTAssertEqual(h.effects.confirms, 1)
    XCTAssertEqual(h.extractor.calls, 1)
  }

  func testTagRemovedByUserIsNotReAttachedWhenRegenerating() async throws {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.generate(taskID: id)
    await waitUntil { h.controller.record(for: id) != nil }
    XCTAssertEqual(h.effects.attached.count, 1)
    // 用户把标签摘了（tags 里没有），重新生成。
    h.controller.generate(taskID: id)
    await waitUntil { h.extractor.calls == 2 && h.controller.state(for: id) == .idle }
    XCTAssertEqual(h.effects.attached.count, 1, "摘掉的标签不再挂回去")
    XCTAssertEqual(try h.store.loadMaterialCard(taskID: id)?.liveSpeakerTagSuppressed, true)
  }

  func testNotLiveSpeakerDoesNotAttachTag() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.extractor.script = [.success(Extractor.ok(live: false))]
    let id = TaskID(UUID())
    h.controller.generate(taskID: id)
    await waitUntil { h.controller.record(for: id) != nil }
    XCTAssertTrue(h.effects.attached.isEmpty)
  }

  func testShortTranscriptFailsWithoutCallingModel() async {
    let h = make(source: "太短")
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.generate(taskID: id)
    await waitUntil { if case .failed = h.controller.state(for: id) { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 0)
  }

  // MARK: 批量

  private func candidates(_ count: Int) -> [MaterialCardCandidate] {
    (0 ..< count).map { _ in MaterialCardCandidate(taskID: TaskID(UUID()), transcriptCharacters: 500) }
  }

  func testBatchEstimatesFirstWithoutCallingModelThenRunsSeriallyAfterConfirm() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.store.candidates = candidates(3) + [MaterialCardCandidate(taskID: TaskID(UUID()), transcriptCharacters: 50_000)]
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    guard case let .estimate(estimate) = h.controller.batchState else { return XCTFail("应先给估算") }
    XCTAssertEqual(estimate.count, 4)
    XCTAssertEqual(estimate.characters, 3 * 500 + MaterialCardPrompt.transcriptCharacterLimit, "每条最多按上限计")
    XCTAssertGreaterThan(estimate.estimatedInputTokens, estimate.characters)
    XCTAssertEqual(h.extractor.calls, 0, "估算阶段不调模型")
    h.controller.confirmBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 4)
  }

  func testBatchStopsAfterThreeConsecutiveFailuresWithoutRetry() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.extractor.script = [.failure(MaterialCardError.invalidResponse)]
    h.store.candidates = candidates(8)
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    h.controller.confirmBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.extractor.calls, MaterialCardController.consecutiveFailureLimit, "连续失败 3 次就停，每条只试一次")
  }

  func testBatchStopsImmediatelyOnAuthFailure() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.extractor.script = [.failure(TranscriptTidyError.authInvalid)]
    h.store.candidates = candidates(5)
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    h.controller.confirmBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 1)
  }

  func testBatchWithNoCandidatesFinishesWithoutModel() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.controller.prepareBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 0)
  }

  func testBatchAsksConsentInEstimateAndConfirmsOnce() async {
    let h = make(gate: gateNeedingConsent)
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.store.candidates = candidates(2)
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    guard case let .estimate(estimate) = h.controller.batchState else { return XCTFail() }
    XCTAssertEqual(estimate.needsConsent?.host, "api.example.test")
    XCTAssertEqual(h.extractor.calls, 0)
    h.controller.confirmBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.effects.confirms, 1)
    XCTAssertEqual(h.extractor.calls, 2)
  }

  private final class Mutable<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
  }

  private func switchingGate(_ host: Mutable<String>) -> (Effects) -> ModelCallGate {
    { effects in
      ModelCallGate(
        status: { .needsConfirmation(host: host.value, model: "m") },
        confirm: { shown, _ in effects.confirm(); return shown == host.value }
      )
    }
  }

  func testSingleCardProviderChangedBetweenDialogAndSendAsksAgainWithoutCallingModel() async {
    let host = Mutable("a.example.test")
    let h = make(gate: switchingGate(host))
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    let id = TaskID(UUID())
    h.controller.generate(taskID: id)
    await waitUntil { h.controller.state(for: id) == .needsConsent(host: "a.example.test", model: "m") }
    host.value = "b.example.test"
    h.controller.confirmConsent(taskID: id)
    await waitUntil { h.controller.state(for: id) == .needsConsent(host: "b.example.test", model: "m") }
    XCTAssertEqual(h.extractor.calls, 0, "服务商换了，旧确认作废，没发送")
    h.controller.confirmConsent(taskID: id)
    await waitUntil { h.controller.record(for: id) != nil }
    XCTAssertEqual(h.extractor.calls, 1)
  }

  func testBatchProviderChangedBetweenDialogAndSendReturnsToEstimateWithoutCallingModel() async {
    let host = Mutable("a.example.test")
    let h = make(gate: switchingGate(host))
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.store.candidates = candidates(2)
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    host.value = "b.example.test"
    h.controller.confirmBatch()
    await waitUntil {
      if case let .estimate(e) = h.controller.batchState { e.needsConsent?.host == "b.example.test" } else { false }
    }
    XCTAssertEqual(h.extractor.calls, 0)
    h.controller.confirmBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertEqual(h.extractor.calls, 2)
  }

  func testStopBatchHaltsBeforeAllItemsAreProcessed() async {
    let h = make()
    defer { h.defaults.removePersistentDomain(forName: h.suite) }
    h.store.candidates = candidates(50)
    h.controller.prepareBatch()
    await waitUntil { if case .estimate = h.controller.batchState { true } else { false } }
    h.controller.confirmBatch()
    h.controller.stopBatch()
    await waitUntil { if case .finished = h.controller.batchState { true } else { false } }
    XCTAssertLessThan(h.extractor.calls, 50)
  }

  func testMCPPayloadHasNullWithoutCardAndFieldsWithCard() {
    XCTAssertTrue(MaterialCardMCP.payload(nil) is NSNull)
    let record = TaskMaterialCardRecord(taskID: TaskID(UUID()), card: Extractor.ok(live: true).card, createdAtMilliseconds: 1, updatedAtMilliseconds: 7)
    let payload = MaterialCardMCP.payload(record) as? [String: Any]
    XCTAssertEqual(payload?["speaker"] as? String, "开发者")
    XCTAssertEqual(payload?["is_live_speaker"] as? Bool, true)
    XCTAssertEqual(payload?["viewpoints"] as? [String], ["观点"])
    XCTAssertNotNil(payload?["quotes"])
  }
}
