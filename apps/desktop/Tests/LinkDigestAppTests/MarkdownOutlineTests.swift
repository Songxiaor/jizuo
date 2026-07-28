import XCTest
@testable import LinkDigestApp

final class MarkdownOutlineTests: XCTestCase {
  private func blocks(_ markdown: String) -> [MarkdownPresentation.Block] {
    MarkdownPresentation.blocks(from: markdown)
  }

  func testCollectsHeadingsInDocumentOrderWithTheirLevels() {
    let entries = MarkdownOutline.entries(from: blocks("""
    ## 如何兑换您的礼品

    正文一。

    ## 故障排除

    ### 我看不到兑换电子邮件

    ### 我在尝试兑换时收到错误
    """))

    XCTAssertEqual(entries.map(\.text), [
      "如何兑换您的礼品", "故障排除", "我看不到兑换电子邮件", "我在尝试兑换时收到错误",
    ])
    XCTAssertEqual(entries.map(\.level), [2, 2, 3, 3])
    // 下标必须严格递增，否则跳转会乱序。
    XCTAssertEqual(entries.map(\.blockIndex), entries.map(\.blockIndex).sorted())
  }

  /// 用下标而不是文本定位：同名小节很常见，按文本找会跳错地方。
  func testDuplicateHeadingTextsStayDistinct() {
    let entries = MarkdownOutline.entries(from: blocks("""
    ## 故障排除

    正文。

    ## 故障排除

    正文。
    """))
    XCTAssertEqual(entries.count, 2)
    XCTAssertNotEqual(entries[0].blockIndex, entries[1].blockIndex)
    XCTAssertNotEqual(entries[0].id, entries[1].id)
  }

  func testShortDocumentsDoNotEarnAnOutline() {
    XCTAssertFalse(MarkdownOutline.shouldPresent(MarkdownOutline.entries(from: blocks("""
    ## 只有一个标题

    正文。
    """))))
    XCTAssertFalse(MarkdownOutline.shouldPresent(MarkdownOutline.entries(from: blocks(
      "完全没有标题的一段正文。"
    ))))
  }

  func testThreeOrMoreHeadingsEarnAnOutline() {
    let entries = MarkdownOutline.entries(from: blocks("""
    ## 一

    ## 二

    ## 三
    """))
    XCTAssertEqual(entries.count, 3)
    XCTAssertTrue(MarkdownOutline.shouldPresent(entries))
  }

  /// 缩进按目录自身最浅级归零：抽取侧已把正文重基到 h2 起，
  /// 用绝对 level 算会让整份目录白缩进一格。
  func testIndentIsRelativeToTheShallowestHeadingPresent() {
    let entries = MarkdownOutline.entries(from: blocks("""
    ## 顶级

    ### 次级

    #### 三级
    """))
    XCTAssertEqual(entries.map { MarkdownOutline.indentDepth(of: $0, in: entries) }, [0, 1, 2])

    // 正文本身从 h3 起的文档，同样要从最左侧开始。
    let deep = MarkdownOutline.entries(from: blocks("""
    ### 顶级

    #### 次级
    """))
    XCTAssertEqual(deep.map { MarkdownOutline.indentDepth(of: $0, in: deep) }, [0, 1])
  }

  func testEmptyHeadingsAreDropped() {
    let entries = MarkdownOutline.entries(from: [
      .heading(level: 2, text: "   "),
      .heading(level: 2, text: "真标题"),
    ])
    XCTAssertEqual(entries.map(\.text), ["真标题"])
  }
}

/// 目录接进渲染时的两条约束。
///
/// 这两条都不报错、不崩溃，坏了只是「点了没反应」或「选不动了」，所以钉住。
extension MarkdownOutlineTests {
  private func presentationSource() throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/MarkdownPresentation.swift"),
      encoding: .utf8)
  }

  /// 只在目录真的会出现时才按标题切分文本段。
  ///
  /// 切分的代价是跨章节连续选择会断在标题上。约八成条目够不上目录，那些必须保持
  /// 原有的「相邻文本块合成一个 NSTextView」，一个字都不变。
  func testRunsOnlySplitAtHeadingsWhenAnOutlineWillBeShown() throws {
    let source = try presentationSource()
    XCTAssertTrue(
      source.contains("MarkdownOutline.shouldPresent(MarkdownOutline.entries(from: blocks))"),
      "切分必须由「目录是否出现」决定，无条件切会牺牲八成条目的连续选择")
    XCTAssertTrue(
      source.contains("guard anchorable, case .heading = block else { return false }"),
      "只在标题处切；在别的块切会把段落打散")
  }

  /// 目录入口不能挂在「纯文本」那一行的条件里。
  ///
  /// 第一版就是这么写的，结果按钮从没出现过：真实阅读区两个调用点都传
  /// showsInlinePlainTextToggle: false（纯文本开关在菜单里），那一行永不渲染。
  /// 这类错不报错、不崩溃，只是功能静默消失。
  func testOutlineEntryDoesNotDependOnTheInlinePlainTextToggle() throws {
    let source = try presentationSource()
    XCTAssertTrue(
      source.contains("if showsInlinePlainTextToggle || showsOutlineEntry {"),
      "目录入口要有自己的显示条件，不能被纯文本开关的开关捎带")
    XCTAssertTrue(
      source.contains("if showsOutlineEntry { outlineButton }"),
      "两个控件各自判断，不能共用一个条件")
  }

  /// 目录解析结果要缓存，不能每次 body 求值现算。
  ///
  /// 解析成本随正文长度线性增长，库里最长一条 73432 字，跟着重绘重算会肉眼可见地卡。
  func testOutlineEntriesAreCachedPerSource() throws {
    let source = try presentationSource()
    XCTAssertTrue(
      source.contains("@State private var outlineEntries"),
      "目录结果要存进 state")
    XCTAssertTrue(
      source.contains(".task(id: source) {"),
      "按 source 重算一次，同一条正文内的重绘不再解析")
  }

  /// 弹层里列出的每个模块，详情页都必须真的挂了同名锚点。
  ///
  /// 列出一个点了跳不到的死链接，比不列更糟——用户会以为功能坏了。
  /// 两处分别在两个文件里，最容易漂移。
  func testEveryListedModuleHasAMatchingAnchor() throws {
    let history = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8)

    // 声明侧：navigationModules 里出现的 anchor 名。
    let declared = matches(#"\.init\(anchor: "([a-z]+)""#, in: history)
      + matches(#"anchor: "([a-z]+)","#, in: history)
    // 挂载侧：真正 .id(ReadingAnchor.module("x")) 的名字。
    let mounted = Set(matches(#"ReadingAnchor\.module\("([a-z]+)"\)"#, in: history))

    XCTAssertFalse(mounted.isEmpty, "详情页一个模块锚点都没挂")
    for name in Set(declared) {
      XCTAssertTrue(mounted.contains(name), "模块「\(name)」被列进导航，但详情页没有对应锚点")
    }
  }

  private func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      guard let range = Range($0.range(at: 1), in: text) else { return nil }
      return String(text[range])
    }
  }

  /// 有模块时按钮不能只写「章节」。
  func testButtonTitleReflectsWhatThePopoverActuallyContains() throws {
    let source = try presentationSource()
    XCTAssertTrue(source.contains("private var outlineButtonTitle: String"))
    XCTAssertTrue(source.contains("return \"导航 \\(sections + navigationModules.count)\""))
    XCTAssertTrue(
      source.contains("return \"模块 \\(navigationModules.count)\""),
      "没有章节但有模块时，入口仍要出现")
  }

  /// 滚动条要细、浅灰、无轨道底。
  ///
  /// 系统默认在浅色背景上是深灰，滚动时更深，在纸质主题的米黄画布上又黑又粗。
  /// 只改 scrollerStyle 不够——那只管「是否常驻」，颜色和粗细还是系统的。
  func testScrollersAreSubtleNotSystemDefault() throws {
    let helper = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/SubtleScroller.swift"),
      encoding: .utf8)
    // 不声明这个，AppKit 根本不会把自定义 scroller 用在 overlay 样式上。
    XCTAssertTrue(helper.contains("isCompatibleWithOverlayScrollers"))
    XCTAssertTrue(helper.contains("override func drawKnob()"), "颜色只能靠自绘")
    XCTAssertTrue(
      helper.contains("override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}"),
      "参考标准没有轨道底色")
    // makeNSView 返回时探针还没挂进树，enclosingScrollView 恒为 nil。
    XCTAssertTrue(helper.contains("viewDidMoveToWindow"), "当场设置找不到容器，必须延到挂载之后")

    let history = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8)
    XCTAssertTrue(history.contains(".subtleScrollers()"), "详情区没接")
  }

  /// 跳转靠 ScrollViewReader 驱动外层滚动容器。
  func testOutlineJumpUsesScrollAnchors() throws {
    let source = try presentationSource()
    XCTAssertTrue(source.contains("ScrollViewReader { proxy in"))
    XCTAssertTrue(source.contains("proxy.scrollTo(target, anchor: .top)"))
    XCTAssertTrue(
      source.contains(".id(ReadingAnchor.block(entry.anchor))"),
      "每段要挂锚点，且与模块共用一套锚点类型，否则 Int 与 String 会撞车")
  }
}
