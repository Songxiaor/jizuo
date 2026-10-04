import XCTest
@testable import LinkDigestApp

final class LiveTranslationPreviewTests: XCTestCase {
  private let source = """
  ## 开场

  00:20 Good evening.

  00:25 Thank you.

  ## 灯笼

  00:27 I have a lantern, a screen, and a question.

  00:32 What is light?
  """

  func testHalfWrittenLineIsHeldBack() {
    XCTAssertEqual(LiveTranslationPreview.completedText(of: "00:20 晚上好。\n00:25 谢"), "00:20 晚上好。")
    XCTAssertEqual(LiveTranslationPreview.completedText(of: "00:20 晚上"), "")
  }

  func testPendingSourceStartsAfterLastTranslatedStamp() {
    let pending = LiveTranslationPreview.untranslatedSource(source, afterTranslated: "00:20 晚上好。\n00:25 谢谢。")
    XCTAssertEqual(pending, """
    ## 灯笼

    00:27 I have a lantern, a screen, and a question.

    00:32 What is light?
    """)
  }

  func testNothingTranslatedYetKeepsWholeSource() {
    XCTAssertEqual(LiveTranslationPreview.untranslatedSource(source, afterTranslated: nil), source)
    XCTAssertEqual(LiveTranslationPreview.untranslatedSource(source, afterTranslated: "## 开场"), source)
  }

  func testFullyTranslatedLeavesNothingPending() {
    XCTAssertEqual(LiveTranslationPreview.untranslatedSource(source, afterTranslated: "00:32 光是什么？"), "")
  }

  func testSourceWithoutStampsCannotBeAligned() {
    XCTAssertNil(LiveTranslationPreview.untranslatedSource("Hello.\n\nWorld.", afterTranslated: "你好。"))
  }

  func testHourStampsCompareByValue() {
    let long = "59:58 a\n\n1:00:02 b\n\n1:00:09 c"
    XCTAssertEqual(LiveTranslationPreview.untranslatedSource(long, afterTranslated: "1:00:02 乙"), "1:00:09 c")
  }

  func testLayersFollowTranslationOrder() {
    let completed = "# 标题\n\n## 配文\n\n配文译文\n\n## 视频转写\n\n00:20 晚上好。"
    XCTAssertEqual(LiveTranslationPreview.translatedLayerHeadings(in: completed), ["配文", "视频转写"])
    XCTAssertEqual(LiveTranslationPreview.translatedBody(of: "视频转写", in: completed), "00:20 晚上好。")
    XCTAssertNil(LiveTranslationPreview.translatedBody(of: "画面字幕", in: completed))
    XCTAssertNil(LiveTranslationPreview.unlayeredBody(in: completed))
    XCTAssertEqual(LiveTranslationPreview.unlayeredBody(in: "第一段\n\n第二段"), "第一段\n\n第二段")
  }
}
