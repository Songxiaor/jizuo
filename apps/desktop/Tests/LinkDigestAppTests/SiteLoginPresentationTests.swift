import XCTest

/// 「站点登录」这页的分组必须如实反映「登录对这个站点起什么作用」。
///
/// 改这页之前它按「已支持 / 手动链接抓取 / 无需登录」分组，两处会误导：
/// - B 站被归进「已支持」，让人以为必须登录。实际上不登录照样抓取和转写，登录只抬高
///   「重新获取播放」的清晰度上限。
/// - 抖音和小红书并列在「手动链接抓取」下，让人以为登录完粘链接就能用。实际上抖音正文
///   由页面脚本渲染，服务端 HTML 里没有内容，即使登录也常常取不到，只能走扩展。
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

  /// B 站不能再被描述成「必须登录」。
  func testBilibiliSectionSaysLoginIsOptional() throws {
    let text = try source()
    XCTAssertFalse(
      text.contains("Text(\"已支持\")"),
      "「已支持」既没说清 B 站要不要登录，也暗示另外两组不受支持")
    XCTAssertTrue(
      text.contains("登录可选"),
      "B 站那组的标题应当说明登录是可选的")
    XCTAssertTrue(
      text.contains("B 站不登录也能抓取和转写"),
      "footer 必须写明不登录也能用，否则读者会以为是前提")
  }

  /// 抖音必须在行内带出限制，而不是只躺在 footer 里。
  func testDouyinRowCarriesItsOwnLimitationNote() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("site-login-\\(id)-note"),
      "行内提示的能力被删了，抖音的限制就只能写在 footer 里，读者看不到")
    XCTAssertTrue(
      text.contains("note: \"抖音正文由页面脚本渲染"),
      "抖音行必须带限制说明——「已登录」会让人以为手动粘链接就能用")
    XCTAssertTrue(
      text.contains("抓抖音请优先用浏览器扩展"),
      "必须给出可执行的替代路径，只说不行等于没说")
  }

  /// 扩展与这一页的会话是两条独立入口，不能让人以为用扩展也要先在这里登录。
  func testFooterSeparatesExtensionPathFromAppOwnedSessions() throws {
    let text = try source()
    XCTAssertTrue(
      text.contains("这一页只管「手动粘贴链接」这条入口"),
      "必须点明这页的适用范围，否则会被当成所有抓取路径的开关")
    XCTAssertTrue(
      text.contains("与这里的会话无关"),
      "扩展走浏览器自己的登录态，这一点要说清")
  }
}
