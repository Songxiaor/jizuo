import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 抖音渲染兜底的时限与重试策略。
///
/// 这条策略只做一件事：把「页面没在时限内加载出来」和「换个会话也没用」分开。
/// 前者在后台被降速时很常见，值得再开一次会话；后者（跳站、验证、取消）重试
/// 只会把失败拖长一倍。
final class DouyinCaptureRetryPolicyTests: XCTestCase {
  private var videoURL: URL {
    URL(string: "https://www.douyin.com/video/7707222307812019475")!
  }

  private var noteURL: URL {
    URL(string: "https://www.douyin.com/note/7707222307812019475")!
  }

  func testDeadlineIsWiderThanTheOldTwentySeconds() {
    XCTAssertGreaterThanOrEqual(DouyinCaptureRetryPolicy.videoTimeout, .seconds(35))
    XCTAssertGreaterThanOrEqual(DouyinCaptureRetryPolicy.noteTimeout, .seconds(35))
    XCTAssertGreaterThan(DouyinCaptureRetryPolicy.videoTimeout, .seconds(20))
  }

  func testTimeoutFollowsTheContentKind() {
    XCTAssertEqual(DouyinCaptureRetryPolicy.timeout(for: videoURL), DouyinCaptureRetryPolicy.videoTimeout)
    XCTAssertEqual(DouyinCaptureRetryPolicy.timeout(for: noteURL), DouyinCaptureRetryPolicy.noteTimeout)
  }

  func testOnlyTheFirstTimeoutGetsASecondSession() {
    XCTAssertTrue(DouyinCaptureRetryPolicy.shouldRetry(after: .timedOut, attempt: 1))
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .timedOut, attempt: 2), "最多两次，不能无限重试")
  }

  func testOtherFailuresDoNotGetASecondSession() {
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .extensionCaptureRequired, attempt: 1))
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .webHostNotAllowed, attempt: 1))
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .verificationRequired, attempt: 1))
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .network, attempt: 1))
    XCTAssertFalse(DouyinCaptureRetryPolicy.shouldRetry(after: .cancelled, attempt: 1))
  }
}
