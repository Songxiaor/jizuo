import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 「AI 整理标签」流程：先过数据去向确认；预览前不改任何东西；确认后先备份，
/// 备份失败一个合并都不执行；只经注入的 mergeTags 执行。全程模拟模型，不联网。
@MainActor
final class TagTidyControllerTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private struct StubTidier: TagTidying {
    let result: Result<TagTidyOutcome, Error>
    func proposePlan(tags: [HistoryNavigationTag]) async throws -> TagTidyOutcome { try result.get() }
  }

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _merges: [([String], String)] = []
    private var _backups = 0
    private var _confirms = 0
    var merges: [([String], String)] { lock.lock(); defer { lock.unlock() }; return _merges }
    var backups: Int { lock.lock(); defer { lock.unlock() }; return _backups }
    var confirms: Int { lock.lock(); defer { lock.unlock() }; return _confirms }
    func merge(_ s: [String], _ t: String) { lock.lock(); _merges.append((s, t)); lock.unlock() }
    func backup() { lock.lock(); _backups += 1; lock.unlock() }
    func confirm() { lock.lock(); _confirms += 1; lock.unlock() }
  }

  private struct BackupFailure: Error {}

  private func tags() -> [HistoryNavigationTag] {
    [("AI工具", 5), ("人工智能工具", 3), ("Swift", 4)].map { HistoryNavigationTag(tag: HistoryTag(rawValue: $0.0)!, count: $0.1) }
  }

  private func outcome() -> TagTidyOutcome {
    TagTidyOutcome(
      plan: TagTidyPlan(
        merges: [.init(id: 0, target: "AI 工具", sources: ["AI工具", "人工智能工具"], sourceCounts: [5, 3])],
        frequent: ["AI 工具", "Swift"]
      ),
      totalTokens: 1234
    )
  }

  private func make(
    result: Result<TagTidyOutcome, Error>? = nil,
    gate: ModelCallGate = .alwaysAllowed,
    readOnly: Bool = false,
    backupFails: Bool = false,
    recorder: Recorder,
    store: FrequentTagStore? = nil
  ) -> TagTidyController {
    TagTidyController(
      tidier: StubTidier(result: result ?? .success(outcome())),
      gate: gate,
      store: store ?? FrequentTagStore(directoryURL: directory),
      tags: { [self] in tags() },
      isReadOnly: { readOnly },
      backup: { recorder.backup(); if backupFails { throw BackupFailure() } },
      merge: { sources, target in recorder.merge(sources, target) },
      didApply: {}
    )
  }

  private func settle(_ controller: TagTidyController, until: (TagTidyController.State) -> Bool) async {
    for _ in 0 ..< 200 where !until(controller.state) { try? await Task.sleep(nanoseconds: 10_000_000) }
  }

  func testProposeShowsPreviewWithoutChangingAnything() async {
    let recorder = Recorder()
    let controller = make(recorder: recorder)
    controller.start()
    await settle(controller) { $0 == .preview }
    XCTAssertEqual(controller.state, .preview)
    XCTAssertEqual(controller.plan?.merges.count, 1)
    XCTAssertEqual(recorder.merges.count, 0)
    XCTAssertEqual(recorder.backups, 0)
    XCTAssertTrue(FrequentTagStore(directoryURL: directory).allowedNames.isEmpty, "确认前不写常用表")
  }

  func testApplyBacksUpFirstThenMergesOnlyEnabledGroupsAndWritesFrequentList() async {
    let recorder = Recorder()
    let controller = make(recorder: recorder)
    controller.start()
    await settle(controller) { $0 == .preview }
    controller.plan?.merges[0].target = "AI 工具箱"   // 用户改名
    controller.apply()
    await settle(controller) { if case .finished = $0 { true } else { false } }
    XCTAssertEqual(recorder.backups, 1)
    XCTAssertEqual(recorder.merges.count, 1)
    XCTAssertEqual(recorder.merges[0].1, "AI 工具箱")
    XCTAssertEqual(recorder.merges[0].0, ["ai工具", "人工智能工具"].map { HistoryTagNormalizer.normalized($0)!.normalizedName })
    XCTAssertEqual(FrequentTagStore(directoryURL: directory).allowedNames, ["AI 工具箱", "Swift"], "常用表里的目标名跟着改名走")
  }

  func testDisabledGroupIsNotExecuted() async {
    let recorder = Recorder()
    let controller = make(recorder: recorder)
    controller.start()
    await settle(controller) { $0 == .preview }
    controller.plan?.merges[0].isEnabled = false
    controller.adoptFrequent = false
    controller.apply()
    await settle(controller) { if case .finished = $0 { true } else { false } }
    XCTAssertEqual(recorder.merges.count, 0)
    XCTAssertEqual(recorder.backups, 0)
  }

  func testBackupFailureMeansNoMergeAndNoFrequentListChange() async {
    let recorder = Recorder()
    let controller = make(backupFails: true, recorder: recorder)
    controller.start()
    await settle(controller) { $0 == .preview }
    controller.apply()
    await settle(controller) { if case .failed = $0 { true } else { false } }
    XCTAssertEqual(controller.state, .failed(TagTidyError.backupFailed.userMessage))
    XCTAssertEqual(recorder.backups, 1)
    XCTAssertEqual(recorder.merges.count, 0, "备份失败不执行任何合并")
    XCTAssertTrue(FrequentTagStore(directoryURL: directory).allowedNames.isEmpty)
  }

  func testReadOnlyNeverStartsOrCallsModel() async {
    let recorder = Recorder()
    let controller = make(readOnly: true, recorder: recorder)
    controller.start()
    XCTAssertEqual(controller.state, .failed(TagTidyError.notAllowed.userMessage))
  }

  func testUnconfirmedDestinationAsksFirstAndOnlyProceedsAfterConfirm() async {
    let recorder = Recorder()
    let gate = ModelCallGate(
      status: { recorder.confirms > 0 ? .allowed : .needsConfirmation(host: "api.example.test", model: "m") },
      confirm: { _, _ in recorder.confirm(); return true }
    )
    let controller = make(gate: gate, recorder: recorder)
    controller.start()
    await settle(controller) { if case .needsConsent = $0 { true } else { false } }
    XCTAssertEqual(controller.state, .needsConsent(host: "api.example.test", model: "m"))
    XCTAssertNil(controller.plan, "确认之前不发模型")
    controller.confirmConsent()
    await settle(controller) { $0 == .preview }
    XCTAssertEqual(controller.state, .preview)
    XCTAssertEqual(recorder.confirms, 1)
  }

  func testProviderChangedBetweenDialogAndSendInvalidatesConsentAndAsksAgain() async {
    let recorder = Recorder()
    // 弹窗展示 host A；确认时当前服务商已经是 host B：不记确认、不发送，重新弹窗展示 B。
    let current = Locked("a.example.test")
    let gate = ModelCallGate(
      status: { .needsConfirmation(host: current.value, model: "m") },
      confirm: { host, _ in recorder.confirm(); return host == current.value }
    )
    let controller = make(gate: gate, recorder: recorder)
    controller.start()
    await settle(controller) { if case .needsConsent = $0 { true } else { false } }
    XCTAssertEqual(controller.state, .needsConsent(host: "a.example.test", model: "m"))
    current.value = "b.example.test"
    controller.confirmConsent()
    await settle(controller) { $0 == .needsConsent(host: "b.example.test", model: "m") }
    XCTAssertEqual(controller.state, .needsConsent(host: "b.example.test", model: "m"))
    XCTAssertNil(controller.plan, "作废后没有发送")
  }

  func testCancelDuringApplyStopsBeforeNextGroupAndReportsCounts() async {
    let recorder = Recorder()
    let tidierOutcome = TagTidyOutcome(
      plan: TagTidyPlan(merges: [
        .init(id: 0, target: "甲", sources: ["AI工具"], sourceCounts: [5]),
        .init(id: 1, target: "乙", sources: ["Swift"], sourceCounts: [4]),
        .init(id: 2, target: "丙", sources: ["人工智能工具"], sourceCounts: [3]),
      ], frequent: ["甲"]),
      totalTokens: 100, model: "m-x"
    )
    var box: TagTidyController?
    let controller = TagTidyController(
      tidier: StubTidier(result: .success(tidierOutcome)), gate: .alwaysAllowed,
      store: FrequentTagStore(directoryURL: directory), tags: { [self] in tags() }, isReadOnly: { false },
      backup: { recorder.backup() },
      merge: { s, t in
        recorder.merge(s, t)
        if recorder.merges.count == 1 { await MainActor.run { box?.cancel() } }
        try? await Task.sleep(nanoseconds: 20_000_000)
      },
      didApply: {}
    )
    box = controller
    controller.start()
    await settle(controller) { $0 == .preview }
    controller.apply()
    await settle(controller) { if case .finished = $0 { true } else { false } }
    XCTAssertEqual(recorder.merges.count, 1, "取消后不再执行下一组")
    guard case let .finished(message) = controller.state else { return XCTFail("应已结束") }
    XCTAssertTrue(message.contains("已完成 1 组、未执行 2 组"), message)
    XCTAssertTrue(message.contains("备份"), message)
    XCTAssertTrue(FrequentTagStore(directoryURL: directory).allowedNames.isEmpty, "中途停止不写常用表")
    XCTAssertEqual(controller.lastUsage?.model, "m-x")
    XCTAssertEqual(controller.lastUsage?.totalTokens, 100)
  }

  func testFullApplyReportsAllGroupsDoneAndTokenUsage() async {
    let recorder = Recorder()
    let controller = make(recorder: recorder)
    controller.start()
    await settle(controller) { $0 == .preview }
    controller.apply()
    await settle(controller) { if case .finished = $0 { true } else { false } }
    guard case let .finished(message) = controller.state else { return XCTFail("应已结束") }
    XCTAssertTrue(message.contains("已完成 1 组、未执行 0 组"), message)
    XCTAssertTrue(message.contains("1234 token"), message)
  }

  func testModelFailureGivesPlainMessageAndChangesNothing() async {
    let recorder = Recorder()
    let controller = make(result: .failure(TagTidyError.invalidResponse), recorder: recorder)
    controller.start()
    await settle(controller) { if case .failed = $0 { true } else { false } }
    XCTAssertEqual(controller.state, .failed(TagTidyError.invalidResponse.userMessage))
    XCTAssertEqual(recorder.merges.count, 0)
  }
}

private final class Locked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: T
  init(_ value: T) { _value = value }
  var value: T {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); _value = newValue; lock.unlock() }
  }
}
