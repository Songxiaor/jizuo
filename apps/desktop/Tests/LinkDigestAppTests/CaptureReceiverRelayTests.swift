import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

/// CaptureReceiver 的代抓接线：扩展来问任务能拿到 job id；带 job id 送回的内容
/// 交给代抓流程，而不是在接收器里再入库一遍。
final class CaptureReceiverRelayTests: XCTestCase {
  private func envelope(jobID: String?) -> Data {
    var object: [String: Any] = [
      "version": 1,
      "requestId": "capture-1",
      "createdAt": "2026-11-19T00:00:00Z",
      "source": ["kind": "browser_capture", "url": "https://example.test/relay", "title": "代抓", "platform": "generic"],
      "capture": [
        "method": "rendered_dom", "text": "正文", "characterCount": 2,
        "completeness": "full_article", "capturedAt": "2026-11-19T00:00:00Z",
      ],
      "evidence": ["sourceLabel": "test", "usedCookie": false],
    ]
    if let jobID { object["captureJobID"] = jobID }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  func testJobQueryIsAnsweredWithTheRelayJob() async {
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in },
      browserCaptureJobSink: { request in
        XCTAssertEqual(request.urls, ["https://v.douyin.com/abc/"])
        return "job-1"
      }
    )
    let query = try! JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJob", "version": 1, "requestId": "q1", "tabID": 7,
      "urls": ["https://v.douyin.com/abc/"],
    ])
    let response = await receiver.process(query)
    XCTAssertEqual(response, .browserCaptureJob(version: 1, requestId: "q1", jobID: "job-1"))
  }

  func testJobQueryWithoutRelayWiringSaysNoJob() async {
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in }
    )
    let query = try! JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJob", "version": 1, "requestId": "q2", "tabID": 7,
      "urls": ["https://example.test/x"],
    ])
    let response = await receiver.process(query)
    XCTAssertEqual(response, .browserCaptureJob(version: 1, requestId: "q2", jobID: nil))
  }

  func testBlockedOutcomeIsRoutedToTheRelayAndAcknowledged() async {
    let routed = SendableDeliveryProbe()
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in routed.recordUnexpectedCapture() },
      browserCaptureOutcomeSink: { outcome in
        XCTAssertEqual(outcome.jobID, "job-1")
        XCTAssertEqual(outcome.reason, .noteUnavailable)
        XCTAssertTrue(outcome.finalURL.hasPrefix("https://www.xiaohongshu.com/404"))
        return true
      }
    )
    let message = try! JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJobOutcome", "version": 1, "requestId": "o1", "jobID": "job-1",
      "finalURL": "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031",
      "reason": "note_unavailable",
    ])
    let response = await receiver.process(message)
    XCTAssertEqual(response, .browserCaptureJob(version: 1, requestId: "o1", jobID: nil))
    XCTAssertEqual(routed.captureCount, 0, "错误页回报不是内容，不能入库")
  }

  func testJobTaggedCaptureGoesToTheRelayInsteadOfASecondIngest() async {
    let delivered = SendableDeliveryProbe()
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in
        delivered.recordUnexpectedCapture()
      },
      browserCaptureDeliverySink: { jobID, wire in
        XCTAssertEqual(jobID, "job-1")
        XCTAssertEqual(wire.characterCount, 2)
        return true
      }
    )
    let response = await receiver.process(envelope(jobID: "job-1"))
    XCTAssertEqual(response, .taskAccepted(version: 1, requestId: "capture-1", characterCount: 2))
    XCTAssertEqual(delivered.captureCount, 0, "代抓内容由队列入库，接收器不能再存一遍")
  }

  func testExpiredJobIsDiscardedInsteadOfSavedASecondTime() async {
    let ingestProbe = SendableDeliveryProbe()
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in ingestProbe.recordUnexpectedCapture() },
      browserCaptureDeliverySink: { _, _ in false }
    )
    let response = await receiver.process(envelope(jobID: "stale-job"))
    guard case let .error(error) = response else {
      return XCTFail("作废 job 的内容不能再落成一次普通抓取：\(response)")
    }
    XCTAssertEqual(error.code, "CAPTURE_JOB_EXPIRED")
    XCTAssertFalse(error.retryable)
    XCTAssertEqual(ingestProbe.captureCount, 0, "丢掉的代抓内容不能进库")
  }

  func testUnclaimedJobIsNotIngested() async {
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in },
      browserCaptureDeliverySink: { _, _ in false }
    )
    // 没有历史库时普通入库也会报存储错误；用错误码区分是不是走了「作废丢弃」这一支。
    let response = await receiver.process(envelope(jobID: "stale-job"))
    guard case let .error(error) = response else {
      return XCTFail("过期的 job 不能回 taskAccepted：\(response)")
    }
    XCTAssertEqual(error.code, "CAPTURE_JOB_EXPIRED")
  }
}

private final class SendableDeliveryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var captures = 0

  func recordUnexpectedCapture() { lock.withLock { captures += 1 } }
  var captureCount: Int { lock.withLock { captures } }
}
