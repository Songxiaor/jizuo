import XCTest
@testable import LinkDigestApp

final class CommentFetchServiceTests: XCTestCase {
  func testHiddenPageOnlyFollowsWebSchemes() {
    XCTAssertTrue(CommentFetchService.allowsNavigation(to: URL(string: "https://www.douyin.com/video/1")))
    XCTAssertTrue(CommentFetchService.allowsNavigation(to: URL(string: "about:blank")))
    XCTAssertFalse(CommentFetchService.allowsNavigation(to: URL(string: "bitbrowser://cc/")))
    XCTAssertFalse(CommentFetchService.allowsNavigation(to: URL(string: "snssdk1128://aweme/detail/1")))
    XCTAssertFalse(CommentFetchService.allowsNavigation(to: URL(string: "mailto:a@b.c")))
  }
}
