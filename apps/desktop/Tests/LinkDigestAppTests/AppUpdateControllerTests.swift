import Foundation
import XCTest

@testable import LinkDigestApp

final class AppUpdateControllerTests: XCTestCase {
  private let publicKey = "s0iZUen0dQ8irIs2kGI4ulzWvrqOn18atSGPguAIWHY="

  func testConfigurationAcceptsSignedHTTPSFeedWithManualInstallDefault() throws {
    let configuration = try XCTUnwrap(AppUpdateConfiguration(infoDictionary: [
      "SUFeedURL": "https://github.com/Songxiaor/linkdigest/releases/latest/download/appcast.xml",
      "SUPublicEDKey": publicKey,
      "SUAutomaticallyUpdate": false,
    ]))

    XCTAssertEqual(
      configuration.feedURL.absoluteString,
      "https://github.com/Songxiaor/linkdigest/releases/latest/download/appcast.xml"
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
}
