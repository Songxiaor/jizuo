import XCTest
@testable import LinkDigestCore

final class ProductDisplayTests: XCTestCase {
  func testBundledDisplayResourceProvidesTheSharedAppAndExtensionNames() {
    XCTAssertEqual(ProductDisplay.name, "汲作")
    XCTAssertEqual(ProductDisplay.extensionDescription, "把当前页面存进汲作")
    XCTAssertEqual(ProductDisplay.extensionName, "汲作 浏览器扩展")
  }
}
