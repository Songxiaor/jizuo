import XCTest
@testable import LinkDigestApp

/// 写列表时的按键行为。
///
/// 断言钉的是「用户敲回车时期望发生什么」，不是实现细节。
final class MarkdownListEditingTests: XCTestCase {
  func testContinuesAnUnorderedList() {
    let result = MarkdownListEditing.continuation(forLine: "- 第一条")
    XCTAssertEqual(result, .init(deletingPrefixLength: 0, insert: "\n- "))
  }

  func testOrderedListNumbersIncrement() {
    XCTAssertEqual(
      MarkdownListEditing.continuation(forLine: "1. 第一条"),
      .init(deletingPrefixLength: 0, insert: "\n2. ")
    )
    // 从 9 到 10 是最容易写错的一处。
    XCTAssertEqual(
      MarkdownListEditing.continuation(forLine: "9. 第九条"),
      .init(deletingPrefixLength: 0, insert: "\n10. ")
    )
  }

  func testIndentationIsCarriedToTheNextItem() {
    XCTAssertEqual(
      MarkdownListEditing.continuation(forLine: "    - 缩进项"),
      .init(deletingPrefixLength: 0, insert: "\n    - ")
    )
  }

  /// 空列表项上回车是「我列完了」，不是「再来一项」。
  func testEmptyItemExitsTheListInsteadOfAddingAnother() {
    let result = MarkdownListEditing.continuation(forLine: "- ")
    XCTAssertEqual(result, .init(deletingPrefixLength: 2, insert: ""))
    // 缩进的空项要连缩进一起删掉。
    XCTAssertEqual(
      MarkdownListEditing.continuation(forLine: "  1. "),
      .init(deletingPrefixLength: 5, insert: "")
    )
  }

  /// 任务列表续出来的是未勾选的新项——刚敲完回车的那一项当然还没做完。
  func testCheckedTaskContinuesAsUnchecked() {
    XCTAssertEqual(
      MarkdownListEditing.continuation(forLine: "- [x] 已完成"),
      .init(deletingPrefixLength: 0, insert: "\n- [ ] ")
    )
  }

  func testPlainLineIsNotAList() {
    XCTAssertNil(MarkdownListEditing.continuation(forLine: "普通一段话"))
    XCTAssertNil(MarkdownListEditing.continuation(forLine: ""))
    // 标题不是列表，不该被续。
    XCTAssertNil(MarkdownListEditing.continuation(forLine: "# 标题"))
    // 减号后面没有空格是正文，不是列表项。
    XCTAssertNil(MarkdownListEditing.continuation(forLine: "-没有空格"))
  }

  /// 一个键管三种状态：写清单时这三步本来就是连着发生的。
  func testTaskTogglesThroughThreeStates() {
    let plain = "买牛奶"
    let todo = MarkdownListEditing.toggledTask(plain)
    XCTAssertEqual(todo, "- [ ] 买牛奶")
    let done = MarkdownListEditing.toggledTask(todo)
    XCTAssertEqual(done, "- [x] 买牛奶")
    // 再按一次退回普通列表项，而不是变回没有符号的纯文字——已经在清单里了。
    XCTAssertEqual(MarkdownListEditing.toggledTask(done), "- 买牛奶")
  }

  func testTogglingKeepsIndentAndBulletSymbol() {
    XCTAssertEqual(MarkdownListEditing.toggledTask("  * 缩进项"), "  * [ ] 缩进项")
    XCTAssertEqual(MarkdownListEditing.toggledTask("  * [ ] 缩进项"), "  * [x] 缩进项")
    XCTAssertEqual(MarkdownListEditing.toggledTask("\t+ 制表符"), "\t+ [ ] 制表符")
  }

  /// 空行上按也要能用：先给出一个空待办，接着直接打字。
  func testTogglingAnEmptyLineStartsATask() {
    XCTAssertEqual(MarkdownListEditing.toggledTask(""), "- [ ] ")
    XCTAssertEqual(MarkdownListEditing.toggledTask("   "), "   - [ ] ")
  }

  func testWrapAddsMarkersAroundTheSelection() {
    let text = "把这段加粗"
    let range = text.range(of: "这段")!
    let (result, selection) = MarkdownListEditing.toggleWrap(text, selection: range, marker: "**")
    XCTAssertEqual(result, "把**这段**加粗")
    // 选区仍框着原来那两个字，可以接着敲。
    XCTAssertEqual(String(result[selection]), "这段")
  }

  /// ⌘B 是个开关：再按一次要把记号取消，而不是套成四个星号。
  func testWrapTogglesOffWhenAlreadyWrapped() {
    let text = "把**这段**取消"
    let inner = text.range(of: "这段")!
    let (result, selection) = MarkdownListEditing.toggleWrap(text, selection: inner, marker: "**")
    XCTAssertEqual(result, "把这段取消")
    XCTAssertEqual(String(result[selection]), "这段")

    // 选中时连记号一起选上的情况同样要能取消。
    let withMarkers = text.range(of: "**这段**")!
    let (result2, _) = MarkdownListEditing.toggleWrap(text, selection: withMarkers, marker: "**")
    XCTAssertEqual(result2, "把这段取消")
  }

  func testWrapWithEmptySelectionInsertsAnEmptyPair() {
    let text = "光标在这里"
    let caret = text.index(text.startIndex, offsetBy: 3)
    let (result, selection) = MarkdownListEditing.toggleWrap(text, selection: caret..<caret, marker: "**")
    XCTAssertEqual(result, "光标在****这里")
    // 光标落在两对记号中间，直接开始打字就是粗体内容。
    XCTAssertEqual(selection.lowerBound, result.index(result.startIndex, offsetBy: 5))
    XCTAssertTrue(selection.isEmpty)
  }
}
