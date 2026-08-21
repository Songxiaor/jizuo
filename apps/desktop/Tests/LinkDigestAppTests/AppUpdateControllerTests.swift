import Foundation
import XCTest

@testable import LinkDigestApp

final class AppUpdateControllerTests: XCTestCase {
  private let publicKey = "s0iZUen0dQ8irIs2kGI4ulzWvrqOn18atSGPguAIWHY="

  func testConfigurationAcceptsSignedHTTPSFeedWithManualInstallDefault() throws {
    let configuration = try XCTUnwrap(AppUpdateConfiguration(infoDictionary: [
      "SUFeedURL": "https://github.com/Songxiaor/jizuo/releases/latest/download/appcast.xml",
      "SUPublicEDKey": publicKey,
      "SUAutomaticallyUpdate": false,
    ]))

    XCTAssertEqual(
      configuration.feedURL.absoluteString,
      "https://github.com/Songxiaor/jizuo/releases/latest/download/appcast.xml"
    )
    XCTAssertEqual(configuration.publicEDKey, publicKey)
    XCTAssertFalse(configuration.automaticallyUpdates)
  }

  func testConfigurationRejectsUnsafeOrIncompleteFeedSettings() {
    XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
      "SUFeedURL": "http://example.test/appcast.xml",
      "SUPublicEDKey": publicKey,
      "SUAutomaticallyUpdate": false,
    ]))
    XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
      "SUFeedURL": "https://example.test/appcast.xml",
      "SUPublicEDKey": "not-a-public-key",
      "SUAutomaticallyUpdate": false,
    ]))
    XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
      "SUFeedURL": "https://example.test/appcast.xml",
      "SUPublicEDKey": publicKey,
    ]))
  }

  /// 设置里必须有「版本与更新」，不能只藏在顶部菜单。
  func testSettingsExposesVersionAndUpdateEntry() throws {
    let settings = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(settings.contains("case .updates: \"版本与更新\""))
    XCTAssertTrue(settings.contains(".updates"))
    XCTAssertTrue(settings.contains("AppUpdateSettingsView(updater: updater)"))

    let page = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/AppUpdateSettingsView.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(page.contains("有新版本时提醒我"))
    XCTAssertTrue(page.contains("检查更新"))
    XCTAssertTrue(page.contains("app-update-check"))
    XCTAssertTrue(page.contains("app-update-remind-toggle"))
    XCTAssertTrue(page.contains("不会自己安装"))
    XCTAssertFalse(
      page.contains("automaticallyDownloadsUpdates = true"),
      "设置页不得打开静默下载或静默安装"
    )
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
