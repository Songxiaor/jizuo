import XCTest
@testable import LinkDigestApp

/// 中文加粗被 CommonMark 的 flanking 规则打断。
///
/// 规则原文：闭合的 `**` 若前面是标点、后面又不是空格或标点，就不算闭合标记。
/// 它是为空格分隔语言设计的——中文正文不写空格，「提示：」后面直接接下文是常态，
/// 于是 `**重要提示：**您的礼品…` 会把星号原样显示出来。实测 Foundation 严格照做，
/// 英文的 `**Important:**your` 同样失败，所以这不是中文独有，只是中文必然撞上。
final class CJKEmphasisTests: XCTestCase {
  private func plain(_ markdown: String) -> String {
    String(MarkdownPresentation.inlineAttributed(markdown).characters)
  }

  // 这条是整件事的起点：真实抓到的一句帮助文档正文。
  func testBoldFollowedByCJKWithoutSpaceStillRenders() {
    let source = "**重要提示：**您的礼品将在购买日期后365天过期。"
    let output = plain(source)
    XCTAssertFalse(output.contains("**"), "星号必须被解析掉，不能显示给用户")
    XCTAssertTrue(output.contains("重要提示"))
    XCTAssertTrue(output.contains("您的礼品"))
    // 字符不增不减：只把标点移出强调范围，不插空格、不删内容。
    XCTAssertEqual(output.replacingOccurrences(of: "*", with: "").count, output.count)
    XCTAssertTrue(output.contains("重要提示：您的礼品"), "标点仍在原位，只是不再加粗")
  }

  func testSameProblemInLatinTextIsAlsoFixed() {
    XCTAssertFalse(plain("**Important:**your gift expires.").contains("**"))
  }

  /// 本来就能正常解析的写法不该被动到。
  func testAlreadyValidEmphasisIsUntouched() {
    for source in [
      "**重要提示：** 您的礼品将过期。",
      "前面有字**重要提示**后面有字",
      "**整段加粗没有标点结尾**",
      "没有任何强调的普通句子。",
    ] {
      XCTAssertFalse(plain(source).contains("**"), "\(source) 解析后不该残留星号")
    }
  }

  /// 行内代码里的星号是代码，不是强调。
  func testAsterisksInsideCodeSpansAreNotRewritten() {
    let source = "用 `a ** b：**c` 这个表达式"
    let normalized = MarkdownPresentation.normalizingCJKEmphasis(source)
    XCTAssertEqual(normalized, source, "代码跨度里的内容必须原样保留")
  }

  /// 斜体走同一条规则。
  func testItalicFollowsTheSameRule() {
    XCTAssertFalse(plain("*注意：*这里要小心。").contains("*"))
  }

  /// 归一化本身是纯函数，直接钉住改写结果。
  func testNormalizationMovesTrailingPunctuationOutsideTheEmphasis() {
    XCTAssertEqual(
      MarkdownPresentation.normalizingCJKEmphasis("**重要提示：**您的礼品"),
      "**重要提示**：您的礼品"
    )
    XCTAssertEqual(
      MarkdownPresentation.normalizingCJKEmphasis("**已经正确：** 有空格"),
      "**已经正确：** 有空格"
    )
  }

  func testPlainTextWithoutEmphasisMarkersShortCircuits() {
    let source = "完全没有强调标记的一段中文。"
    XCTAssertEqual(MarkdownPresentation.normalizingCJKEmphasis(source), source)
  }
}
