import XCTest
import LinkDigestCore

/// 设置页的跨页排版约定：**一个设置项 = 一个 Section = 一张卡片**，说明跟着控件走。
///
/// 改这套之前，设置项普遍写成「Section header + 控件行 + 卡片外的长 footer」，
/// 全部设置页加起来 17 处。两个后果：说明离它控制的控件隔着一整块间距，读的时候
/// 对不上号；footer 一律展开，四五行密字把页面撑满，控件密度极低。
///
/// 这类退化不报错、不崩溃——加一个设置项时顺手写个 footer 是最省事的写法，
/// 所以必须由测试守住，否则页面会慢慢变回原样。
final class SettingsLayoutConventionTests: XCTestCase {
  private static let pages = [
    "ProviderSettingsView",
    "MediaStorageSettingsView",
    "BrowserSupportSettingsView",
    "SiteLoginSettingsView",
  ]

  /// `ProviderSettingsView` 的模型编辑子流程里仍有三处 footer，装的是**动态状态**
  /// （服务商文档提示、模型目录状态、测试连接结果），不是静态说明——状态紧贴控件
  /// 本来就合理，所以按页给出允许上限而不是一刀切归零。
  private static let allowedFooters = [
    "ProviderSettingsView": 3,
    "MediaStorageSettingsView": 0,
    "BrowserSupportSettingsView": 0,
    "SiteLoginSettingsView": 0,
  ]

  private func source(_ name: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(name).swift"),
      encoding: .utf8)
  }

  private func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var index = text.startIndex
    while let range = text.range(of: needle, range: index..<text.endIndex) {
      count += 1
      index = range.upperBound
    }
    return count
  }

  func testSettingsPagesDoNotGrowNewFooterExplanations() throws {
    for page in Self.pages {
      let text = try source(page)
      let footers = occurrences(of: "} footer: {", in: text)
      let allowed = Self.allowedFooters[page] ?? 0
      XCTAssertLessThanOrEqual(
        footers, allowed,
        "\(page) 的 footer 从 \(allowed) 涨到了 \(footers)。静态说明要放进 SettingsCard，"
          + "只有跟着状态变的提示才留在 footer")
    }
  }

  /// 卡片构件必须是同一份。三处各写一份必然漂移，而漂移不报错。
  func testAllSettingsPagesUseTheSharedCard() throws {
    for page in Self.pages where page != "SiteLoginSettingsView" {
      let text = try source(page)
      XCTAssertTrue(
        text.contains("SettingsCard(") || text.contains("settingCard("),
        "\(page) 没有使用共享的设置卡片构件")
    }
    let shared = try source("SettingsCard")
    XCTAssertTrue(shared.contains("struct SettingsCard"))
    XCTAssertTrue(
      shared.contains("DisclosureGroup(\"了解更多\")"),
      "详细说明默认收起是这套约定的一半，删掉它 footer 就会以另一种形式回来")
  }

  /// 控件自带逐项解释时，卡片说明必须前置，否则读成倒的。
  ///
  /// 一组单选里每项下面都有一句话；说明再放控件后面，读者会先读到某一项的解释，
  /// 才读到整张卡在讲什么。
  func testChoiceCardsPlaceSummaryAboveTheOptions() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertEqual(
      occurrences(of: "summaryPlacement: .aboveControl", in: media), 2,
      "「历史在线播放」和「B 站清晰度」两张卡的控件都自带逐项解释，说明必须前置")

    let shared = try source("SettingsCard")
    XCTAssertTrue(
      shared.contains("case aboveControl"),
      "卡片必须支持说明前置，否则这类卡只能各自绕开构件重写一遍")
  }

  /// 单选要能在选之前比较，选择钮要贴着文字。
  func testChoiceListsShowEveryOptionsExplanation() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertTrue(
      media.contains("SettingsChoiceList("),
      "inline Picker 会把单选钮甩到行最右端，且只显示选中项的解释")
    XCTAssertFalse(
      media.contains(".pickerStyle(.inline)"),
      "inline Picker 的写法回来了，就又要点一次才能看到另一项在说什么")

    let shared = try source("SettingsCard")
    XCTAssertTrue(shared.contains("struct SettingsChoiceList"))
    XCTAssertTrue(
      shared.contains("Text(choice.explanation)"),
      "每一项都要带自己的解释，不能只显示选中的那条")
  }

  /// 控件不能横跨整个详情区。
  ///
  /// Form 行会撑满整行，于是 Toggle 的开关、LabeledContent 的值、Picker 的下拉
  /// 全被推到最右端，和自己的标题隔着大半个窗口，看的时候要来回扫。卡片默认给
  /// 控件设上限宽度；`full` 只留给本来就需要整行的控件。
  func testCardsCapControlWidthByDefault() throws {
    let shared = try source("SettingsCard")
    XCTAssertTrue(
      shared.contains("var controlWidth: SettingsControlWidth = .compact"),
      "默认必须是收窄的；默认放开等于这个问题没修")
    XCTAssertTrue(
      shared.contains("frame(maxWidth: controlWidth.maximum, alignment: .leading)"),
      "上限宽度要真的作用到控件上")
    XCTAssertTrue(
      shared.contains("case .compact: 440"),
      "收窄档要有具体数值，不能是 .infinity 换个名字")
  }

  /// 单选各项的解释必须写清「你要多做什么」和「代价落在哪」，不能只堆形容词。
  ///
  /// 原来写的是「更省流量，也更可预期」，用户看完的反馈是「主要是没清楚两个
  /// 功能的区别」——那是文案没写好，不是他没读。形容词不构成可比较的信息。
  func testRestoreModeExplanationsStateBehaviourAndCost() throws {
    let automatic = SessionMediaRestoreMode.automatic.settingsExplanation
    let manual = SessionMediaRestoreMode.manual.settingsExplanation

    // 自动：说清代价按「每打开一条」计，并点名最重的那个平台。
    XCTAssertTrue(automatic.contains("每打开一条"), "自动的代价要写成可计量的频次")
    XCTAssertTrue(automatic.contains("抖音"), "平台间开销差很多，最重的那个要点名")

    // 手动：说清多做的那个动作，以及不发请求的范围。
    XCTAssertTrue(manual.contains("重新获取播放"), "手动要写明多点的是哪个按钮")
    XCTAssertTrue(manual.contains("路过的不发"), "要写明什么情况下不发请求")

    for text in [automatic, manual] {
      XCTAssertFalse(
        text.contains("更省流量") || text.contains("更可预期"),
        "形容词不构成可比较的信息")
    }
  }

  /// 跨页依赖要给出去处，而不是只说一句「依赖某某」。
  func testCrossPageDependencyPointsSomewhere() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertTrue(
      media.contains("SettingsCrossReference("),
      "B 站清晰度依赖站点登录，必须指明去哪一页")
    XCTAssertTrue(media.contains("站点登录 → B 站"))
  }
}
