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
    XCTAssertEqual(notice?.message, "上次翻译在\(ProductDisplay.name)退出时中断，没有结果，重新点一次就行。")
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

  func testLatestForKindIgnoresOtherKinds() {
    let runs = [
      run(.translate, .failed, at: 10),
      run(.summarize, .completed, at: 20),
    ]
    XCTAssertEqual(UnfinishedRunNotice.latest(in: runs, kind: .translate)?.kind, .translate)
    XCTAssertNil(UnfinishedRunNotice.latest(in: runs, kind: .summarize))
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

  /// 工序行副标题带第一句原因。悬停仍是正文里那整段（原因 + 怎么处理）。
  func testFailedRunSubtitleIncludesTheShortReasonAndHoverKeepsTheFullText() {
    let notice = UnfinishedRunNotice.latest(in: [
      run(.summarize, .failed, at: 20, failureCode: "MODEL_ENDPOINT_NOT_FOUND")
    ])
    XCTAssertEqual(
      notice?.message,
      "上次总结没有完成：这个服务地址上没有汲作要调用的接口"
    )
    let full = V02ErrorCatalog.presentation(for: "MODEL_ENDPOINT_NOT_FOUND").visibleText
    XCTAssertEqual(notice?.detail, full)
    XCTAssertTrue(full.contains("请回到「模型服务」核对服务地址"))
    XCTAssertFalse(notice?.message.contains("请回到") ?? true, "怎么处理不进副标题")
  }

  func testFailureWithoutACodeStaysASingleSentence() {
    let notice = UnfinishedRunNotice.latest(in: [run(.translate, .failed, at: 20)])
    XCTAssertEqual(notice?.message, "上次翻译没有完成。")
    XCTAssertEqual(notice?.detail, notice?.message)
  }

  func testProcessFailureCopyUsesTheFirstSentenceForEveryStep() {
    XCTAssertEqual(
      ProcessFailureCopy.subtitle(step: "转写", reason: "找不到可转写的本机视频。请稍后再试。"),
      "上次转写没有完成：找不到可转写的本机视频"
    )
    XCTAssertEqual(
      ProcessFailureCopy.subtitle(step: "校对", reason: "模型没有返回内容；原文没有改动。"),
      "上次校对没有完成：模型没有返回内容；原文没有改动"
    )
    XCTAssertEqual(ProcessFailureCopy.subtitle(step: "脑图", reason: "   "), "上次脑图没有完成。")
    XCTAssertEqual(
      ProcessFailureCopy.brief("上次总结没有完成：服务地址上没有这个接口"),
      "服务地址上没有这个接口"
    )
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
    XCTAssertTrue(source.contains("ignoreLanguageMatch: true"), "未完成翻译再试时不能被语言匹配挡住")
    XCTAssertTrue(source.contains("run-failure-retry"), "失败页自己要有再试按钮")
    XCTAssertTrue(source.contains("再翻译一次"))
    XCTAssertTrue(source.contains("再总结一次"))
  }
}
