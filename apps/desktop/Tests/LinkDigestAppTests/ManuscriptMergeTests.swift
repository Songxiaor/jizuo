import XCTest
@testable import LinkDigestApp

/// 2026-10-14 Syc 定：校对稿和朱批合成一档，只留「朱批 / 机器原稿」两选一；
/// 批注（下划线 + 右边页边的改动）单独一个开关管，默认显示，全局记住。
final class ManuscriptMergeTests: XCTestCase {
  func testModeIsNowOnlyTwoChoices() {
    XCTAssertEqual(TranscriptManuscript.Mode.allCases, [.marked, .original])
    XCTAssertEqual(TranscriptManuscript.Mode.marked.title, "朱批")
    XCTAssertEqual(TranscriptManuscript.Mode.original.title, "机器原稿")
  }

  func testDefaultModeIsMarkedNotMachineDraft() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(
      content.contains("@State private var manuscriptMode: TranscriptManuscript.Mode = .marked"),
      "默认打开要看到朱批（校对稿本体），不是机器原稿"
    )
    XCTAssertTrue(
      content.contains("manuscriptMode = .marked"),
      "换条目要回到朱批，不能把「正在核对原稿」带到下一条"
    )
    XCTAssertFalse(content.contains(".revised"), "校对稿已经并进朱批，代码里不该再有这个档位")
  }

  /// 批注显示与否是「这个人的习惯」，不是某一条内容自己的状态：用 @AppStorage 全局记住，
  /// 不是 @State（那样换一条内容、重开 App 就会丢）。
  func testAnnotationVisibilityIsPersistedGlobally() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(
      content.contains(#"@AppStorage("reading-shows-manuscript-annotations") private var showsManuscriptAnnotations = true"#),
      "批注默认显示，且要用 @AppStorage 全局记住，不能是 @State"
    )
  }

  /// 批注开关只管下划线和右边页边；「改字 N 处」这行统计跟着「朱批」这一档走，
  /// 不随批注显示与否隐藏（Syc 原话：这行统计一直保留）。
  func testSummaryLineIsIndependentOfTheAnnotationToggle() throws {
    let content = try appSource("HistoryContentView.swift")
    let start = try XCTUnwrap(content.range(of: "@ViewBuilder private var manuscriptSwitch: some View {"))
    let end = try XCTUnwrap(content.range(of: "private var manuscriptAnnotationsToggle", range: start.upperBound..<content.endIndex))
    let switchBody = String(content[start.lowerBound..<end.lowerBound])
    // 统计行只认 manuscriptMode，紧跟着的下一行才是批注开关——两件事分开判断，
    // 不能把 showsManuscriptAnnotations 夹进「要不要显示这行统计」的条件里。
    XCTAssertTrue(switchBody.contains("if manuscriptMode == .marked {\n          Text(summary)"))
    XCTAssertFalse(
      switchBody.range(of: #"if manuscriptMode == \.marked[^\n]*showsManuscriptAnnotations"#, options: .regularExpression) != nil,
      "统计这行的显示条件不能夹着 showsManuscriptAnnotations"
    )
    XCTAssertTrue(switchBody.contains("manuscriptAnnotationsToggle"), "朱批档旁边要有批注开关")
  }

  /// 显示时：下划线 + 右边页边；隐藏时：两样都不画，正文恢复整栏宽度（`showsNotes` 为 false
  /// 时 `TranscriptManuscriptView` 既不画下划线也不留出右边页边那一列）。
  func testHidingAnnotationsTurnsOffUnderlinesAndTheMarginColumn() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(
      content.contains("showsNotes: mode == .marked && showsManuscriptAnnotations"),
      "批注开关要真的控制下划线和右边页边，不能只是摆设"
    )
  }

  /// 原来只有「校对稿」那一档能点字编辑；校对稿并进朱批后，批注隐藏时必须能编辑（Syc 明确要求），
  /// 批注显示时——判断：编辑的是同一份校对稿文字，和批注显示与否无关，所以也设成可编辑，
  /// 不用先隐藏批注才能动手改。机器原稿（本机听写原样）不管批注开关状态都不可编辑。
  func testEditingWorksInMarkedRegardlessOfAnnotationVisibility() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(
      content.contains("onTapText: mode == .marked && canEditSource(snapshot) && !model.isReadOnly"),
      "朱批档要能点字编辑，不能只在隐藏批注时才行"
    )
    XCTAssertFalse(content.contains("onTapText: mode == .revised"))
  }

  /// 没有机器原稿可比时（没校对过，或原稿已经不在库里），退回朱批档显示，不是一个已经
  /// 删掉的「校对稿」档位。
  func testFallsBackToMarkedWhenThereIsNoMachineDraftToCompare() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(
      content.contains("let mode = machine == nil ? TranscriptManuscript.Mode.marked : manuscriptMode")
    )
  }

  /// 两选一的切换控件还在、还是表头右边那颗分段控件，没有变成别的样子。
  func testSwitchIsStillATwoWaySegmentedControl() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(content.contains("Picker(\"转写稿版本\", selection: $manuscriptMode)"))
    XCTAssertTrue(content.contains("ForEach(TranscriptManuscript.Mode.allCases)"))
    XCTAssertTrue(content.contains(".pickerStyle(.segmented)"))
    XCTAssertTrue(content.contains("transcript-manuscript-modes"))
  }

  /// 批注开关本身：小按钮、悬停提示跟着状态换文案、有稳定的无障碍标识符方便测试和自动化点击。
  func testAnnotationToggleButtonHasStateDependentHelpText() throws {
    let content = try appSource("HistoryContentView.swift")
    let start = try XCTUnwrap(content.range(of: "private var manuscriptAnnotationsToggle: some View {"))
    let end = try XCTUnwrap(content.range(of: "\n  }\n", range: start.upperBound..<content.endIndex))
    let toggle = String(content[start.lowerBound..<end.lowerBound])
    XCTAssertTrue(toggle.contains("showsManuscriptAnnotations.toggle()"))
    XCTAssertTrue(toggle.contains(#"showsManuscriptAnnotations ? "eye" : "eye.slash""#))
    XCTAssertTrue(toggle.contains(#".help(showsManuscriptAnnotations ? "隐藏批注" : "显示批注")"#))
    XCTAssertTrue(toggle.contains("transcript-manuscript-annotations-toggle"))
  }

  /// 导出不动：导出对话框和导出内容仍按「校对稿 / 机器原稿」两个名字来，`machineVersion` 的判断
  /// 条件也没变（`manuscriptMode == .original`，这个值不受这次合并影响）。
  func testExportLayerNamingIsUntouched() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(content.contains("machineVersion: manuscriptMode == .original"))
    let exportSelection = try appSource("ExportContentSelection.swift")
    XCTAssertTrue(exportSelection.contains("case .proofread: \"校对稿\""))
    XCTAssertTrue(exportSelection.contains("case .machineTranscript: \"机器原稿\""))
  }

  private func appSource(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("Sources/LinkDigestApp/\(name)"), encoding: .utf8)
  }
}
