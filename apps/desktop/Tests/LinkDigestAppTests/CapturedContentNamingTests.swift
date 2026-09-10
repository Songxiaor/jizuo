import XCTest
@testable import LinkDigestApp
import LinkDigestCore

final class CapturedContentNamingTests: XCTestCase {
  func testDouyinShortCaptionUsesStoredTitle() {
    let name = CapturedContentNaming.name(
      title: "今天去海边了",
      body: "# 今天去海边了\n\n今天去海边了",
      host: "www.douyin.com",
      author: "阿强",
      published: "2026-03-15T10:00:00+08:00"
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "今天去海边了")
    XCTAssertTrue(
      CapturedContentNaming.hidesRepeatedHeading(name: name, body: "# 今天去海边了\n\n今天去海边了")
    )
  }

  func testDouyinLongCaptionTakesFirstSentenceAndTruncates() {
    let first = "这是一句超过四十个字的抖音配文，用来确认派生名称会被截断并且不会去找模型帮忙完成检查"
    XCTAssertGreaterThan(first.count, 40)
    let title = "\(first)。后面这句很长也不该出现在名称里。"
    let name = CapturedContentNaming.name(
      title: title,
      body: title,
      host: "v.douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, String(first.prefix(40)) + "…")
    XCTAssertFalse(
      CapturedContentNaming.hidesRepeatedHeading(name: name, body: title),
      "长段首句名称不等于全文，阅读区应保留正文"
    )
  }

  func testDouyinStripsTrailingHashtagsButKeepsOrdinaryHash() {
    let tagged = CapturedContentNaming.name(
      title: "今天去海边了 #日常 #旅行",
      body: "今天去海边了 #日常 #旅行",
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(tagged.origin, .caption)
    XCTAssertEqual(tagged.text, "今天去海边了")
    XCTAssertFalse(
      CapturedContentNaming.hidesRepeatedHeading(name: tagged, body: "今天去海边了 #日常 #旅行"),
      "正文仍含话题串，不等于名称，不能藏"
    )

    let glued = CapturedContentNaming.name(
      title: "今天去海边了#日常#旅行",
      body: "今天去海边了#日常#旅行",
      host: "iesdouyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(glued.text, "今天去海边了")

    let csharp = CapturedContentNaming.name(
      title: "用 C# 写小工具",
      body: "用 C# 写小工具",
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(csharp.text, "用 C# 写小工具")
  }

  func testDouyinDoesNotSplitEnglishVersionNumbers() {
    let title = "升级到 5.0 之后手感完全不同了。下一句不要出现在名称里。"
    let name = CapturedContentNaming.name(
      title: title,
      body: title,
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "升级到 5.0 之后手感完全不同了。")
    XCTAssertFalse(name.text.contains("下一句"))
  }

  func testDouyinEmojiCountsAsOneCharacterTowardForty() {
    let forty = String(repeating: "😀", count: 40)
    let fortyOne = String(repeating: "😀", count: 41)
    let kept = CapturedContentNaming.name(
      title: forty,
      body: forty,
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(kept.text, forty)
    XCTAssertFalse(kept.text.hasSuffix("…"))

    let truncated = CapturedContentNaming.name(
      title: fortyOne,
      body: fortyOne,
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(truncated.text, forty + "…")
    XCTAssertEqual(truncated.text.count, 41)
  }

  func testDouyinFallsBackToBodyWhenTitleIsMissing() {
    let name = CapturedContentNaming.name(
      title: CapturedDocumentTitle.missing,
      body: "配文写在正文里。第二句丢掉。",
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "配文写在正文里。")
  }

  func testXiaohongshuKeepsOriginalTitle() {
    let title = "一间温暖的房子。周末改造记录"
    let name = CapturedContentNaming.name(
      title: title,
      body: "\(title)\n\n保留作者的描述与 #空间设计",
      host: "www.xiaohongshu.com",
      author: "小红",
      published: "2026-04-01"
    )
    XCTAssertEqual(name.origin, .sourceTitle)
    XCTAssertEqual(name.text, title)
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: name, body: title))
  }

  func testBilibiliTitleWithPeriodIsNotSentenceSplit() {
    let title = "【教程】Unity 5.0 入门. 完整版"
    let name = CapturedContentNaming.name(
      title: title,
      body: "第一段讲解环境安装。",
      host: "bilibili.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .sourceTitle)
    XCTAssertEqual(name.text, title)
  }

  func testYouTubeWeChatAndOrdinaryArticlesKeepSourceTitle() {
    let youtube = CapturedContentNaming.name(
      title: "Why 5.0 still matters. A long talk",
      body: "Transcript of the talk.",
      host: "youtu.be",
      author: nil,
      published: nil
    )
    XCTAssertEqual(youtube.origin, .sourceTitle)
    XCTAssertEqual(youtube.text, "Why 5.0 still matters. A long talk")

    let wechat = CapturedContentNaming.name(
      title: "春节前，把这三件事做完。",
      body: "正文从这里开始。",
      host: "mp.weixin.qq.com",
      author: "公众号作者",
      published: "2026-01-20"
    )
    XCTAssertEqual(wechat.origin, .sourceTitle)
    XCTAssertEqual(wechat.text, "春节前，把这三件事做完。")

    let longTitle = String(repeating: "长", count: 48)
    let article = CapturedContentNaming.name(
      title: longTitle,
      body: "文章第一段。",
      host: "example.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(article.origin, .sourceTitle)
    XCTAssertEqual(article.text, longTitle, "独立标题不按 40 字截断")
  }

  func testXArticleTitleIsProtectedWhenItDiffersFromBody() {
    let title = "Why the web feels worse now"
    let body = "A few years ago I started noticing the ads first.\n\nThen the layout."
    let name = CapturedContentNaming.name(
      title: title,
      body: body,
      host: "x.com",
      author: "syc",
      published: nil
    )
    XCTAssertEqual(name.origin, .sourceTitle)
    XCTAssertEqual(name.text, title)
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: name, body: body))
  }

  func testXPostCaptionUsesSeventyTwoCharactersAndBreaksAtWordBoundary() {
    let body = "The greatest focus hack is to know what you want and why you want it before anyone else tells you what to want"
    let name = CapturedContentNaming.name(
      title: "The greatest focus hack is to know what …",
      body: body,
      host: "x.com",
      author: "DAN KOE",
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertTrue(name.text.hasSuffix("…"))
    XCTAssertLessThanOrEqual(name.text.count, 73)
    XCTAssertGreaterThan(name.text.count, 45, "推文标题应放宽到两行能装下的长度，不再 40 字就截")
    XCTAssertTrue(body.hasPrefix(String(name.text.dropLast())), "从正文重新取，不沿用抓取端截过的标题")
    let stem = String(name.text.dropLast())
    let nextIndex = body.index(body.startIndex, offsetBy: stem.count)
    XCTAssertTrue(body[nextIndex].isWhitespace, "不能在单词中间截断：\(name.text)")

    let short = CapturedContentNaming.name(
      title: "Grab a notebook.", body: "Grab a notebook.\n\nWrite it down.", host: "x.com", author: nil, published: nil
    )
    XCTAssertEqual(short.text, "Grab a notebook.")
  }

  func testXPostMatchingBodyStartIsTreatedAsCaption() {
    let body = "just shipped a small thing today\n\nmore in the thread"
    let name = CapturedContentNaming.name(
      title: "just shipped a small thing today",
      body: body,
      host: "twitter.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "just shipped a small thing today")

    let truncated = CapturedContentNaming.name(
      title: "just shipped a small thing…",
      body: "just shipped a small thing today and it feels great",
      host: "x.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(truncated.origin, .caption)
    // 抓取端截过的标题只当「这是配文」的证据，标题本身从正文重新取完整句子。
    XCTAssertEqual(truncated.text, "just shipped a small thing today and it feels great")
  }

  func testMissingTitleUsesFirstSubstantialParagraph() {
    let body = """
    ---
    author: "阿强"
    published: "2026-03-15"
    ---

    ![封面](https://example.test/cover.jpg)

    ```
    code only
    ```

    https://example.test/raw

    这是正文第一段，讲了很多。第二句丢掉。

    第二段不该当名称。
    """
    let name = CapturedContentNaming.name(
      title: "example.com · /long/path",
      body: body,
      host: "example.com",
      author: "阿强",
      published: "2026-03-15"
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "这是正文第一段，讲了很多。")
    XCTAssertFalse(name.text.contains("example.test"), "图片 URL 不能当名称")
  }

  func testImageOnlyFallsBackToAuthorAndDate() {
    let body = """
    ---
    cover_image: "https://example.test/a.jpg"
    ---

    ![](https://example.test/a.jpg)
    """
    let withAuthor = CapturedContentNaming.name(
      title: nil,
      body: body,
      host: "douyin.com",
      author: "阿强",
      published: "2026-03-15T10:00:00Z"
    )
    XCTAssertEqual(withAuthor.origin, .fallback)
    XCTAssertEqual(withAuthor.text, "阿强 · 内容 · 2026-03-15")

    let platformOnly = CapturedContentNaming.name(
      title: CapturedDocumentTitle.missing,
      body: "![](https://example.test/a.jpg)",
      host: "www.douyin.com",
      author: nil,
      published: "2026年3月15日 10:00"
    )
    XCTAssertEqual(platformOnly.origin, .fallback)
    XCTAssertEqual(platformOnly.text, "抖音 · 内容 · 2026年3月15日")

    let noDate = CapturedContentNaming.name(
      title: nil,
      body: "![](https://example.test/a.jpg)",
      host: "xiaohongshu.com",
      author: "小红",
      published: nil
    )
    XCTAssertEqual(noDate.origin, .fallback)
    XCTAssertEqual(noDate.text, "小红 · 内容")
    XCTAssertFalse(noDate.text.contains("视频"), "不凭媒体猜测视频")
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: noDate, body: body))
  }

  func testHidesRepeatedHeadingOnlyWhenCaptionEqualsWholeBody() {
    let caption = CapturedContentNaming.Name(text: "今天去海边了", origin: .caption)
    XCTAssertTrue(CapturedContentNaming.hidesRepeatedHeading(name: caption, body: "今天去海边了"))
    XCTAssertTrue(
      CapturedContentNaming.hidesRepeatedHeading(
        name: caption,
        body: "# 今天去海边了\n\n今天去海边了\n\n![](https://example.test/a.jpg)"
      )
    )
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: caption, body: ""))
    XCTAssertFalse(
      CapturedContentNaming.hidesRepeatedHeading(
        name: CapturedContentNaming.Name(text: "独立标题", origin: .sourceTitle),
        body: "独立标题"
      )
    )
    XCTAssertFalse(
      CapturedContentNaming.hidesRepeatedHeading(
        name: CapturedContentNaming.Name(text: "阿强 · 内容", origin: .fallback),
        body: "阿强 · 内容"
      )
    )
    XCTAssertFalse(
      CapturedContentNaming.hidesRepeatedHeading(
        name: CapturedContentNaming.Name(text: "第一句。", origin: .caption),
        body: "第一句。第二句还在。"
      )
    )
  }

  func testHashtagLineIsNotTreatedAsHeading() {
    let name = CapturedContentNaming.name(
      title: nil,
      body: "#家居\n\n今天的新发现。下一句不要。",
      host: "douyin.com",
      author: nil,
      published: nil
    )
    XCTAssertEqual(name.origin, .caption)
    XCTAssertEqual(name.text, "今天的新发现。")
  }
}
