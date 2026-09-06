import XCTest
@testable import LinkDigestCore

/// 长文重排：什么值得重排，以及提示词的契约。
///
/// 提示词是**代码里的固定契约**，不是用户模板——重排一旦变成重写，用户拿到的
/// 就不再是他抓的那篇文章了，而这件事无法从产出上一眼看出来。所以约束写在代码
/// 里，并且由测试钉住。
final class ArticleReformatTests: XCTestCase {
  private func shape(_ characters: Int, headings: Int) -> ContentShape {
    ContentShape(
      characterCount: characters, headingCount: headings,
      imageCount: 0, imageRunCount: 0, hasCode: false, hasTable: false
    )
  }

  // MARK: 值不值得重排

  func testLongAndStructurelessProseIsEligible() {
    XCTAssertEqual(
      ArticleReformatEligibility.evaluate(shape: shape(5_000, headings: 0), allowsOutline: true),
      .eligible
    )
  }

  /// 已经分好节的文章重排一遍只是把钱烧掉。阈值取自实测：这台机器上 76% 的条目
  /// 不满足「≥2000 字且标题少于 3 个」，本来就不该走这条路。
  func testAlreadyStructuredIsRejected() {
    XCTAssertEqual(
      ArticleReformatEligibility.evaluate(shape: shape(9_000, headings: 8), allowsOutline: true),
      .alreadyStructured
    )
  }

  func testShortProseIsRejected() {
    XCTAssertEqual(
      ArticleReformatEligibility.evaluate(shape: shape(400, headings: 0), allowsOutline: true),
      .tooShort
    )
  }

  /// 转写稿和图集：前者已有时间锚点，后者根本没有可分节的正文。
  /// 判据直接复用排版档案的 `allowsOutline`，不另起一套。
  func testNonProseIsRejectedEvenWhenLong() {
    XCTAssertEqual(
      ArticleReformatEligibility.evaluate(shape: shape(20_000, headings: 0), allowsOutline: false),
      .notProse
    )
  }

  func testOnlyEligibleCanReformat() {
    XCTAssertTrue(ArticleReformatEligibility.eligible.canReformat)
    for rejected in [ArticleReformatEligibility.alreadyStructured, .tooShort, .notProse] {
      XCTAssertFalse(rejected.canReformat)
      XCTAssertNotNil(rejected.userMessage, "被拒绝时必须能说出理由")
    }
  }

  // MARK: 提示词契约

  func testArticleStyleUsesItsOwnPrompt() {
    XCTAssertEqual(TidyStyle.article.systemPrompt, TranscriptTidyPrompt.article)
    XCTAssertNotEqual(TidyStyle.article.systemPrompt, TidyStyle.transcript.systemPrompt)
    XCTAssertNotEqual(TidyStyle.article.systemPrompt, TidyStyle.note.systemPrompt)
  }

  /// 这一条是整个功能的安全底线：重排不得改动正文。
  func testArticlePromptForbidsRewriting() {
    let prompt = TranscriptTidyPrompt.article
    for forbidden in ["改动正文的任何一个字", "增删内容", "调整段落顺序", "翻译", "概括"] {
      XCTAssertTrue(prompt.contains(forbidden), "提示词必须明确禁止：\(forbidden)")
    }
    XCTAssertTrue(prompt.contains("##"), "必须指明用 Markdown 小标题")
  }

  /// 转写稿的提示词照样不许改写——顺带守住既有契约，免得改这一处碰坏那一处。
  func testTranscriptPromptStillForbidsRewriting() {
    XCTAssertTrue(TranscriptTidyPrompt.system.contains("严格禁止"))
    XCTAssertTrue(TranscriptTidyPrompt.note.contains("严格禁止"))
  }

  func testEveryStyleHasANonEmptyPrompt() {
    for style in TidyStyle.allCases {
      XCTAssertFalse(style.systemPrompt.isEmpty, "\(style.rawValue) 没有提示词")
    }
  }
}

/// 分片对提示词的影响。
///
/// 长稿会切片，每片是一次独立请求，模型看不到全篇。指令若按「全篇」写，模型对
/// 每一片都会各自判断「这篇要不要标题」——实测一份 6214 字的稿子切两片，
/// 第一片一个标题都没插，四个标题全挤在第二片。
final class ChunkAwarePromptTests: XCTestCase {
  func testTranscriptPromptScopesHeadingCountToTheChunk() {
    let prompt = TranscriptTidyPrompt.system
    XCTAssertFalse(prompt.contains("全篇 3 到 10 个"), "按全篇说的数量指令对分片无效")
    XCTAssertTrue(prompt.contains("无论长短都要插标题"))
    XCTAssertTrue(
      prompt.contains("你不插就等于那一截永远没有标题"),
      "必须点破「这只是一截」这个误解，否则模型会跳过"
    )
  }

  /// 「保持片段边界原样」这句话容易被读成「所以不要加结构」，必须当场纠正。
  func testChunkBoundaryNoticeDoesNotSuppressHeadings() {
    let prompt = TranscriptTidyPrompt.system
    let range = try? XCTUnwrap(prompt.range(of: "保持片段边界原样"))
    XCTAssertNotNil(range)
    if let range {
      let tail = prompt[range.upperBound...]
      XCTAssertTrue(tail.contains("照样要给它插标题"), "片段说明之后必须紧跟一句纠正")
    }
  }

  /// 长文重排走的是另一份提示词，同样按「这一段文字」说，不按全篇。
  func testArticlePromptAlsoScopesToTheChunk() {
    XCTAssertTrue(TranscriptTidyPrompt.article.contains("输入是同一篇文章的一个连续片段"))
  }
}
