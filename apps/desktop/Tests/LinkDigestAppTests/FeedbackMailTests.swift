import XCTest
@testable import LinkDigestApp

/// 「反馈问题」按钮拼出来的收件地址。
///
/// 这条测试防的不是拼串本身，而是**占位地址被当成真地址发出去**：地址原来写的是
/// `feedback@`，而唯一的生产调用点传的是 `releaseConfiguration: nil`，于是那个
/// 占位串会一路走到用户点「写邮件…」才暴露——点开是一封收件人为空的邮件。
/// 所以这里断言的是行为（兜底必须可用、配置优先、畸形配置不生效），不是某个字面量。
final class FeedbackMailTests: XCTestCase {
  func testFallsBackToAUsableAddressWhenNoConfigurationIsInjected() {
    let address = FeedbackMail.address(releaseConfiguration: nil)
    XCTAssertTrue(address.contains("@"), "兜底地址必须能发信，收到的却是「\(address)」")
    XCTAssertFalse(address.hasSuffix("@"), "兜底地址不能是占位串：「\(address)」")
    XCTAssertTrue(address.hasSuffix(".com") || address.hasSuffix(".cn"), "地址要带顶级域：「\(address)」")
  }

  func testInjectedConfigurationWinsOverTheBuiltInAddress() {
    XCTAssertEqual(
      FeedbackMail.address(releaseConfiguration: ["supportEmail": "team@example.test"]),
      "team@example.test"
    )
  }

  func testMalformedConfigurationFallsBackInsteadOfShippingGarbage() {
    let malformed: [Any] = ["", "feedback@", "no-at-sign", 42]
    for value in malformed {
      XCTAssertEqual(
        FeedbackMail.address(releaseConfiguration: ["supportEmail": value]),
        FeedbackMail.supportAddress,
        "配置里的畸形值「\(value)」不该被采用"
      )
    }
  }

  /// 网页版写信不是「另一个入口」，它必须和 mailto 带一样的东西——否则用户在
  /// 只有浏览器的机器上发出来的信里就没有版本信息，而那正是我们要收集的部分。
  func testWebComposeCarriesTheSameSubjectAndBodyAsMailto() throws {
    let environment = DiagnosticsReport.liveEnvironment()
    let address = FeedbackMail.supportAddress
    let mailto = try XCTUnwrap(FeedbackMail.mailtoURL(address: address, environment: environment))
    let web = try XCTUnwrap(FeedbackMail.webComposeURL(address: address, environment: environment))
    let webItems = try XCTUnwrap(URLComponents(url: web, resolvingAgainstBaseURL: false)?.queryItems)
    let mailtoItems = try XCTUnwrap(URLComponents(url: mailto, resolvingAgainstBaseURL: false)?.queryItems)

    XCTAssertEqual(web.scheme, "https")
    XCTAssertEqual(web.host, "mail.google.com")
    XCTAssertEqual(webItems.first { $0.name == "to" }?.value, address)
    XCTAssertEqual(
      webItems.first { $0.name == "su" }?.value,
      mailtoItems.first { $0.name == "subject" }?.value,
      "网页版与 mailto 的主题必须是同一句"
    )
    let webBody = try XCTUnwrap(webItems.first { $0.name == "body" }?.value)
    XCTAssertEqual(webBody, mailtoItems.first { $0.name == "body" }?.value, "两边的正文必须一致")
    XCTAssertTrue(webBody.contains(environment.shortVersion), "正文里要带上版本号")
  }

  /// `mailto:` 落在浏览器上时必须改走网页版；有真邮件应用时不该劫持它。
  func testHandlerKindDecidesWhichComposeEntryIsUsed() throws {
    let address = FeedbackMail.supportAddress
    let environment = DiagnosticsReport.liveEnvironment()

    guard case let .webMail(url) = FeedbackMail.composeTarget(
      address: address, environment: environment, handlerIsWebBrowser: true
    ) else {
      return XCTFail("mailto 落在浏览器上时必须改走网页版写信，否则用户点开只有一片空白")
    }
    XCTAssertEqual(url.host, "mail.google.com")

    guard case let .mailClient(url) = FeedbackMail.composeTarget(
      address: address, environment: environment, handlerIsWebBrowser: false
    ) else {
      return XCTFail("有真正的邮件应用时应当直接用 mailto")
    }
    XCTAssertEqual(url.scheme, "mailto")
    XCTAssertEqual(url.path, address)
  }

  func testMailtoURLAddressesTheSupportInbox() throws {
    let address = FeedbackMail.address(releaseConfiguration: nil)
    let url = try XCTUnwrap(
      FeedbackMail.mailtoURL(address: address, environment: DiagnosticsReport.liveEnvironment())
    )
    XCTAssertEqual(url.scheme, "mailto")
    XCTAssertEqual(url.path, address, "mailto 的收件人必须就是兜底地址")
  }
}
