import Foundation
import XCTest

final class DataAssetsSettingsPresentationTests: XCTestCase {
  func testDataPageIsInConnectionGroupAndExplainsDestructiveAndDiagnosticBoundaries() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let provider = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    let page = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/DataAssetsSettingsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(provider.contains("case service, generation, appearance, mediaStorage, knowledgeVault, data"))
    XCTAssertTrue(provider.contains(".knowledgeVault, .data"))
    XCTAssertTrue(provider.contains("DataAssetsSettingsView(model: dataAssets)"))
    XCTAssertTrue(page.contains("先自动备份，再恢复"))
    XCTAssertTrue(page.contains("任何一步失败都不会覆盖当前数据"))
    XCTAssertTrue(page.contains("退出汲作"))
    XCTAssertTrue(page.contains("不包含密钥、Cookie、Token、历史正文、摘要或完整 URL 列表"))
    XCTAssertTrue(page.contains("不会自动上传"))
  }
}
