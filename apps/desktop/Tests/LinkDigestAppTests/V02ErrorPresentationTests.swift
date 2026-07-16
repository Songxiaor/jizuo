import XCTest
@testable import LinkDigestApp
import LinkDigestCore

final class V02ErrorPresentationTests: XCTestCase {
  func testEveryStableCodeHasMessageAndRecoveryAction() {
    XCTAssertEqual(V02ErrorCatalog.allStableCodes.count, 23)

    for code in V02ErrorCatalog.allStableCodes {
      let presentation = V02ErrorCatalog.presentation(for: code)
      XCTAssertFalse(presentation.message.isEmpty, "Missing message for \(code)")
      XCTAssertFalse(presentation.recoveryAction.isEmpty, "Missing recovery for \(code)")
      XCTAssertFalse(presentation.visibleText.contains(code), "Internal code leaked for \(code)")
    }
  }

  func testCriticalProviderFailuresGiveRequiredRecoveryActions() {
    let auth = V02ErrorCatalog.presentation(for: ModelProviderErrorCode.authInvalid.rawValue)
    XCTAssertTrue(auth.recoveryAction.contains("更新 API Key"))

    let rateLimit = V02ErrorCatalog.presentation(for: ModelProviderErrorCode.rateLimited.rawValue)
    XCTAssertTrue(rateLimit.recoveryAction.contains("稍后重试或更换模型服务"))

    let unavailable = V02ErrorCatalog.presentation(
      for: ModelProviderErrorCode.providerUnavailable.rawValue
    )
    XCTAssertTrue(unavailable.message.contains("Provider 暂时不可用"))
    XCTAssertTrue(unavailable.recoveryAction.contains("稍后重试"))

    let protocolFailure = V02ErrorCatalog.presentation(
      for: ModelProviderErrorCode.protocolIncompatible.rawValue
    )
    XCTAssertTrue(
      protocolFailure.recoveryAction.contains(
        "检查 Base URL 是否是 OpenAI-compatible Chat Completions API root"
      )
    )
  }

  func testUnknownInputNeverEchoesCodeBodyHeaderSecretOrPrivateURL() {
    let sentinel = "sentinel-\(UUID().uuidString)"
    let privateURL = "https://private.example.test/account?token=\(sentinel)"
    let untrustedInputs = [
      "MODEL_VENDOR_PRIVATE_FAILURE",
      "provider raw body: {\"error\":\"\(sentinel)\"}",
      "Authorization: Bearer \(sentinel)",
      "X-Provider-Trace: \(sentinel)",
      privateURL
    ]

    for rawInput in untrustedInputs {
      let presentation = V02ErrorCatalog.presentation(for: rawInput)

      XCTAssertEqual(
        presentation.visibleText,
        "操作未完成。 请检查模型配置和网络后重试。"
      )
      XCTAssertFalse(presentation.visibleText.contains(rawInput))
      XCTAssertFalse(presentation.visibleText.contains(sentinel))
      XCTAssertFalse(presentation.visibleText.contains("Authorization"))
      XCTAssertFalse(presentation.visibleText.contains("X-Provider-Trace"))
      XCTAssertFalse(presentation.visibleText.contains("provider raw body"))
      XCTAssertFalse(presentation.visibleText.contains(privateURL))
    }
  }
}
