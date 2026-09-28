import XCTest
@testable import LinkDigestCore

final class CommentCaptureTests: XCTestCase {
  private let sample: [CapturedComment] = [
    .init(id: "a", author: "小明", body: "第一条评论\n第二行", depth: 0, likes: "1.2万", published: "2026-09-20"),
    .init(id: "b", author: "作者**本人**", body: "回复一下", depth: 1, permalink: "https://x.com/u/status/2"),
    .init(id: "c", author: "u/redditor", body: "reddit body", depth: 0, score: "42"),
  ]

  /// 与扩展 tests/comments.test.ts「writes the heading and headers…」同一段期望文本。
  func testMarkdownMatchesExtensionFormatExactly() {
    XCTAssertEqual(CommentCapture.markdown(expectedCount: 88, comments: sample), [
      "## 评论（已保存 3 条 / 页面显示 88）",
      "",
      "- **小明** · 赞 1.2万 · 2026-09-20 · 回复层级 0",
      "  第一条评论",
      "  第二行",
      "  - **作者本人** · [原评论](https://x.com/u/status/2) · 回复层级 1",
      "    回复一下",
      "- **u/redditor** · score 42 · 回复层级 0",
      "  reddit body",
    ].joined(separator: "\n"))
    XCTAssertEqual(
      CommentCapture.markdown(expectedCount: 2, comments: Array(sample.prefix(2))).components(separatedBy: "\n").first,
      "## 评论（已保存 2 条）"
    )
    XCTAssertEqual(CommentCapture.markdown(expectedCount: nil, comments: []), "")
  }

  func testReplacingCommentsSwapsOnlyTheTrailingSection() {
    let body = "# 标题\n\n正文\n\n## 评论（当前页面已加载 3）\n\n- **u/a** · score 1\n  hi"
    let replaced = CommentCapture.replacingComments(in: body, expectedCount: nil, selected: [sample[0]])
    XCTAssertTrue(replaced.hasPrefix("# 标题\n\n正文\n\n## 评论（已保存 1 条）"))
    XCTAssertFalse(replaced.contains("u/a"))
    XCTAssertEqual(CommentCapture.replacingComments(in: body, expectedCount: nil, selected: []), "# 标题\n\n正文")
    let plain = "正文\n\n## 评论区的设计\n\n文字"
    XCTAssertEqual(CommentCapture.strippingCommentSection(from: plain), plain)
  }

  func testPlatformDetectionMatchesExtension() {
    let cases: [(String, String?)] = [
      ("https://www.reddit.com/r/x/comments/abc/title/", "reddit"),
      ("https://news.ycombinator.com/item?id=1", "community"),
      ("https://x.com/someone/status/123456", "x"),
      ("https://www.youtube.com/watch?v=abc", "youtube"),
      ("https://www.bilibili.com/video/BV1GJ411x7h7", "bilibili"),
      ("https://www.zhihu.com/question/1/answer/2", "zhihu"),
      ("https://zhuanlan.zhihu.com/p/123", "zhihu"),
      ("https://www.douyin.com/video/7300000000000000000", "douyin"),
      ("https://www.douyin.com/jingxuan?modal_id=7300000000000000000", "douyin"),
      ("https://www.xiaohongshu.com/explore/64a1b2c3d4e5f6a7b8c9d0e1", "xiaohongshu"),
      ("https://x.com/someone", nil),
      ("https://mp.weixin.qq.com/s/abc", nil),
      ("https://www.youtube.com/", nil),
    ]
    for (raw, expected) in cases {
      XCTAssertEqual(CommentCapture.platform(for: URL(string: raw)!), expected, raw)
    }
  }

  func testDecodesCollectorJSONAndBuildsFunctionBody() throws {
    let json = #"{"platform":"bilibili","comments":[{"id":"h1","author":"甲","body":"好","depth":0,"likes":"3"}],"expectedCount":120,"limit":20}"#
    let collection = try XCTUnwrap(CommentCapture.decodeCollection(json: json))
    XCTAssertEqual(collection.comments.first?.likes, "3")
    XCTAssertEqual(collection.expectedCount, 120)
    XCTAssertNil(CommentCapture.decodeCollection(json: "null"))
    let body = CommentCapture.collectorFunctionBody(script: "var a = \"x\";\nextractComments;", limit: 500)
    XCTAssertTrue(body.contains("__linkdigestCommentLimit = 100"))
    XCTAssertTrue(body.contains(#""var a = \"x\";\nextractComments;""#))
  }

  func testCollectorScriptIsBundled() throws {
    let script = try XCTUnwrap(CommentCapture.collectorScript())
    XCTAssertTrue(script.contains("extractComments"))
  }
}
