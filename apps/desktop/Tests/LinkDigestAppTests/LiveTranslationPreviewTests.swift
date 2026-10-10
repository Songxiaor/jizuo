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

  func testRetranslationReplacesThePreviousTranslationByParagraph() {
    let previous = """
    欢迎了解 Swift

    Swift 是一门高性能的系统编程语言。

    它默认内存安全。
    """
    let draft = LiveTranslationPreview.replacementDraft(
      incoming: "Swift 编程语言\n\n欢迎了解",
      base: previous
    )
    XCTAssertEqual(draft.settled, "Swift 编程语言\n\n欢迎了解")
    XCTAssertEqual(draft.pending, "它默认内存安全。")
    XCTAssertFalse(draft.settled.contains("Swift is"))
    XCTAssertFalse(draft.pending?.contains("Swift is") == true)

    let waiting = LiveTranslationPreview.replacementDraft(incoming: nil, base: previous)
    XCTAssertEqual(waiting.settled, "")
    XCTAssertEqual(waiting.pending, previous)
  }

  func testLayersFollowTranslationOrder() {
    let completed = "# 标题\n\n## 配文\n\n配文译文\n\n## 视频转写\n\n00:20 晚上好。"
    XCTAssertEqual(LiveTranslationPreview.translatedLayerHeadings(in: completed), ["配文", "视频转写"])
    XCTAssertEqual(LiveTranslationPreview.translatedBody(of: "视频转写", in: completed), "00:20 晚上好。")
    XCTAssertNil(LiveTranslationPreview.translatedBody(of: "画面字幕", in: completed))
    XCTAssertNil(LiveTranslationPreview.unlayeredBody(in: completed))
    XCTAssertEqual(LiveTranslationPreview.unlayeredBody(in: "第一段\n\n第二段"), "第一段\n\n第二段")
  }

  /// 直播预览不显示评论区（2026-10-09 Syc：「一直闪」）。
  ///
  /// 译文每写完一行就重拼一次正文，评论段被模型原样逐行回抄；评论块是嵌在文字视图里的
  /// 嵌入块，复用键带着评论内容，每多抄一行块就整体重建一次，重建中的宿主视图在文字
  /// 引擎里被换成默认的半透明纸片——上万点高的评论块一次一次地换，就是压在评论上
  /// 反复闪的那一大片。评论不是译文，边翻边看不需要它；翻完落库后由成品路径照常显示。
  func testLivePreviewStripsTheCommentsSection() {
    let withComments = "# 标题\n\n## 配文\n\n配文译文。\n\n## 评论（已保存 3 条）\n\n- **甲** · 赞 1\n  好的"
    XCTAssertEqual(
      LiveTranslationPreview.strippingComments(from: withComments),
      "# 标题\n\n## 配文\n\n配文译文。"
    )
    // 没有评论段的正文原样返回，不去动内容。
    XCTAssertEqual(LiveTranslationPreview.strippingComments(from: "配文译文。"), "配文译文。")
    // 「评论区」这类正文里的字不算：切分点是行首的 `## 评论` 小标题。
    XCTAssertEqual(
      LiveTranslationPreview.strippingComments(from: "评论区的设计\n\n正文"),
      "评论区的设计\n\n正文"
    )
  }
}
