import XCTest
@testable import LinkDigestCore

final class ProductDisplayTests: XCTestCase {
  func testBundledDisplayResourceProvidesTheSharedAppAndExtensionNames() {
    XCTAssertEqual(ProductDisplay.name, "LinkDigest")
    XCTAssertEqual(ProductDisplay.extensionDescription, "Send the current page to LinkDigest")
    XCTAssertEqual(ProductDisplay.extensionName, "LinkDigest 浏览器扩展")
  }
}
