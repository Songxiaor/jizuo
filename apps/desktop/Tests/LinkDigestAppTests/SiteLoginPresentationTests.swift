import XCTest

/// 「站点登录」这页每一行必须如实反映「登录对这个站点起什么作用」。
///
/// 改这页之前它按「已支持 / 手动链接抓取 / 无需登录」分组，两处会误导：
/// - B 站被归进「已支持」，让人以为必须登录。实际上不登录照样抓取和转写，登录只抬高
///   「重新获取播放」的清晰度上限。
/// - 抖音和小红书并列在「手动链接抓取」下，让人以为登录完粘链接就能用。实际上抖音正文
///   由页面脚本渲染，服务端 HTML 里没有内容，即使登录也常常取不到，只能走扩展。
///
/// 三个站点后来又收进了同一张行组卡（一站一行），原来靠分组标题携带的「登录起
/// 什么作用」改由每行自己的 caption 携带——信息没有丢，只是挪了地方，测试也要
/// 跟着看行内 caption，而不是已经不存在的分组标题。
///
/// 这类偏差不报错、不崩溃，只是让人按错误的预期操作，所以用测试钉住。
final class SiteLoginPresentationTests: XCTestCase {
  private func source() throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/SiteLoginSettingsView.swift"),
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

  /// B 站不能再被描述成「必须登录」。
  ///
  /// 「登录是可选的」这件事现在由分组标题独自承担——卡片里已经不写说明了，所以
  /// 标题一旦退回「已支持」那种说法，页面上就再没有第二处能纠正它。
  func testBilibiliSectionSaysLoginIsOptional() throws {
    let text = try source()
    XCTAssertFalse(
      text.contains("Text(\"已支持\")"),
      "「已支持」既没说清 B 站要不要登录，也暗示另外两组不受支持")
    XCTAssertTrue(
      text.contains("登录可选"),
      "B 站那组的标题应当说明登录是可选的")
  }

  /// 抖音必须在自己那一行带出限制，而不是只躺在 footer 或另一份文档里。
  ///
  /// 三站合并进一张行组卡之后，「限制说明」不再是单独的 `note:` 参数，而是
  /// 抖音那一行自己的 caption——断言只钉两件不变的事：这一行确实有自己专属的
  /// caption 标识，以及说明里点名了「建议用扩展」这条可执行的替代路径。
  /// 不钉整句原文——文案本来就还会再改，钉死会把每次润色都变成假失败。
  func testDouyinRowCarriesItsOwnLimitationNote() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("site-login-\\(id)-caption"),
      "行内说明的能力被删了，抖音的限制就没地方带出来，读者看不到")
    XCTAssertTrue(
      text.contains("建议用扩展"),
      "必须给出可执行的替代路径，只说不行等于没说")
  }

  /// 三个站点必须收进同一张行组卡，一站一行，不能各占一张大卡或被拆回
  /// Form 的分割线切成几段。
  ///
  /// 原来每个站点独占一张大卡，内容却稀薄（一行状态 + 一行按钮），三张卡叠起来
  /// 全是空白。改成行组卡之后，三站共用同一个 `siteRow` 构件和同一张
  /// `SettingsThemedCardChrome`——只要退回「各写一份」或「LabeledContent 逐行」，
  /// 页面就会变回一堆稀疏的卡片或者被 Form 分割线切碎。
  func testSitesShareOneRowGroupCardNotSeparateCards() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("private func siteRow("),
      "三个站点必须收进同一个行构件，不能各写一份，否则文案和交互迟早各自漂移")
    XCTAssertEqual(
      occurrences(of: ".modifier(SettingsThemedCardChrome())", in: text), 1,
      "三个站点必须收进同一张自绘卡，不能各自套一层卡面")
    XCTAssertFalse(
      text.contains("LabeledContent("),
      "LabeledContent 会各自成为一个 Form 行，正是被切开的那种写法")
  }

  /// 卡片里不许再长回机制解释。
  ///
  /// 这页曾经每张卡都是「副标题 + 一段正文 + 了解更多」，讲的全是实现机制：登录墙
  /// 长什么样、正文由谁渲染、Cookie 存在哪里。同一件事被分组标题、副标题、正文说
  /// 三遍，而用的人只需要知道「登不登录有什么区别」——分组标题已经答完了。
  ///
  /// 机制解释属于官方文档。这条测试钉住那个边界：说明既不许回到 footer，也不许以
  /// 「了解更多」的形式重新长在卡片里。抖音那条例外走行内 caption，由另一条测试守。
  func testCardsCarryNoMechanismProse() throws {
    let text = try source()
    XCTAssertFalse(
      text.contains("} footer: {"),
      "说明留在 footer 就离对应站点隔了一段距离，读者不会把两者关联起来")
    XCTAssertFalse(
      text.contains("DisclosureGroup"),
      "「了解更多」装的是机制解释，那属于官方文档，不属于设置页")
    // 只钉「副标题文案」这一种 role 参数：`role: .destructive` 是 Button 的角色，
    // 两者同名，写成裸 `role:` 会把清除按钮也一起判成违规。
    XCTAssertFalse(
      text.contains("role: \""),
      "站名下的副标题是分组标题的原话，重复一遍不增加任何信息")
  }

  /// 「我到底登没登」是打开这页最常见的原因，状态必须能一眼扫到。
  func testLoginStateIsVisualNotOnlyText() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("private func statusBadge("),
      "纯文字「已登录 / 未登录」混在一行里读不出差别")
    XCTAssertTrue(
      text.contains("private func siteIcon("),
      "站点图标是这页的主要视觉锚点")
  }

  /// 扩展与这一页的会话是两条独立入口，不能让人以为用扩展也要先在这里登录。
  func testFooterSeparatesExtensionPathFromAppOwnedSessions() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("这一页只管手动粘链接"),
      "必须点明这页的适用范围，否则会被当成所有抓取路径的开关")
    XCTAssertTrue(
      text.contains("用扩展抓不需要在这里登录"),
      "扩展走浏览器自己的登录态，这一点要说清")
  }
}
