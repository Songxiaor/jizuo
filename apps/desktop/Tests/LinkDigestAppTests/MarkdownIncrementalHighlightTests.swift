import AppKit
import XCTest
@testable import LinkDigestApp

/// 增量着色。
///
/// 编辑器以前每敲一个字就把整篇重着色一遍：13 条正则全文跑、双链全文扫、
/// 整个文本存储 setAttributes。几万字的笔记上这件事跟不上手速。
///
/// 改成「只重算改动那几行」之后，唯一的风险是**结果不一样**——少上一层色、
/// 多留一条旧属性，用户看到的就是花屏。所以这里不断言具体颜色，而是钉住
/// 「局部重算 == 全文重算」这条等价关系，并用随机编辑去撞它。
@MainActor
final class MarkdownIncrementalHighlightTests: XCTestCase {
  private let base = NSFont.systemFont(ofSize: 16)
  private let palette = MarkdownSyntaxHighlighter.Palette(
    primary: .black, secondary: .gray, accent: .blue, code: .darkGray
  )
  private let lineSpacing: CGFloat = 6

  private func fullyHighlighted(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    MarkdownSyntaxHighlighter.apply(
      to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing
    )
    return storage
  }

  /// 逐字符比较两份着色结果；相同返回 nil，不同返回第一处差异的说明。
  private func firstDifference(_ lhs: NSTextStorage, _ rhs: NSTextStorage) -> String? {
    guard lhs.string == rhs.string else { return "文字本身不同" }
    let keys: [NSAttributedString.Key] = [
      .font, .foregroundColor, .paragraphStyle, .strikethroughStyle, .strikethroughColor,
      .underlineStyle, .underlineColor, .link,
    ]
    for index in 0..<lhs.length {
      for key in keys {
        let left = lhs.attribute(key, at: index, effectiveRange: nil)
        let right = rhs.attribute(key, at: index, effectiveRange: nil)
        if Self.attributesLookTheSame(left, right) { continue }
        do {
          let context = (lhs.string as NSString).substring(
            with: NSRange(location: max(0, index - 12), length: min(24, lhs.length - max(0, index - 12)))
          )
          return """
            第 \(index) 个字符的 \(key.rawValue) 不一致（增量 \(String(describing: left)) \
            / 全文 \(String(describing: right))），附近文字：\(context.debugDescription)
            """
        }
      }
    }
    return nil
  }

  /// NSTextStorage 会为中文替字体，替出来的 NSFont 每次都是新对象，`isEqual`
  /// 认不出它们是同一款。这里按「看得见的那几项」比：字体名、字号、字形。
  private static func attributesLookTheSame(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if let left = lhs as? NSFont, let right = rhs as? NSFont {
      return left.fontName == right.fontName
        && left.pointSize == right.pointSize
        && left.fontDescriptor.symbolicTraits == right.fontDescriptor.symbolicTraits
    }
    switch (lhs.map { $0 as AnyObject }, rhs.map { $0 as AnyObject }) {
    case (nil, nil): return true
    case let (left?, right?): return left.isEqual(right)
    default: return false
    }
  }

  // MARK: - 夹具

  private static let fixture = #"""
    # 汲作笔记

    这是一段正文，带 **粗体**、*斜体* 和 `行内代码`。

    ## 二级标题

    - 列表一
    - 列表二
    - [ ] 还没做的
    - [x] 已经做完的

    > 引用一行，退到背景里去

    参考 [[知识库构建]] 与 [[写作流程]] 两条笔记。

    ```swift
    let answer = 42
    // 代码块里的 # 不是标题，- 也不是列表
    print("[[这也不是双链]]")
    ```

    ---

    最后一段带 ~~删除线~~ 和 [一个链接](https://example.test/a)。
    """#

  /// 随机编辑用的字符表。刻意混进结构字符，好让随机编辑真的能造出/毁掉结构。
  private static let alphabet: [String] = [
    "a", "字", " ", "\n", "#", "*", "-", ">", "[", "]", "~", "`", "1", ".",
  ]

  /// 固定种子的伪随机源：失败时能原样重放。
  private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  // MARK: - 等价性

  /// 每个种子 200 次随机单字符增删，每次都比对「只重算受影响范围」与「整篇重算」。
  ///
  /// 多跑几个种子是因为真正的坑都在边界上：回车把一行劈成两半、反引号凑出
  /// 半个围栏、双链被切断。单条序列很容易正好绕开它们。
  func testIncrementalHighlightMatchesFullRehighlightUnderRandomEdits() {
    for seed in [0x5EED_C0FF_EE12_3456, 0x0BAD_F00D_1234_5678, 0x1357_9BDF_2468_ACE0,
                 0xDEAD_BEEF_CAFE_0001] as [UInt64] {
      runRandomEditComparison(seed: seed)
      if testRun?.failureCount ?? 0 > 0 { return }
    }
  }

  private func runRandomEditComparison(seed: UInt64) {
    var random = Seeded(state: seed)
    let storage = fullyHighlighted(Self.fixture)
    var fenceMarkerCount = MarkdownSyntaxHighlighter
      .fenceMarkerLocations(in: storage.string as NSString).count
    var incrementalPasses = 0

    for step in 0..<200 {
      let text = storage.string as NSString
      let insert = text.length < 40 || Int.random(in: 0..<10, using: &random) < 6
      let editedRange: NSRange
      if insert {
        let location = Int.random(in: 0...text.length, using: &random)
        let piece = Self.alphabet[Int.random(in: 0..<Self.alphabet.count, using: &random)]
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: piece)
        editedRange = NSRange(location: location, length: (piece as NSString).length)
      } else {
        let location = Int.random(in: 0..<text.length, using: &random)
        storage.replaceCharacters(in: NSRange(location: location, length: 1), with: "")
        editedRange = NSRange(location: location, length: 0)
      }

      let scope = MarkdownSyntaxHighlighter.scope(
        in: storage.string as NSString,
        editedRange: editedRange,
        previousFenceMarkerCount: fenceMarkerCount
      )
      fenceMarkerCount = scope.fenceMarkerCount
      if let range = scope.range {
        incrementalPasses += 1
        MarkdownSyntaxHighlighter.apply(
          to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing, in: range
        )
      } else {
        MarkdownSyntaxHighlighter.apply(
          to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing
        )
      }

      let reference = fullyHighlighted(storage.string)
      if let difference = firstDifference(storage, reference) {
        XCTFail(
          "种子 \(seed) 第 \(step) 次编辑后局部重算与全文重算不一致：\(difference)"
            + "（改动范围 \(editedRange)，重算范围 \(String(describing: scope.range))）"
        )
        return
      }
    }

    // 全都退回全文重算的话，上面那条等价断言就成了同义反复。
    XCTAssertGreaterThan(
      incrementalPasses, 120,
      "种子 \(seed)：200 次编辑里只有 \(incrementalPasses) 次走到局部重算，增量路径几乎没被测到"
    )
  }

  /// 在围栏代码块里打字：整块要一起重算，不能只刷那一行。
  func testEditInsideFencedBlockRecomputesTheWholeBlock() throws {
    let source = "正文\n\n```\nlet a = 1\nlet b = 2\n```\n\n结尾"
    let text = source as NSString
    let inside = text.range(of: "let b")
    let scope = MarkdownSyntaxHighlighter.scope(
      in: text,
      editedRange: NSRange(location: inside.location, length: 1),
      previousFenceMarkerCount: 2
    )
    let range = try XCTUnwrap(scope.range, "块内编辑应当能走局部重算")
    let fenceStart = text.range(of: "```").location
    XCTAssertLessThanOrEqual(range.location, fenceStart, "重算范围要向前吃到开围栏")
    XCTAssertGreaterThanOrEqual(
      NSMaxRange(range), NSMaxRange(text.range(of: "```", options: .backwards)),
      "重算范围要向后吃到闭围栏"
    )
  }

  /// 插入一行 ``` 会把后面所有代码块的起止对调，这时局部重算无解，只能全文。
  func testInsertingAFenceLineFallsBackToFullRehighlight() {
    let source = "前言\n```\n开头\n```\n中间\n```\n结尾\n```\n"
    let withExtra = "```\n" + source
    let scope = MarkdownSyntaxHighlighter.scope(
      in: withExtra as NSString,
      editedRange: NSRange(location: 0, length: 4),
      previousFenceMarkerCount: 4
    )
    XCTAssertNil(scope.range, "围栏条数变了必须退回全文重算")
    XCTAssertEqual(scope.fenceMarkerCount, 5)
  }

  /// 落单的 ``` 还没配上对，碰它就说明配对随时会变。
  func testEditingAnUnpairedFenceFallsBackToFullRehighlight() {
    let source = "正文\n```\n还没闭合"
    let scope = MarkdownSyntaxHighlighter.scope(
      in: source as NSString,
      editedRange: NSRange(location: (("正文\n```" as NSString).length), length: 0),
      previousFenceMarkerCount: 1
    )
    XCTAssertNil(scope.range)
  }

  // MARK: - 行内规则不再跨行

  /// `^(#{1,6})\s+(.+)$` 里的 `\s` 会吃掉换行：单独一行的 `#` 把**下一行**
  /// 画成了标题。既是显示上的错，也让「只重算这一行」不成立。
  func testLoneHashDoesNotTurnTheNextLineIntoAHeading() {
    let storage = fullyHighlighted("#\n普通正文")
    let bodyIndex = (storage.string as NSString).range(of: "普通正文").location
    let bodyFont = storage.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont
    XCTAssertEqual(bodyFont?.pointSize, base.pointSize, "下一行不该因为上一行有个 # 就变成标题")
  }

  /// 同理：`> ` 后面跟空行时，引用色不该一路蔓延到下一段。
  func testEmptyQuoteLineDoesNotTintTheFollowingParagraph() {
    let storage = fullyHighlighted("> \n\n另起一段")
    let index = (storage.string as NSString).range(of: "另起一段").location
    let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    XCTAssertEqual(color, palette.primary, "下一段不该被上面那行空引用染成次要色")
  }

  // MARK: - ⌘B / ⌘I 的最小编辑

  /// `wrapEdit` 只替换一小段，`toggleWrap` 生成整篇新文本，两者结果必须一致。
  func testWrapEditProducesTheSameDocumentAsToggleWrap() {
    let cases: [(String, String, String)] = [
      ("普通 选中 文字", "选中", "**"),
      ("已经 **选中** 了", "**选中**", "**"),
      ("外面 **选中** 了", "选中", "**"),
      ("斜体 *这段* 文字", "这段", "*"),
      ("空选区", "", "**"),
    ]
    for (text, needle, marker) in cases {
      let range = needle.isEmpty
        ? (text.startIndex..<text.startIndex)
        : text.range(of: needle)!
      let expected = MarkdownListEditing.toggleWrap(text, selection: range, marker: marker)
      let edit = MarkdownListEditing.wrapEdit(text, selection: range, marker: marker)
      var actual = text
      actual.replaceSubrange(edit.range, with: edit.replacement)
      XCTAssertEqual(actual, expected.text, "wrapEdit 与 toggleWrap 在「\(text)」上结果不同")

      let editStartUTF16 = text.utf16.distance(from: text.utf16.startIndex, to: edit.range.lowerBound)
      let selectionStart = editStartUTF16 + edit.selectionOffsetUTF16
      let expectedStart = expected.text.utf16.distance(
        from: expected.text.utf16.startIndex, to: expected.selection.lowerBound
      )
      let expectedLength = expected.text.utf16.distance(
        from: expected.selection.lowerBound, to: expected.selection.upperBound
      )
      XCTAssertEqual(selectionStart, expectedStart, "选区起点不同：\(text)")
      XCTAssertEqual(edit.selectionLengthUTF16, expectedLength, "选区长度不同：\(text)")
    }
  }

  /// ⌘B 只动选区那一小段，前后文一个字都不该进入这次替换。
  func testWrapEditTouchesOnlyTheSelection() {
    let text = "很长的前文" + String(repeating: "字", count: 500) + "选中" + String(repeating: "尾", count: 500)
    let range = text.range(of: "选中")!
    let edit = MarkdownListEditing.wrapEdit(text, selection: range, marker: "**")
    XCTAssertEqual(edit.replacement, "**选中**")
    XCTAssertEqual(text.distance(from: edit.range.lowerBound, to: edit.range.upperBound), 2)
  }

  // MARK: - 性能守卫

  /// 5 万字文档连续 100 次单字符插入。
  ///
  /// 这条不是为了追一个漂亮数字，而是为了在「又有人把全文重算加回热路径」时
  /// 立刻红掉。阈值放在 Debug 下 1 秒，比实测留了很大余量。
  func testLargeDocumentStaysResponsiveWhileTyping() {
    let paragraph = """
      这是一段用来撑长度的正文，里面有 **粗体**、`行内代码` 和 [[双链]]。
      - 列表项，后面跟一句话，让每一行都有结构可以匹配。
      > 一行引用。

      """
    var source = "# 长文档\n\n"
    while source.count < 50_000 { source += paragraph }
    source += "\n```swift\nlet a = 1\n```\n"
    XCTAssertGreaterThan(source.count, 50_000)

    let storage = NSTextStorage(string: source)
    let fullStart = CFAbsoluteTimeGetCurrent()
    MarkdownSyntaxHighlighter.apply(
      to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing
    )
    let fullPass = CFAbsoluteTimeGetCurrent() - fullStart
    var fenceMarkerCount = MarkdownSyntaxHighlighter
      .fenceMarkerLocations(in: storage.string as NSString).count

    var caret = storage.length / 2
    var fallbacks = 0
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<100 {
      storage.replaceCharacters(in: NSRange(location: caret, length: 0), with: "好")
      let scope = MarkdownSyntaxHighlighter.scope(
        in: storage.string as NSString,
        editedRange: NSRange(location: caret, length: 1),
        previousFenceMarkerCount: fenceMarkerCount
      )
      fenceMarkerCount = scope.fenceMarkerCount
      if let range = scope.range {
        MarkdownSyntaxHighlighter.apply(
          to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing, in: range
        )
      } else {
        fallbacks += 1
        MarkdownSyntaxHighlighter.apply(
          to: storage, baseFont: base, palette: palette, lineSpacing: lineSpacing
        )
      }
      caret += 1
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print(
      "[perf] 5 万字：单次全文重算 \(String(format: "%.1f", fullPass * 1000))ms；"
        + "100 次单字符插入合计 \(String(format: "%.1f", elapsed * 1000))ms；"
        + "退回全文 \(fallbacks) 次"
    )
    XCTAssertEqual(fallbacks, 0, "普通打字不该退回全文重算")
    XCTAssertLessThan(elapsed, 1.0, "5 万字下 100 次按键用了 \(elapsed) 秒，打字已经跟不上手")
  }
}
