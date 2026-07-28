import XCTest
import LinkDigestCore
@testable import LinkDigestApp

/// 没跑完的运行要主动说出来。
///
/// 成功有横幅（「翻译已完成」），失败和中断却什么都不显示——状态只落在详情下方
/// 一个被动的元数据字段上。库里那条 `translate / interrupted / APP_INTERRUPTED`
/// 就是这样：关 App 时被打断，表现是「点了翻译，什么也没发生」，用户既不知道它
/// 断过，也没有地方重试。
final class UnfinishedRunNoticeTests: XCTestCase {
  private func run(
    _ kind: RunKind,
    _ status: RunStatus,
    at ms: Int64,
    failureCode: String? = nil
  ) -> HistoryDetailProjection.RunDetail {
    .init(
      run: HistoryRun(
        id: RunID(), taskID: TaskID(), snapshotID: ContentSnapshotID(),
        idempotencyKey: "k-\(ms)", rerunOfRunID: nil, kind: kind, targetLanguage: nil,
        status: status, providerProfileID: nil, providerKind: nil, providerBaseURL: nil,
        providerAPIMode: nil, model: nil, createdAtMilliseconds: ms,
        startedAtMilliseconds: nil, finishedAtMilliseconds: nil,
        failureCode: failureCode, failureRetryable: nil, usageCost: .init()
      ),
      artifact: nil
    )
  }

  func testInterruptedRunProducesAnActionableNotice() {
    let notice = UnfinishedRunNotice.latest(in: [
      run(.translate, .interrupted, at: 10, failureCode: "APP_INTERRUPTED")
    ])
    XCTAssertEqual(notice?.kind, .translate)
    XCTAssertEqual(notice?.status, .interrupted)
    // 说清是「被打断」而不是「出错」——用户才知道重试大概率会成功。
    XCTAssertEqual(notice?.message, "上次翻译在 App 退出时中断，没有结果。")
  }

  /// 断过一次然后重跑成功是常态，不该再打扰。
  func testLaterSuccessOfTheSameKindClearsTheNotice() {
    XCTAssertNil(UnfinishedRunNotice.latest(in: [
      run(.translate, .interrupted, at: 10),
      run(.translate, .completed, at: 20),
    ]))
  }

  /// 成功在前、失败在后，仍要提示——顺序不能只看有没有成功过。
  func testFailureAfterSuccessStillNotifies() {
    let notice = UnfinishedRunNotice.latest(in: [
      run(.summarize, .completed, at: 10),
      run(.summarize, .failed, at: 20),
    ])
    XCTAssertEqual(notice?.kind, .summarize)
  }

  /// 翻译断了不代表总结也断了，两者互不遮蔽。
  func testKindsAreTrackedIndependently() {
    let notice = UnfinishedRunNotice.latest(in: [
      run(.translate, .interrupted, at: 10),
      run(.summarize, .completed, at: 20),
    ])
    XCTAssertEqual(notice?.kind, .translate, "总结成功不该把翻译的中断盖掉")
  }

  /// 用户主动停止不是故障；进行中另有转圈提示。
  func testStoppedAndInFlightRunsAreNotNotices() {
    XCTAssertNil(UnfinishedRunNotice.latest(in: [run(.summarize, .stopped, at: 10)]))
    XCTAssertNil(UnfinishedRunNotice.latest(in: [run(.summarize, .running, at: 10)]))
    XCTAssertNil(UnfinishedRunNotice.latest(in: [run(.summarize, .queued, at: 10)]))
  }

  func testNoRunsMeansNoNotice() {
    XCTAssertNil(UnfinishedRunNotice.latest(in: []))
  }

  /// 横幅必须带可执行的重试，只报告不给出口等于没修。
  func testDetailViewRendersTheNoticeWithARetryAction() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8)
    XCTAssertTrue(source.contains("history-run-unfinished-banner"))
    XCTAssertTrue(source.contains("history-run-unfinished-retry"))
    XCTAssertTrue(
      source.contains("private func retryUnfinishedRun(_ kind: RunKind)"),
      "重试要走和工具栏按钮相同的入口，另起一条路径两边校验迟早漂移")
  }
}
