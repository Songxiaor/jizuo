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
  /// 长视频（2026-11-20 实测 18 分钟那条）详情里清晰度档位多，整段 13 万字以上；
  /// 原来 24 万字的上限加 WebKit 侧 ±11.9 万字截断会把 JSON 尾巴切掉，解析不出 play_addr。
  func testLongVideoDetailWithManyBitRatesIsStillParsed() {
    let bitRate = "{\"gear_name\":\"normal_1080_0\",\"play_addr\":{\"url_list\":[\"https://v.example.test/variant.mp4?" + String(repeating: "x", count: 1_200) + "\"]}}"
    let state = "{\"aweme_detail\":{\"aweme_id\":\"7682114530020740387\",\"video\":{\"play_addr\":{\"url_list\":[\"https://v.example.test/target.mp4\"]},\"bit_rate\":["
      + Array(repeating: bitRate, count: 250).joined(separator: ",")
      + "]}}}"
    XCTAssertGreaterThan(state.count, 300_000)
    XCTAssertEqual(DouyinPageParser.parseStateSnippet(state, pageURL: url)?.videoURL.absoluteString,
                   "https://v.example.test/target.mp4")
  }
}
