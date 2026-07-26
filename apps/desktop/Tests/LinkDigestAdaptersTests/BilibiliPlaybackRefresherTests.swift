import XCTest
import LinkDigestCore
@testable import LinkDigestAdapters

final class BilibiliPlaybackRefresherTests: XCTestCase {
  func testQualityPreferenceMapsToIncreasingQNCeilings() {
    XCTAssertEqual(BilibiliStreamQualityPreference.dataSaver.requestedQN, 64)
    XCTAssertEqual(BilibiliStreamQualityPreference.balanced.requestedQN, 80)
    XCTAssertEqual(BilibiliStreamQualityPreference.highest.requestedQN, 127)
    XCTAssertLessThan(
      BilibiliStreamQualityPreference.dataSaver.requestedQN,
      BilibiliStreamQualityPreference.highest.requestedQN
    )
  }

  func testVideoIDParsingAcceptsBVAndAvPaths() {
    XCTAssertEqual(
      BilibiliPlaybackRefresher.videoID(from: "https://www.bilibili.com/video/BV1xx411c7mD"),
      "BV1xx411c7mD"
    )
    XCTAssertEqual(
      BilibiliPlaybackRefresher.videoID(from: "https://m.bilibili.com/video/av170001?p=1"),
      "av170001"
    )
    XCTAssertNil(BilibiliPlaybackRefresher.videoID(from: "https://www.bilibili.com/"))
    XCTAssertNil(BilibiliPlaybackRefresher.videoID(from: "https://example.test/video/BV1xx411c7mD"))
  }

  func testAllowedCDNRejectsNonBilivideoHosts() {
    XCTAssertTrue(
      BilibiliPlaybackRefresher.isAllowedCDNURL(
        "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/xx.m4s?deadline=1900000000"
      )
    )
    XCTAssertFalse(
      BilibiliPlaybackRefresher.isAllowedCDNURL("https://evil.example.test/video.m4s")
    )
    XCTAssertFalse(
      BilibiliPlaybackRefresher.isAllowedCDNURL("http://upos.bilivideo.com/video.m4s")
    )
    // mcdn 非常规端口：易 404，选流应走 bilivideo.com backup。
    XCTAssertFalse(
      BilibiliPlaybackRefresher.isAllowedCDNURL(
        "https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/foo.m4s"
      )
    )
  }

  func testCodecPlayabilityExcludesDolbyVisionAndPrefersAVC() {
    XCTAssertNil(BilibiliPlaybackRefresher.codecPlayabilityScore("dvh1.08.07"))
    XCTAssertNil(BilibiliPlaybackRefresher.codecPlayabilityScore("dvhe.05.07"))
    let avc = BilibiliPlaybackRefresher.codecPlayabilityScore("avc1.640028")
    let hevc = BilibiliPlaybackRefresher.codecPlayabilityScore("hev1.1.6.L150.90")
    let av1 = BilibiliPlaybackRefresher.codecPlayabilityScore("av01.0.08M.08")
    let aac = BilibiliPlaybackRefresher.codecPlayabilityScore("mp4a.40.2")
    let eac3 = BilibiliPlaybackRefresher.codecPlayabilityScore("ec-3")
    XCTAssertNotNil(avc)
    XCTAssertNotNil(hevc)
    XCTAssertNotNil(av1)
    XCTAssertNotNil(aac)
    XCTAssertGreaterThan(avc!, hevc!)
    XCTAssertGreaterThan(hevc!, av1!)
    XCTAssertGreaterThan(aac!, eac3!)
  }

  func testLongFormVideosPreferProgressiveMP4() {
    // 63 分钟演示片：必须 progressive，不能走易卡死的双轨合成。
    XCTAssertTrue(BilibiliPlaybackRefresher.prefersProgressiveForDuration(63 * 60))
    XCTAssertTrue(BilibiliPlaybackRefresher.prefersProgressiveForDuration(10 * 60))
    XCTAssertFalse(BilibiliPlaybackRefresher.prefersProgressiveForDuration(9 * 60))
    XCTAssertFalse(BilibiliPlaybackRefresher.prefersProgressiveForDuration(nil))
  }
}
