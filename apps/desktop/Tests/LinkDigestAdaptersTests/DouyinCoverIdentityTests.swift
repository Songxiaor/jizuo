import XCTest
@testable import LinkDigestAdapters

final class DouyinCoverIdentityTests: XCTestCase {
  private let pageURL = URL(string: "https://www.douyin.com/video/7682114530020740387")!

  func testMissingTargetCoverDoesNotBorrowAdjacentRecommendation() {
    let state = #"{"items":[{"aweme_id":"7111111111111111111","video":{"cover":{"url_list":["https://p3.douyinpic.com/neighbor.jpg"]}}},{"aweme_id":"7682114530020740387","video":{}}]}"#
    XCTAssertNil(DouyinPageParser.parseAnchoredCoverURL(state, pageURL: pageURL))
  }

  func testTargetCoverBeyondSixThousandCharactersStillBelongsToTarget() {
    let state = "{\"aweme_detail\":{\"aweme_id\":\"7682114530020740387\",\"padding\":\""
      + String(repeating: "a", count: 8_000)
      + "\",\"video\":{\"cover\":{\"url_list\":[\"https://p3.douyinpic.com/target.jpg\"]}}}}"
    XCTAssertEqual(DouyinPageParser.parseAnchoredCoverURL(state, pageURL: pageURL)?.absoluteString,
                   "https://p3.douyinpic.com/target.jpg")
  }

  func testMentioningTargetIDInAnotherCaptionIsNotAnIdentityMatch() {
    let state = #"{"aweme_detail":{"aweme_id":"7111111111111111111","desc":"refer to 7682114530020740387","video":{"cover":{"url_list":["https://p3.douyinpic.com/wrong.jpg"]}}}}"#
    XCTAssertNil(DouyinPageParser.parseAnchoredCoverURL(state, pageURL: pageURL))
  }
  func testCompleteTargetObjectSurvivesIncompleteOuterState() {
    let state = #"window.state = {"items":[{"awemeId":"7682114530020740387","desc":"a {quoted} caption","video":{"originCover":{"urlList":["https://p3.douyinpic.com/original.jpg"]}}},"#
    XCTAssertEqual(DouyinPageParser.parseAnchoredCoverURL(state, pageURL: pageURL)?.absoluteString,
                   "https://p3.douyinpic.com/original.jpg")
  }

}
