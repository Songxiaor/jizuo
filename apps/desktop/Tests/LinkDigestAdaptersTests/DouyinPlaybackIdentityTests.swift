import XCTest
@testable import LinkDigestAdapters

final class DouyinPlaybackIdentityTests: XCTestCase {
  private let url = URL(string: "https://www.douyin.com/video/7682114530020740387")!

  func testMissingTargetStreamDoesNotBorrowRecommendation() {
    let state = #"{"items":[{"aweme_id":"7111111111111111111","video":{"play_addr":{"url_list":["https://v.example.test/neighbor.mp4"]}}},{"aweme_id":"7682114530020740387","video":{"cover":{"url_list":["https://p3.douyinpic.com/target.jpg"]}}}]}"#
    XCTAssertNil(DouyinPageParser.parseStateSnippet(state, pageURL: url))
  }

  func testTargetVideoBeyondLegacyWindowIsStillSelected() {
    let state = "{\"aweme_detail\":{\"aweme_id\":\"7682114530020740387\",\"padding\":\""
      + String(repeating: "a", count: 8_000)
      + "\",\"video\":{\"play_addr\":{\"url_list\":[\"https://v.example.test/target.mp4\"]}}}}"
    XCTAssertEqual(DouyinPageParser.parseStateSnippet(state, pageURL: url)?.videoURL.absoluteString,
                   "https://v.example.test/target.mp4")
  }
}
