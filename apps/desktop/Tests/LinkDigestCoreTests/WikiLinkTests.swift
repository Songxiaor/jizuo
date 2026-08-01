import XCTest
@testable import LinkDigestCore

/// 双链解析。
///
/// 这层是编辑器着色、点击跳转、反向链接三处共用的口径，所以边界要在这里钉死。
final class WikiLinkTests: XCTestCase {
  func testFindsPlainLinks() {
    let text = "参考 [[知识库构建]] 那条。"
    let refs = WikiLink.references(in: text)
    XCTAssertEqual(refs.count, 1)
    XCTAssertEqual(refs.first?.target, "知识库构建")
    XCTAssertEqual(refs.first?.label, "知识库构建")
    // 范围含方括号，着色和替换都要覆盖整段语法。
    XCTAssertEqual(text[refs[0].range], "[[知识库构建]]")
  }

  func testPipeSeparatesTargetFromLabel() {
    let refs = WikiLink.references(in: "见 [[AI 时代的创作|上一条]]")
    XCTAssertEqual(refs.first?.target, "AI 时代的创作")
    XCTAssertEqual(refs.first?.label, "上一条")
  }

  /// 空目标不是链接：`[[]]` 或 `[[|显示]]` 指不到任何东西。
  func testEmptyTargetIsNotALink() {
    XCTAssertTrue(WikiLink.references(in: "[[]]").isEmpty)
    XCTAssertTrue(WikiLink.references(in: "[[   ]]").isEmpty)
    XCTAssertTrue(WikiLink.references(in: "[[|只有显示文字]]").isEmpty)
  }

  /// 显示文字空着就退回用目标，否则正文里会出现一段看不见的链接。
  func testEmptyLabelFallsBackToTarget() {
    XCTAssertEqual(WikiLink.references(in: "[[目标|]]").first?.label, "目标")
  }

  /// 跨行的多半是没写完的半截语法，认成链接会把整段染色。
  func testDoesNotSpanLinesOrNest() {
    XCTAssertTrue(WikiLink.references(in: "[[前半\n后半]]").isEmpty)
    // 半截的外层不该把方括号吞进目标里；内层那对本身是完整的链接，取它是对的。
    XCTAssertEqual(WikiLink.references(in: "[[外层[[内层]]").map(\.target), ["内层"])
    // 单层方括号是 Markdown 链接的写法，不是双链。
    XCTAssertTrue(WikiLink.references(in: "[普通链接](https://example.test)").isEmpty)
  }

  func testFindsSeveralLinksInOrder() {
    let refs = WikiLink.references(in: "[[甲]] 和 [[乙]] 都提到了 [[甲]]")
    XCTAssertEqual(refs.map(\.target), ["甲", "乙", "甲"])
  }

  /// 反向链接和跳转要的是「链向哪些笔记」，重复的同一条只算一次。
  func testTargetsAreDeduplicatedButKeepOrder() {
    XCTAssertEqual(WikiLink.targets(in: "[[乙]] [[甲]] [[乙]]"), ["乙", "甲"])
    // 大小写不同视为同一条，保留第一次出现的写法。
    XCTAssertEqual(WikiLink.targets(in: "[[AI 时代]] [[ai 时代]]"), ["AI 时代"])
  }

  /// 要求人记住当初标题的大小写，等于让链接经常断掉。
  func testTitleMatchingIgnoresCaseAndSurroundingSpace() {
    XCTAssertEqual(WikiLink.normalizedTitle("  AI 时代  "), WikiLink.normalizedTitle("ai 时代"))
    XCTAssertNotEqual(WikiLink.normalizedTitle("甲"), WikiLink.normalizedTitle("乙"))
  }

  func testMarkupWrapsATitle() {
    XCTAssertEqual(WikiLink.markup(for: "知识库"), "[[知识库]]")
  }

  // MARK: - 输入补全

  private func pending(_ text: String, caretAfter marker: String) -> WikiLink.PendingLink? {
    let caret = text.range(of: marker)!.upperBound
    return WikiLink.pendingLink(in: text, caret: caret)
  }

  func testDetectsALinkBeingTyped() {
    let result = pending("先看 [[知识", caretAfter: "知识")
    XCTAssertEqual(result?.query, "知识")
    // `[[` 一敲出来就该能挑，查询为空也算「正在写」。
    XCTAssertEqual(pending("先看 [[", caretAfter: "[[")?.query, "")
  }

  /// 已经写完的链接不该再弹补全，否则光标每次路过旧链接都会冒出候选框。
  func testClosedOrDistantLinkIsNotPending() {
    XCTAssertNil(pending("[[已经写完]] 后面", caretAfter: "后面"))
    XCTAssertNil(pending("完全没有链接", caretAfter: "没有"))
    // 跨行的是没写完的半截语法，不是正在写的链接。
    XCTAssertNil(pending("[[前半\n后半", caretAfter: "后半"))
  }

  /// 光标点回已写好的链接内部时仍算「正在写」——那正是想改目标的时候。
  ///
  /// 只看光标之前的文本是刻意的：后面还有别的链接时，用整段去找会把光标外的
  /// 语法也算进来，导致在第二个链接里打字却按第一个筛候选。
  func testCaretInsideAnExistingLinkStillOffersCompletion() {
    let text = "[[甲]] 和 [[乙]]"
    let caret = text.range(of: "]] 和")!.lowerBound
    XCTAssertEqual(WikiLink.pendingLink(in: text, caret: caret)?.query, "甲")

    // 光标在第二个链接里时，筛的是「乙」而不是「甲」。
    let second = text.range(of: "乙")!.upperBound
    XCTAssertEqual(WikiLink.pendingLink(in: text, caret: second)?.query, "乙")
  }

  func testCompletionsPreferPrefixMatches() {
    let titles = ["构建知识体系", "知识库构建", "无关的一条"]
    XCTAssertEqual(
      WikiLink.completions(for: "知", among: titles),
      ["知识库构建", "构建知识体系"],
      "前缀命中的更可能是想要的那条，要排前面"
    )
    XCTAssertEqual(WikiLink.completions(for: "无关", among: titles), ["无关的一条"])
    XCTAssertTrue(WikiLink.completions(for: "没有这个", among: titles).isEmpty)
  }

  /// 空查询给全部，这样 `[[` 敲完立刻能挑；上限防止候选框长到屏幕外。
  func testEmptyQueryOffersEverythingUpToTheLimit() {
    let titles = (1...20).map { "笔记\($0)" }
    XCTAssertEqual(WikiLink.completions(for: "", among: titles).count, 8)
    XCTAssertEqual(WikiLink.completions(for: "", among: titles, limit: 3), ["笔记1", "笔记2", "笔记3"])
  }

  func testCompletionIgnoresCase() {
    XCTAssertEqual(WikiLink.completions(for: "ai", among: ["AI 时代的创作"]), ["AI 时代的创作"])
  }
}
