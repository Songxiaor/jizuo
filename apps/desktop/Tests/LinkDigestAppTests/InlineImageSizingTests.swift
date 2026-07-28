import XCTest
@testable import LinkDigestApp

/// 小图不该被放大。
///
/// `.resizable()` 会把图片拉伸到给定的 frame，而独立插图的宽度上限原来只按
/// 「最大高度 × 宽高比」算：一张 128×128 的微信表情因此被拉到 560×560，
/// 放大 4.4 倍糊成一整屏。正文配图普遍 800～1080 宽，所以这个缺陷只在小图上显形。
///
/// 判据用「图片自身有多大」而不是「它是不是表情」——按 URL 或域名识别表情要一个站
/// 一个站加，换个图床就失效；尺寸是图片自带的事实。
final class InlineImageSizingTests: XCTestCase {
  private func maximumWidth(width: CGFloat, height: CGFloat) -> CGFloat {
    let image = NSImage(size: NSSize(width: width, height: height))
    return InlineArticleImageView.standaloneMaximumWidthForTesting(of: image)
  }

  /// 真实案例：微信表情 128×128。
  func testSmallEmojiIsNeverScaledUp() {
    XCTAssertEqual(maximumWidth(width: 128, height: 128), 128)
  }

  /// 正文配图不受影响：1080 宽的横图仍按高度上限算宽度。
  func testLargeArticleImagesKeepTheHeightDrivenWidth() {
    // 1080×643 → 比例约 1.68，按 560 高算出的宽约 941，小于自身 1080。
    let width = maximumWidth(width: 1080, height: 643)
    XCTAssertEqual(width, 560 * (1080 / 643), accuracy: 0.5)
    XCTAssertLessThan(width, 1080)
  }

  /// 竖图按高度封顶，宽度远小于自身，行为不变。
  func testPortraitImagesStillCapByHeight() {
    XCTAssertEqual(maximumWidth(width: 1080, height: 1920), 560 * (1080 / 1920), accuracy: 0.5)
  }

  /// 尺寸拿不到时不能返回 0——那会让图片整个消失。
  func testDegenerateSizesFallBackToTheHeightRule() {
    XCTAssertGreaterThan(maximumWidth(width: 0, height: 0), 0)
  }
}
