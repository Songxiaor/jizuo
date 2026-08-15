import Foundation
import GRDB
import XCTest
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

/// 批量总结的护栏。
///
/// 这条功能最容易坏在**静默**上，而不是坏在写不出来：`summarize` 走全局单例
/// `currentCapture` + `runState`，`canStartRun` 里明写 `!runState.isActive`。
/// 只要串行等待有一处没等住，第二条起就会被 `canStartRun` 直接挡掉——不报错、
/// 不留痕，界面上只表现为「点了没反应，18 条只总结了 1 条」。所以下面每条测试
/// 断言的都是「没有静默丢弃」，而不只是「happy path 能跑通」。
@MainActor
final class BatchSummaryTests: XCTestCase {

  override func setUp() {
    super.setUp()
    // 只压缩等待上限，不改行为：产品路径是 20s / 1800s。
    HistoryViewModel.batchSummaryStartTimeoutSeconds = 1
    HistoryViewModel.batchSummaryRunTimeoutSeconds = 5
  }

  override func tearDown() {
    HistoryViewModel.batchSummaryStartTimeoutSeconds = 20
    HistoryViewModel.batchSummaryRunTimeoutSeconds = 1_800
    super.tearDown()
  }

  /// 三条待总结必须一条接一条，而且每条都真的发出去了。
  ///
  /// 并发峰值 > 1 就说明第二条在通道占用时被发起了——真实环境里它会被
  /// `canStartRun` 静默丢掉，用户只看到「有几条没总结」。
  func testBatchSummarizesSeriallyAndSendsEveryItem() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 3)
    let channel = FakeSummaryChannel(fixture: fixture)

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 3 }
    model.selectedTaskIDs = Set(taskIDs)

    XCTAssertTrue(model.canBatchSummarize)
    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    XCTAssertTrue(
      model.batchSummaryConfirmationMessage.contains("tokens"),
      "花钱的动作必须先给出粗估量级：\(model.batchSummaryConfirmationMessage)"
    )

    channel.start(model: model)
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    XCTAssertEqual(channel.startedTaskIDs.count, 3, "有条目根本没被发起")
    XCTAssertEqual(Set(channel.startedTaskIDs), Set(taskIDs))
    XCTAssertEqual(channel.maxConcurrent, 1, "批量必须串行，并发发起会被 canStartRun 静默丢弃")
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("成功 3 条"),
      "结果汇总不对：\(model.batchSummaryOutcomeMessage)"
    )
    for taskID in taskIDs {
      XCTAssertTrue(try fixture.hasCompletedSummary(taskID), "\(taskID.rawValue) 没有落地总结")
    }
  }

  /// 已有总结的条目不重复花钱，而且要在确认前就告诉用户跳过了几条。
  func testAlreadySummarizedItemsAreSkippedBeforeSpendingMoney() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 3)
    try fixture.writeCompletedSummary(taskID: taskIDs[1])
    let channel = FakeSummaryChannel(fixture: fixture)

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 3 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    XCTAssertEqual(model.batchSummaryConfirmationTitle, "对选中的 2 条生成总结？")
    XCTAssertTrue(
      model.batchSummaryConfirmationMessage.contains("1 条已有总结"),
      "跳过原因没有说清楚：\(model.batchSummaryConfirmationMessage)"
    )

    channel.start(model: model)
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    XCTAssertEqual(channel.startedTaskIDs.count, 2)
    XCTAssertFalse(channel.startedTaskIDs.contains(taskIDs[1]), "已有总结的条目被重新发送了一次")
  }

  /// 选中项全都不需要发送时也要给出人话原因，不能表现成「点了没反应」。
  func testNothingToSendStillExplainsWhy() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 2)
    for taskID in taskIDs { try fixture.writeCompletedSummary(taskID: taskID) }

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 2 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryOutcomePresented }

    XCTAssertFalse(model.isBatchSummaryConfirmationPresented)
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("2 条已有总结"),
      "没有给出人话原因：\(model.batchSummaryOutcomeMessage)"
    )
  }

  /// 一条都没能开始（模型未配置 / 存储不可写 / 数据去向确认被取消）时立刻中止，
  /// 不要在剩下十几条上每条空转 20 秒，也不要假装成功。
  func testFailingToStartAbortsTheWholeBatchWithAReason() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 4)
    let channel = FakeSummaryChannel(fixture: fixture)
    channel.neverStarts = true

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 4 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    channel.start(model: model)
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    XCTAssertEqual(channel.startedTaskIDs.count, 1, "第一条就没能开始，不该继续往下发")
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("没能开始总结"),
      "中止原因没有说清楚：\(model.batchSummaryOutcomeMessage)"
    )
    XCTAssertTrue(model.batchSummaryOutcomeMessage.contains("失败 1 条"))
  }

  /// 停止之后剩余条目不再发送，而且要说清楚剩下的没发。
  func testStopKeepsFinishedWorkAndSaysWhatWasNotSent() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 4)
    let channel = FakeSummaryChannel(fixture: fixture)

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 4 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    channel.start(model: model)
    await waitUntil(timeout: .seconds(10)) { channel.startedTaskIDs.count >= 1 }
    model.stopBatchSummary()
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    XCTAssertLessThan(channel.startedTaskIDs.count, 4, "停止之后仍然把剩下的发了出去")
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("已按你的要求停止"),
      "没有说明是被停止的：\(model.batchSummaryOutcomeMessage)"
    )
    XCTAssertFalse(
      model.batchSummaryOutcomeMessage.contains("一直没有结束"),
      "把「用户主动停止」说成了「卡住」：\(model.batchSummaryOutcomeMessage)"
    )
    // 已经发出去的那条不能被说成失败——它还在跑，还在计费，完成后照样落库。
    XCTAssertFalse(
      model.batchSummaryOutcomeMessage.contains("失败"),
      "把仍在进行的那条算成了失败：\(model.batchSummaryOutcomeMessage)"
    )
    // 已经发出去的那条必须被交代，但**交代成哪一种取决于时序**：停止到达时它可能
    // 还在跑（「仍在进行」），也可能刚好已经跑完（「成功 N 条」）。两种说法都诚实。
    //
    // 原来这里只认「仍在进行」，于是在机器快慢不同时会假失败——而它掩盖的恰恰是
    // 真 bug：两个取消分支都直接 break，跳过了按落库状态计数那一步，已经跑完的
    // 那条被报成「未处理」。CI 上就是这么红的。
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("仍在进行")
        || model.batchSummaryOutcomeMessage.contains("成功"),
      "已经发出的那条既没说仍在进行、也没算进成功，等于凭空消失了：\(model.batchSummaryOutcomeMessage)"
    )
    // 停止不等于回滚：已经跑完的产物必须留在库里。
    await waitUntil(timeout: .seconds(5)) { channel.succeededTaskIDs.count >= 1 }
    for taskID in channel.succeededTaskIDs {
      XCTAssertTrue(try fixture.hasCompletedSummary(taskID), "停止把已完成的产物弄丢了")
    }
  }

  /// 在某条**刚好跑完**的瞬间按停止，那条必须算进成功，不能报成「未处理」。
  ///
  /// 上面那条测试等的是「已发出」就停，那时它通常还在飞；这条等它真的落库再停，
  /// 于是确定性地命中另一个分支——不靠机器快慢。
  ///
  /// 这个分支原本是错的：取消检查里直接 `break`，跳过了按落库状态计数那一步。
  /// 用户看到「未处理 4 条，已按你的要求停止」，回到列表却发现历史里多了一条。
  /// 数字和事实对不上比少给信息更糟——它会让人以为总结丢了，然后重跑一遍、
  /// 再花一次钱。本机跑得快，一直命中「还在飞」那条路，所以从没暴露过；
  /// CI 上第一次真跑 swift test 就红了。
  func testStoppingRightAfterAnItemFinishesStillCountsIt() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 4)
    let channel = FakeSummaryChannel(fixture: fixture)

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 4 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    channel.start(model: model)
    // 关键差别：等它真的落库了再停。
    await waitUntil(timeout: .seconds(10)) { channel.succeededTaskIDs.count >= 1 }
    model.stopBatchSummary()
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("成功"),
      "已经跑完并落库的那条被漏计了：\(model.batchSummaryOutcomeMessage)"
    )
    XCTAssertTrue(
      model.batchSummaryOutcomeMessage.contains("已按你的要求停止"),
      "没有说明是被停止的：\(model.batchSummaryOutcomeMessage)"
    )
    // 停止是用户自己的选择，没轮到的那些是「未处理」，不是「失败」。
    XCTAssertFalse(
      model.batchSummaryOutcomeMessage.contains("失败"),
      "把没轮到的条目算成了失败：\(model.batchSummaryOutcomeMessage)"
    )
    for taskID in channel.succeededTaskIDs {
      XCTAssertTrue(try fixture.hasCompletedSummary(taskID), "算进成功的那条其实没落库")
    }
  }

  /// 批量期间 `currentCapture` 会被逐条改写，那不是「新内容到达」。自动管线必须
  /// 在**标记已处理之前**早退，否则这些条目会被永久排除在自动管线之外——以后真的
  /// 重新捕获也不会再自动处理，而且没有任何迹象。
  func testAutoPipelineDoesNotClaimTasksTouchedByABatch() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let taskIDs = try fixture.acceptCaptures(count: 2)
    let channel = FakeSummaryChannel(fixture: fixture)
    // 这一批一条都没能开始，于是被批量碰过的条目**没有**总结产物。
    // 「自动管线还能不能接管它」才成为一个可观测的问题——否则跳过是因为
    // 已有总结，与名额有没有被吃掉分不开。
    channel.neverStarts = true
    channel.onSummarizeStarted = { [weak channel] model, taskID in
      // 模拟批量改写 currentCapture 触发的 onChange。
      model.startAutoPipeline(
        taskID: taskID,
        expectsMedia: false,
        transcribe: false, tidy: false, summarize: true, mindMap: false,
        tidyModel: nil,
        summarizeAction: { _ in channel?.autoPipelineSummarizeCalls += 1; return false },
        isSummaryBusy: { false }
      )
    }

    let model = HistoryViewModel()
    model.configure(history: fixture.service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 2 }
    model.selectedTaskIDs = Set(taskIDs)

    model.requestBatchSummary()
    await waitUntil { model.isBatchSummaryConfirmationPresented }
    channel.start(model: model)
    await waitUntil(timeout: .seconds(10)) { model.isBatchSummaryOutcomePresented }

    let touched = channel.startedTaskIDs[0]
    XCTAssertEqual(channel.autoPipelineSummarizeCalls, 0, "自动管线在批量期间又发了一次总结")
    XCTAssertFalse(try fixture.hasCompletedSummary(touched))

    // 批量结束后，同一条目仍然能被自动管线接管——名额没有被提前吃掉。
    model.selectedTaskIDs = [touched]
    await waitUntil { model.detailState == .loaded && model.detail?.task.id == touched }
    var claimed = false
    model.startAutoPipeline(
      taskID: touched,
      expectsMedia: false,
      transcribe: false, tidy: false, summarize: true, mindMap: false,
      tidyModel: nil,
      summarizeAction: { _ in claimed = true; return false },
      isSummaryBusy: { false }
    )
    await waitUntil(timeout: .seconds(3)) { claimed }
    XCTAssertTrue(claimed, "批量处理过的条目被永久排除在自动管线之外了")
  }

  // MARK: - Helpers

  private func waitUntil(
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      if clock.now >= deadline {
        XCTFail("等待条件超时", file: file, line: line)
        return
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// 一次真实的本机库 + 若干条已抓取内容。
@MainActor
private final class Fixture {
  let root: URL
  let repository: GRDBHistoryRepository
  let service: HistoryApplicationService
  private var clock: Int64 = 1

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-batch-summary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    service = HistoryApplicationService(repository: repository)
  }

  func close() {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
  }

  private func nextClock() -> Int64 {
    clock += 1
    return clock
  }

  func acceptCaptures(count: Int) throws -> [TaskID] {
    try (0..<count).map { index in
      let document = CapturedDocument(
        createdAt: "2026-07-27T00:00:00Z",
        origin: .manualLink,
        url: "https://example.test/batch-\(index)",
        title: "第 \(index) 篇",
        platform: "web",
        method: "fixture",
        text: "第 \(index) 篇的正文，足够长到值得总结一次。",
        completeness: "complete",
        capturedAt: "2026-07-27T00:00:00Z",
        sourceLabel: "fixture"
      )
      return try repository.acceptCapture(
        .init(document: document, receivedAtMilliseconds: nextClock())
      ).taskID
    }
  }

  /// 落一条 completed 的总结 Run——批量成功与否的权威判据就是它。
  func writeCompletedSummary(taskID: TaskID) throws {
    guard let snapshotID = try repository.detail(taskID: taskID).snapshots.last?.id else {
      throw RepositoryFailure.notFound
    }
    let run = try repository.createRun(.init(
      taskID: taskID,
      snapshotID: snapshotID,
      idempotencyKey: "batch:\(taskID.rawValue):\(UUID().uuidString)",
      kind: .summarize,
      createdAtMilliseconds: nextClock()
    ))
    try repository.markRunRunning(.init(
      runID: run.runID,
      startedAtMilliseconds: nextClock(),
      provider: .init()
    ))
    try repository.finishRun(.init(
      runID: run.runID,
      status: .completed,
      finishedAtMilliseconds: nextClock(),
      artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "总结正文。")
    ))
  }

  func hasCompletedSummary(_ taskID: TaskID) throws -> Bool {
    try repository.detail(taskID: taskID).runs
      .contains { $0.run.kind == .summarize && $0.run.status == .completed }
  }
}

/// 替身模型通道：只做真实路径做的两件事——**发起**（立刻返回）和**占用**
/// 那条唯一的通道，生成在后台完成后才落库。`requestRun` 也是这样：启动即返回。
@MainActor
private final class FakeSummaryChannel {
  private let fixture: Fixture
  private var busyCount = 0
  private var inFlight = 0

  private(set) var startedTaskIDs: [TaskID] = []
  private(set) var succeededTaskIDs: [TaskID] = []
  private(set) var maxConcurrent = 0

  /// 模拟「压根没启动」：模型未配置、存储不可写、或数据去向确认被取消。
  var neverStarts = false
  var generationDelay: Duration = .milliseconds(80)
  var autoPipelineSummarizeCalls = 0
  var onSummarizeStarted: (@MainActor (HistoryViewModel, TaskID) -> Void)?

  init(fixture: Fixture) { self.fixture = fixture }

  var isBusy: Bool { busyCount > 0 }

  func start(model: HistoryViewModel) {
    model.confirmBatchSummary(
      summarize: { [weak self, weak model] detail in
        guard let self, let model else { return }
        self.summarize(detail, model: model)
      },
      isBusy: { [weak self] in self?.isBusy ?? false }
    )
  }

  private func summarize(_ detail: HistoryDetailProjection, model: HistoryViewModel) {
    let taskID = detail.task.id
    startedTaskIDs.append(taskID)
    onSummarizeStarted?(model, taskID)
    guard !neverStarts else { return }
    inFlight += 1
    maxConcurrent = max(maxConcurrent, inFlight)
    busyCount += 1
    Task { [weak self] in
      try? await Task.sleep(for: self?.generationDelay ?? .milliseconds(80))
      guard let self else { return }
      try? self.fixture.writeCompletedSummary(taskID: taskID)
      self.succeededTaskIDs.append(taskID)
      self.inFlight -= 1
      self.busyCount -= 1
    }
  }
}
